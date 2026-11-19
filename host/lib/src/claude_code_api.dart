import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'package:remote_ai_sync/src/domain/models.dart';
import 'agent_executable_resolver.dart';

class ClaudeCodeApi {
  ClaudeCodeApi({
    required this.executable,
    required this.projectsDirectory,
    required this.version,
    ClaudeProcessLauncher? processLauncher,
  }) : _processLauncher = processLauncher ?? _startProcess;

  final String executable;
  final Directory projectsDirectory;
  final String version;
  final ClaudeProcessLauncher _processLauncher;
  final Map<String, File> _transcripts = {};
  final Map<String, HostSession> _pendingSessions = {};
  final Map<String, Process> _activeProcesses = {};
  final Set<String> _interruptedSessions = {};
  final Map<String, String> _modelOverrides = {};
  final Map<String, String> _effortOverrides = {};
  final Map<String, AgentMessage> _streamingMessages = {};
  final Map<String, String?> _transcriptModels = {};

  static Future<ClaudeCodeApi> start({
    String executable = 'claude',
    Directory? projectsDirectory,
  }) async {
    final resolvedExecutable = await resolveAgentExecutable(executable);
    if (resolvedExecutable == null) {
      throw AgentExecutableNotFoundException(executable);
    }
    final result = await Process.run(resolvedExecutable, const ['--version']);
    if (result.exitCode != 0) {
      throw ClaudeCodeException(
        'Claude Code CLI 已找到，但版本检查失败：${_stderr(result.stderr, '命令返回失败。')}',
      );
    }
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    final root =
        projectsDirectory ??
        Directory(
          p.join(home ?? Directory.current.path, '.claude', 'projects'),
        );
    return ClaudeCodeApi(
      executable: resolvedExecutable,
      projectsDirectory: root,
      version: _stdout(result.stdout, 'Claude Code'),
    );
  }

  Future<List<HostSession>> listSessions({
    required String directory,
    required bool global,
  }) async {
    final sessions = <HostSession>[];
    _transcripts.clear();
    if (await projectsDirectory.exists()) {
      await for (final entity in projectsDirectory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.jsonl')) {
          continue;
        }
        final match = RegExp(
          r'([0-9a-fA-F-]{36})\.jsonl$',
        ).firstMatch(entity.path);
        if (match == null) continue;
        try {
          final transcript = await _readTranscript(entity);
          if (transcript.directory == null ||
              (!global && !_sameDirectory(transcript.directory!, directory))) {
            continue;
          }
          final id = 'claude:${match.group(1)}';
          _transcripts[id] = entity;
          sessions.add(
            HostSession(
              id: id,
              agentId: 'claude',
              title: transcript.title ?? 'Claude Code 会话',
              updatedAt: _timeLabel(await entity.lastModified()),
              directory: transcript.directory,
            ),
          );
        } on FileSystemException {
          continue;
        }
      }
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final persistedIds = sessions.map((session) => session.id).toSet();
    for (final entry in _pendingSessions.entries.toList()) {
      if (persistedIds.contains(entry.key)) {
        _pendingSessions.remove(entry.key);
      } else {
        sessions.add(entry.value);
      }
    }
    return sessions;
  }

  Future<List<AgentMessage>> listMessages(String sessionId) async {
    final file = _transcripts[sessionId] ?? await _findTranscript(sessionId);
    final messages = <AgentMessage>[];
    var turn = 0;
    var lineNumber = 0;
    if (file != null) {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        lineNumber++;
        final entry = _decodeEntry(line);
        if (entry == null) continue;
        final type = entry['type'];
        if (type == 'user') {
          final content = _contentBlocks(
            entry['message'] is Map
                ? (entry['message'] as Map)['content']
                : null,
          );
          final text = _textContent(content);
          final tools = _toolResults(content, 'claude-turn-$turn', lineNumber);
          if (text.isNotEmpty) {
            messages.add(
              _message(
                '$sessionId-user-$lineNumber',
                MessageAuthor.user,
                text,
                entry,
              ),
            );
            turn++;
          }
          messages.addAll(tools);
        } else if (type == 'assistant') {
          final message = entry['message'];
          if (message is! Map) continue;
          final content = _contentBlocks(message['content']);
          final text = _textContent(content);
          if (text.isNotEmpty) {
            messages.add(
              _message(
                '$sessionId-assistant-$lineNumber',
                MessageAuthor.assistant,
                text,
                entry,
              ),
            );
          }
          for (var blockIndex = 0; blockIndex < content.length; blockIndex++) {
            final block = content[blockIndex];
            if (block['type'] != 'tool_use') continue;
            final input = block['input'];
            messages.add(
              _message(
                '$sessionId-tool-$lineNumber-$blockIndex',
                MessageAuthor.tool,
                '${block['name'] ?? 'Tool'}\n${const JsonEncoder.withIndent('  ').convert(input ?? const {})}',
                entry,
                groupId: 'claude-turn-$turn',
              ),
            );
          }
        }
      }
    }
    final streaming = _streamingMessages[sessionId];
    if (streaming != null &&
        (messages.isEmpty ||
            messages.last.author != MessageAuthor.assistant ||
            messages.last.text != streaming.text)) {
      messages.add(streaming);
    }
    return messages;
  }

  Future<Map<String, Object?>> controls(String sessionId) async {
    final model =
        _modelOverrides[sessionId] ?? await _latestTranscriptModel(sessionId);
    return {
      'models': [
        for (final alias in const ['sonnet', 'opus', 'haiku', 'fable'])
          {
            'id': alias,
            'name': alias[0].toUpperCase() + alias.substring(1),
            'efforts': const ['low', 'medium', 'high', 'xhigh', 'max'],
            'defaultEffort': 'medium',
          },
        if (model != null &&
            !const {'sonnet', 'opus', 'haiku', 'fable'}.contains(model))
          {
            'id': model,
            'name': model,
            'efforts': const ['low', 'medium', 'high', 'xhigh', 'max'],
            'defaultEffort': 'medium',
          },
      ],
      'skills': const <String>[],
      'settings': {
        'model': model,
        'effort': _effortOverrides[sessionId] ?? 'medium',
        'running': _activeProcesses.containsKey(_rawSessionId(sessionId)),
      },
    };
  }

  void updateSettings(
    String sessionId, {
    required String model,
    required String effort,
  }) {
    if (model.trim().isEmpty) {
      _modelOverrides.remove(sessionId);
    } else {
      _modelOverrides[sessionId] = model.trim();
    }
    if (effort.trim().isEmpty) {
      _effortOverrides.remove(sessionId);
    } else {
      _effortOverrides[sessionId] = effort.trim();
    }
  }

  Future<String?> _latestTranscriptModel(String sessionId) async {
    if (_transcriptModels.containsKey(sessionId)) {
      return _transcriptModels[sessionId];
    }
    final file = _transcripts[sessionId] ?? await _findTranscript(sessionId);
    if (file == null) return null;
    String? model;
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final entry = _decodeEntry(line);
      if (entry?['type'] != 'assistant') continue;
      final message = entry?['message'];
      if (message is Map && message['model'] is String) {
        model = (message['model'] as String).trim();
      }
    }
    final normalized = model?.isEmpty == true ? null : model;
    _transcriptModels[sessionId] = normalized;
    return normalized;
  }

  Future<String> createSession(String directory) async {
    final id = _uuidV4();
    final session = HostSession(
      id: 'claude:$id',
      agentId: 'claude',
      remoteManaged: true,
      title: '新建 Claude Code 会话',
      updatedAt: _timeLabel(DateTime.now()),
      directory: directory,
    );
    _pendingSessions[session.id] = session;
    return session.id;
  }

  Future<void> sendMessage(
    String sessionId,
    String text, {
    required String directory,
    void Function()? onTranscriptChanged,
  }) async {
    final rawId = _rawSessionId(sessionId);
    final arguments = await buildSendArguments(sessionId, text);
    if (_activeProcesses.containsKey(rawId)) {
      throw const ClaudeCodeException('此 Claude Code 会话已有远程请求正在运行。');
    }
    final process = await _processLauncher(
      executable,
      arguments,
      workingDirectory: directory,
      runInShell: Platform.isWindows,
    );
    _activeProcesses[rawId] = process;
    final stderr = StringBuffer();
    final stream = StringBuffer();
    var streamReportedError = false;
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write)
        .asFuture<void>();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          final event = _decodeEntry(line);
          final rawEvent = event?['event'];
          if (event?['type'] == 'stream_event' && rawEvent is Map) {
            final delta = rawEvent['delta'];
            final fragment = delta is Map && delta['type'] == 'text_delta'
                ? delta['text']?.toString()
                : null;
            if (fragment != null && fragment.isNotEmpty) {
              stream.write(fragment);
              _streamingMessages[sessionId] = AgentMessage(
                id: '$sessionId-streaming',
                author: MessageAuthor.assistant,
                text: stream.toString(),
                time: _timeLabel(DateTime.now()),
              );
              onTranscriptChanged?.call();
            }
          }
          if (event?['type'] == 'result' && event?['is_error'] == true) {
            streamReportedError = true;
            stderr.writeln(event?['result'] ?? 'Claude Code 请求失败。');
          }
        });
    try {
      await Future.wait([stdoutDone, stderrDone]);
      final code = await process.exitCode;
      final interrupted = _interruptedSessions.remove(rawId);
      if (!interrupted && (code != 0 || streamReportedError)) {
        throw ClaudeCodeException(
          _stderr(stderr.toString(), 'Claude Code 退出，代码 $code。'),
        );
      }
    } finally {
      _interruptedSessions.remove(rawId);
      _activeProcesses.remove(rawId);
      _streamingMessages.remove(sessionId);
      _transcriptModels.remove(sessionId);
      onTranscriptChanged?.call();
    }
  }

  Future<List<String>> buildSendArguments(String sessionId, String text) async {
    final rawId = _rawSessionId(sessionId);
    final transcript =
        _transcripts[sessionId] ?? await _findTranscript(sessionId);
    return <String>[
      '--print',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      if (_modelOverrides[sessionId] case final model?) ...['--model', model],
      if (_effortOverrides[sessionId] case final effort?) ...[
        '--effort',
        effort,
      ],
      if (transcript == null) ...[
        '--session-id',
        rawId,
      ] else ...[
        '--resume',
        rawId,
      ],
      text,
    ];
  }

  Future<void> interruptSession(String sessionId) async {
    final id = _rawSessionId(sessionId);
    final process = _activeProcesses[id];
    if (process == null) {
      throw const ClaudeCodeException('当前没有由 RemoteAISync 启动的 Claude 请求。');
    }
    _interruptedSessions.add(id);
    if (!process.kill(ProcessSignal.sigint)) {
      _interruptedSessions.remove(id);
      throw const ClaudeCodeException('Claude Code 请求无法停止。');
    }
  }

  Future<File?> _findTranscript(String id) async {
    if (!await projectsDirectory.exists()) return null;
    final rawId = _rawSessionId(id);
    await for (final entity in projectsDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && p.basenameWithoutExtension(entity.path) == rawId) {
        _transcripts[id] = entity;
        return entity;
      }
    }
    return null;
  }

  Future<_ClaudeTranscript> _readTranscript(File file) async {
    String? directory;
    String? title;
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final entry = _decodeEntry(line);
      if (entry == null) continue;
      directory ??= entry['cwd']?.toString();
      if (entry['type'] == 'user' && title == null) {
        final message = entry['message'];
        final content = message is Map ? message['content'] : null;
        final text = _textContent(_contentBlocks(content));
        if (text.isNotEmpty) {
          title = text.replaceAll(RegExp(r'\s+'), ' ').trim();
        }
      }
      if (directory != null && title != null) break;
    }
    return _ClaudeTranscript(directory: directory, title: title);
  }

  static List<Map<String, dynamic>> _contentBlocks(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
    }
    if (value is String && value.isNotEmpty) {
      return [
        {'type': 'text', 'text': value},
      ];
    }
    return const [];
  }

  static String _textContent(List<Map<String, dynamic>> blocks) => blocks
      .where((block) => block['type'] == 'text')
      .map((block) => block['text']?.toString() ?? '')
      .where((text) => text.trim().isNotEmpty)
      .join('\n')
      .trim();

  static List<AgentMessage> _toolResults(
    List<Map<String, dynamic>> blocks,
    String groupId,
    int lineNumber,
  ) => [
    for (var index = 0; index < blocks.length; index++)
      if (blocks[index]['type'] == 'tool_result')
        AgentMessage(
          id: 'claude-tool-result-$lineNumber-$index-${blocks[index]['tool_use_id'] ?? ''}',
          author: MessageAuthor.tool,
          text: _toolResultText(blocks[index]['content']),
          time: '',
          groupId: groupId,
        ),
  ];

  static String _toolResultText(Object? value) {
    if (value is String) return value;
    if (value is List) return _textContent(_contentBlocks(value));
    return value?.toString() ?? '';
  }

  static AgentMessage _message(
    String id,
    MessageAuthor author,
    String text,
    Map<String, dynamic> entry, {
    String? groupId,
  }) => AgentMessage(
    id: id,
    author: author,
    text: text,
    time: entry['timestamp']?.toString() ?? '',
    groupId: groupId,
  );

  static Map<String, dynamic>? _decodeEntry(String line) {
    try {
      final value = jsonDecode(line);
      return value is Map ? value.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  static String _rawSessionId(String id) =>
      id.startsWith('claude:') ? id.substring(7) : id;

  static bool _sameDirectory(String left, String right) {
    final a = p.normalize(p.absolute(left));
    final b = p.normalize(p.absolute(right));
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  static String _timeLabel(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static String _stdout(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static String _stderr(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required bool runInShell,
  }) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: runInShell,
  );

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

typedef ClaudeProcessLauncher =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required bool runInShell,
    });

class _ClaudeTranscript {
  const _ClaudeTranscript({this.directory, this.title});
  final String? directory;
  final String? title;
}

class ClaudeCodeException implements Exception {
  const ClaudeCodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

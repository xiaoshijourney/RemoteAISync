import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:remote_ai_sync/src/domain/models.dart';
import 'agent_executable_resolver.dart';

/// A local, per-bridge Codex app-server client. It never exposes app-server
/// directly on the network; the paired bridge remains the only remote entry.
class CodexApi {
  CodexApi._(this._process, this.projectDirectory, this.version) {
    _sessionScopeDirectory = projectDirectory;
    _stdout = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_receive);
    _stderr = _process.stderr.drain<void>();
    _process.exitCode.then((_) => _failPending('Codex app-server 已退出。'));
  }

  final Process _process;
  final String projectDirectory;
  final String version;
  late final StreamSubscription<String> _stdout;
  late final Future<void> _stderr;
  final _events = StreamController<void>.broadcast();
  final Map<int, Completer<Object?>> _pending = {};
  final Map<String, _CodexRequest> _requests = {};
  final Map<String, Map<String, dynamic>> _items = {};
  final Map<String, String> _turnDiffs = {};
  final Map<String, Map<String, _LiveCodexItem>> _liveItems = {};
  final Map<String, Map<String, AgentMessage>> _liveTurnErrors = {};
  final Set<String> _loadedThreads = {};
  final Set<String> _startedThreads = {};
  final Map<String, String> _activeTurns = {};
  final Map<String, String> _completedTurns = {};
  final Map<String, HostSession> _newSessions = {};
  final Map<String, HostSession> _ephemeralSessions = {};
  late String _sessionScopeDirectory;
  List<HostSession> _cachedPersistedSessions = const [];
  DateTime? _lastSessionScan;
  bool _usedGlobalSessionScan = false;
  int _nextId = 1;
  bool _closed = false;

  Stream<void> get events => _events.stream;

  int pendingCountFor(String sessionId) {
    final threadId = _threadId(sessionId);
    return _requests.values
        .where((request) => request.threadId == threadId)
        .length;
  }

  void invalidateSessionCache() => _lastSessionScan = null;

  void setSessionScopeDirectory(String directory) {
    _sessionScopeDirectory = directory == '*'
        ? '*'
        : p.normalize(p.absolute(directory));
    invalidateSessionCache();
  }

  Future<List<Map<String, Object?>>> listModels() async {
    final models = <Map<String, Object?>>[];
    String? cursor;
    final seen = <String>{};
    for (var page = 0; page < 10; page++) {
      final result = _map(
        await _request('model/list', {'limit': 100, 'cursor': ?cursor}),
      );
      for (final item
          in (result['data'] as List? ?? const []).whereType<Map>()) {
        final model = _map(item);
        final id = model['model']?.toString() ?? model['id']?.toString();
        if (id == null || id.isEmpty || model['hidden'] == true) continue;
        models.add({
          'id': id,
          'name': model['displayName']?.toString() ?? id,
          'defaultEffort': model['defaultReasoningEffort']?.toString(),
          'efforts': (model['supportedReasoningEfforts'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => item['reasoningEffort']?.toString())
              .whereType<String>()
              .toList(),
        });
      }
      final next = result['nextCursor']?.toString();
      if (next == null || next.isEmpty || !seen.add(next)) break;
      cursor = next;
    }
    return models;
  }

  Future<List<String>> listSkills({String? directory}) async {
    return (await _listSkillRecords(directory: directory))
        .map((skill) => skill['name']?.toString())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<List<Map<String, dynamic>>> _listSkillRecords({
    String? directory,
  }) async {
    final result = _map(
      await _request('skills/list', {
        'cwds': [directory ?? projectDirectory],
      }),
    );
    return (result['data'] as List? ?? const [])
        .whereType<Map>()
        .expand(
          (entry) => (entry['skills'] as List? ?? const []).whereType<Map>(),
        )
        .map(_map)
        .where((skill) => skill['enabled'] != false)
        .toList();
  }

  Future<List<Map<String, Object?>>> _skillInputFor(
    String text, {
    String? directory,
  }) async {
    final match = RegExp(r'^\$([^\s]+)').firstMatch(text.trimLeft());
    if (match == null) return const [];
    final name = match.group(1);
    for (final skill in await _listSkillRecords(directory: directory)) {
      final path = skill['path']?.toString();
      if (skill['name'] == name && path != null && path.isNotEmpty) {
        return [
          {'type': 'skill', 'name': name, 'path': path},
        ];
      }
    }
    return const [];
  }

  Future<Map<String, Object?>> readSettings(String sessionId) async {
    final threadId = _threadId(sessionId);
    final result = _map(
      await _request('thread/read', {
        'threadId': threadId,
        'includeTurns': false,
      }),
    );
    final thread = _map(result['thread']);
    return {
      'model': thread['model']?.toString(),
      'effort': thread['reasoningEffort']?.toString(),
      'running': _activeTurns.containsKey(threadId),
    };
  }

  Future<void> updateSettings(
    String sessionId, {
    required String model,
    required String effort,
  }) async {
    final threadId = _threadId(sessionId);
    final models = await listModels();
    final matching = models.where((item) => item['id'] == model);
    if (matching.isEmpty ||
        !(matching.first['efforts'] as List).contains(effort)) {
      throw const CodexApiException('所选模型或思考强度不可用。');
    }
    await _request('thread/settings/update', {
      'threadId': threadId,
      'model': model,
      'effort': effort,
    });
    final activeTurn = _activeTurns[threadId];
    if (activeTurn != null) {
      await _request('turn/settings/update', {
        'threadId': threadId,
        'turnId': activeTurn,
        'model': model,
        'effort': effort,
      });
    }
    _events.add(null);
  }

  Future<void> interrupt(String sessionId) async {
    final threadId = _threadId(sessionId);
    final turnId = _activeTurns[threadId];
    if (turnId == null) {
      throw const CodexApiException('此会话当前没有正在运行的回复。');
    }
    await _request('turn/interrupt', {'threadId': threadId, 'turnId': turnId});
  }

  Future<void> compact(String sessionId) async {
    final threadId = _threadId(sessionId);
    await _ensureThreadLoaded(threadId);
    await _request('thread/compact/start', {'threadId': threadId});
    _events.add(null);
  }

  Future<void> reviewUncommitted(String sessionId) async {
    final threadId = _threadId(sessionId);
    await _ensureThreadLoaded(threadId);
    final result = _map(
      await _request('review/start', {
        'threadId': threadId,
        'target': {'type': 'uncommittedChanges'},
        'delivery': 'inline',
      }),
    );
    final turnId = _map(result['turn'])['id']?.toString();
    if (turnId != null && _completedTurns[threadId] != turnId) {
      _activeTurns[threadId] = turnId;
    }
    _startedThreads.add(threadId);
    _events.add(null);
  }

  static Future<CodexApi> start({
    required String projectDirectory,
    String executable = 'codex',
  }) async {
    final cwd = p.normalize(p.absolute(projectDirectory));
    final resolvedExecutable = await resolveAgentExecutable(executable);
    if (resolvedExecutable == null) {
      throw AgentExecutableNotFoundException(executable);
    }
    final versionResult = await Process.run(resolvedExecutable, ['--version']);
    if (versionResult.exitCode != 0) {
      throw CodexApiException('Codex CLI 已找到，但版本检查失败：${versionResult.stderr}');
    }
    final process = await Process.start(resolvedExecutable, [
      'app-server',
      '--listen',
      'stdio://',
    ], workingDirectory: cwd);
    return attach(
      process,
      projectDirectory: cwd,
      version: versionResult.stdout.toString().trim(),
    );
  }

  /// Attaches to a local app-server process. Also used by protocol tests.
  static Future<CodexApi> attach(
    Process process, {
    required String projectDirectory,
    required String version,
  }) async {
    final api = CodexApi._(
      process,
      p.normalize(p.absolute(projectDirectory)),
      version,
    );
    try {
      await api._request('initialize', {
        'capabilities': {'experimentalApi': true},
        'clientInfo': {
          'name': 'remoteaisync',
          'title': 'RemoteAISync',
          'version': '0.1.0',
        },
      });
      api._write({'method': 'initialized'});
      return api;
    } catch (_) {
      await api.close();
      rethrow;
    }
  }

  Future<List<HostSession>> listSessions() async {
    final now = DateTime.now();
    final refreshAfter = _usedGlobalSessionScan
        ? const Duration(seconds: 10)
        : const Duration(seconds: 2);
    if (_lastSessionScan == null ||
        now.difference(_lastSessionScan!) >= refreshAfter) {
      final exact = _sessionScopeDirectory == '*'
          ? await _listThreadPages(maxPages: 10)
          : await _listThreadPages(cwd: _sessionScopeDirectory, maxPages: 4);
      var matching = _uniqueProjectThreads(exact);
      _usedGlobalSessionScan =
          _sessionScopeDirectory != '*' &&
          Platform.isWindows &&
          matching.isEmpty;
      if (_usedGlobalSessionScan) {
        // app-server's cwd filter is exact; Windows path spelling is not.
        final all = await _listThreadPages(maxPages: 10);
        matching = _uniqueProjectThreads(all);
      }
      _cachedPersistedSessions = matching
          .map((item) {
            final title = item['name']?.toString().trim();
            final preview = item['preview']?.toString().trim() ?? '';
            final heading = title?.isNotEmpty == true
                ? title!
                : preview.isNotEmpty
                ? preview.split('\n').first
                : '未命名 Codex 会话';
            final stamp = item['updatedAt'];
            final date = stamp is num
                ? DateTime.fromMillisecondsSinceEpoch(stamp.toInt() * 1000)
                : DateTime.now();
            return HostSession(
              id: 'codex:${item['id']}',
              agentId: 'codex',
              remoteManaged:
                  item['threadSource'] == 'remoteaisync' ||
                  (_newSessions['${item['id']}']?.remoteManaged ?? false),
              directory: item['cwd']?.toString(),
              title: heading.length > 80
                  ? '${heading.substring(0, 80)}…'
                  : heading,
              updatedAt:
                  '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
            );
          })
          .toList(growable: false);
      _lastSessionScan = DateTime.now();
    }
    final persistedIds = _cachedPersistedSessions
        .map((session) => session.id)
        .toSet();
    _newSessions.removeWhere((id, _) => persistedIds.contains('codex:$id'));
    return [
      ..._cachedPersistedSessions,
      ..._newSessions.values,
      ..._ephemeralSessions.values,
    ];
  }

  List<Map<String, dynamic>> _uniqueProjectThreads(
    List<Map<String, dynamic>> rows,
  ) {
    final seen = <String>{};
    return rows.where((item) {
      if (_sessionScopeDirectory == '*') {
        if (!_hasDirectory(item)) return false;
      } else if (!_isDirectoryThread(item, _sessionScopeDirectory)) {
        return false;
      }
      return seen.add(item['id'] as String);
    }).toList();
  }

  bool _hasDirectory(Map<String, dynamic> item) => item['cwd'] is String;

  bool _isDirectoryThread(Map<String, dynamic> item, String directory) {
    final cwd = item['cwd'];
    if (item['id'] is! String || cwd is! String) return false;
    try {
      final normalized = p.normalize(p.absolute(cwd));
      final target = p.normalize(p.absolute(directory));
      return Platform.isWindows
          ? normalized.toLowerCase() == target.toLowerCase()
          : normalized == target;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _listThreadPages({
    String? cwd,
    required int maxPages,
  }) async {
    final rows = <Map<String, dynamic>>[];
    final seenCursors = <String>{};
    String? cursor;
    for (var page = 0; page < maxPages; page++) {
      final params = <String, Object?>{
        'limit': 50,
        'sourceKinds': ['cli', 'vscode', 'exec', 'appServer', 'unknown'],
        'modelProviders': <String>[],
        'sortKey': 'recency_at',
        'sortDirection': 'desc',
      };
      if (cwd != null) params['cwd'] = cwd;
      if (cursor != null) params['cursor'] = cursor;
      final result = _map(await _request('thread/list', params));
      rows.addAll(
        (result['data'] as List? ?? const []).whereType<Map>().map(_map),
      );
      final next = result['nextCursor']?.toString();
      if (next == null || next.isEmpty || !seenCursors.add(next)) break;
      cursor = next;
    }
    return rows;
  }

  Future<List<AgentMessage>> listMessages(String sessionId) async {
    final threadId = _threadId(sessionId);
    if (_ephemeralSessions.containsKey(threadId)) {
      final messages = <AgentMessage>[];
      _mergeLiveMessages(threadId, messages, const {});
      _mergeTurnErrors(threadId, messages);
      return messages.length <= 100
          ? messages
          : messages.sublist(messages.length - 100);
    }
    if (_newSessions.containsKey(threadId) &&
        !_startedThreads.contains(threadId)) {
      return const [];
    }
    Map<String, dynamic> result;
    try {
      result = _map(
        await _request('thread/turns/list', {
          'threadId': threadId,
          'limit': 20,
          'itemsView': 'full',
          'sortDirection': 'desc',
        }),
      );
    } on CodexApiException catch (error) {
      // A new thread can briefly have an empty rollout while Codex writes its
      // first turn. Keep the live stream visible until the next refresh.
      if (!_newSessions.containsKey(threadId) ||
          !_startedThreads.contains(threadId) ||
          !error.message.contains('rollout at') ||
          !error.message.contains('is empty')) {
        rethrow;
      }
      final live = <AgentMessage>[];
      _mergeLiveMessages(threadId, live, const {});
      _mergeTurnErrors(threadId, live);
      return live.length <= 100 ? live : live.sublist(live.length - 100);
    }
    final turns = (result['data'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final messages = <AgentMessage>[];
    final persistedItems = <String, Map<String, dynamic>>{};
    for (final turn in turns.reversed) {
      final stamp = turn['startedAt'];
      final date = stamp is num
          ? DateTime.fromMillisecondsSinceEpoch(stamp.toInt() * 1000)
          : DateTime.now();
      final time =
          '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      for (final item
          in (turn['items'] as List? ?? const []).whereType<Map>()) {
        final itemId = item['id']?.toString();
        if (itemId != null) persistedItems[itemId] = _map(item);
        final type = item['type']?.toString();
        final text = _codexItemText(item);
        if (text.trim().isEmpty) continue;
        messages.add(
          AgentMessage(
            id: item['id']?.toString() ?? '${turn['id']}:${messages.length}',
            author: _codexItemAuthor(type),
            text: text,
            time: time,
            groupId: turn['id']?.toString(),
          ),
        );
      }
      final error = _map(turn['error']);
      final message = error['message']?.toString();
      if (message?.isNotEmpty == true) {
        final details = error['additionalDetails']?.toString();
        messages.add(
          AgentMessage(
            id: '${turn['id']}:error',
            author: MessageAuthor.system,
            text: [
              'Codex 错误：$message',
              if (details?.isNotEmpty == true) details,
            ].join('\n'),
            time: time,
          ),
        );
      }
    }
    await _mergeLatestThreadItems(threadId, messages, persistedItems);
    _mergeLiveMessages(threadId, messages, persistedItems);
    _mergeTurnErrors(threadId, messages);
    final visible = messages.length <= 100
        ? messages
        : messages.sublist(messages.length - 100);
    return visible;
  }

  Future<void> _mergeLatestThreadItems(
    String threadId,
    List<AgentMessage> messages,
    Map<String, Map<String, dynamic>> persistedItems,
  ) async {
    List<Map<String, dynamic>> entries;
    try {
      final result = _map(
        await _request('thread/items/list', {
          'threadId': threadId,
          'limit': 100,
          'sortDirection': 'desc',
        }),
      );
      entries = (result['data'] as List? ?? const [])
          .whereType<Map>()
          .map(_map)
          .toList();
    } on CodexApiException {
      // Older app-server builds can still show completed turns.
      return;
    }
    if (entries.isEmpty) return;
    final latestTurnId = entries.first['turnId']?.toString();
    if (latestTurnId == null || latestTurnId.isEmpty) return;
    final positions = <String, int>{
      for (var index = 0; index < messages.length; index++)
        messages[index].id: index,
    };
    for (final entry in entries.reversed) {
      if (entry['turnId']?.toString() != latestTurnId) continue;
      final item = _map(entry['item']);
      final itemId = item['id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      final text = _codexItemText(item);
      if (text.trim().isEmpty) continue;
      final position = positions[itemId];
      if (position != null && messages[position].text.length >= text.length) {
        continue;
      }
      final stamp = entry['startedAtMs'] ?? entry['completedAtMs'];
      final message = AgentMessage(
        id: itemId,
        author: _codexItemAuthor(item['type']?.toString()),
        text: text,
        time: position == null
            ? _timeFromMilliseconds(stamp)
            : messages[position].time,
        groupId: entry['turnId']?.toString(),
      );
      persistedItems[itemId] = item;
      if (position == null) {
        positions[itemId] = messages.length;
        messages.add(message);
      } else {
        messages[position] = message;
      }
    }
  }

  void _mergeTurnErrors(String threadId, List<AgentMessage> messages) {
    final errors = _liveTurnErrors[threadId];
    if (errors == null) return;
    final seen = messages.map((message) => message.id).toSet();
    for (final error in errors.values) {
      if (seen.add(error.id)) messages.add(error);
    }
  }

  void _mergeLiveMessages(
    String threadId,
    List<AgentMessage> messages,
    Map<String, Map<String, dynamic>> persistedItems,
  ) {
    final live = _liveItems[threadId];
    if (live == null) return;
    final positions = <String, int>{
      for (var index = 0; index < messages.length; index++)
        messages[index].id: index,
    };
    for (final entry in live.entries.toList()) {
      final item = entry.value;
      var text = _codexItemText(item.value);
      final persisted = persistedItems[entry.key];
      if (persisted != null) {
        final savedText = _codexItemText(persisted);
        if (savedText.length >= text.length) {
          if (item.completed) {
            live.remove(entry.key);
          } else {
            // A subsequent delta must continue from the latest full snapshot.
            item.value = Map<String, dynamic>.from(persisted);
          }
          continue;
        }
      }
      if (text.trim().isEmpty) continue;
      final message = AgentMessage(
        id: entry.key,
        author: _codexItemAuthor(item.value['type']?.toString()),
        text: text,
        time: item.time,
        groupId: item.turnId,
      );
      final position = positions[entry.key];
      if (position == null) {
        positions[entry.key] = messages.length;
        messages.add(message);
      } else {
        messages[position] = message;
      }
    }
    if (live.isEmpty) _liveItems.remove(threadId);
  }

  void _rememberLiveItem(
    String threadId,
    String turnId,
    Map<String, dynamic> value, {
    required bool completed,
  }) {
    final itemId = value['id']?.toString();
    if (itemId == null || itemId.isEmpty) return;
    final items = _liveItems.putIfAbsent(threadId, () => {});
    final previous = items[itemId];
    if (previous == null) {
      items[itemId] = _LiveCodexItem(
        turnId,
        Map<String, dynamic>.from(value),
        _timeFromMilliseconds(value['startedAtMs']),
        completed,
      );
    } else {
      for (final field in value.entries) {
        final oldValue = previous.value[field.key];
        if (!completed &&
            oldValue is String &&
            (field.key == 'text' || field.key == 'aggregatedOutput') &&
            (field.value == null ||
                (field.value is String &&
                    field.value.toString().length < oldValue.length))) {
          continue;
        }
        if (!completed &&
            field.key == 'summary' &&
            oldValue is List &&
            field.value is List &&
            field.value.toString().length < oldValue.toString().length) {
          continue;
        }
        previous.value[field.key] = field.value;
      }
      previous.completed = previous.completed || completed;
    }
    while (items.length > 120) {
      items.remove(items.keys.first);
    }
  }

  void _appendLiveDelta(String method, Map<String, dynamic> params) {
    final threadId = params['threadId']?.toString();
    final turnId = params['turnId']?.toString();
    final itemId = params['itemId']?.toString();
    final delta = params['delta'];
    if (threadId == null ||
        turnId == null ||
        itemId == null ||
        delta is! String ||
        delta.isEmpty) {
      return;
    }
    final type = switch (method) {
      'item/agentMessage/delta' => 'agentMessage',
      'item/commandExecution/outputDelta' => 'commandExecution',
      'item/reasoning/summaryTextDelta' => 'reasoning',
      _ => null,
    };
    if (type == null) return;
    final items = _liveItems.putIfAbsent(threadId, () => {});
    final item = items.putIfAbsent(
      itemId,
      () => _LiveCodexItem(
        turnId,
        {'id': itemId, 'type': type},
        _timeFromMilliseconds(null),
        false,
      ),
    );
    if (type == 'reasoning') {
      final index = params['summaryIndex'];
      if (index is! int || index < 0 || index > 20) return;
      final summary = List<String>.from(item.value['summary'] as List? ?? []);
      while (summary.length <= index) {
        summary.add('');
      }
      summary[index] += delta;
      item.value['summary'] = summary;
    } else {
      final field = type == 'commandExecution' ? 'aggregatedOutput' : 'text';
      item.value[field] = '${item.value[field] ?? ''}$delta';
    }
    while (items.length > 120) {
      items.remove(items.keys.first);
    }
  }

  Future<String> createSession({
    bool ephemeral = false,
    String? directory,
  }) async {
    final cwd = directory == null ? null : p.normalize(p.absolute(directory));
    final result = _map(
      await _request('thread/start', {
        'cwd': ?cwd,
        'ephemeral': ephemeral,
        'approvalPolicy': 'on-request',
        'approvalsReviewer': 'user',
        'sandbox': 'workspace-write',
        'threadSource': 'remoteaisync',
      }),
    );
    final id = _map(result['thread'])['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const CodexApiException('Codex 未返回新会话 ID。');
    }
    _loadedThreads.add(id);
    final now = DateTime.now();
    final session = HostSession(
      id: 'codex:$id',
      agentId: 'codex',
      remoteManaged: true,
      title: ephemeral ? '临时 Codex 会话' : '新建 Codex 会话',
      directory: cwd,
      updatedAt:
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    );
    if (ephemeral) {
      _ephemeralSessions[id] = session;
    } else {
      _newSessions[id] = session;
    }
    _events.add(null);
    return 'codex:$id';
  }

  List<AgentForm> listForms(String sessionId) => _requests.entries
      .where(
        (entry) =>
            entry.value.threadId == _threadId(sessionId) &&
            entry.value.method == 'item/tool/requestUserInput',
      )
      .map((entry) {
        final questions = (entry.value.params['questions'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        return AgentForm(
          id: entry.key,
          sessionId: sessionId,
          title: 'Codex 需要你的回答',
          fields: questions.map((question) {
            final options = (question['options'] as List? ?? const [])
                .whereType<Map>()
                .toList();
            return AgentFormField(
              key: question['id']?.toString() ?? '',
              type: AgentFormFieldType.string,
              title: question['question']?.toString(),
              description: question['header']?.toString(),
              required: true,
              custom: question['isOther'] == true || options.isEmpty,
              options: options
                  .map(
                    (option) => AgentFormOption(
                      value: option['label']?.toString() ?? '',
                      label: option['label']?.toString() ?? '',
                      description: option['description']?.toString(),
                    ),
                  )
                  .toList(),
            );
          }).toList(),
        );
      })
      .toList(growable: false);

  List<AgentPermission> listPermissions(String sessionId) => _requests.entries
      .where(
        (entry) =>
            entry.value.threadId == _threadId(sessionId) &&
            (entry.value.method == 'item/commandExecution/requestApproval' ||
                entry.value.method == 'item/fileChange/requestApproval' ||
                entry.value.method == 'item/permissions/requestApproval'),
      )
      .map((entry) {
        final params = entry.value.params;
        final item = _items['${entry.value.threadId}:${params['itemId']}'];
        final turnDiff =
            _turnDiffs['${entry.value.threadId}:${params['turnId']}'];
        final isCommand =
            entry.value.method == 'item/commandExecution/requestApproval';
        final isPermissions =
            entry.value.method == 'item/permissions/requestApproval';
        return AgentPermission(
          id: entry.key,
          sessionId: sessionId,
          action: isCommand
              ? 'commandExecution'
              : isPermissions
              ? 'permissions'
              : 'fileChange',
          resources: isCommand
              ? [
                  if (params['kind'] == 'writeStdin') '审批类型：向已有终端发送输入',
                  if (params['cwd'] != null) '目录：${params['cwd']}',
                  params['command']?.toString() ??
                      item?['command']?.toString() ??
                      '命令详情未提供，请在电脑端核对。',
                  if (params['networkApprovalContext'] != null)
                    '网络请求：${_renderJson(params['networkApprovalContext'])}',
                ]
              : isPermissions
              ? [jsonEncode(params['permissions'] ?? {})]
              : _fileChangeResources(item, params, turnDiff: turnDiff),
          message: params['reason']?.toString(),
          toolId: params['itemId']?.toString(),
        );
      })
      .toList(growable: false);

  Future<void> sendReply(
    String sessionId,
    String text, {
    List<String> localImages = const [],
    String? directory,
  }) async {
    final threadId = _threadId(sessionId);
    await _ensureThreadLoaded(threadId);
    final input = <Map<String, Object?>>[
      {'type': 'text', 'text': text, 'text_elements': <Object>[]},
      ...await _skillInputFor(text, directory: directory),
      for (final path in localImages) {'type': 'localImage', 'path': path},
    ];
    final activeTurnId = _activeTurns[threadId];
    if (activeTurnId != null) {
      try {
        await _request('turn/steer', {
          'threadId': threadId,
          'expectedTurnId': activeTurnId,
          'input': input,
        });
      } catch (_) {
        if (_activeTurns[threadId] == activeTurnId) {
          _activeTurns.remove(threadId);
        }
        rethrow;
      }
    } else {
      final result = _map(
        await _request('turn/start', {
          'threadId': threadId,
          'input': input,
          'approvalPolicy': 'on-request',
          'approvalsReviewer': 'user',
        }),
      );
      final turnId = _map(result['turn'])['id']?.toString();
      if (turnId != null && _completedTurns[threadId] != turnId) {
        _activeTurns[threadId] = turnId;
      }
    }
    _startedThreads.add(threadId);
    _events.add(null);
  }

  Future<void> _ensureThreadLoaded(String threadId) async {
    if (!_loadedThreads.contains(threadId)) {
      await _request('thread/resume', {
        'threadId': threadId,
        'excludeTurns': true,
        'approvalPolicy': 'on-request',
        'approvalsReviewer': 'user',
        'sandbox': 'workspace-write',
      });
      _loadedThreads.add(threadId);
    }
  }

  /// Stores input for a desktop-owned thread without taking over its writer.
  Future<String> queueDesktopMessage(
    String sessionId,
    String text, {
    List<String> localImages = const [],
    String? directory,
  }) async {
    final threadId = _threadId(sessionId);
    if (text.trim().isEmpty && localImages.isEmpty) {
      throw const CodexApiException('请输入消息或添加附件。');
    }
    Map<String, dynamic> result;
    try {
      result = _map(
        await _request('thread/queue/add', {
          'threadId': threadId,
          'clientUserMessageId': _newClientMessageId(),
          'input': [
            {'type': 'text', 'text': text, 'text_elements': <Object>[]},
            ...await _skillInputFor(text, directory: directory),
            for (final path in localImages)
              {'type': 'localImage', 'path': path},
          ],
        }),
      );
    } on CodexApiException catch (error) {
      if (error.message.contains('no rollout found') ||
          (error.message.contains('rollout at') &&
              error.message.contains('is empty'))) {
        throw const CodexApiException('此 Codex 会话尚未保存首轮消息，请稍后重试。');
      }
      rethrow;
    }
    final id = _map(result['queuedSubmission'])['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const CodexApiException('Codex 未确认消息入队。');
    }
    return id;
  }

  /// Starts an idle desktop thread directly, falling back to the shared queue
  /// only while Codex reports that another process owns the thread writer.
  Future<String?> sendDesktopMessage(
    String sessionId,
    String text, {
    List<String> localImages = const [],
    String? directory,
  }) async {
    try {
      await sendReply(
        sessionId,
        text,
        localImages: localImages,
        directory: directory,
      );
      return null;
    } on CodexApiException catch (error) {
      if (!error.activeWriter) rethrow;
      return queueDesktopMessage(
        sessionId,
        text,
        localImages: localImages,
        directory: directory,
      );
    }
  }

  Future<List<AgentQueuedMessage>> listQueuedMessages(String sessionId) async {
    final rows = <Object?>[];
    final seenCursors = <String>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final result = _map(
        await _request('thread/queue/list', {
          'threadId': _threadId(sessionId),
          'limit': 50,
          'cursor': cursor,
        }),
      );
      rows.addAll(result['data'] as List? ?? const []);
      final next = result['nextCursor']?.toString();
      if (next == null || next.isEmpty) {
        return _parseQueuedMessages(rows);
      }
      if (!seenCursors.add(next)) {
        throw const CodexApiException('Codex 返回重复队列游标，无法读取完整消息。');
      }
      cursor = next;
    }
    throw const CodexApiException('Codex 队列超过读取上限，无法确认全部消息。');
  }

  List<AgentQueuedMessage> _parseQueuedMessages(List<Object?> rows) {
    return rows
        .whereType<Map>()
        .map((raw) {
          final item = _map(raw);
          final input = (item['input'] as List? ?? const [])
              .whereType<Map>()
              .map(_map)
              .toList();
          final text = input
              .where((part) => part['type'] == 'text')
              .map((part) => part['text']?.toString() ?? '')
              .where((value) => value.isNotEmpty)
              .join('\n');
          return AgentQueuedMessage(
            id: item['id']?.toString() ?? '',
            text: text,
            imageCount: input
                .where((part) => part['type'] == 'localImage')
                .length,
          );
        })
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Returns false when the desktop process already consumed this submission.
  Future<bool> deleteQueuedMessage(
    String sessionId,
    String queuedSubmissionId,
  ) async {
    if (queuedSubmissionId.isEmpty) {
      throw const CodexApiException('待撤回的消息 ID 无效。');
    }
    final result = _map(
      await _request('thread/queue/delete', {
        'threadId': _threadId(sessionId),
        'queuedSubmissionId': queuedSubmissionId,
      }),
    );
    final deleted = result['deleted'];
    if (deleted is! bool) {
      throw const CodexApiException('Codex 未确认撤回结果。');
    }
    return deleted;
  }

  Future<void> replyToForm(
    String sessionId,
    String formId,
    Map<String, Object?> answer,
  ) async {
    final request = _requests[formId];
    if (request == null ||
        request.threadId != _threadId(sessionId) ||
        request.method != 'item/tool/requestUserInput') {
      throw const CodexApiException('此 Codex 提问已失效。');
    }
    final answers = <String, Object?>{};
    for (final question
        in (request.params['questions'] as List? ?? const [])
            .whereType<Map>()) {
      final key = question['id']?.toString() ?? '';
      final value = answer[key];
      if (key.isEmpty || value == null) {
        throw const CodexApiException('请回答所有 Codex 问题。');
      }
      answers[key] = {
        'answers': value is List
            ? value.map((item) => item.toString()).toList()
            : [value.toString()],
      };
    }
    _respond(request.id, {'answers': answers});
    _requests.remove(formId);
    _events.add(null);
  }

  Future<void> replyToPermission(
    String sessionId,
    String requestId, {
    required String decision,
  }) async {
    final request = _requests[requestId];
    if (request == null ||
        request.threadId != _threadId(sessionId) ||
        (request.method != 'item/commandExecution/requestApproval' &&
            request.method != 'item/fileChange/requestApproval' &&
            request.method != 'item/permissions/requestApproval')) {
      throw const CodexApiException('此 Codex 审批已失效。');
    }
    Future<Object?>? interrupt;
    if (request.method == 'item/permissions/requestApproval') {
      _respond(request.id, {
        'permissions': decision == 'once'
            ? request.params['permissions'] ?? {}
            : {},
        'scope': 'turn',
      });
      if (decision == 'reject') {
        interrupt = _request('turn/interrupt', {
          'threadId': request.threadId,
          'turnId': request.params['turnId'],
        });
      }
    } else {
      _respond(request.id, {
        'decision': decision == 'once' ? 'accept' : 'cancel',
      });
    }
    _requests.remove(requestId);
    _events.add(null);
    await interrupt;
  }

  Future<Object?> _request(String method, Map<String, Object?> params) {
    if (_closed) return Future.error(const CodexApiException('Codex 连接已关闭。'));
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _write({'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pending.remove(id);
        throw CodexApiException('Codex $method 响应超时。');
      },
    );
  }

  void _write(Map<String, Object?> message) =>
      _process.stdin.writeln(jsonEncode(message));

  void _respond(Object? id, Map<String, Object?> result) {
    _write({'id': id, 'result': result});
  }

  void _receive(String line) {
    try {
      final frame = jsonDecode(line);
      if (frame is! Map) return;
      final id = frame['id'];
      final method = frame['method']?.toString();
      if (method != null && id != null) {
        final params = _map(frame['params']);
        final threadId =
            params['threadId']?.toString() ??
            params['conversationId']?.toString() ??
            '';
        if (threadId.isNotEmpty &&
            (method == 'item/tool/requestUserInput' ||
                method == 'item/commandExecution/requestApproval' ||
                method == 'item/fileChange/requestApproval' ||
                method == 'item/permissions/requestApproval')) {
          _requests['$id'] = _CodexRequest(id, method, threadId, params);
          _events.add(null);
        }
        return;
      }
      if (method != null) {
        final params = _map(frame['params']);
        final threadId = params['threadId']?.toString();
        if (method == 'turn/started' && threadId != null) {
          final turnId = _map(params['turn'])['id']?.toString();
          if (turnId != null) {
            _activeTurns[threadId] = turnId;
            _completedTurns.remove(threadId);
          }
        }
        if (method == 'serverRequest/resolved') {
          _requests.remove(params['requestId']?.toString());
        }
        if (method == 'turn/completed' && threadId != null) {
          final turn = _map(params['turn']);
          final turnId = turn['id']?.toString();
          if (turnId != null) {
            final error = _map(turn['error']);
            final message = error['message']?.toString();
            if (message != null && message.isNotEmpty) {
              final details = error['additionalDetails']?.toString();
              final at = turn['completedAt'] ?? turn['startedAt'];
              final errors = _liveTurnErrors.putIfAbsent(threadId, () => {});
              errors[turnId] = AgentMessage(
                id: '$turnId:error',
                author: MessageAuthor.system,
                text: [
                  'Codex 错误：$message',
                  if (details != null && details.isNotEmpty) details,
                ].join('\n'),
                time: _timeFromMilliseconds(at is num ? at * 1000 : null),
              );
              while (errors.length > 20) {
                errors.remove(errors.keys.first);
              }
            }
            _turnDiffs.remove('$threadId:$turnId');
            for (final live
                in _liveItems[threadId]?.values ?? const <_LiveCodexItem>[]) {
              if (live.turnId == turnId) live.completed = true;
            }
            if (_activeTurns[threadId] == turnId) {
              _activeTurns.remove(threadId);
            }
            _completedTurns[threadId] = turnId;
            _requests.removeWhere(
              (_, request) =>
                  request.threadId == threadId &&
                  request.params['turnId']?.toString() == turnId,
            );
          }
        }
        if (method == 'item/started' ||
            method == 'item/updated' ||
            method == 'item/completed') {
          final item = Map<String, dynamic>.from(_map(params['item']));
          final itemId = item['id']?.toString();
          if (threadId != null && itemId != null) {
            final key = '$threadId:$itemId';
            final previous = _items[key];
            if (item['type'] == 'fileChange' && previous != null) {
              final oldChanges = (previous['changes'] as List? ?? const [])
                  .whereType<Map>()
                  .map(_map)
                  .toList();
              final newChanges = (item['changes'] as List? ?? const [])
                  .whereType<Map>()
                  .map(_map)
                  .toList();
              if (newChanges.isEmpty && oldChanges.isNotEmpty) {
                item['changes'] = oldChanges;
              } else if (newChanges.isNotEmpty && oldChanges.isNotEmpty) {
                final oldByPath = {
                  for (final change in oldChanges)
                    if (change['path'] is String)
                      change['path'] as String: change,
                };
                item['changes'] = newChanges.map((change) {
                  final old = oldByPath[change['path']];
                  if ((change['diff'] == null || change['diff'] == '') &&
                      old?['diff'] is String) {
                    return {...change, 'diff': old!['diff']};
                  }
                  return change;
                }).toList();
              }
            }
            _items[key] = item;
            final turnId = params['turnId']?.toString();
            if (turnId != null) {
              _rememberLiveItem(
                threadId,
                turnId,
                item,
                completed: method == 'item/completed',
              );
            }
          }
        }
        if (method == 'item/fileChange/patchUpdated' && threadId != null) {
          final turnId = params['turnId']?.toString();
          final itemId = params['itemId']?.toString();
          if (turnId != null && itemId != null) {
            final key = '$threadId:$itemId';
            final item = _items.putIfAbsent(
              key,
              () => {'id': itemId, 'type': 'fileChange'},
            );
            item['changes'] = params['changes'];
            _rememberLiveItem(threadId, turnId, item, completed: false);
          }
        }
        if (method == 'turn/diff/updated' && threadId != null) {
          final turnId = params['turnId']?.toString();
          final diff = params['diff'];
          if (turnId != null && diff is String) {
            _turnDiffs['$threadId:$turnId'] = _preview(diff, limit: 12000);
            while (_turnDiffs.length > 100) {
              _turnDiffs.remove(_turnDiffs.keys.first);
            }
          }
        }
        _appendLiveDelta(method, params);
        if (method == 'serverRequest/resolved' ||
            method.startsWith('item/') ||
            method.startsWith('turn/') ||
            method.startsWith('thread/')) {
          _events.add(null);
        }
        return;
      }
      final completer = id is int ? _pending.remove(id) : null;
      if (completer == null) return;
      if (frame['error'] != null) {
        final error = _map(frame['error']);
        final rawMessage = error['message']?.toString() ?? 'Codex 请求失败。';
        completer.completeError(
          CodexApiException(
            _codexErrorMessage(rawMessage),
            activeWriter: rawMessage.contains('already has an active writer'),
          ),
        );
      } else {
        completer.complete(frame['result']);
      }
    } catch (_) {
      // Ignore malformed or unrelated app-server notifications.
    }
  }

  void _failPending(String message) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(CodexApiException(message));
      }
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending('Codex 连接已关闭。');
    await _stdout.cancel();
    await _process.stdin.close();
    if (!await _process.exitCode
        .timeout(const Duration(seconds: 2), onTimeout: () => -1)
        .then((code) => code != -1)) {
      _process.kill();
    }
    await _stderr;
    await _events.close();
  }
}

class _CodexRequest {
  const _CodexRequest(this.id, this.method, this.threadId, this.params);
  final Object id;
  final String method;
  final String threadId;
  final Map<String, dynamic> params;
}

class _LiveCodexItem {
  _LiveCodexItem(this.turnId, this.value, this.time, this.completed);

  final String turnId;
  Map<String, dynamic> value;
  final String time;
  bool completed;
}

String _timeFromMilliseconds(Object? value) {
  final date = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.now();
  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String _codexItemText(Map item) {
  final type = item['type']?.toString();
  switch (type) {
    case 'userMessage':
      return (item['content'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (content) =>
                content['text']?.toString() ??
                (content['type'] == 'localImage'
                    ? '图片：${content['path']}'
                    : ''),
          )
          .where((value) => value.isNotEmpty)
          .join('\n');
    case 'agentMessage':
    case 'plan':
      return item['text']?.toString() ?? '';
    case 'reasoning':
      return (item['summary'] as List? ?? const []).join('\n');
    case 'commandExecution':
      final output = item['aggregatedOutput']?.toString() ?? '';
      return [
        '命令：${item['command'] ?? ''}',
        if (item['cwd'] != null) '目录：${item['cwd']}',
        if (item['exitCode'] != null) '退出码：${item['exitCode']}',
        if (item['status'] == 'failed') '命令执行失败',
        if (output.isNotEmpty) _preview(output),
      ].join('\n');
    case 'fileChange':
      final changes = (item['changes'] as List? ?? const [])
          .whereType<Map>()
          .map((change) {
            final path = change['path']?.toString() ?? '未知路径';
            final kind = change['kind']?.toString() ?? '修改';
            final diff = change['diff']?.toString() ?? '';
            return diff.isEmpty
                ? '$path ($kind)'
                : '$path ($kind)\n${_preview(diff, limit: 8000)}';
          })
          .toList();
      return [
        '文件修改：',
        ...changes,
        if (item['status'] == 'failed') '文件修改失败',
      ].join('\n');
    case 'mcpToolCall':
      final result = _map(item['result']);
      final content = (result['content'] as List? ?? const [])
          .whereType<Map>()
          .map((part) => part['text']?.toString() ?? '')
          .where((value) => value.isNotEmpty)
          .join('\n');
      final error = _map(item['error'])['message']?.toString();
      return [
        'MCP 工具：${item['server'] ?? ''}/${item['tool'] ?? ''}',
        if (item['arguments'] != null)
          '参数：${_preview(_renderJson(item['arguments']), limit: 4000)}',
        if (error?.isNotEmpty == true) '错误：$error',
        if (content.isNotEmpty) _preview(content),
        if (content.isEmpty && result['structuredContent'] != null)
          _preview(_renderJson(result['structuredContent'])),
      ].join('\n');
    case 'dynamicToolCall':
      final content = (item['contentItems'] as List? ?? const [])
          .whereType<Map>()
          .map((part) => part['text']?.toString() ?? '')
          .where((value) => value.isNotEmpty)
          .join('\n');
      return [
        '工具：${item['namespace'] ?? ''}/${item['tool'] ?? ''}',
        if (item['arguments'] != null)
          '参数：${_preview(_renderJson(item['arguments']), limit: 4000)}',
        if (item['success'] == false) '工具执行失败',
        if (content.isNotEmpty) _preview(content),
      ].join('\n');
    case 'functionCallOutput':
      return '工具输出：${_preview(_renderJson(item['output']))}';
    case 'webSearch':
      return '网页搜索：${item['query'] ?? ''}';
    case 'imageView':
      return '查看图片：${item['path'] ?? ''}';
    default:
      return '';
  }
}

MessageAuthor _codexItemAuthor(String? type) => switch (type) {
  'userMessage' => MessageAuthor.user,
  'commandExecution' ||
  'fileChange' ||
  'mcpToolCall' ||
  'dynamicToolCall' ||
  'functionCallOutput' ||
  'webSearch' ||
  'imageView' => MessageAuthor.tool,
  _ => MessageAuthor.assistant,
};

String _renderJson(Object? value) =>
    value is String ? value : jsonEncode(value);

String _codexErrorMessage(String message) {
  if (message.contains('already has an active writer')) {
    return '此 Codex 会话正由桌面版或另一进程控制。请在桌面端继续，网页仍可查看历史并排队消息。';
  }
  return message;
}

String _preview(String value, {int limit = 12000}) =>
    value.length <= limit ? value : '${value.substring(0, limit)}\n…内容过长，已截断。';

List<String> _fileChangeResources(
  Map<String, dynamic>? item,
  Map<String, dynamic> params, {
  String? turnDiff,
}) {
  final changes =
      (item?['changes'] as List? ?? params['changes'] as List? ?? const [])
          .whereType<Map>();
  final details = changes.map((change) {
    final path = change['path']?.toString() ?? '未知路径';
    final kind = change['kind']?.toString() ?? '修改';
    final diff = change['diff']?.toString().trim() ?? '';
    if (diff.isEmpty) return '$path ($kind)';
    const limit = 8000;
    final preview = diff.length > limit
        ? '${diff.substring(0, limit)}\n…差异过长，请在电脑端查看完整内容。'
        : diff;
    return '$path ($kind)\n$preview';
  }).toList();
  final grantRoot = params['grantRoot']?.toString();
  if (details.isNotEmpty) {
    return [
      if (grantRoot != null && grantRoot.isNotEmpty) '写入目录：$grantRoot',
      ...details,
    ];
  }
  return [
    if (grantRoot != null && grantRoot.isNotEmpty) '写入目录：$grantRoot',
    if (turnDiff != null && turnDiff.trim().isNotEmpty)
      '当前轮次累计差异（可能包含其他修改）：\n${_preview(turnDiff, limit: 8000)}'
    else
      'Codex 未提供文件差异详情，请在电脑端核对后再审批。',
  ];
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : {};

String _threadId(String sessionId) {
  if (!sessionId.startsWith('codex:') || sessionId.length <= 6) {
    throw const CodexApiException('无效的 Codex 会话 ID。');
  }
  return sessionId.substring(6);
}

String _newClientMessageId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class CodexApiException implements Exception {
  const CodexApiException(this.message, {this.activeWriter = false});
  final String message;
  final bool activeWriter;
  @override
  String toString() => message;
}

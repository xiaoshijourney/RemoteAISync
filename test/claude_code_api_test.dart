import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/claude_code_api.dart';

void main() {
  late Directory root;
  late ClaudeCodeApi api;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('remoteaisync-claude-');
    api = ClaudeCodeApi(
      executable: 'claude',
      projectsDirectory: root,
      version: '2.1.294',
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'discovers Claude project transcripts and maps messages and tools',
    () async {
      const sessionId = '28b911f0-aeae-4e0d-a57a-65ee6c46a640';
      final projectLogs = Directory('${root.path}/E--Work-Example')
        ..createSync(recursive: true);
      final transcript = File('${projectLogs.path}/$sessionId.jsonl');
      await transcript.writeAsString(
        [
          jsonEncode({
            'type': 'user',
            'sessionId': sessionId,
            'cwd': r'E:\Work\Example',
            'timestamp': '2026-11-09T10:00:00.000Z',
            'message': {'role': 'user', 'content': 'Inspect this project'},
          }),
          jsonEncode({
            'type': 'assistant',
            'sessionId': sessionId,
            'cwd': r'E:\Work\Example',
            'timestamp': '2026-11-09T10:00:01.000Z',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'I will inspect the project.'},
                {
                  'type': 'tool_use',
                  'id': 'tool-1',
                  'name': 'Read',
                  'input': {'file_path': r'E:\Work\Example\README.md'},
                },
              ],
            },
          }),
          jsonEncode({
            'type': 'user',
            'sessionId': sessionId,
            'cwd': r'E:\Work\Example',
            'timestamp': '2026-11-09T10:00:02.000Z',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 'tool-1',
                  'content': 'README text',
                },
              ],
            },
          }),
        ].join('\n'),
      );

      final sessions = await api.listSessions(
        directory: r'E:\Work\Example',
        global: false,
      );
      expect(sessions, hasLength(1));
      expect(sessions.single.id, 'claude:$sessionId');
      expect(sessions.single.agentId, 'claude');
      expect(sessions.single.title, 'Inspect this project');

      final messages = await api.listMessages('claude:$sessionId');
      expect(messages.map((message) => message.author), [
        MessageAuthor.user,
        MessageAuthor.assistant,
        MessageAuthor.tool,
        MessageAuthor.tool,
      ]);
      expect(messages[2].groupId, messages[3].groupId);
      expect(messages[2].text, contains('Read'));
      expect(messages[3].text, 'README text');
    },
  );

  test(
    'keeps newly created sessions visible until Claude persists the transcript',
    () async {
      final sessionId = await api.createSession(r'E:\Work\Example');
      final sessions = await api.listSessions(
        directory: r'E:\Work\Example',
        global: false,
      );
      expect(sessions.single.id, sessionId);
      expect(sessions.single.directory, r'E:\Work\Example');
    },
  );

  test(
    'keeps new sessions visible before the Claude projects folder exists',
    () async {
      await root.delete(recursive: true);
      final sessionId = await api.createSession(r'E:\Work\Example');

      final sessions = await api.listSessions(
        directory: r'E:\Work\Example',
        global: false,
      );

      expect(sessions.single.id, sessionId);
    },
  );

  test('exposes Claude text deltas before a transcript is written', () async {
    final streamed = Completer<List<AgentMessage>>();
    late _FakeClaudeProcess fakeProcess;
    api = ClaudeCodeApi(
      executable: 'claude',
      projectsDirectory: root,
      version: 'test',
      processLauncher:
          (_, _, {required workingDirectory, required runInShell}) async {
            fakeProcess = _FakeClaudeProcess([
              {
                'type': 'stream_event',
                'event': {
                  'type': 'content_block_delta',
                  'delta': {'type': 'text_delta', 'text': 'Streaming response'},
                },
              },
            ]);
            return fakeProcess;
          },
    );
    final sessionId = await api.createSession(r'E:\Work\Example');
    final sending = api.sendMessage(
      sessionId,
      'Start a response',
      directory: r'E:\Work\Example',
      onTranscriptChanged: () {
        unawaited(
          api.listMessages(sessionId).then((messages) {
            if (!streamed.isCompleted) streamed.complete(messages);
          }),
        );
      },
    );

    final messages = await streamed.future;
    expect(messages.single.author, MessageAuthor.assistant);
    expect(messages.single.text, 'Streaming response');
    fakeProcess.complete();
    await sending;
  });

  test(
    'interrupts a running Claude CLI process and clears running state',
    () async {
      final launched = Completer<_FakeClaudeProcess>();
      api = ClaudeCodeApi(
        executable: 'claude',
        projectsDirectory: root,
        version: 'test',
        processLauncher:
            (_, _, {required workingDirectory, required runInShell}) async {
              final process = _FakeClaudeProcess(const [], killSucceeds: true);
              launched.complete(process);
              return process;
            },
      );
      final sessionId = await api.createSession(r'E:\Work\Example');
      final sending = api.sendMessage(
        sessionId,
        'Start a long response',
        directory: r'E:\Work\Example',
      );
      final process = await launched.future;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      var running = false;
      while (!running && DateTime.now().isBefore(deadline)) {
        final settings = (await api.controls(sessionId))['settings'] as Map;
        running = settings['running'] == true;
        if (!running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      expect(running, isTrue);

      await api.interruptSession(sessionId);
      await sending;

      expect(process.receivedSignal, ProcessSignal.sigint);
      expect(
        (await api.controls(sessionId))['settings'],
        containsPair('running', false),
      );
    },
  );

  test(
    'builds resumable Claude CLI requests with saved model settings',
    () async {
      const rawId = '3f00b1c8-82b1-4ded-8ea0-37f7b83d8d1d';
      final transcript = File('${root.path}/project/$rawId.jsonl')
        ..parent.createSync(recursive: true);
      await transcript.writeAsString(
        jsonEncode({
          'type': 'user',
          'cwd': r'E:\Work\Example',
          'message': {'role': 'user', 'content': 'Earlier prompt'},
        }),
      );
      await api.listSessions(directory: r'E:\Work\Example', global: false);
      api.updateSettings(
        'claude:$rawId',
        model: 'claude-fable-5-1',
        effort: 'high',
      );

      final arguments = await api.buildSendArguments(
        'claude:$rawId',
        'Continue the task',
      );

      expect(arguments, containsAll(['--resume', rawId]));
      expect(arguments, containsAll(['--model', 'claude-fable-5-1']));
      expect(arguments, containsAll(['--effort', 'high']));
      expect(arguments, contains('--include-partial-messages'));
      expect(arguments, isNot(contains('--permission-mode')));
      expect(arguments, isNot(contains('default')));
      expect(arguments.last, 'Continue the task');
    },
  );

  test(
    'filters sessions to the selected workspace unless global is enabled',
    () async {
      final id = 'b62bc890-c6d1-4b05-8c55-f5418e55151e';
      final transcript = File('${root.path}/other/$id.jsonl')
        ..parent.createSync(recursive: true);
      await transcript.writeAsString(
        jsonEncode({
          'type': 'user',
          'sessionId': id,
          'cwd': r'E:\Work\Other',
          'message': {'role': 'user', 'content': 'Other project'},
        }),
      );

      expect(
        await api.listSessions(directory: r'E:\Work\Example', global: false),
        isEmpty,
      );
      expect(
        await api.listSessions(directory: r'E:\Work\Example', global: true),
        hasLength(1),
      );
    },
  );
}

class _FakeClaudeProcess implements Process {
  _FakeClaudeProcess(
    List<Map<String, Object?>> events, {
    this.killSucceeds = false,
  }) : _stdout = Stream<List<int>>.fromIterable([
         utf8.encode(events.map(jsonEncode).join('\n')),
       ]);

  final bool killSucceeds;
  final Stream<List<int>> _stdout;
  final IOSink _stdin = IOSink(StreamController<List<int>>().sink);
  final _exitCode = Completer<int>();
  ProcessSignal? receivedSignal;

  void complete() => _exitCode.complete(0);

  @override
  int get pid => 1;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => _stdin;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    receivedSignal = signal;
    if (killSucceeds) complete();
    return killSucceeds;
  }
}

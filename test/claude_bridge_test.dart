import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/bridge.dart';
// ignore: avoid_relative_lib_imports
import '../host/lib/src/claude_code_api.dart';
import 'support/pairing_helper.dart';

void main() {
  test('Claude sessions work end to end through the host WebSocket', () async {
    final project = await Directory.systemTemp.createTemp(
      'remoteaisync-claude-bridge-',
    );
    List<String>? launchedArguments;
    _FakeClaudeProcess? process;
    final claude = ClaudeCodeApi(
      executable: 'fake-claude',
      projectsDirectory: Directory('${project.path}/claude-projects'),
      version: 'test-claude',
      processLauncher:
          (
            _,
            arguments, {
            required workingDirectory,
            required runInShell,
          }) async {
            launchedArguments = List.of(arguments);
            process = _FakeClaudeProcess([
              {
                'type': 'stream_event',
                'event': {
                  'type': 'content_block_delta',
                  'delta': {
                    'type': 'text_delta',
                    'text': 'Synthetic Claude response',
                  },
                },
              },
            ]);
            return process!;
          },
    );
    final port = await _unusedPort();
    const pairingToken = 'claude-bridge-test-pairing-token-0123456789';
    final bridge = await AgentBridge.start(
      projectDirectory: project.path,
      websocketPort: port,
      pairingToken: pairingToken,
      allowLocalDevConfig: true,
      executable: 'fake-opencode',
      openCodeCommandRunner:
          ({
            required executable,
            required arguments,
            required workingDirectory,
          }) async => ProcessResult(1, 1, '', 'OpenCode unavailable in test.'),
      codexExecutable: 'missing-codex-for-claude-test',
      claudeApi: claude,
    );
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    final http = HttpClient();
    final journal = _EventJournal();
    final subscription = socket.listen((raw) {
      journal.add(jsonDecode(raw as String) as Map<String, dynamic>);
    });

    try {
      final hostReady = journal.nextWhere(
        (event) => event['kind'] == 'host.ready',
      );
      await pairTestDevice(
        http: http,
        port: port,
        adminToken: pairingToken,
        socket: socket,
        events: journal.stream,
      );
      final readyEvent = await hostReady.timeout(const Duration(seconds: 5));
      final hostReadyData = readyEvent;
      final agents = (hostReadyData['payload'] as Map)['agents'] as List;
      expect(
        agents.singleWhere((agent) => agent['id'] == 'claude')['availability'],
        'available',
      );

      final created = await _command(journal, socket, 'session.create', {
        'agentId': 'claude',
        'directory': project.path,
      });
      final sessionId = created['sessionId'] as String;
      expect(sessionId, startsWith('claude:'));
      await journal.nextWhere(
        (event) =>
            event['kind'] == 'host.snapshot' &&
            ((event['payload'] as Map)['sessions'] as List).any(
              (session) => session['id'] == sessionId,
            ),
      );

      await _command(journal, socket, 'session.select', {
        'sessionId': sessionId,
        'selectionGeneration': 1,
      });
      final controls = await _command(journal, socket, 'session.controls', {
        'sessionId': sessionId,
      });
      expect(controls['models'], isNotEmpty);
      expect((controls['settings'] as Map)['running'], isFalse);

      final settings = await _command(
        journal,
        socket,
        'session.settings.update',
        {'sessionId': sessionId, 'model': 'sonnet', 'effort': 'high'},
      );
      expect(settings['ok'], isTrue);

      const attachmentBytes = [80, 68, 70];
      final upload = await _command(journal, socket, 'attachment.begin', {
        'sessionId': sessionId,
        'name': 'reference.pdf',
        'sizeBytes': attachmentBytes.length,
        'mimeType': 'application/pdf',
      });
      final uploadId = upload['uploadId'] as String;
      await _command(journal, socket, 'attachment.chunk', {
        'uploadId': uploadId,
        'offset': 0,
        'data': base64Encode(attachmentBytes),
      });
      final finished = await _command(journal, socket, 'attachment.finish', {
        'uploadId': uploadId,
      });
      final attachmentId = finished['attachmentId'] as String;

      final replyFuture = _command(journal, socket, 'session.reply', {
        'sessionId': sessionId,
        'text': 'Review the attached reference',
        'attachmentIds': [attachmentId],
      });
      await _waitFor(() => process != null);
      expect(launchedArguments, containsAll(['--model', 'sonnet']));
      expect(launchedArguments, containsAll(['--effort', 'high']));
      expect(launchedArguments, contains('--include-partial-messages'));
      expect(launchedArguments, isNot(contains('--permission-mode')));
      expect(launchedArguments!.last, contains('reference.pdf'));

      final streamed = await journal.nextWhere(
        (event) =>
            event['kind'] == 'session.snapshot' &&
            event['sessionId'] == sessionId &&
            ((event['payload'] as Map)['messages'] as List).any(
              (message) => message['text'] == 'Synthetic Claude response',
            ),
      );
      expect(streamed['sessionId'], sessionId);
      process!.complete();
      expect((await replyFuture)['ok'], isTrue);
    } finally {
      process?.complete();
      await socket.close();
      http.close(force: true);
      await subscription.cancel();
      await journal.close();
      await bridge.close();
      await project.delete(recursive: true);
    }
  });
}

Future<int> _unusedPort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
}

Future<Map<String, dynamic>> _command(
  _EventJournal journal,
  WebSocket socket,
  String kind,
  Map<String, Object?> payload,
) async {
  final id = 'claude-test-${DateTime.now().microsecondsSinceEpoch}';
  final result = journal.nextWhere(
    (event) =>
        (event['kind'] == 'command.result' ||
            event['kind'] == 'command.error') &&
        (event['payload'] as Map)['commandId'] == id,
  );
  socket.add(
    jsonEncode({
      'schemaVersion': 1,
      'commandId': id,
      'kind': kind,
      'expectedRevision': 0,
      'payload': payload,
    }),
  );
  final event = await result.timeout(const Duration(seconds: 8));
  final data = (event['payload'] as Map).cast<String, dynamic>();
  if (event['kind'] == 'command.error') {
    fail('$kind failed: ${data['message']}');
  }
  return data;
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _EventJournal {
  final events = <Map<String, dynamic>>[];
  final _stream = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get stream => _stream.stream;

  void add(Map<String, dynamic> event) {
    events.add(event);
    _stream.add(event);
  }

  Future<Map<String, dynamic>> nextWhere(
    bool Function(Map<String, dynamic>) predicate,
  ) {
    for (final event in events) {
      if (predicate(event)) return Future.value(event);
    }
    return _stream.stream.firstWhere(predicate);
  }

  Future<void> close() => _stream.close();
}

class _FakeClaudeProcess implements Process {
  _FakeClaudeProcess(List<Map<String, Object?>> events)
    : _stdout = Stream<List<int>>.fromIterable([
        utf8.encode(events.map(jsonEncode).join('\n')),
      ]);

  final Stream<List<int>> _stdout;
  final IOSink _stdin = IOSink(StreamController<List<int>>().sink);
  final _exitCode = Completer<int>();

  void complete() {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

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
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}

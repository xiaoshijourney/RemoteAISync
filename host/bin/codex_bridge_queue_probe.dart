import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Tests a saved external Codex thread through the paired WebSocket bridge.
/// The disposable CLI thread is deleted before this probe exits.
Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 3) {
    throw const FormatException('Usage: <host-port> <pairing-token> [project]');
  }
  final port = int.parse(arguments[0]);
  final project = arguments.length == 3
      ? Directory(arguments[2]).absolute.path
      : Directory.current.path;
  String? threadId;
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  final events = StreamController<Map<String, dynamic>>.broadcast();
  try {
    final process = await Process.start('codex', [
      'exec',
      '--json',
      '-C',
      project,
      '-s',
      'read-only',
      '-',
    ], workingDirectory: project);
    process.stdin.writeln(
      'RemoteAISync external-session probe: reply OK only. Do not use tools.',
    );
    await process.stdin.close();
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    final error = process.stderr.transform(utf8.decoder).join();
    final status = await process.exitCode.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        process.kill();
        throw TimeoutException('Codex exec probe timed out.');
      },
    );
    final frames = await output;
    for (final line in frames) {
      try {
        final event = jsonDecode(line);
        if (event is Map && event['type'] == 'thread.started') {
          threadId = event['thread_id']?.toString();
        }
      } on FormatException {
        // Other CLI output is irrelevant to the probe.
      }
    }
    if (status != 0 || threadId == null) {
      throw StateError('Codex exec failed: ${(await error).trim()}');
    }
    stdout.writeln('Disposable external Codex thread created.');

    socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    Map<String, dynamic>? latestHost;
    subscription = socket.listen((raw) {
      if (raw is! String) return;
      final frame = jsonDecode(raw);
      if (frame is! Map) return;
      final event = frame.cast<String, dynamic>();
      if (event['kind'] == 'host.snapshot') latestHost = event;
      events.add(event);
    });
    final hostSnapshot = _next(
      events,
      (event) => event['kind'] == 'host.snapshot',
    );
    socket.add(
      _frame('client.hello', 'probe-hello', {'pairingToken': arguments[1]}),
    );
    await hostSnapshot;
    final refresh = _nextCommand(events, 'probe-refresh');
    socket.add(_frame('session.refresh', 'probe-refresh', {}));
    await refresh;
    final sessionId = 'codex:$threadId';
    final sessions =
        ((latestHost?['payload'] as Map?)?['sessions'] as List? ?? const [])
            .whereType<Map>()
            .toList();
    final matches = sessions.where((item) => item['id'] == sessionId).toList();
    if (matches.length != 1 || matches.single['remoteManaged'] == true) {
      throw StateError(
        'Disposable thread was not listed as an external session.',
      );
    }

    final selected = _nextCommand(events, 'probe-select');
    socket.add(
      _frame('session.select', 'probe-select', {
        'sessionId': sessionId,
        'selectionGeneration': 1,
      }),
    );
    await selected;
    final sent = _nextCommand(events, 'probe-queue');
    final pending = _next(events, (event) {
      if (event['kind'] != 'session.snapshot') return false;
      final payload = event['payload'];
      if (payload is! Map || payload['sessionId'] != sessionId) return false;
      return (payload['queuedMessages'] as List? ?? const [])
          .whereType<Map>()
          .any(
            (item) =>
                item['text']?.toString().contains('bridge queue probe') == true,
          );
    });
    socket.add(
      _frame('session.reply', 'probe-queue', {
        'sessionId': sessionId,
        'text': 'RemoteAISync bridge queue probe. No action is required.',
      }),
    );
    final result = await sent;
    final payload = result['payload'] as Map;
    if (payload['delivery'] != 'queued' ||
        payload['queuedSubmissionId']?.toString().isEmpty != false) {
      throw StateError('Bridge did not confirm queued delivery.');
    }
    stdout.writeln('Bridge confirmed delivery to the desktop queue.');
    await pending;
    stdout.writeln('Bridge snapshot shows the pending queue item.');
    final withdrawn = _nextCommand(events, 'probe-withdraw');
    final emptyQueue = _next(events, (event) {
      if (event['kind'] != 'session.snapshot') return false;
      final snapshot = event['payload'];
      if (snapshot is! Map || snapshot['sessionId'] != sessionId) return false;
      return !(snapshot['queuedMessages'] as List? ?? const [])
          .whereType<Map>()
          .any((item) => item['id'] == payload['queuedSubmissionId']);
    });
    socket.add(
      _frame('session.queue.delete', 'probe-withdraw', {
        'sessionId': sessionId,
        'queuedSubmissionId': payload['queuedSubmissionId'],
      }),
    );
    await withdrawn;
    await emptyQueue;
    stdout.writeln('Bridge confirmed queue withdrawal.');
  } finally {
    await subscription?.cancel();
    await socket?.close();
    await events.close();
    if (threadId != null) {
      final deleted = await Process.run('codex', [
        'delete',
        '--force',
        threadId,
        '-C',
        project,
      ]).timeout(const Duration(seconds: 20));
      if (deleted.exitCode != 0) {
        stderr.writeln('Could not remove probe thread $threadId.');
        exitCode = 1;
      }
    }
  }
}

Future<Map<String, dynamic>> _next(
  StreamController<Map<String, dynamic>> events,
  bool Function(Map<String, dynamic>) predicate,
) => events.stream.firstWhere(predicate).timeout(const Duration(seconds: 20));

Future<Map<String, dynamic>> _nextCommand(
  StreamController<Map<String, dynamic>> events,
  String commandId,
) async {
  final response = await _next(events, (event) {
    final payload = event['payload'];
    return payload is Map && payload['commandId'] == commandId;
  });
  if (response['kind'] != 'command.result') {
    throw StateError(
      'Bridge command $commandId failed: ${response['payload']}',
    );
  }
  return response;
}

String _frame(String kind, String commandId, Map<String, Object?> payload) =>
    jsonEncode({
      'schemaVersion': 1,
      'kind': kind,
      'commandId': commandId,
      'payload': payload,
    });

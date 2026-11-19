import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Synthetic end-to-end test; no Codex tool is executed.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run host/bin/codex_hook_probe.dart <port> <pairing-token>',
    );
    exitCode = 2;
    return;
  }
  final port = int.parse(arguments[0]);
  final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final subscription = socket.listen((raw) {
    final frame = jsonDecode(raw as String);
    if (frame is Map) events.add(frame.cast<String, dynamic>());
  });
  try {
    final ready = events.stream
        .firstWhere((event) => event['kind'] == 'host.ready')
        .timeout(const Duration(seconds: 15));
    final snapshot = events.stream
        .firstWhere((event) => event['kind'] == 'host.snapshot')
        .timeout(const Duration(seconds: 15));
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'client.hello',
        'commandId': 'hook-probe-hello',
        'payload': {'pairingToken': arguments[1]},
      }),
    );
    final readyEvent = await ready;
    final capabilities = (readyEvent['payload'] as Map)['capabilities'] as Map;
    if (capabilities['codexDesktopHookApprovals'] != true) {
      throw StateError('Desktop hook endpoint is not ready.');
    }
    final host = await snapshot;
    final sessions = ((host['payload'] as Map)['sessions'] as List)
        .whereType<Map>()
        .where(
          (session) =>
              session['agentId'] == 'codex' && session['remoteManaged'] != true,
        )
        .toList();
    if (sessions.isEmpty) throw StateError('No external Codex session found.');
    final sessionId = sessions.first['id'].toString();
    final selected = events.stream
        .firstWhere(
          (event) =>
              (event['payload'] as Map)['commandId'] == 'hook-probe-select',
        )
        .timeout(const Duration(seconds: 15));
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'session.select',
        'commandId': 'hook-probe-select',
        'payload': {'sessionId': sessionId, 'selectionGeneration': 1},
      }),
    );
    if ((await selected)['kind'] != 'command.result') {
      throw StateError('Could not select the Codex session.');
    }
    for (final decision in ['once', 'reject']) {
      final pending = events.stream
          .firstWhere((event) {
            if (event['kind'] != 'session.snapshot') return false;
            final payload = event['payload'] as Map;
            return payload['sessionId'] == sessionId &&
                (payload['permissions'] as List? ?? const [])
                    .whereType<Map>()
                    .any(
                      (item) => item['id'].toString().startsWith('codex-hook:'),
                    );
          })
          .timeout(const Duration(seconds: 20));
      final hook = await Process.start('dart', [
        File('host/bin/codex_permission_hook.dart').absolute.path,
        '--port',
        '$port',
      ], workingDirectory: Directory.current.path);
      hook.stdin.writeln(
        jsonEncode({
          'hook_event_name': 'PermissionRequest',
          'session_id': sessionId.substring(6),
          'cwd': Directory.current.path,
          'tool_name': 'Bash',
          'tool_input': {'command': 'echo RemoteAISync hook probe'},
        }),
      );
      await hook.stdin.close();
      final detail = await pending;
      final permission = ((detail['payload'] as Map)['permissions'] as List)
          .whereType<Map>()
          .firstWhere(
            (item) => item['id'].toString().startsWith('codex-hook:'),
          );
      final id = permission['id'].toString();
      final cleared = events.stream
          .firstWhere((event) {
            if (event['kind'] != 'session.snapshot') return false;
            final payload = event['payload'] as Map;
            return payload['sessionId'] == sessionId &&
                !(payload['permissions'] as List? ?? const [])
                    .whereType<Map>()
                    .any((item) => item['id'] == id);
          })
          .timeout(const Duration(seconds: 20));
      final result = events.stream
          .firstWhere(
            (event) =>
                (event['payload'] as Map)['commandId'] ==
                'hook-probe-$decision',
          )
          .timeout(const Duration(seconds: 15));
      socket.add(
        jsonEncode({
          'schemaVersion': 1,
          'kind': 'session.permission.reply',
          'commandId': 'hook-probe-$decision',
          'payload': {
            'sessionId': sessionId,
            'requestId': id,
            'decision': decision,
          },
        }),
      );
      if ((await result)['kind'] != 'command.result') {
        throw StateError('Approval resolution failed.');
      }
      final output = await utf8.decoder
          .bind(hook.stdout)
          .join()
          .timeout(const Duration(seconds: 15));
      if (await hook.exitCode != 0) {
        throw StateError('Hook process failed.');
      }
      final response = jsonDecode(output) as Map;
      final behavior =
          ((response['hookSpecificOutput'] as Map)['decision']
              as Map)['behavior'];
      final expected = decision == 'once' ? 'allow' : 'deny';
      if (behavior != expected) {
        throw StateError('Expected $expected, got $behavior.');
      }
      await cleared;
      stdout.writeln('Desktop hook $expected decision reached Codex output.');
    }
  } finally {
    await subscription.cancel();
    await events.close();
    await socket.close();
  }
}

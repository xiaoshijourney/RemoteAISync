import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/application/host_client.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  test('completes pairing, selects a session, and forwards a reply', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final replies = <String>[];
    final serverSubscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final kind = frame['kind'];
        final commandId = frame['commandId'];
        final payload = frame['payload'] as Map<String, dynamic>;

        if (kind == 'client.hello') {
          _sendEvent(socket, 'host.ready', {'openCodeVersion': '2.0.6'});
          _sendEvent(socket, 'host.snapshot', {
            'sessions': [
              {
                'id': 'ses_test',
                'title': 'Fresh project session',
                'updatedAt': '12:00',
              },
            ],
          });
        } else if (kind == 'session.select') {
          _sendEvent(socket, 'session.snapshot', {
            'sessionId': payload['sessionId'],
            'messages': [
              {
                'id': 'msg_test',
                'author': 'assistant',
                'text': 'Bridge is ready.',
                'time': '12:00',
              },
            ],
          });
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        } else if (kind == 'session.reply') {
          replies.add(payload['text'] as String);
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        }
      });
    });
    final client = HostClient();

    try {
      await client.connect(
        address: '127.0.0.1',
        port: server.port,
        pairingToken: 'test-pairing-token',
      );
      expect(client.status, HostConnectionStatus.connected);
      expect(client.hostVersion, '2.0.6');
      await _waitFor(() => client.sessions.isNotEmpty);
      expect(client.sessions.single.title, 'Fresh project session');

      await client.selectSession(client.sessions.single);
      await _waitFor(() => client.messages.isNotEmpty);
      expect(client.messages.single.text, 'Bridge is ready.');

      await client.sendReply('Continue with the test suite.');
      expect(replies, ['Continue with the test suite.']);
    } finally {
      await client.disconnect();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void _sendEvent(WebSocket socket, String kind, Map<String, Object?> payload) {
  socket.add(
    jsonEncode({'schemaVersion': 1, 'kind': kind, 'payload': payload}),
  );
}

import 'dart:convert';
import 'dart:io';

Future<void> pairTestDevice({
  required HttpClient http,
  required int port,
  required String adminToken,
  required WebSocket socket,
  required Stream<Map<String, dynamic>> events,
}) async {
  final inviteRequest = await http.postUrl(
    Uri.parse('http://127.0.0.1:$port/pairing/invite'),
  );
  inviteRequest.headers.set('x-remoteaisync-token', adminToken);
  final inviteResponse = await inviteRequest.close();
  final inviteBody =
      jsonDecode(await utf8.decoder.bind(inviteResponse).join()) as Map;
  if (inviteResponse.statusCode != HttpStatus.ok) {
    throw StateError('Could not create test pairing invite.');
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toString();
  final deviceId = 'test-device-$suffix';
  final deviceToken = 'test-device-token-${suffix.padLeft(32, '0')}';
  final pending = events
      .firstWhere((event) => event['kind'] == 'pairing.pending')
      .timeout(const Duration(seconds: 3));
  socket.add(
    jsonEncode({
      'schemaVersion': 1,
      'kind': 'client.hello',
      'payload': {
        'pairingToken': inviteBody['invite'],
        'deviceId': deviceId,
        'deviceToken': deviceToken,
        'deviceName': 'Test device',
      },
    }),
  );
  await pending;
  final ready = events
      .firstWhere((event) => event['kind'] == 'host.ready')
      .timeout(const Duration(seconds: 3));
  final approvalRequest = await http.postUrl(
    Uri.parse(
      'http://127.0.0.1:$port/pairing/approve?id=${Uri.encodeQueryComponent(deviceId)}',
    ),
  );
  approvalRequest.headers.set('x-remoteaisync-token', adminToken);
  final approvalResponse = await approvalRequest.close();
  await approvalResponse.drain<void>();
  if (approvalResponse.statusCode != HttpStatus.ok) {
    throw StateError('Could not approve test pairing.');
  }
  await ready;
}

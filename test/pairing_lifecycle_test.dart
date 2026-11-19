import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/bridge.dart';

void main() {
  test('approves, remembers, rejects, and revokes paired devices', () async {
    final project = await Directory.systemTemp.createTemp(
      'remoteaisync-pairing-lifecycle-',
    );
    final port = await _findFreePort();
    const adminToken = 'local-admin-token-0123456789abcdef0123456789';
    AgentBridge? bridge;
    HttpClient? http;
    WebSocket? approvedSocket;
    WebSocket? reconnectSocket;
    WebSocket? rejectedSocket;
    StreamSubscription<dynamic>? approvedSubscription;
    StreamSubscription<dynamic>? reconnectSubscription;
    StreamSubscription<dynamic>? rejectedSubscription;
    try {
      bridge = await AgentBridge.start(
        projectDirectory: project.path,
        websocketPort: port,
        pairingToken: adminToken,
        allowLocalDevConfig: true,
        executable: 'missing-opencode-for-pairing-test',
        openCodeCommandRunner:
            ({
              required executable,
              required arguments,
              required workingDirectory,
            }) async =>
                throw ProcessException(executable, arguments, 'missing'),
        codexExecutable: 'missing-codex-for-pairing-test',
        claudeExecutable: 'missing-claude-for-pairing-test',
      );
      http = HttpClient();
      final invite = await _createInvite(http, port, adminToken);
      const deviceId = 'phone-device-id-0123456789';
      const deviceToken = 'phone-device-token-01234567890123456789';
      approvedSocket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final approvedEvents = StreamController<Map<String, dynamic>>.broadcast();
      approvedSubscription = approvedSocket
          .map(_decode)
          .listen(approvedEvents.add);
      final approvalRequest = _expectEvent(
        approvedEvents.stream,
        'pairing.pending',
      );
      approvedSocket.add(
        _hello(invite: invite, deviceId: deviceId, deviceToken: deviceToken),
      );
      await approvalRequest;
      expect((await _getStatus(http, port))['pendingPairings'], hasLength(1));

      final approvedReady = _expectEvent(approvedEvents.stream, 'host.ready');
      await _resolve(http, port, adminToken, 'approve', deviceId);
      await approvedReady;
      expect((await _getStatus(http, port))['pairedDevices'], hasLength(1));

      reconnectSocket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final reconnectEvents =
          StreamController<Map<String, dynamic>>.broadcast();
      reconnectSubscription = reconnectSocket
          .map(_decode)
          .listen(reconnectEvents.add);
      final reconnected = _expectEvent(reconnectEvents.stream, 'host.ready');
      reconnectSocket.add(_hello(deviceId: deviceId, deviceToken: deviceToken));
      await reconnected;
      await approvedSocket.done.timeout(const Duration(seconds: 3));
      await approvedSubscription.cancel();
      approvedSubscription = null;

      final statusAfterReconnect = await _getStatus(http, port);
      expect(statusAfterReconnect['connectedClients'], 1);
      final topologyNodes =
          ((statusAfterReconnect['topology'] as Map)['nodes'] as List)
              .whereType<Map>()
              .where((node) => node['role'] == 'client')
              .toList();
      expect(topologyNodes, hasLength(1));

      for (var attempt = 0; attempt < 3; attempt++) {
        final previousSocket = reconnectSocket!;
        final previousSubscription = reconnectSubscription!;
        final nextSocket = await WebSocket.connect(
          'ws://127.0.0.1:$port/ws',
        );
        final nextEvents = StreamController<Map<String, dynamic>>.broadcast();
        final nextSubscription = nextSocket
            .map(_decode)
            .listen(nextEvents.add);
        final nextReady = _expectEvent(nextEvents.stream, 'host.ready');
        nextSocket.add(_hello(deviceId: deviceId, deviceToken: deviceToken));
        await nextReady;
        await previousSocket.done.timeout(const Duration(seconds: 3));
        await previousSubscription.cancel();

        reconnectSocket = nextSocket;
        reconnectSubscription = nextSubscription;
        final repeatedReconnectStatus = await _getStatus(http, port);
        expect(repeatedReconnectStatus['connectedClients'], 1);
        final repeatedTopologyNodes =
            ((repeatedReconnectStatus['topology'] as Map)['nodes'] as List)
                .whereType<Map>()
                .where((node) => node['role'] == 'client')
                .toList();
        expect(repeatedTopologyNodes, hasLength(1));
      }

      final activeReconnectSocket = reconnectSocket!;
      final activeReconnectSubscription = reconnectSubscription!;
      final revoked = activeReconnectSocket.done.timeout(
        const Duration(seconds: 3),
      );
      await _resolve(
        http,
        port,
        adminToken,
        'device',
        deviceId,
        method: 'DELETE',
      );
      await revoked;
      await activeReconnectSubscription.cancel();
      reconnectSubscription = null;

      final nextInvite = await _createInvite(http, port, adminToken);
      const rejectedId = 'rejected-device-id-0123456789';
      rejectedSocket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final rejectedEvents = StreamController<Map<String, dynamic>>.broadcast();
      rejectedSubscription = rejectedSocket
          .map(_decode)
          .listen(rejectedEvents.add);
      final rejectedPending = _expectEvent(
        rejectedEvents.stream,
        'pairing.pending',
      );
      rejectedSocket.add(
        _hello(
          invite: nextInvite,
          deviceId: rejectedId,
          deviceToken: 'rejected-device-token-01234567890123456789',
        ),
      );
      await rejectedPending;
      final rejectedError = _expectEvent(
        rejectedEvents.stream,
        'command.error',
      );
      await _resolve(http, port, adminToken, 'reject', rejectedId);
      await rejectedError;
      expect((await _getStatus(http, port))['pairedDevices'], isEmpty);
    } finally {
      await rejectedSubscription?.cancel();
      await reconnectSubscription?.cancel();
      await approvedSubscription?.cancel();
      await rejectedSocket?.close();
      await reconnectSocket?.close();
      await approvedSocket?.close();
      http?.close(force: true);
      await bridge?.close();
      await project.delete(recursive: true);
    }
  });
}

Future<int> _findFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<String> _createInvite(HttpClient client, int port, String token) async {
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port/pairing/invite'),
  );
  request.headers.set('x-remoteaisync-token', token);
  final response = await request.close();
  expect(response.statusCode, HttpStatus.ok);
  final data = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
  return data['invite'] as String;
}

Future<Map<String, dynamic>> _getStatus(HttpClient client, int port) async {
  final request = await client.getUrl(
    Uri.parse('http://127.0.0.1:$port/status'),
  );
  final response = await request.close();
  expect(response.statusCode, HttpStatus.ok);
  return (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
      .cast<String, dynamic>();
}

Future<void> _resolve(
  HttpClient client,
  int port,
  String token,
  String action,
  String deviceId, {
  String method = 'POST',
}) async {
  final uri = Uri.parse(
    'http://127.0.0.1:$port/pairing/$action?id=${Uri.encodeQueryComponent(deviceId)}',
  );
  final request = method == 'DELETE'
      ? await client.deleteUrl(uri)
      : await client.postUrl(uri);
  request.headers.set('x-remoteaisync-token', token);
  final response = await request.close();
  expect(response.statusCode, HttpStatus.ok);
  await response.drain<void>();
}

String _hello({
  String? invite,
  required String deviceId,
  required String deviceToken,
}) => jsonEncode({
  'schemaVersion': 1,
  'kind': 'client.hello',
  'payload': {
    'pairingToken': ?invite,
    'deviceId': deviceId,
    'deviceToken': deviceToken,
    'deviceName': 'Test phone',
  },
});

Map<String, dynamic> _decode(dynamic raw) =>
    (jsonDecode(raw as String) as Map).cast<String, dynamic>();

Future<Map<String, dynamic>> _expectEvent(
  Stream<Map<String, dynamic>> events,
  String kind,
) => events
    .firstWhere((event) => event['kind'] == kind)
    .timeout(const Duration(seconds: 3));

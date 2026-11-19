import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/application/host_client.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/relay_server.dart';

void main() {
  test('authenticates a room and relays data in both directions', () async {
    final token = List<String>.filled(4, '0123456789abcdef').join();
    final hostToken = List<String>.filled(4, 'fedcba9876543210').join();
    final relay = await RelayServer.bind(
      port: 0,
      clientToken: token,
      hostToken: hostToken,
    );
    expect(relay.address.isLoopback, isTrue);
    WebSocket? host;
    WebSocket? client;
    StreamSubscription<dynamic>? hostSubscription;
    StreamSubscription<dynamic>? clientSubscription;
    final hostFrames = StreamController<Map<String, dynamic>>.broadcast();
    final clientFrames = StreamController<Map<String, dynamic>>.broadcast();
    try {
      host = await WebSocket.connect('ws://127.0.0.1:${relay.port}/relay');
      hostSubscription = host.listen((raw) => hostFrames.add(_decode(raw)));
      host.add(
        jsonEncode({
          'kind': 'relay.hello',
          'role': 'host',
          'room': 'room_id_123456',
          'token': hostToken,
          'peerId': 'host',
        }),
      );
      final hostReady = await _expectFrame(
        hostFrames.stream,
        (frame) => frame['kind'] == 'relay.ready',
      );
      expect(
        ((hostReady['topology'] as Map)['nodes'] as List)
            .whereType<Map>()
            .map((node) => node['role'])
            .toSet(),
        {'relay', 'host'},
      );

      client = await WebSocket.connect('ws://127.0.0.1:${relay.port}/relay');
      clientSubscription = client.listen(
        (raw) => clientFrames.add(_decode(raw)),
      );
      final roomTopologyFuture = _expectFrame(
        hostFrames.stream,
        (frame) => frame['kind'] == 'relay.topology',
      );
      client.add(
        jsonEncode({
          'kind': 'relay.hello',
          'role': 'client',
          'room': 'room_id_123456',
          'token': hostReady['clientToken'],
        }),
      );
      final open = await _expectFrame(
        hostFrames.stream,
        (frame) => frame['kind'] == 'relay.open',
      );
      final channelId = open['channelId'] as String;
      host.add(jsonEncode({'kind': 'relay.ready', 'channelId': channelId}));
      await _expectFrame(
        clientFrames.stream,
        (frame) => frame['kind'] == 'relay.ready',
      );
      final roomTopology = await roomTopologyFuture;
      final roomNodes = ((roomTopology['topology'] as Map)['nodes'] as List)
          .whereType<Map>()
          .toList();
      expect(roomNodes.map((node) => node['role']).toSet(), {
        'relay',
        'host',
        'client',
      });
      final roomLinks = ((roomTopology['topology'] as Map)['links'] as List)
          .whereType<Map>()
          .toList();
      expect(roomLinks, hasLength(2));
      expect(roomLinks.every((link) => link['route'] == 'relay'), isTrue);

      client.add(jsonEncode({'kind': 'relay.data', 'data': 'client-frame'}));
      final fromClient = await _expectFrame(
        hostFrames.stream,
        (frame) => frame['kind'] == 'relay.data',
      );
      expect(fromClient['channelId'], channelId);
      expect(fromClient['data'], 'client-frame');

      host.add(
        jsonEncode({
          'kind': 'relay.data',
          'channelId': channelId,
          'data': 'host-frame',
        }),
      );
      final fromHost = await _expectFrame(
        clientFrames.stream,
        (frame) => frame['kind'] == 'relay.data',
      );
      expect(fromHost['data'], 'host-frame');
      expect(relay.clientCount, 1);
      expect(relay.hostCount, 1);
      expect(relay.roomCount, 1);
      final topology = relay.topologySnapshot();
      final nodes = (topology['nodes'] as List).whereType<Map>();
      expect(
        nodes.any(
          (node) => (node['role'] == 'host') && (node['bytesOut'] as num) > 0,
        ),
        isTrue,
      );
      host.add(jsonEncode({'kind': 'relay.ping'}));
      await _expectFrame(
        hostFrames.stream,
        (frame) => frame['kind'] == 'relay.pong',
      );

      final http = HttpClient();
      try {
        final health = await http.getUrl(
          Uri.parse('http://127.0.0.1:${relay.port}/health'),
        );
        final healthResponse = await health.close();
        final healthData =
            jsonDecode(await utf8.decoder.bind(healthResponse).join())
                as Map<String, dynamic>;
        expect(healthData.containsKey('topology'), isFalse);

        final statusRequest = await http.getUrl(
          Uri.parse('http://127.0.0.1:${relay.port}/status'),
        );
        final statusResponse = await statusRequest.close();
        final statusData =
            jsonDecode(await utf8.decoder.bind(statusResponse).join())
                as Map<String, dynamic>;
        expect(statusResponse.statusCode, HttpStatus.ok);
        expect(statusData['topology'], isA<Map>());
      } finally {
        http.close(force: true);
      }
    } finally {
      await clientSubscription?.cancel();
      await hostSubscription?.cancel();
      await client?.close();
      await host?.close();
      await relay.close();
      await hostFrames.close();
      await clientFrames.close();
    }
  });

  test(
    'replaces an existing client channel when the same peer reconnects',
    () async {
      final clientToken = List<String>.filled(4, '0123456789abcdef').join();
      final hostToken = List<String>.filled(4, 'fedcba9876543210').join();
      final relay = await RelayServer.bind(
        port: 0,
        clientToken: clientToken,
        hostToken: hostToken,
      );
      final hostFrames = StreamController<Map<String, dynamic>>.broadcast();
      final firstClientFrames =
          StreamController<Map<String, dynamic>>.broadcast();
      final secondClientFrames =
          StreamController<Map<String, dynamic>>.broadcast();
      WebSocket? host;
      WebSocket? firstClient;
      WebSocket? secondClient;
      StreamSubscription<dynamic>? hostSubscription;
      StreamSubscription<dynamic>? firstClientSubscription;
      StreamSubscription<dynamic>? secondClientSubscription;
      try {
        host = await WebSocket.connect('ws://127.0.0.1:${relay.port}/relay');
        hostSubscription = host.listen((raw) => hostFrames.add(_decode(raw)));
        host.add(
          jsonEncode({
            'kind': 'relay.hello',
            'role': 'host',
            'room': 'room_id_123456',
            'token': hostToken,
          }),
        );
        final hostReady = await _expectFrame(
          hostFrames.stream,
          (frame) => frame['kind'] == 'relay.ready',
        );

        Future<WebSocket> connectClient(
          StreamController<Map<String, dynamic>> frames,
          void Function(StreamSubscription<dynamic> value) setSubscription,
        ) async {
          final socket = await WebSocket.connect(
            'ws://127.0.0.1:${relay.port}/relay',
          );
          setSubscription(socket.listen((raw) => frames.add(_decode(raw))));
          socket.add(
            jsonEncode({
              'kind': 'relay.hello',
              'role': 'client',
              'room': 'room_id_123456',
              'token': hostReady['clientToken'],
              'peerId': 'phone-device-1',
            }),
          );
          final open = await _expectFrame(
            hostFrames.stream,
            (frame) => frame['kind'] == 'relay.open',
          );
          socket.add(jsonEncode({'kind': 'relay.ping'}));
          await _expectFrame(
            frames.stream,
            (frame) => frame['kind'] == 'relay.pong',
          );
          final channelId = open['channelId'];
          host!.add(
            jsonEncode({'kind': 'relay.ready', 'channelId': channelId}),
          );
          await _expectFrame(
            frames.stream,
            (frame) => frame['kind'] == 'relay.ready',
          );
          return socket;
        }

        firstClient = await connectClient(
          firstClientFrames,
          (value) => firstClientSubscription = value,
        );
        expect(relay.clientCount, 1);
        final closedOldChannel = _expectFrame(
          hostFrames.stream,
          (frame) => frame['kind'] == 'relay.close',
        );
        secondClient = await connectClient(
          secondClientFrames,
          (value) => secondClientSubscription = value,
        );
        await closedOldChannel;
        await expectLater(
          firstClient.done.timeout(const Duration(seconds: 3)),
          completes,
        );

        expect(relay.clientCount, 1);
        final clientNodes = (relay.topologySnapshot()['nodes'] as List)
            .whereType<Map>()
            .where((node) => node['role'] == 'client')
            .toList();
        expect(clientNodes, hasLength(1));
      } finally {
        await secondClientSubscription?.cancel();
        await firstClientSubscription?.cancel();
        await hostSubscription?.cancel();
        await secondClient?.close();
        await firstClient?.close();
        await host?.close();
        await relay.close();
        await hostFrames.close();
        await firstClientFrames.close();
        await secondClientFrames.close();
      }
    },
  );

  test('rejects invalid credentials before assigning a relay room', () async {
    final relay = await RelayServer.bind(
      port: 0,
      clientToken: List<String>.filled(4, '0123456789abcdef').join(),
      hostToken: List<String>.filled(4, 'fedcba9876543210').join(),
    );
    try {
      final client = await WebSocket.connect(
        'ws://127.0.0.1:${relay.port}/relay',
      );
      final received = Completer<Map<String, dynamic>>();
      client.listen((raw) {
        if (!received.isCompleted) received.complete(_decode(raw));
      });
      client.add(
        jsonEncode({
          'kind': 'relay.hello',
          'role': 'host',
          'room': 'room_id_123456',
          'token': 'wrong',
        }),
      );
      final frame = await received.future.timeout(const Duration(seconds: 3));
      expect(frame['kind'], 'relay.error');
      expect(relay.roomCount, 0);
      await client.close();
    } finally {
      await relay.close();
    }
  });

  test(
    'connects the Flutter host client through an isolated relay channel',
    () async {
      final clientToken = List<String>.filled(4, '0123456789abcdef').join();
      final hostToken = List<String>.filled(4, 'fedcba9876543210').join();
      final relay = await RelayServer.bind(
        port: 0,
        clientToken: clientToken,
        hostToken: hostToken,
      );
      final host = await WebSocket.connect(
        'ws://127.0.0.1:${relay.port}/relay',
      );
      final hostSubscription = host.listen((raw) {
        final frame = _decode(raw);
        if (frame['kind'] == 'relay.open') {
          final channelId = frame['channelId'];
          host.add(jsonEncode({'kind': 'relay.ready', 'channelId': channelId}));
          host.add(
            jsonEncode({
              'kind': 'relay.data',
              'channelId': channelId,
              'data': jsonEncode({
                'schemaVersion': 1,
                'kind': 'host.ready',
                'seq': 1,
                'sessionId': '',
                'payload': {'openCodeVersion': 'test'},
              }),
            }),
          );
        }
      });
      final client = HostClient();
      try {
        host.add(
          jsonEncode({
            'kind': 'relay.hello',
            'role': 'host',
            'room': 'room_id_654321',
            'token': hostToken,
          }),
        );
        await client.connect(
          address: '',
          pairingToken: 'main-host-pairing-token',
          relayUrl: 'ws://127.0.0.1:${relay.port}',
          relayRoom: 'room_id_654321',
          relayToken: relay.clientTokenForRoom('room_id_654321'),
        );
        expect(client.status, HostConnectionStatus.connected);
        expect(client.hostVersion, 'test');
        expect(relay.clientCount, 1);
      } finally {
        await client.disconnect();
        await hostSubscription.cancel();
        await host.close();
        await relay.close();
      }
    },
  );

  test(
    'issues one-time host registration credentials and rejects reuse',
    () async {
      final root = Directory.systemTemp.createTempSync('remoteaisync-relay-');
      final adminToken = List<String>.filled(4, 'admin-secret-012345').join();
      final relay = await RelayServer.bind(
        port: 0,
        clientToken: adminToken,
        hostToken: List<String>.filled(4, 'legacy-host-secret').join(),
        storageDirectory: root.path,
      );
      final http = HttpClient();
      try {
        final issued = await _postJson(
          http,
          'http://127.0.0.1:${relay.port}/admin/registration-code',
          headers: {'x-remoteaisync-admin-token': adminToken},
        );
        expect(issued.status, HttpStatus.created);
        final registration = jsonDecode(issued.body) as Map<String, dynamic>;
        final registerUri = 'http://127.0.0.1:${relay.port}/register-host';
        final body = {'registrationCode': registration['code']};
        final registered = await _postJson(http, registerUri, body: body);
        expect(registered.status, HttpStatus.created);
        final credentials = jsonDecode(registered.body) as Map<String, dynamic>;
        expect(credentials['room'], isA<String>());
        expect(credentials['hostToken'], isNot(credentials['clientToken']));

        final reused = await _postJson(http, registerUri, body: body);
        expect(reused.status, HttpStatus.unauthorized);

        final host = await WebSocket.connect(
          'ws://127.0.0.1:${relay.port}/relay',
        );
        final hostFrames = host.map(_decode);
        host.add(
          jsonEncode({
            'kind': 'relay.hello',
            'role': 'host',
            'room': credentials['room'],
            'token': credentials['hostToken'],
          }),
        );
        final ready = await hostFrames
            .firstWhere((frame) => frame['kind'] == 'relay.ready')
            .timeout(const Duration(seconds: 3));
        expect(ready['clientToken'], credentials['clientToken']);
        await host.close();
      } finally {
        http.close(force: true);
        await relay.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('registration codes expire and can be revoked', () async {
    final token = List<String>.filled(4, 'admin-secret-012345').join();
    final relay = await RelayServer.bind(
      port: 0,
      clientToken: token,
      hostToken: List<String>.filled(4, 'legacy-host-secret').join(),
      registrationCodeLifetime: const Duration(milliseconds: 30),
    );
    final http = HttpClient();
    try {
      final base = 'http://127.0.0.1:${relay.port}';
      final expired = await _postJson(
        http,
        '$base/admin/registration-code',
        headers: {'x-remoteaisync-admin-token': token},
      );
      final expiredData = jsonDecode(expired.body) as Map<String, dynamic>;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final expiredUse = await _postJson(
        http,
        '$base/register-host',
        body: {'registrationCode': expiredData['code']},
      );
      expect(expiredUse.status, HttpStatus.unauthorized);

      final revoked = await _postJson(
        http,
        '$base/admin/registration-code',
        headers: {'x-remoteaisync-admin-token': token},
      );
      final revokedData = jsonDecode(revoked.body) as Map<String, dynamic>;
      final request = await http.deleteUrl(
        Uri.parse('$base/admin/registration-code?id=${revokedData['id']}'),
      );
      request.headers.set('x-remoteaisync-admin-token', token);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final revokedUse = await _postJson(
        http,
        '$base/register-host',
        body: {'registrationCode': revokedData['code']},
      );
      expect(revokedUse.status, HttpStatus.unauthorized);
    } finally {
      http.close(force: true);
      await relay.close();
    }
  });

  test('tracks peer reconnects and relay heartbeat round trips', () async {
    final hostToken = List<String>.filled(4, 'fedcba9876543210').join();
    final relay = await RelayServer.bind(
      port: 0,
      clientToken: List<String>.filled(4, '0123456789abcdef').join(),
      hostToken: hostToken,
    );
    final frames = StreamController<Map<String, dynamic>>.broadcast();
    WebSocket? host;
    StreamSubscription<dynamic>? subscription;
    try {
      Future<WebSocket> connectHost() async {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${relay.port}/relay',
        );
        subscription = socket.listen((raw) => frames.add(_decode(raw)));
        socket.add(
          jsonEncode({
            'kind': 'relay.hello',
            'role': 'host',
            'room': 'room_id_123456',
            'token': hostToken,
            'peerId': 'host-device',
          }),
        );
        await _expectFrame(
          frames.stream,
          (frame) => frame['kind'] == 'relay.ready',
        );
        socket.add(jsonEncode({'kind': 'relay.ping'}));
        await _expectFrame(
          frames.stream,
          (frame) => frame['kind'] == 'relay.pong',
        );
        return socket;
      }

      host = await connectHost();
      await subscription?.cancel();
      await host.close();
      host = await connectHost();
      final hostNode = (relay.topologySnapshot()['nodes'] as List)
          .whereType<Map>()
          .firstWhere((node) => node['role'] == 'host');
      expect(hostNode['reconnects'], 1);
      expect(hostNode['heartbeatAt'], isA<String>());
    } finally {
      await subscription?.cancel();
      await host?.close();
      await relay.close();
      await frames.close();
    }
  });
}

Future<({int status, String body})> _postJson(
  HttpClient client,
  String address, {
  Map<String, String> headers = const {},
  Map<String, Object?> body = const {},
}) async {
  final request = await client.postUrl(Uri.parse(address));
  request.headers.contentType = ContentType.json;
  for (final entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  request.write(jsonEncode(body));
  final response = await request.close();
  return (
    status: response.statusCode,
    body: await utf8.decoder.bind(response).join(),
  );
}

Map<String, dynamic> _decode(dynamic raw) =>
    (jsonDecode(raw as String) as Map).cast<String, dynamic>();

Future<Map<String, dynamic>> _expectFrame(
  Stream<Map<String, dynamic>> frames,
  bool Function(Map<String, dynamic>) predicate,
) => frames.firstWhere(predicate).timeout(const Duration(seconds: 3));

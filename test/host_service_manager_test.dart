import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/desktop/host_service_manager.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  test('reads relay health from its selected port and mode', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/health') {
        request.response.write(
          jsonEncode({'status': 'ok', 'rooms': 2, 'hosts': 1, 'clients': 3}),
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final manager = HostServiceManager(
      mode: HostRuntimeMode.relay,
      relayPort: server.port,
      monitor: false,
    );
    addTearDown(manager.dispose);
    addTearDown(subscription.cancel);
    addTearDown(server.close);

    await manager.refresh();

    expect(manager.snapshot.reachable, isTrue);
    expect(manager.snapshot.mode, HostRuntimeMode.relay);
    expect(manager.snapshot.relayRooms, 2);
    expect(manager.snapshot.relayHosts, 1);
    expect(manager.snapshot.relayClients, 3);
  });

  test('reads the number of connected clients from host health', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/health') {
        request.response.write(
          jsonEncode({'status': 'ok', 'connectedClients': 2}),
        );
      } else if (request.uri.path == '/status') {
        request.response.write(
          jsonEncode({
            'status': 'ok',
            'connectedClients': 2,
            'agents': [
              {
                'id': 'opencode',
                'availability': 'available',
                'version': '2.1.0',
              },
              {
                'id': 'codex',
                'availability': 'unavailable',
                'detail': 'Codex app-server 未启动',
              },
              {
                'id': 'claude',
                'availability': 'unsupported',
                'detail': 'Claude Code 适配器尚未接入',
              },
            ],
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final manager = HostServiceManager(port: server.port, monitor: false);
    addTearDown(manager.dispose);
    addTearDown(subscription.cancel);
    addTearDown(server.close);

    await manager.refresh();

    expect(manager.snapshot.reachable, isTrue);
    expect(manager.snapshot.connectedClients, 2);
    expect(manager.snapshot.agentStatuses['opencode']?.version, '2.1.0');
    expect(
      manager.snapshot.agentStatuses['codex']?.availability,
      AgentAvailability.unavailable,
    );
    expect(
      manager.snapshot.agentStatuses['claude']?.availability,
      AgentAvailability.unsupported,
    );
  });

  test('keeps an active pairing invite across status refreshes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/health') {
        request.response.write(jsonEncode({'status': 'ok'}));
      } else if (request.uri.path == '/status') {
        request.response.write(jsonEncode({'status': 'ok'}));
      } else if (request.uri.path == '/dev-config') {
        request.response.write(
          jsonEncode({
            'pairingToken': 'admin-token',
            'lanAddresses': ['192.168.1.20'],
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final invite = 'invite-token-012345678901234567890123';
    final manager = HostServiceManager(
      port: server.port,
      monitor: false,
      initialSnapshot: HostServiceSnapshot(
        pairingInvite: invite,
        pairingInviteExpiresAt: DateTime.now()
            .add(const Duration(minutes: 4))
            .toIso8601String(),
      ),
    );
    addTearDown(manager.dispose);
    addTearDown(subscription.cancel);
    addTearDown(server.close);

    await manager.refresh();

    expect(manager.snapshot.pairingInvite, invite);
    expect(manager.snapshot.pairingInviteExpiresAt, isNotNull);
  });
}

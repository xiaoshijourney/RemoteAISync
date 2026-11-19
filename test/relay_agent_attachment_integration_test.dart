import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/application/host_client.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/bridge.dart';
// ignore: avoid_relative_lib_imports
import '../host/lib/src/relay_connector.dart';
// ignore: avoid_relative_lib_imports
import '../host/lib/src/relay_server.dart';

void main() {
  test(
    'a file uploaded by a paired client reaches Codex through the relay',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'remoteaisync-relay-agent-attachment-',
      );
      final workspacePort = await _availablePort();
      const room = 'remoteaisync_probe_001';
      final pairingToken = _token('pair');
      final relayClientToken = _token('client');
      final relayHostToken = _token('host');
      final codex = Platform.environment['REMOTEAISYNC_CODEX_EXECUTABLE'];
      if (codex == null || codex.trim().isEmpty) {
        await root.delete(recursive: true);
        fail('Set REMOTEAISYNC_CODEX_EXECUTABLE to run this live-agent test.');
      }

      final relay = await RelayServer.bind(
        port: 0,
        clientToken: relayClientToken,
        hostToken: relayHostToken,
      );
      AgentBridge? bridge;
      RelayConnector? connector;
      HostClient? client;
      try {
        bridge = await AgentBridge.start(
          projectDirectory: root.path,
          websocketPort: workspacePort,
          pairingToken: pairingToken,
          executable: 'remoteaisync-no-opencode',
          openCodeCommandRunner:
              ({
                required executable,
                required arguments,
                required workingDirectory,
              }) async =>
                  ProcessResult(1, 1, '', 'disabled in integration test'),
          codexExecutable: codex,
          claudeExecutable: 'remoteaisync-no-claude',
        );
        connector = RelayConnector(
          bridge: bridge,
          relayUri: Uri.parse('ws://127.0.0.1:${relay.port}'),
          roomId: room,
          hostToken: relayHostToken,
        );
        unawaited(connector.start());
        final relayDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (relay.hostCount == 0 && DateTime.now().isBefore(relayDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          relay.hostCount,
          1,
          reason: 'Host failed to join the test relay.',
        );

        client = HostClient();
        await client.connect(
          address: '',
          pairingToken: pairingToken,
          relayUrl: 'ws://127.0.0.1:${relay.port}',
          relayRoom: room,
          relayToken: relay.clientTokenForRoom(room),
        );
        await client.createAgentSession(
          'codex',
          directory: root.path,
          ephemeral: true,
        );

        const canary = 'RAISYNC_FILE_CANARY_71D4B0C9';
        final attachment = File(
          '${root.path}${Platform.pathSeparator}probe.txt',
        );
        await attachment.writeAsString('The verification code is $canary.');
        final roundTrip = File(
          '${root.path}${Platform.pathSeparator}roundtrip.bin',
        );
        final roundTripBytes = List<int>.generate(
          620 * 1024 + 17,
          (index) => index % 239,
        );
        await roundTrip.writeAsBytes(roundTripBytes);
        final downloaded = await client.downloadWorkspaceFile(roundTrip.path);
        expect(downloaded.name, 'roundtrip.bin');
        expect(downloaded.bytes, roundTripBytes);
        await client.deleteWorkspaceFile(roundTrip.path);
        expect(await roundTrip.exists(), isFalse);

        final attachmentId = await client.uploadAttachment(
          XFile(attachment.path),
        );
        await client.sendReply(
          'Open this uploaded file: ${attachment.path}. Read its contents and reply with only the verification code.',
          attachmentIds: [attachmentId],
        );

        final deadline = DateTime.now().add(const Duration(seconds: 75));
        String? response;
        while (DateTime.now().isBefore(deadline)) {
          final matching = client.messages
              .where((message) => message.author.name == 'assistant')
              .map((message) => message.text)
              .where((text) => text.contains(canary))
              .toList(growable: false);
          response = matching.isEmpty ? null : matching.first;
          if (response != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (response == null) {
          final transcript = client.messages
              .map((message) => '${message.author.name}:${message.text.length}')
              .join(', ');
          fail(
            'Codex did not echo the uploaded file marker. Messages: $transcript',
          );
        }
        expect(response, contains(canary));
        expect(await attachment.exists(), isTrue);
      } finally {
        await client?.disconnect();
        await connector?.close();
        await relay.close();
        await bridge?.close();
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['REMOTEAISYNC_RUN_LIVE_AGENT_TEST'] != '1'
        ? 'Opt-in test; requires the user-installed Codex CLI.'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<int> _availablePort() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close(force: true);
  return port;
}

String _token(String label) =>
    '$label-${DateTime.now().microsecondsSinceEpoch}-'
    '0123456789abcdef0123456789abcdef';

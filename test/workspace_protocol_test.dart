import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/bridge.dart';
import 'support/pairing_helper.dart';

void main() {
  test(
    'paired clients can browse, create folders, read, write, and select a workspace',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'remoteaisync-workspace-',
      );
      final existing = File('${root.path}${Platform.pathSeparator}note.txt');
      await existing.writeAsString('before');
      final image = File('${root.path}${Platform.pathSeparator}preview.png');
      await image.writeAsBytes([1, 2, 3]);
      final downloadBytes = List<int>.generate(
        700 * 1024 + 19,
        (index) => index % 251,
      );
      final downloadFile = File(
        '${root.path}${Platform.pathSeparator}download.bin',
      );
      await downloadFile.writeAsBytes(downloadBytes);
      final reserved = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close(force: true);
      final token = 'test-pairing-token-' * 3;
      final bridge = await AgentBridge.start(
        projectDirectory: root.path,
        websocketPort: port,
        pairingToken: token,
        allowLocalDevConfig: true,
        executable: 'fake-opencode',
        openCodeCommandRunner:
            ({
              required executable,
              required arguments,
              required workingDirectory,
            }) async =>
                ProcessResult(1, 1, '', 'OpenCode service is not running.'),
        codexExecutable: 'missing-codex-for-workspace-test',
      );
      final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final http = HttpClient();
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final subscription = socket.listen((raw) {
        events.add(jsonDecode(raw as String) as Map<String, dynamic>);
      });
      Future<Map<String, dynamic>> command(
        String kind,
        Map<String, Object?> payload,
      ) async {
        final id = 'test-${DateTime.now().microsecondsSinceEpoch}';
        final completer = Completer<Map<String, dynamic>>();
        final listen = events.stream.listen((event) {
          final data = event['payload'];
          if (data is Map && data['commandId'] == id) {
            completer.complete(data.cast<String, dynamic>());
          }
        });
        socket.add(
          jsonEncode({
            'schemaVersion': 1,
            'commandId': id,
            'kind': kind,
            'expectedRevision': 0,
            'payload': payload,
          }),
        );
        try {
          return await completer.future.timeout(const Duration(seconds: 5));
        } finally {
          await listen.cancel();
        }
      }

      try {
        await pairTestDevice(
          http: http,
          port: port,
          adminToken: token,
          socket: socket,
          events: events.stream,
        );

        if (Platform.isWindows) {
          final roots = await command('workspace.list', {'path': '@roots'});
          expect(roots['ok'], isTrue);
          expect(
            (roots['entries'] as List).map((entry) => (entry as Map)['name']),
            contains(root.path.substring(0, 2)),
          );
        }

        final listed = await command('workspace.list', {'path': root.path});
        expect(listed['ok'], isTrue);
        expect(
          (listed['entries'] as List).map((entry) => (entry as Map)['name']),
          contains('note.txt'),
        );

        final created = await command('workspace.mkdir', {
          'parent': root.path,
          'name': 'new-folder',
        });
        expect(created['ok'], isTrue);
        expect(
          await Directory(
            '${root.path}${Platform.pathSeparator}new-folder',
          ).exists(),
          isTrue,
        );

        final written = await command('workspace.write', {
          'path': existing.path,
          'content': 'after',
        });
        expect(written['ok'], isTrue);
        expect(await existing.readAsString(), 'after');

        final binaryBefore = await image.readAsBytes();
        final binaryWrite = await command('workspace.write', {
          'path': image.path,
          'content': 'not an image',
        });
        expect(binaryWrite['ok'], isNot(true));
        expect(await image.readAsBytes(), binaryBefore);

        final missingPath = '${root.path}${Platform.pathSeparator}missing.txt';
        final missingWrite = await command('workspace.write', {
          'path': missingPath,
          'content': 'do not create',
        });
        expect(missingWrite['ok'], isNot(true));
        expect(await File(missingPath).exists(), isFalse);

        final read = await command('workspace.read', {'path': existing.path});
        expect(read['text'], 'after');
        final imagePreview = await command('workspace.read', {
          'path': image.path,
        });
        expect(imagePreview['previewKind'], 'image');
        expect(imagePreview['mimeType'], 'image/png');
        expect(imagePreview['bytes'], 'AQID');

        final firstChunk = await command('workspace.download', {
          'path': downloadFile.path,
          'offset': 0,
          'length': 256 * 1024,
        });
        expect(firstChunk['fileName'], 'download.bin');
        expect(firstChunk['totalBytes'], downloadBytes.length);
        expect(firstChunk['done'], isFalse);
        final secondChunk = await command('workspace.download', {
          'path': downloadFile.path,
          'offset': 256 * 1024,
          'length': 256 * 1024,
        });
        expect(secondChunk['done'], isFalse);
        final thirdChunk = await command('workspace.download', {
          'path': downloadFile.path,
          'offset': 512 * 1024,
          'length': 256 * 1024,
        });
        expect(thirdChunk['done'], isTrue);
        expect([
          ...base64Decode(firstChunk['data'] as String),
          ...base64Decode(secondChunk['data'] as String),
          ...base64Decode(thirdChunk['data'] as String),
        ], downloadBytes);

        final deleted = await command('workspace.delete', {
          'path': downloadFile.path,
        });
        expect(deleted['ok'], isTrue);
        expect(await downloadFile.exists(), isFalse);
        final deleteDirectory = await command('workspace.delete', {
          'path': root.path,
        });
        expect(deleteDirectory['ok'], isNot(true));
        expect(await Directory(root.path).exists(), isTrue);

        final selected = await command('workspace.select', {
          'path': root.path,
          'sessionScope': 'all',
        });
        expect(selected['ok'], isTrue);
      } finally {
        await socket.close();
        http.close(force: true);
        await subscription.cancel();
        await events.close();
        await bridge.close();
        await root.delete(recursive: true);
      }
    },
  );
}

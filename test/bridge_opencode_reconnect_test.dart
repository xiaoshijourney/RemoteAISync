import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/bridge.dart';

void main() {
  test('starts the host bridge when no supported agent is installed', () async {
    final project = await Directory.systemTemp.createTemp(
      'remoteaisync-no-agents-',
    );
    AgentBridge? bridge;
    try {
      Future<ProcessResult> missingExecutable({
        required String executable,
        required List<String> arguments,
        required String workingDirectory,
      }) async {
        throw ProcessException(executable, arguments, 'not installed');
      }

      bridge = await AgentBridge.start(
        projectDirectory: project.path,
        websocketPort: 0,
        executable: 'missing-opencode-for-test',
        openCodeCommandRunner: missingExecutable,
        codexExecutable: 'missing-codex-for-test',
        claudeExecutable: 'missing-claude-for-test',
      );

      expect(bridge.agentStatuses, hasLength(3));
      expect(
        bridge.agentStatuses.map((agent) => agent['availability']),
        everyElement('notInstalled'),
      );
      expect(bridge.pairingTokenValue, isNotEmpty);
    } finally {
      await bridge?.close();
      await project.delete(recursive: true);
    }
  });

  test(
    'discovers OpenCode when its local service starts after the host',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'remoteaisync-opencode-retry-',
      );
      final state = Directory('${project.path}${Platform.pathSeparator}state');
      await state.create();
      final serviceFile = File(
        '${state.path}${Platform.pathSeparator}service.json',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/info') {
          request.response.write(jsonEncode({'version': 'test-version'}));
        } else if (request.uri.path == '/api/session') {
          request.response.write(jsonEncode({'data': []}));
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('{}');
        }
        await request.response.close();
      });
      var serviceStarted = false;
      Future<ProcessResult> commandRunner({
        required String executable,
        required List<String> arguments,
        required String workingDirectory,
      }) async {
        if (arguments.join(' ') == 'service status') {
          return ProcessResult(
            0,
            serviceStarted ? 0 : 1,
            serviceStarted ? 'http://127.0.0.1:${server.port}' : '',
            '',
          );
        }
        if (arguments.join(' ') == 'debug paths state') {
          return ProcessResult(0, 0, state.path, '');
        }
        return ProcessResult(0, 1, '', 'unexpected command');
      }

      await serviceFile.writeAsString(
        jsonEncode({
          'url': 'http://127.0.0.1:${server.port}',
          'password': 'test-password',
        }),
      );

      AgentBridge? bridge;
      try {
        bridge = await AgentBridge.start(
          projectDirectory: project.path,
          websocketPort: 0,
          executable: 'fake-opencode',
          openCodeCommandRunner: commandRunner,
          openCodeDiscoveryRetryInterval: const Duration(milliseconds: 100),
          codexExecutable: 'missing-codex-for-test',
        );
        expect(_openCodeStatus(bridge), 'unavailable');
        expect(
          bridge.agentStatuses.singleWhere(
            (agent) => agent['id'] == 'codex',
          )['availability'],
          'notInstalled',
        );
        expect(bridge.agentStatuses, hasLength(3));

        serviceStarted = true;
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (_openCodeStatus(bridge) != 'available' &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }

        expect(_openCodeStatus(bridge), 'available');
        expect(bridge.agentStatuses.first['version'], 'test-version');
      } finally {
        await bridge?.close();
        await serverSubscription.cancel();
        await server.close(force: true);
        await project.delete(recursive: true);
      }
    },
  );
}

String _openCodeStatus(AgentBridge bridge) => bridge.agentStatuses
    .singleWhere((agent) => agent['id'] == 'opencode')['availability']
    .toString();

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/codex_hook_broker.dart';
// ignore: avoid_relative_lib_imports
import '../host/lib/src/codex_hook_runtime.dart';

void main() {
  test('desktop hook approvals resolve only for their session', () async {
    final broker = CodexHookBroker(waitTimeout: const Duration(seconds: 1));
    try {
      final request = broker.request(
        sessionId: 'codex:desktop-thread',
        toolName: 'Bash',
        toolInput: {'command': 'echo test'},
      );
      final permission = broker.listPermissions('codex:desktop-thread').single;
      expect(permission.resources.join('\n'), contains('echo test'));
      expect(broker.pendingCountFor('codex:desktop-thread'), 1);
      expect(
        broker.resolve('codex:other-thread', permission.id, allow: true),
        isFalse,
      );
      expect(
        broker.resolve('codex:desktop-thread', permission.id, allow: true),
        isTrue,
      );
      expect(await request, isTrue);
      expect(broker.pendingCountFor('codex:desktop-thread'), 0);
    } finally {
      await broker.close();
    }
  });

  test(
    'desktop hook returns control to Codex on timeout or shutdown',
    () async {
      final broker = CodexHookBroker(
        waitTimeout: const Duration(milliseconds: 20),
      );
      expect(
        await broker.request(
          sessionId: 'codex:desktop-thread',
          toolName: 'Bash',
          toolInput: {},
        ),
        isNull,
      );
      final pending = broker.request(
        sessionId: 'codex:desktop-thread',
        toolName: 'Bash',
        toolInput: {},
      );
      await broker.close();
      expect(await pending, isNull);
    },
  );

  test('desktop hook falls back when paired clients disconnect', () async {
    final broker = CodexHookBroker(waitTimeout: const Duration(minutes: 5));
    final pending = broker.request(
      sessionId: 'codex:desktop-thread',
      toolName: 'Bash',
      toolInput: {},
    );
    broker.fallBackPending();
    expect(await pending, isNull);
    expect(broker.pendingCountFor('codex:desktop-thread'), 0);
    await broker.close();
  });

  test('desktop hook limits the number of pending approvals', () async {
    final broker = CodexHookBroker(waitTimeout: const Duration(minutes: 5));
    const session = 'codex:desktop-thread';
    try {
      final requests = List.generate(
        20,
        (_) =>
            broker.request(sessionId: session, toolName: 'Bash', toolInput: {}),
      );
      expect(broker.pendingCountFor(session), 20);
      expect(
        await broker.request(
          sessionId: session,
          toolName: 'Bash',
          toolInput: {},
        ),
        isNull,
      );
      for (final permission in broker.listPermissions(session)) {
        expect(broker.resolve(session, permission.id, allow: false), isTrue);
      }
      expect(await Future.wait(requests), everyElement(isFalse));
      expect(broker.pendingCountFor(session), 0);
    } finally {
      await broker.close();
    }
  });

  test('hook process maps local allow and fallback responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final temp = await Directory.systemTemp.createTemp(
      'remoteaisync-hook-test-',
    );
    const token = 'local-hook-test-token';
    await writeCodexHookRuntime(
      port: port,
      projectDirectory: temp.path,
      token: token,
    );
    var decision = 'allow';
    final subscription = server.listen((request) async {
      expect(request.uri.path, '/codex-hook/approval');
      expect(request.headers.value('x-remoteaisync-hook-token'), token);
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['tool_name'], 'Bash');
      expect(body['tool_input'], {'command': 'echo test'});
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'decision': decision}));
      await request.response.close();
    });
    try {
      final allowed = await _runHook(port, temp.path);
      expect((allowed['hookSpecificOutput'] as Map)['decision'], {
        'behavior': 'allow',
      });
      decision = 'fallback';
      expect(await _runHook(port, temp.path), isEmpty);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await deleteCodexHookRuntimeIfOwned(port: port, token: token);
      await temp.delete(recursive: true);
    }
  });

  test('installer preserves other hooks and is repeatable', () async {
    final temp = await Directory.systemTemp.createTemp(
      'remoteaisync-hook-install-test-',
    );
    final config = File(
      '${temp.path}${Platform.pathSeparator}.codex${Platform.pathSeparator}hooks.json',
    );
    await config.parent.create(recursive: true);
    await config.writeAsString(
      jsonEncode({
        'hooks': {
          'SessionStart': [
            {
              'hooks': [
                {'type': 'command', 'command': 'echo existing'},
              ],
            },
          ],
          'PermissionRequest': [
            {
              'matcher': 'Bash',
              'hooks': [
                {'type': 'command', 'command': 'echo existing approval'},
                {
                  'type': 'command',
                  'command': 'dart codex_permission_hook.dart --port 7777',
                },
              ],
            },
          ],
        },
      }),
    );
    try {
      final installer = File(
        'host/bin/install_codex_permission_hook.dart',
      ).absolute.path;
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await Process.run(_dartExecutable(), [
          installer,
          '--project',
          temp.path,
          '--port',
          '8898',
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      }
      final parsed = jsonDecode(await config.readAsString()) as Map;
      final hooks = parsed['hooks'] as Map;
      expect(hooks['SessionStart'], hasLength(1));
      expect(hooks['PermissionRequest'], hasLength(2));
      final approvalGroups = hooks['PermissionRequest'] as List;
      expect((approvalGroups.first as Map)['matcher'], 'Bash');
      expect((approvalGroups.first as Map)['hooks'], [
        {'type': 'command', 'command': 'echo existing approval'},
      ]);
      final command =
          (((approvalGroups.last as Map)['hooks'] as List).single
                  as Map)['command']
              .toString();
      expect(command, contains('codex_permission_hook.dart'));
      expect(command, contains('--port 8898'));
    } finally {
      await temp.delete(recursive: true);
    }
  });
}

Future<Map> _runHook(int port, String project) async {
  final script = File('host/bin/codex_permission_hook.dart').absolute.path;
  final process = await Process.start(_dartExecutable(), [
    script,
    '--port',
    '$port',
  ], workingDirectory: project);
  process.stdin.writeln(
    jsonEncode({
      'hook_event_name': 'PermissionRequest',
      'session_id': '01a1a4ed-3e7c-70e3-b828-81f7fc2a2ee9',
      'cwd': project,
      'tool_name': 'Bash',
      'tool_input': {'command': 'echo test'},
    }),
  );
  await process.stdin.close();
  final output = await utf8.decoder
      .bind(process.stdout)
      .join()
      .timeout(const Duration(seconds: 10));
  final error = await utf8.decoder.bind(process.stderr).join();
  expect(await process.exitCode, 0, reason: error);
  return jsonDecode(output) as Map;
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null) return 'dart';
  return '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}';
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/codex_api.dart';
// ignore: avoid_relative_lib_imports
import '../host/lib/src/agent_executable_resolver.dart';

void main() {
  test('reports a missing Codex CLI separately from app-server failures', () {
    expect(
      CodexApi.start(
        projectDirectory: Directory.current.path,
        executable: 'remoteaisync-definitely-missing-codex',
      ),
      throwsA(isA<AgentExecutableNotFoundException>()),
    );
  });

  test('normalizes a relative project path before listing threads', () async {
    final temp = await Directory.systemTemp.createTemp(
      'remoteaisync-codex-path-test-',
    );
    final fixture = File('test/support/fake_codex_app_server.dart').absolute;
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final dartExecutable = flutterRoot == null
        ? 'dart'
        : '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart.exe';
    final process = await Process.start(dartExecutable, [
      fixture.path,
      '${temp.path}${Platform.pathSeparator}responses.jsonl',
    ], workingDirectory: Directory.current.path);
    final api = await CodexApi.attach(
      process,
      projectDirectory: '.',
      version: 'codex-cli test',
    );
    try {
      expect(api.projectDirectory, Directory.current.path);
      expect(
        (await api.listSessions()).map((session) => session.id),
        contains('codex:fake-thread'),
      );
    } finally {
      await api.close();
      await temp.delete(recursive: true);
    }
  });

  test(
    'finds Windows desktop threads despite cwd spelling differences',
    () async {
      if (!Platform.isWindows) return;
      final temp = await Directory.systemTemp.createTemp(
        'remoteaisync-codex-cwd-test-',
      );
      final fixture = File('test/support/fake_codex_app_server.dart').absolute;
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final dartExecutable = flutterRoot == null
          ? 'dart'
          : '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart.exe';
      final process = await Process.start(dartExecutable, [
        fixture.path,
        '${temp.path}${Platform.pathSeparator}responses.jsonl',
      ], workingDirectory: Directory.current.path);
      final api = await CodexApi.attach(
        process,
        projectDirectory: Directory.current.path
            .replaceAll(r'\', '/')
            .toLowerCase(),
        version: 'codex-cli test',
      );
      try {
        final sessions = await api.listSessions();
        expect(
          sessions.map((session) => session.id),
          contains('codex:fake-thread'),
        );
        expect(
          sessions.map((session) => session.id),
          contains('codex:persisted-app-server-thread'),
        );
      } finally {
        await api.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('Codex app-server maps history, questions and approvals', () async {
    final temp = await Directory.systemTemp.createTemp(
      'remoteaisync-codex-test-',
    );
    final log = File('${temp.path}${Platform.pathSeparator}responses.jsonl');
    final fixture = File('test/support/fake_codex_app_server.dart').absolute;
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final dartExecutable = flutterRoot == null
        ? 'dart'
        : '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart.exe';
    final process = await Process.start(dartExecutable, [
      fixture.path,
      log.path,
    ], workingDirectory: Directory.current.path);
    final api = await CodexApi.attach(
      process,
      projectDirectory: Directory.current.path,
      version: 'codex-cli test',
    );
    try {
      final sessions = await api.listSessions();
      expect(
        sessions.map((session) => session.id),
        contains('codex:persisted-app-server-thread'),
      );
      expect(
        sessions
            .firstWhere(
              (session) => session.id == 'codex:persisted-app-server-thread',
            )
            .remoteManaged,
        isTrue,
      );
      final runningDesktop = await api.listMessages(
        'codex:persisted-app-server-thread',
      );
      expect(runningDesktop[runningDesktop.length - 2].text, 'Desktop prompt');
      expect(runningDesktop.last.text, 'Desktop response while running');
      expect(
        runningDesktop.map((message) => message.id),
        isNot(contains('older-unlisted-item')),
      );
      final desktopSession = sessions.firstWhere(
        (session) => session.id == 'codex:fake-thread',
      );
      expect(desktopSession.agentId, 'codex');
      expect(desktopSession.remoteManaged, isFalse);
      final messages = await api.listMessages(desktopSession.id);
      expect(messages.map((item) => item.author), [
        MessageAuthor.user,
        MessageAuthor.assistant,
        MessageAuthor.tool,
        MessageAuthor.tool,
        MessageAuthor.tool,
        MessageAuthor.tool,
        MessageAuthor.tool,
        MessageAuthor.system,
      ]);
      expect(messages.first.text, 'Hello Codex');
      expect(messages[3].text, contains('退出码：2'));
      expect(messages[3].text, contains('命令执行失败'));
      expect(messages[4].text, contains('+new line'));
      expect(messages[5].text, contains('错误：not found'));
      expect(messages[6].text, contains('check complete'));
      expect(messages.last.text, contains('Model unavailable'));
      final queuedId = await api.queueDesktopMessage(
        desktopSession.id,
        'Queued from phone',
        localImages: ['/tmp/phone.png'],
      );
      expect(queuedId, 'fake-queued-1');
      final queued = await api.listQueuedMessages(desktopSession.id);
      expect(queued, hasLength(1));
      expect(queued.single.text, 'Queued from phone');
      expect(queued.single.imageCount, 1);
      final paged = await api.listQueuedMessages('codex:fake-paged-thread');
      expect(paged.map((item) => item.id), ['paged-1', 'paged-2']);
      expect(
        await api.deleteQueuedMessage(desktopSession.id, queuedId),
        isTrue,
      );
      expect(await api.listQueuedMessages(desktopSession.id), isEmpty);
      expect(
        await api.deleteQueuedMessage(desktopSession.id, queuedId),
        isFalse,
      );

      await _waitFor(
        () =>
            api.listForms(desktopSession.id).isNotEmpty &&
            api.listPermissions(desktopSession.id).length == 4,
      );
      expect(api.pendingCountFor(desktopSession.id), 5);
      final form = api.listForms(desktopSession.id).single;
      expect(form.fields.single.options.first.value, 'Safe');
      expect(form.fields.single.custom, isTrue);
      final permissions = api.listPermissions(desktopSession.id);
      expect(permissions.map((item) => item.action), [
        'commandExecution',
        'fileChange',
        'fileChange',
        'permissions',
      ]);
      expect(permissions[0].resources.first, contains('已有终端'));
      expect(permissions[1].resources.first, contains('C:\\Shared'));
      expect(permissions[1].resources.last, contains('lib/main.dart'));
      expect(permissions[1].resources.last, contains('+new line'));
      expect(permissions[2].resources.single, contains('当前轮次累计差异'));
      expect(permissions[2].resources.single, contains('+new line'));

      await api.replyToForm(desktopSession.id, form.id, {'mode': 'Safe'});
      await api.replyToPermission(
        desktopSession.id,
        permissions[0].id,
        decision: 'once',
      );
      await api.replyToPermission(
        desktopSession.id,
        permissions[1].id,
        decision: 'reject',
      );
      await api.replyToPermission(
        desktopSession.id,
        permissions[2].id,
        decision: 'reject',
      );
      await api.replyToPermission(
        desktopSession.id,
        permissions[3].id,
        decision: 'reject',
      );
      expect(api.pendingCountFor(desktopSession.id), 0);
      await api.sendReply(desktopSession.id, 'Continue');
      await api.sendReply(desktopSession.id, 'Adjust this turn');
      await api.sendReply(desktopSession.id, 'Start after completion');
      await _waitFor(
        () => log.existsSync() && log.readAsLinesSync().length == 10,
      );

      final responses = log
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect((responses[0]['result'] as Map)['answers'], {
        'mode': {
          'answers': ['Safe'],
        },
      });
      expect((responses[1]['result'] as Map)['decision'], 'accept');
      expect((responses[2]['result'] as Map)['decision'], 'cancel');
      expect((responses[3]['result'] as Map)['decision'], 'cancel');
      expect((responses[4]['result'] as Map)['permissions'], isEmpty);
      expect(responses[5]['method'], 'turn/interrupt');
      expect(responses[6]['method'], 'thread/resume');
      expect((responses[6]['params'] as Map)['approvalPolicy'], 'on-request');
      expect((responses[6]['params'] as Map)['sandbox'], 'workspace-write');
      expect(responses[7]['method'], 'turn/start');
      expect((responses[7]['params'] as Map)['approvalPolicy'], 'on-request');
      expect(responses[8]['method'], 'turn/steer');
      expect((responses[8]['params'] as Map)['expectedTurnId'], 'test-turn-1');
      expect(responses[9]['method'], 'turn/start');

      final newSessionDirectory = await Directory.systemTemp.createTemp(
        'remoteaisync-codex-session-directory-',
      );
      final newSessionId = await api.createSession(
        directory: newSessionDirectory.path,
      );
      expect(newSessionId, 'codex:new-thread');
      expect(
        (await api.listSessions())
            .firstWhere((session) => session.id == newSessionId)
            .directory,
        newSessionDirectory.path,
      );
      await newSessionDirectory.delete(recursive: true);
      final defaultDirectorySessionId = await api.createSession();
      expect(defaultDirectorySessionId, 'codex:new-thread-2');
      expect(
        (await api.listSessions())
            .firstWhere((session) => session.id == defaultDirectorySessionId)
            .directory,
        isNull,
      );
      await _waitFor(
        () =>
            log.existsSync() &&
            log.readAsLinesSync().any((line) {
              final frame = jsonDecode(line) as Map<String, dynamic>;
              return frame['method'] == 'thread/start' &&
                  (frame['params'] as Map)['cwd'] == null;
            }),
      );
      expect(
        (await api.listSessions())
            .firstWhere((session) => session.id == newSessionId)
            .remoteManaged,
        isTrue,
      );
      expect(
        (await api.listSessions()).map((session) => session.id),
        contains(newSessionId),
      );
      expect(await api.listMessages(newSessionId), isEmpty);
      expect(
        (await api.listSessions()).map((session) => session.id),
        contains(newSessionId),
      );
      await api.sendReply(
        newSessionId,
        'Persist this thread',
        localImages: ['/tmp/sample.png'],
      );
      final streaming = await api.listMessages(newSessionId);
      expect(
        streaming.where((message) => message.id == 'agent-stream'),
        hasLength(1),
      );
      expect(
        streaming.firstWhere((message) => message.id == 'agent-stream').text,
        'Hello world',
      );
      expect(
        streaming.firstWhere((message) => message.id == 'command-stream').text,
        contains('done'),
      );
      expect(
        streaming
            .firstWhere((message) => message.id == 'reasoning-stream')
            .text,
        'Analyzing the request',
      );
      final afterRolloutWrite = await api.listMessages(newSessionId);
      expect(
        afterRolloutWrite.map((message) => message.id),
        contains('agent-stream'),
      );
      api.invalidateSessionCache();
      final persistedRemote = (await api.listSessions()).singleWhere(
        (session) => session.id == newSessionId,
      );
      expect(persistedRemote.title, 'Persisted Codex session');
      expect(persistedRemote.remoteManaged, isTrue);
      final lastStart = log
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .lastWhere(
            (frame) =>
                frame['method'] == 'turn/start' &&
                (frame['params'] as Map)['threadId'] == 'new-thread',
          );
      expect((lastStart['params'] as Map)['input'], [
        {'type': 'text', 'text': 'Persist this thread', 'text_elements': []},
        {'type': 'localImage', 'path': '/tmp/sample.png'},
      ]);
      expect((lastStart['params'] as Map)['approvalsReviewer'], 'user');
      expect(
        (await api.listSessions()).where(
          (session) => session.id == newSessionId,
        ),
        hasLength(1),
      );
      final models = await api.listModels();
      expect(models.single['id'], 'gpt-6-sol');
      expect(models.single['efforts'], ['medium', 'high']);
      expect(await api.listSkills(), ['review']);
      expect((await api.readSettings(newSessionId))['effort'], 'medium');
      await api.updateSettings(
        newSessionId,
        model: 'gpt-6-sol',
        effort: 'high',
      );
      expect((await api.readSettings(newSessionId))['effort'], 'high');
      expect(
        log
            .readAsLinesSync()
            .map((line) => jsonDecode(line) as Map)
            .where((frame) => frame['method'] == 'thread/settings/update'),
        isNotEmpty,
      );
      await api.interrupt(newSessionId);
      expect(
        log
            .readAsLinesSync()
            .map((line) => jsonDecode(line) as Map)
            .where((frame) => frame['method'] == 'turn/interrupt'),
        isNotEmpty,
      );
      await api.sendReply(newSessionId, r'$review Check this change');
      final skillTurn = log
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map)
          .lastWhere((frame) => frame['method'] == 'turn/steer');
      expect((skillTurn['params'] as Map)['input'], [
        {
          'type': 'text',
          'text': r'$review Check this change',
          'text_elements': [],
        },
        {
          'type': 'skill',
          'name': 'review',
          'path':
              '${Directory.current.path}${Platform.pathSeparator}review${Platform.pathSeparator}SKILL.md',
        },
      ]);
      await api.compact(newSessionId);
      await api.reviewUncommitted(newSessionId);
      final actionFrames = log
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map)
          .where(
            (frame) =>
                frame['method'] == 'thread/compact/start' ||
                frame['method'] == 'review/start',
          )
          .toList();
      expect(actionFrames.map((frame) => frame['method']), [
        'thread/compact/start',
        'review/start',
      ]);
      expect((actionFrames.first['params'] as Map)['threadId'], 'new-thread');
      expect((actionFrames.last['params'] as Map)['delivery'], 'inline');
      expect((actionFrames.last['params'] as Map)['target'], {
        'type': 'uncommittedChanges',
      });
      await expectLater(
        api.sendReply('codex:busy-thread', 'Hello'),
        throwsA(
          isA<CodexApiException>().having(
            (error) => error.message,
            'message',
            contains('正由桌面版或另一进程控制'),
          ),
        ),
      );
      final ephemeralId = await api.createSession(ephemeral: true);
      expect(ephemeralId, 'codex:ephemeral-thread');
      await api.sendReply(ephemeralId, 'Fail this turn');
      List<AgentMessage> failureMessages = const [];
      for (var attempt = 0; attempt < 100; attempt++) {
        failureMessages = await api.listMessages(ephemeralId);
        if (failureMessages.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(failureMessages, hasLength(1));
      expect(failureMessages.single.author, MessageAuthor.system);
      expect(failureMessages.single.text, contains('Transient model failure'));
      expect(failureMessages.single.text, contains('Retry later'));
    } finally {
      await api.close();
      await temp.delete(recursive: true);
    }
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

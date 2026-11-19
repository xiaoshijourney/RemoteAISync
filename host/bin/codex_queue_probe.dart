import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports
import '../lib/src/codex_api.dart';

/// Verifies queue add/list/delete against a disposable saved CLI thread.
/// The thread is removed before this probe exits.
Future<void> main(List<String> arguments) async {
  final activeTurnProbe = arguments.contains('--active-turn');
  final settingsProbe = arguments.contains('--cross-process-settings');
  final paths = arguments
      .where((argument) => !argument.startsWith('--'))
      .toList();
  if (paths.length > 1 ||
      arguments.any(
        (argument) =>
            argument.startsWith('--') &&
            argument != '--active-turn' &&
            argument != '--cross-process-settings',
      )) {
    throw const FormatException(
      'Usage: [project] [--active-turn] [--cross-process-settings]',
    );
  }
  final project = paths.isEmpty
      ? Directory.current.absolute.path
      : Directory(paths.single).absolute.path;
  String? threadId;
  CodexApi? bridge;
  CodexApi? writer;
  try {
    final process = await Process.start('codex', [
      'exec',
      '--json',
      '-C',
      project,
      '-s',
      'read-only',
      '-',
    ], workingDirectory: project);
    process.stdin.writeln(
      'RemoteAISync queue probe: reply OK only. Do not use tools.',
    );
    await process.stdin.close();
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    final errors = process.stderr.transform(utf8.decoder).join();
    final status = await process.exitCode.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        process.kill();
        throw TimeoutException('Codex CLI probe timed out.');
      },
    );
    for (final line in await output) {
      try {
        final event = jsonDecode(line);
        if (event is Map && event['type'] == 'thread.started') {
          threadId = event['thread_id']?.toString();
        }
      } on FormatException {
        // Ignore unrelated CLI output.
      }
    }
    if (status != 0 || threadId == null) {
      throw StateError('Codex CLI probe failed: ${(await errors).trim()}');
    }

    bridge = await CodexApi.start(projectDirectory: project);
    final sessionId = 'codex:$threadId';
    if (activeTurnProbe || settingsProbe) {
      writer = await CodexApi.start(projectDirectory: project);
      await writer.sendReply(
        sessionId,
        'RemoteAISync active-turn probe. Explain in several short paragraphs '
        'how a queued follow-up differs from a new turn. Do not use tools.',
      );
    }
    if (settingsProbe) {
      final before = await writer!.readSettings(sessionId);
      try {
        final bridgeView = await bridge.readSettings(sessionId);
        stdout.writeln(
          'Independent app-server reads effort ${bridgeView['effort']}.',
        );
      } on CodexApiException catch (error) {
        stdout.writeln('Independent app-server read failed: ${error.message}');
      }
      final models = await bridge.listModels();
      final matching = models.where((model) => model['id'] == before['model']);
      final model = matching.isEmpty ? models.first : matching.first;
      final efforts = (model['efforts'] as List).cast<String>();
      final alternate = efforts.where((effort) => effort != before['effort']);
      if (alternate.isEmpty) {
        throw StateError(
          'No alternate reasoning effort for cross-process probe.',
        );
      }
      try {
        await bridge.updateSettings(
          sessionId,
          model: model['id'] as String,
          effort: alternate.first,
        );
        final writerView = await writer.readSettings(sessionId);
        stdout.writeln(
          'Cross-process settings update accepted; writer reads effort '
          '${writerView['effort']} (requested ${alternate.first}).',
        );
      } on CodexApiException catch (error) {
        stdout.writeln(
          'Cross-process settings update rejected: ${error.message}',
        );
      }
    }
    const queuedText =
        'RemoteAISync queue transport probe. No action is required.';
    final queuedId = await bridge.queueDesktopMessage(sessionId, queuedText);
    if (!activeTurnProbe &&
        !(await bridge.listQueuedMessages(
          sessionId,
        )).any((item) => item.id == queuedId)) {
      throw StateError('Codex did not list the queued message.');
    }
    if (activeTurnProbe) {
      var consumed = false;
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final messages = await writer!.listMessages(sessionId);
        if (messages.any((item) => item.text.contains(queuedText))) {
          consumed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      stdout.writeln(
        consumed
            ? 'Active app-server observed the queued follow-up.'
            : 'Queued follow-up remained unobserved during the active-turn window.',
      );
    }
    final remaining = await bridge.listQueuedMessages(sessionId);
    if (!remaining.any((item) => item.id == queuedId)) {
      stdout.writeln('Queued message was consumed before withdrawal.');
      return;
    }
    if (!await bridge.deleteQueuedMessage(sessionId, queuedId)) {
      throw StateError('Codex did not confirm queue withdrawal.');
    }
    if ((await bridge.listQueuedMessages(
      sessionId,
    )).any((item) => item.id == queuedId)) {
      throw StateError('Withdrawn message remains in the queue.');
    }
    stdout.writeln('Saved Codex thread passed queue add/list/delete.');
  } finally {
    await writer?.close();
    await bridge?.close();
    if (threadId != null) {
      final cleanup = await Process.run('codex', [
        'delete',
        '--force',
        threadId,
        '-C',
        project,
      ]).timeout(const Duration(seconds: 20));
      if (cleanup.exitCode != 0) {
        stderr.writeln('Could not remove disposable probe thread.');
        exitCode = 1;
      }
    }
  }
}

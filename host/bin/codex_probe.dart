import 'dart:async';
import 'dart:io';

import 'package:remote_ai_sync/src/domain/models.dart';

// ignore: avoid_relative_lib_imports
import '../lib/src/codex_api.dart';

/// Local smoke test. Optional ephemeral turns never persist conversation content.
Future<void> main(List<String> arguments) async {
  if (arguments.contains('--actions-test')) {
    await _runActionProbe();
    return;
  }
  final paths = arguments.where((argument) => !argument.startsWith('--'));
  final project = paths.isEmpty ? Directory.current.path : paths.first;
  final codex = await CodexApi.start(projectDirectory: project);
  try {
    final sessions = await codex.listSessions();
    stdout.writeln('${codex.version}: ${sessions.length} sessions in $project');
    if (arguments.contains('--controls-test')) {
      final models = await codex.listModels();
      final skills = await codex.listSkills();
      stdout.writeln('Models: ${models.length}; skills: ${skills.length}');
      if (models.isEmpty) {
        throw StateError('Codex returned no available models.');
      }
      final ephemeralId = await codex.createSession(ephemeral: true);
      final before = await codex.readSettings(ephemeralId);
      final selected = models.firstWhere(
        (model) => model['id'] == before['model'],
        orElse: () => models.first,
      );
      final efforts = (selected['efforts'] as List).cast<String>();
      if (efforts.isEmpty) throw StateError('Model has no effort options.');
      final effort = efforts.contains(before['effort'])
          ? before['effort'] as String
          : efforts.first;
      await codex.updateSettings(
        ephemeralId,
        model: selected['id'] as String,
        effort: effort,
      );
      final after = await codex.readSettings(ephemeralId);
      if (after['model'] != selected['id'] || after['effort'] != effort) {
        throw StateError('Codex did not retain model and effort settings.');
      }
      stdout.writeln('Ephemeral Codex model/effort settings accepted.');
    }
    if (sessions.isNotEmpty) {
      final messages = await codex.listMessages(sessions.first.id);
      stdout.writeln('Latest session: ${messages.length} display messages');
      if (arguments.contains('--queue-inspect')) {
        final queued = await codex.listQueuedMessages(sessions.first.id);
        stdout.writeln('Latest session: ${queued.length} queued messages');
      }
      if (arguments.contains('--inspect-live')) {
        for (final message in messages.skip(
          messages.length > 5 ? messages.length - 5 : 0,
        )) {
          stdout.writeln(
            '  ${message.author.name} ${message.id} (${message.text.length} chars)',
          );
        }
      }
    }
    if (arguments.contains('--send-test') ||
        arguments.contains('--stream-test')) {
      final sessionId = await codex.createSession(ephemeral: true);
      await codex.sendReply(
        sessionId,
        'RemoteAISync adapter smoke test: reply with OK only. Do not use tools.',
      );
      stdout.writeln('Ephemeral Codex turn accepted by app-server.');
      if (arguments.contains('--stream-test')) {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        var observed = false;
        while (DateTime.now().isBefore(deadline)) {
          final messages = await codex.listMessages(sessionId);
          if (messages.any(
            (message) =>
                message.author == MessageAuthor.assistant &&
                message.text.trim().isNotEmpty,
          )) {
            observed = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!observed) throw StateError('No streamed Codex item observed.');
        stdout.writeln('Ephemeral Codex streaming item observed.');
      }
    }
  } finally {
    await codex.close();
  }
}

Future<void> _runActionProbe() async {
  final temporary = await Directory.systemTemp.createTemp(
    'remoteaisync-codex-actions-',
  );
  CodexApi? codex;
  try {
    final initial = File(
      '${temporary.path}${Platform.pathSeparator}sample.txt',
    );
    await initial.writeAsString('before\n');
    for (final args in [
      ['init', '-q'],
      ['add', 'sample.txt'],
      [
        '-c',
        'user.name=RemoteAISync Probe',
        '-c',
        'user.email=probe@localhost',
        'commit',
        '-q',
        '-m',
        'initial',
      ],
    ]) {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: temporary.path,
      );
      if (result.exitCode != 0) {
        throw StateError('Temporary Git setup failed: ${result.stderr}');
      }
    }
    await initial.writeAsString('after\n');
    codex = await CodexApi.start(projectDirectory: temporary.path);
    final sessionId = await codex.createSession(ephemeral: true);
    await codex.sendReply(sessionId, 'Reply OK only. Do not use tools.');
    await _waitUntilIdle(codex, sessionId);
    await codex.compact(sessionId);
    await _waitUntilIdle(codex, sessionId);
    stdout.writeln('Real Codex app-server accepted thread/compact/start.');
    await codex.reviewUncommitted(sessionId);
    stdout.writeln(
      'Real Codex app-server accepted inline review/start; '
      'review completion was not checked.',
    );
  } finally {
    await codex?.close();
    final parent = temporary.parent.absolute.path.toLowerCase();
    final systemTemp = Directory.systemTemp.absolute.path.toLowerCase();
    if (parent != systemTemp ||
        !temporary.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('remoteaisync-codex-actions-')) {
      throw StateError('Refusing to remove unexpected probe directory.');
    }
    await temporary.delete(recursive: true);
  }
}

Future<void> _waitUntilIdle(CodexApi codex, String sessionId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    if ((await codex.readSettings(sessionId))['running'] != true) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('Codex probe turn did not finish.');
}

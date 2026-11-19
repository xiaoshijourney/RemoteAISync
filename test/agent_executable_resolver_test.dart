import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/agent_executable_resolver.dart';

void main() {
  test('resolves an executable from a supplied search directory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'remoteaisync-agent-path-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File(
      '${directory.path}${Platform.pathSeparator}fixture-agent.exe',
    );
    await executable.writeAsString('fixture');

    expect(
      await resolveAgentExecutable(
        'fixture-agent',
        searchDirectories: [directory.path],
      ),
      executable.absolute.path,
    );
  });

  test('returns null when no executable is found', () async {
    final directory = await Directory.systemTemp.createTemp(
      'remoteaisync-agent-empty-path-',
    );
    addTearDown(() => directory.delete(recursive: true));

    expect(
      await resolveAgentExecutable(
        'remoteaisync-definitely-missing-agent',
        searchDirectories: [directory.path],
      ),
      isNull,
    );
  });
}

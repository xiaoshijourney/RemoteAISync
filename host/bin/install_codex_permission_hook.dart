import 'dart:convert';
import 'dart:io';

/// Adds the optional project-level Codex PermissionRequest hook without
/// replacing unrelated hooks. Codex still requires the user's project trust.
Future<void> main(List<String> arguments) async {
  var project = Directory.current.absolute.path;
  var port = 8910;
  for (var index = 0; index < arguments.length; index += 2) {
    if (index + 1 >= arguments.length) {
      throw const FormatException('Expected --project and/or --port values.');
    }
    switch (arguments[index]) {
      case '--project':
        project = Directory(arguments[index + 1]).absolute.path;
      case '--port':
        port = int.parse(arguments[index + 1]);
      default:
        throw FormatException('Unknown option: ${arguments[index]}');
    }
  }
  if (port < 1 || port > 65535 || !Directory(project).existsSync()) {
    throw const FormatException('Invalid project directory or port.');
  }
  final script = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('codex_permission_hook.dart').toFilePath();
  final command = '"${Platform.resolvedExecutable}" "$script" --port $port';
  final file = File(
    '$project${Platform.pathSeparator}.codex${Platform.pathSeparator}hooks.json',
  );
  Map<String, dynamic> config = {};
  if (await file.exists()) {
    final existing = jsonDecode(await file.readAsString());
    if (existing is! Map || existing['hooks'] is! Map) {
      throw const FormatException('Existing hooks.json has an invalid shape.');
    }
    config = Map<String, dynamic>.from(existing);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    await file.copy('${file.path}.bak-$stamp');
  }
  final hooks = Map<String, dynamic>.from(config['hooks'] as Map? ?? const {});
  final approvals = List<Object?>.from(
    hooks['PermissionRequest'] as List? ?? const [],
  );
  final retained = <Object?>[];
  for (final entry in approvals) {
    if (entry is! Map || entry['hooks'] is! List) {
      retained.add(entry);
      continue;
    }
    final commands = (entry['hooks'] as List).where((hook) {
      return hook is! Map ||
          hook['command']?.toString().contains('codex_permission_hook.dart') !=
              true;
    }).toList();
    if (commands.isNotEmpty) retained.add({...entry, 'hooks': commands});
  }
  retained.add({
    'hooks': [
      {'type': 'command', 'command': command, 'timeout': 330},
    ],
  });
  hooks['PermissionRequest'] = retained;
  config['hooks'] = hooks;
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(config)}\n',
    flush: true,
  );
  stdout.writeln('Codex hook configuration updated: ${file.path}');
  stdout.writeln('Review this file and approve project hooks in Codex.');
}

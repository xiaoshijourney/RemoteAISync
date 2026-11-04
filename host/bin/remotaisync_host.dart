import 'dart:async';
import 'dart:io';

// ignore: avoid_relative_lib_imports
import '../lib/src/bridge.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  if (options.showHelp) {
    stdout.writeln('''
RemoteAISync local OpenCode bridge

Options:
  --project <directory>       OpenCode workspace (default: current directory)
  --port <port>                WebSocket port (default: 8787)
  --token <secret>             Pairing token; generated automatically if omitted
  --opencode <executable>      OpenCode executable (default: opencode)
  --help                       Show this help
''');
    return;
  }

  final project = Directory(options.project).absolute;
  if (!await project.exists()) {
    stderr.writeln('Project directory does not exist.');
    exitCode = 2;
    return;
  }

  final bridge = await OpenCodeBridge.start(
    projectDirectory: project.path,
    websocketPort: options.port,
    pairingToken: options.pairingToken,
    executable: options.executable,
  );
  stdout.writeln(
    'RemoteAISync local bridge listening at ws://127.0.0.1:${options.port}/ws',
  );
  stdout.writeln(
    'OpenCode ${bridge.openCodeVersion} is scoped to ${project.path}',
  );
  stdout.writeln('Pairing token (this run only): ${bridge.pairingTokenValue}');
  stdout.writeln('Press Ctrl+C to stop.');

  final stopped = Completer<void>();
  final signals = <StreamSubscription<ProcessSignal>>[];
  final watchedSignals = Platform.isWindows
      ? [ProcessSignal.sigint]
      : [ProcessSignal.sigint, ProcessSignal.sigterm];
  for (final signal in watchedSignals) {
    signals.add(
      signal.watch().listen((_) {
        if (!stopped.isCompleted) stopped.complete();
      }),
    );
  }
  await stopped.future;
  for (final subscription in signals) {
    await subscription.cancel();
  }
  await bridge.close();
}

_Options _parseArguments(List<String> arguments) {
  var project = Directory.current.path;
  var port = 8787;
  var executable = 'opencode';
  String? pairingToken;
  var showHelp = false;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '--help' || argument == '-h') {
      showHelp = true;
      continue;
    }
    if (i + 1 >= arguments.length) {
      throw FormatException('Missing value for $argument');
    }
    final value = arguments[++i];
    switch (argument) {
      case '--project':
        project = value;
        break;
      case '--port':
        port = int.tryParse(value) ?? 0;
        if (port < 1 || port > 65535) {
          throw const FormatException('Port must be between 1 and 65535.');
        }
        break;
      case '--opencode':
        executable = value;
        break;
      case '--token':
        pairingToken = value;
        break;
      default:
        throw FormatException('Unknown option: $argument');
    }
  }
  if (pairingToken != null && pairingToken.length < 32) {
    throw const FormatException(
      'Pairing token must be at least 32 characters.',
    );
  }
  return _Options(
    project: project,
    port: port,
    executable: executable,
    pairingToken: pairingToken,
    showHelp: showHelp,
  );
}

class _Options {
  const _Options({
    required this.project,
    required this.port,
    required this.executable,
    required this.pairingToken,
    required this.showHelp,
  });

  final String project;
  final int port;
  final String executable;
  final String? pairingToken;
  final bool showHelp;
}

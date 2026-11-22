import 'dart:async';
import 'dart:io';

// ignore_for_file: avoid_relative_lib_imports

import '../lib/src/update_service.dart';

Future<void> main(List<String> arguments) async {
  final options = _parse(arguments);
  if (options.help) {
    stdout.writeln('''
RemoteAISync update management service

Options:
  --bind-address <ip>   Listen address (default: 127.0.0.1)
  --port <port>         Listen port (default: 8930)
  --data-dir <path>     Persistent data directory
  --init-admin          Create the first administrator password and exit
  --help                Show this help
''');
    return;
  }
  if (options.initializeAdmin) {
    stdout.write('Create update administrator password (12+ characters): ');
    final previousEcho = stdin.echoMode;
    try {
      stdin.echoMode = false;
      final password = stdin.readLineSync() ?? '';
      stdin.echoMode = previousEcho;
      stdout.writeln();
      await UpdateService.initializeAdmin(
        dataDirectory: options.dataDirectory,
        password: password,
      );
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', [
          '600',
          '${options.dataDirectory}/admin.json',
        ]);
      }
      stdout.writeln(
        'Administrator initialized. The password is not stored in plaintext.',
      );
    } finally {
      stdin.echoMode = previousEcho;
    }
    return;
  }
  final service = await UpdateService.bind(
    port: options.port,
    bindAddress: options.bindAddress,
    dataDirectory: options.dataDirectory,
  );
  stdout.writeln(
    'RemoteAISync update service listening on ${options.bindAddress}:${service.port}',
  );
  stdout.writeln(
    'Public release manifests and artifact downloads are served via Caddy.',
  );
  final stopped = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) {
      if (!stopped.isCompleted) stopped.complete();
    }),
    ProcessSignal.sigterm.watch().listen((_) {
      if (!stopped.isCompleted) stopped.complete();
    }),
  ];
  await stopped.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await service.close();
}

_Options _parse(List<String> arguments) {
  var bindAddress = '127.0.0.1';
  var port = 8930;
  var dataDirectory =
      Platform.environment['REMOTEAI_UPDATES_DATA_DIR'] ??
      (Platform.isWindows
          ? '${Platform.environment['PROGRAMDATA'] ?? r'C:\ProgramData'}${Platform.pathSeparator}RemoteAISync${Platform.pathSeparator}updates'
          : '/var/lib/remotaisync-updates');
  var initializeAdmin = false;
  var help = false;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    switch (argument) {
      case '--bind-address':
        if (++i >= arguments.length) {
          throw ArgumentError('Missing --bind-address value.');
        }
        bindAddress = arguments[i];
      case '--port':
        if (++i >= arguments.length) {
          throw ArgumentError('Missing --port value.');
        }
        port = int.parse(arguments[i]);
        if (port < 1 || port > 65535) {
          throw ArgumentError('Port must be in 1..65535.');
        }
      case '--data-dir':
        if (++i >= arguments.length) {
          throw ArgumentError('Missing --data-dir value.');
        }
        dataDirectory = arguments[i];
      case '--init-admin':
        initializeAdmin = true;
      case '--help':
        help = true;
      default:
        throw ArgumentError('Unknown option: $argument');
    }
  }
  return _Options(
    bindAddress: bindAddress,
    port: port,
    dataDirectory: dataDirectory,
    initializeAdmin: initializeAdmin,
    help: help,
  );
}

class _Options {
  const _Options({
    required this.bindAddress,
    required this.port,
    required this.dataDirectory,
    required this.initializeAdmin,
    required this.help,
  });

  final String bindAddress;
  final int port;
  final String dataDirectory;
  final bool initializeAdmin;
  final bool help;
}

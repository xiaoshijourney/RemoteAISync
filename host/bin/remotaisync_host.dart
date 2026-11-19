import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ignore_for_file: avoid_relative_lib_imports

import '../lib/src/bridge.dart';
import '../lib/src/relay_connector.dart';
import '../lib/src/relay_server.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  if (options.showHelp) {
    stdout.writeln('''
RemoteAISync local Agent bridge

Options:
  --mode <host|relay>          Run the Agent host or the WebSocket relay (default: host)
  --project <directory>       Agent workspace (default: current directory)
  --port <port>                WebSocket port (default: 8910)
  --bind-address <ip>          Listen address (default: 0.0.0.0 for host, 127.0.0.1 for relay)
  --data-dir <directory>       Relay persistent data directory
  --relay-url <ws(s)://url>    Optional relay URL for host mode
  --relay-room <room-id>       Relay room ID used by the host
  --relay-token <secret>       Relay client access secret (at least 32 characters)
  --relay-host-token <secret>  Host-only relay secret (at least 32 characters)
  --allow-public-host          Advertise and accept a configured public host route
  --public-host-url <wss-url>  Public host URL, for example wss://host.example.com/ws
  --allowed-origin <origin>    Additional browser Origin allowed for public host mode
  --tls-cert <path>            Optional PEM certificate chain for native WSS
  --tls-key <path>             Optional PEM private key for native WSS
  --tls-password <password>    Optional private key password
  --token <secret>             Pairing token; generated automatically if omitted
  --persist-token              Reuse a local token for development
  --issue-registration-code    Issue one-time host code via local relay admin API
  --revoke-registration-code <id> Revoke a host code
  --opencode <executable>      OpenCode executable (default: opencode)
  --codex <executable>         Codex executable (default: codex)
  --claude <executable>        Claude Code executable (default: claude)
  --help                       Show this help
''');
    return;
  }

  if (options.issueRegistrationCode || options.revokeRegistrationCode != null) {
    await _runRelayAdminCommand(options);
    return;
  }

  if (options.mode == 'relay') {
    final relayToken =
        options.relayToken ??
        Platform.environment['REMOTEAI_RELAY_ADMIN_TOKEN'];
    final relayHostToken =
        options.relayHostToken ??
        Platform.environment['REMOTEAI_RELAY_HOST_SECRET'];
    if (relayToken == null || relayHostToken == null) {
      stderr.writeln(
        'Relay mode requires --relay-token and --relay-host-token.',
      );
      exitCode = 2;
      return;
    }
    final relay = await RelayServer.bind(
      port: options.port,
      clientToken: relayToken,
      hostToken: relayHostToken,
      bindAddress: InternetAddress.tryParse(options.bindAddress),
      storageDirectory: options.dataDirectory ?? options.project,
      securityContext: await _loadSecurityContext(options),
    );
    stdout.writeln(
      'RemoteAISync relay listening on ${options.bindAddress}:${relay.port}',
    );
    stdout.writeln('  WebSocket backend: ws://127.0.0.1:${relay.port}/relay');
    stdout.writeln(
      '  Health backend:    http://127.0.0.1:${relay.port}/health',
    );
    await _waitForStop(onStop: relay.close);
    return;
  }

  final project = Directory(options.project).absolute;
  if (!await project.exists()) {
    stderr.writeln('Project directory does not exist.');
    exitCode = 2;
    return;
  }

  final pairingToken = await _resolvePairingToken(options, project.path);
  final stopped = Completer<void>();
  final bridge = await AgentBridge.start(
    projectDirectory: project.path,
    websocketPort: options.port,
    pairingToken: pairingToken,
    allowLocalDevConfig: options.persistToken,
    onLocalDevShutdown: options.persistToken
        ? () async {
            if (!stopped.isCompleted) stopped.complete();
          }
        : null,
    executable: options.executable,
    codexExecutable: options.codexExecutable,
    claudeExecutable: options.claudeExecutable,
    bindAddress: InternetAddress.tryParse(options.bindAddress),
    publicHostEnabled: options.publicHostEnabled,
    publicHostUrl: options.publicHostUrl,
    publicAllowedOrigins: options.publicAllowedOrigins.toSet(),
    securityContext: await _loadSecurityContext(options),
  );
  RelayConnector? relayConnector;
  if (options.relayUrl != null) {
    if (options.relayRoom == null || options.relayHostToken == null) {
      await bridge.close();
      stderr.writeln(
        'Host relay mode requires --relay-room and --relay-host-token.',
      );
      exitCode = 2;
      return;
    }
    relayConnector = RelayConnector(
      bridge: bridge,
      relayUri: Uri.parse(options.relayUrl!),
      roomId: options.relayRoom!,
      hostToken: options.relayHostToken!,
    );
    unawaited(relayConnector.start());
  }
  stdout.writeln('RemoteAISync bridge listening:');
  stdout.writeln('  Local: ws://127.0.0.1:${options.port}/ws');
  for (final address in bridge.lanAddresses) {
    stdout.writeln('  LAN:   ws://$address:${options.port}/ws');
  }
  if (bridge.publicHostEnabled && bridge.publicHostUrl != null) {
    stdout.writeln('  Public: ${bridge.publicHostUrl}');
  }
  if (options.relayUrl != null) {
    stdout.writeln('Relay room: ${options.relayRoom}');
    stdout.writeln('Relay tunnel: ${options.relayUrl}');
  }
  stdout.writeln(
    bridge.api == null
        ? 'OpenCode unavailable: ${bridge.openCodeUnavailableReason ?? 'status unknown'}.'
        : 'OpenCode ${bridge.openCodeVersion ?? 'available'} is scoped to ${project.path}',
  );
  stdout.writeln(
    bridge.codex == null
        ? 'Codex unavailable: ${bridge.codexUnavailableReason ?? 'status unknown'}.'
        : 'Codex ${bridge.codex!.version} is scoped to ${project.path}',
  );
  stdout.writeln(
    bridge.claude == null
        ? 'Claude Code unavailable: ${bridge.claudeUnavailableReason ?? 'status unknown'}.'
        : 'Claude Code ${bridge.claude!.version} is available with local transcript sync.',
  );
  if (bridge.api == null && bridge.codex == null && bridge.claude == null) {
    stdout.writeln(
      'No supported Agent is available yet; the host remains online so clients can display this state.',
    );
  }
  if (bridge.codex != null) {
    stdout.writeln(
      bridge.codexHookRuntimeReady
          ? 'Optional Codex desktop approval hook endpoint is ready.'
          : 'Codex desktop approval hook runtime is unavailable.',
    );
  }
  stdout.writeln(
    options.persistToken && options.pairingToken == null
        ? 'Pairing token (persistent development token): ${bridge.pairingTokenValue}'
        : 'Pairing token (this run only): ${bridge.pairingTokenValue}',
  );
  stdout.writeln('Press Ctrl+C to stop.');
  await _waitForStop(stopSignal: stopped.future);
  await relayConnector?.close();
  await bridge.close();
}

Future<void> _waitForStop({
  Future<void>? stopSignal,
  Future<void> Function()? onStop,
}) async {
  final signalStop = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  final signals = Platform.isWindows
      ? [ProcessSignal.sigint]
      : [ProcessSignal.sigint, ProcessSignal.sigterm];
  for (final signal in signals) {
    subscriptions.add(
      signal.watch().listen((_) {
        if (!signalStop.isCompleted) signalStop.complete();
      }),
    );
  }
  if (stopSignal == null) {
    await signalStop.future;
  } else {
    await Future.any([stopSignal, signalStop.future]);
  }
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await onStop?.call();
}

_Options _parseArguments(List<String> arguments) {
  var project = Directory.current.path;
  var port = 8910;
  var mode = 'host';
  final environment = Platform.environment;
  String? relayUrl = environment['REMOTEAI_RELAY_URL'];
  String? relayRoom = environment['REMOTEAI_RELAY_ROOM'];
  String? relayToken;
  String? relayHostToken = environment['REMOTEAI_RELAY_HOST_TOKEN'];
  String? dataDirectory;
  var bindAddress = '0.0.0.0';
  var executable = 'opencode';
  var codexExecutable = 'codex';
  var claudeExecutable = 'claude';
  String? pairingToken;
  var persistToken = false;
  var issueRegistrationCode = false;
  String? revokeRegistrationCode;
  var publicHostEnabled = false;
  String? publicHostUrl;
  String? tlsCertificatePath;
  String? tlsKeyPath;
  String? tlsPassword;
  final publicAllowedOrigins = <String>[];
  var showHelp = false;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '--help' || argument == '-h') {
      showHelp = true;
      continue;
    }
    if (argument == '--persist-token') {
      persistToken = true;
      continue;
    }
    if (argument == '--issue-registration-code') {
      issueRegistrationCode = true;
      continue;
    }
    if (argument == '--allow-public-host') {
      publicHostEnabled = true;
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
      case '--data-dir':
        dataDirectory = value;
        break;
      case '--bind-address':
        bindAddress = value;
        if (InternetAddress.tryParse(bindAddress) == null) {
          throw const FormatException('--bind-address must be an IP address.');
        }
        break;
      case '--mode':
        mode = value;
        if (!{'host', 'relay'}.contains(mode)) {
          throw const FormatException('Mode must be host or relay.');
        }
        break;
      case '--relay-url':
        relayUrl = value;
        break;
      case '--relay-room':
        relayRoom = value;
        break;
      case '--relay-token':
        relayToken = value;
        break;
      case '--relay-host-token':
        relayHostToken = value;
        break;
      case '--public-host-url':
        publicHostUrl = value;
        break;
      case '--allowed-origin':
        final origin = Uri.tryParse(value);
        if (origin == null ||
            origin.host.isEmpty ||
            !{'http', 'https'}.contains(origin.scheme)) {
          throw const FormatException(
            '--allowed-origin must be an http(s) origin.',
          );
        }
        publicAllowedOrigins.add(value);
        break;
      case '--tls-cert':
        tlsCertificatePath = value;
        break;
      case '--tls-key':
        tlsKeyPath = value;
        break;
      case '--tls-password':
        tlsPassword = value;
        break;
      case '--revoke-registration-code':
        revokeRegistrationCode = value;
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
      case '--codex':
        codexExecutable = value;
        break;
      case '--claude':
        claudeExecutable = value;
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
  if (relayToken != null && relayToken.length < 32) {
    throw const FormatException('Relay token must be at least 32 characters.');
  }
  if (relayHostToken != null && relayHostToken.length < 32) {
    throw const FormatException(
      'Relay host token must be at least 32 characters.',
    );
  }
  if (relayToken != null && relayToken == relayHostToken) {
    throw const FormatException(
      'Relay host and client tokens must be different.',
    );
  }
  if (relayRoom != null &&
      !RegExp(r'^[A-Za-z0-9_-]{12,96}$').hasMatch(relayRoom)) {
    throw const FormatException(
      'Relay room ID must be 12-96 letters, digits, _ or -.',
    );
  }
  if (mode == 'relay' && (relayUrl != null || relayRoom != null)) {
    throw const FormatException(
      'Relay server mode cannot use --relay-url or --relay-room.',
    );
  }
  if (mode == 'host' &&
      relayUrl != null &&
      (relayRoom == null || relayHostToken == null)) {
    throw const FormatException(
      'Host relay mode requires --relay-room and --relay-host-token.',
    );
  }
  if (mode == 'relay' &&
      (publicHostEnabled ||
          publicHostUrl != null ||
          publicAllowedOrigins.isNotEmpty)) {
    throw const FormatException(
      'Public host options are only valid in host mode.',
    );
  }
  tlsCertificatePath ??= environment['REMOTEAI_TLS_CERT'];
  tlsKeyPath ??= environment['REMOTEAI_TLS_KEY'];
  tlsPassword ??= environment['REMOTEAI_TLS_PASSWORD'];
  if ((tlsCertificatePath == null) != (tlsKeyPath == null)) {
    throw const FormatException(
      'Native WSS requires both --tls-cert/REMOTEAI_TLS_CERT and --tls-key/REMOTEAI_TLS_KEY.',
    );
  }
  if (mode == 'host' &&
      !publicHostEnabled &&
      (publicHostUrl != null || publicAllowedOrigins.isNotEmpty)) {
    throw const FormatException(
      'Use --allow-public-host before configuring public host options.',
    );
  }
  if (publicHostEnabled) {
    final uri = Uri.tryParse(publicHostUrl ?? '');
    if (uri == null ||
        uri.scheme != 'wss' ||
        uri.host.isEmpty ||
        (uri.path.isNotEmpty && uri.path != '/ws')) {
      throw const FormatException(
        '--public-host-url must be wss://host.example.com/ws.',
      );
    }
    if (uri.path.isEmpty || uri.path == '/') {
      publicHostUrl = uri.replace(path: '/ws').toString();
    }
  }
  if (issueRegistrationCode && revokeRegistrationCode != null) {
    throw const FormatException(
      'Choose either --issue-registration-code or --revoke-registration-code.',
    );
  }
  return _Options(
    project: project,
    port: port,
    mode: mode,
    relayUrl: relayUrl,
    relayRoom: relayRoom,
    relayToken: relayToken,
    relayHostToken: relayHostToken,
    dataDirectory: dataDirectory,
    bindAddress: bindAddress,
    executable: executable,
    codexExecutable: codexExecutable,
    claudeExecutable: claudeExecutable,
    pairingToken: pairingToken,
    persistToken: persistToken,
    issueRegistrationCode: issueRegistrationCode,
    revokeRegistrationCode: revokeRegistrationCode,
    publicHostEnabled: publicHostEnabled,
    publicHostUrl: publicHostUrl,
    publicAllowedOrigins: publicAllowedOrigins,
    tlsCertificatePath: tlsCertificatePath,
    tlsKeyPath: tlsKeyPath,
    tlsPassword: tlsPassword,
    showHelp: showHelp,
  );
}

Future<SecurityContext?> _loadSecurityContext(_Options options) async {
  final certificate = options.tlsCertificatePath;
  final key = options.tlsKeyPath;
  if (certificate == null || key == null) return null;
  final context = SecurityContext();
  context.useCertificateChain(certificate);
  context.usePrivateKey(key, password: options.tlsPassword);
  return context;
}

Future<void> _runRelayAdminCommand(_Options options) async {
  final token =
      Platform.environment['REMOTEAI_RELAY_ADMIN_TOKEN'] ?? options.relayToken;
  if (token == null || token.length < 32) {
    stderr.writeln(
      'Set REMOTEAI_RELAY_ADMIN_TOKEN to the relay admin secret first.',
    );
    exitCode = 2;
    return;
  }
  final isIssue = options.issueRegistrationCode;
  final uri = Uri(
    scheme: options.tlsCertificatePath != null ? 'https' : 'http',
    host: '127.0.0.1',
    port: options.port,
    path: '/admin/registration-code',
    queryParameters: isIssue ? null : {'id': options.revokeRegistrationCode!},
  );
  final client = HttpClient();
  try {
    final request = isIssue
        ? await client.postUrl(uri)
        : await client.deleteUrl(uri);
    request.headers.set('x-remoteaisync-admin-token', token);
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await utf8.decoder.bind(response).join();
    final expected = isIssue ? HttpStatus.created : HttpStatus.ok;
    if (response.statusCode != expected) {
      stderr.writeln(
        'Relay admin request failed (${response.statusCode}): $body',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln(body);
  } finally {
    client.close(force: true);
  }
}

Future<String?> _resolvePairingToken(
  _Options options,
  String projectPath,
) async {
  if (!options.persistToken) {
    return options.pairingToken;
  }
  final tokenFile = File(
    '${Directory(projectPath).path}${Platform.pathSeparator}'
    '.remoteaisync${Platform.pathSeparator}dev-pairing-token',
  );
  if (options.pairingToken != null) {
    await tokenFile.parent.create(recursive: true);
    await tokenFile.writeAsString('${options.pairingToken}\n', flush: true);
    return options.pairingToken;
  }
  if (await tokenFile.exists()) {
    final token = (await tokenFile.readAsString()).trim();
    if (token.length < 32) {
      throw StateError('The saved development pairing token is invalid.');
    }
    return token;
  }
  final random = Random.secure();
  final token = base64Url.encode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  await tokenFile.parent.create(recursive: true);
  await tokenFile.writeAsString('$token\n', flush: true);
  return token;
}

class _Options {
  const _Options({
    required this.project,
    required this.port,
    required this.mode,
    required this.relayUrl,
    required this.relayRoom,
    required this.relayToken,
    required this.relayHostToken,
    required this.dataDirectory,
    required this.bindAddress,
    required this.executable,
    required this.codexExecutable,
    required this.claudeExecutable,
    required this.pairingToken,
    required this.persistToken,
    required this.issueRegistrationCode,
    required this.revokeRegistrationCode,
    required this.publicHostEnabled,
    required this.publicHostUrl,
    required this.publicAllowedOrigins,
    required this.tlsCertificatePath,
    required this.tlsKeyPath,
    required this.tlsPassword,
    required this.showHelp,
  });

  final String project;
  final int port;
  final String mode;
  final String? relayUrl;
  final String? relayRoom;
  final String? relayToken;
  final String? relayHostToken;
  final String? dataDirectory;
  final String bindAddress;
  final String executable;
  final String codexExecutable;
  final String claudeExecutable;
  final String? pairingToken;
  final bool persistToken;
  final bool issueRegistrationCode;
  final String? revokeRegistrationCode;
  final bool publicHostEnabled;
  final String? publicHostUrl;
  final List<String> publicAllowedOrigins;
  final String? tlsCertificatePath;
  final String? tlsKeyPath;
  final String? tlsPassword;
  final bool showHelp;
}

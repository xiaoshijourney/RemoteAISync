import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:remote_ai_sync/src/domain/models.dart';
import 'package:remote_ai_sync/src/domain/transport_protocol.dart';
import 'agent_executable_resolver.dart';
import 'codex_api.dart';
import 'claude_code_api.dart';
import 'codex_hook_broker.dart';
import 'codex_hook_runtime.dart';
import 'open_code_api.dart';
import 'upload_store.dart';

class AgentBridge {
  AgentBridge._({
    required this.projectDirectory,
    required this.openCodeExecutable,
    required this.openCodeCommandRunner,
    required this.openCodeDiscoveryRetryInterval,
    required this.api,
    required this.codex,
    required this.openCodeVersion,
    required this.openCodeUnavailableReason,
    required this.openCodeUnavailableAvailability,
    required this.codexUnavailableReason,
    required this.codexUnavailableAvailability,
    required this.claude,
    required this.claudeUnavailableReason,
    required this.claudeUnavailableAvailability,
    required this.pairingToken,
    required this.uploads,
    required this.hookBroker,
    required this.hookToken,
    required this.websocketPort,
    required this.bindAddress,
    required this.publicHostEnabled,
    required this.publicHostUrl,
    required this.publicAllowedOrigins,
    required this.allowLocalDevConfig,
    required this.securityContext,
  }) : _openCodeReachable = api != null,
       _codexReachable = codex != null,
       _workspaceDirectory = projectDirectory;

  final String projectDirectory;
  final String openCodeExecutable;
  final OpenCodeCommandRunner? openCodeCommandRunner;
  final Duration openCodeDiscoveryRetryInterval;
  OpenCodeApi? api;
  final CodexApi? codex;
  String? openCodeVersion;
  String? openCodeUnavailableReason;
  String openCodeUnavailableAvailability;
  final String? codexUnavailableReason;
  final String codexUnavailableAvailability;
  final ClaudeCodeApi? claude;
  final String? claudeUnavailableReason;
  final String claudeUnavailableAvailability;
  final String pairingToken;
  final UploadStore uploads;
  final CodexHookBroker hookBroker;
  final String hookToken;
  final int websocketPort;
  final InternetAddress? bindAddress;
  final bool publicHostEnabled;
  final String? publicHostUrl;
  final Set<String> publicAllowedOrigins;
  final bool allowLocalDevConfig;
  final SecurityContext? securityContext;
  bool _openCodeReachable;
  bool _codexReachable;
  String _workspaceDirectory;
  bool _allSessions = false;
  DateTime? _lastOpenCodeDiscoveryAttempt = DateTime.now();
  bool _hookRuntimeReady = false;
  late final _RemoteSocketServer _server;
  late final Timer _refreshTimer;
  Timer? _eventDebounce;
  bool _eventRefreshQueued = false;
  bool _closed = false;
  Future<void>? _refreshTask;
  List<HostSession> _sessions = const [];
  final Map<String, List<AgentMessage>> _messages = {};
  final Map<String, List<AgentForm>> _forms = {};
  final Map<String, List<AgentPermission>> _permissions = {};
  final Map<String, List<AgentQueuedMessage>> _queuedMessages = {};
  final Map<String, String> _queueWarnings = {};
  final Set<String> _runningOpenCodeSessions = {};
  final Map<String, _RelayChannelBinding> _relayChannels = {};
  String? relayUrl;
  String? relayRoom;
  String? relayClientToken;
  bool relayConnected = false;
  DateTime? relayConnectedAt;
  DateTime? relayHeartbeatAt;
  Map<String, Object?>? relayTopology;
  String? _pairingInvite;
  DateTime? _pairingInviteExpiresAt;
  final Map<String, _RemoteClient> _pendingPairings = {};
  final Map<String, Map<String, String>> _pairedDevices = {};

  void _startBackgroundTasks() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refresh());
    });
    unawaited(_watchEvents());
    if (codex != null) unawaited(_watchCodexEvents());
    unawaited(_watchHookEvents());
  }

  static Future<AgentBridge> start({
    required String projectDirectory,
    required int websocketPort,
    String? pairingToken,
    bool allowLocalDevConfig = false,
    Future<void> Function()? onLocalDevShutdown,
    String executable = 'opencode',
    OpenCodeCommandRunner? openCodeCommandRunner,
    Duration openCodeDiscoveryRetryInterval = const Duration(seconds: 10),
    String codexExecutable = 'codex',
    String claudeExecutable = 'claude',
    ClaudeCodeApi? claudeApi,
    InternetAddress? bindAddress,
    bool publicHostEnabled = false,
    String? publicHostUrl,
    Set<String> publicAllowedOrigins = const {},
    SecurityContext? securityContext,
  }) async {
    final directory = Directory(p.normalize(p.absolute(projectDirectory)));
    if (!await directory.exists()) {
      throw ArgumentError.value(projectDirectory, 'projectDirectory');
    }

    OpenCodeApi? api;
    String? version;
    String? openCodeUnavailableReason;
    var openCodeAvailability = 'unavailable';
    try {
      final service = await OpenCodeServiceConnection.discover(
        executable: executable,
        workingDirectory: directory.path,
        commandRunner: openCodeCommandRunner,
      );
      api = OpenCodeApi(
        baseUri: service.baseUri,
        password: service.password,
        projectDirectory: directory.path,
        executable: executable,
      );
      version = await api.version();
    } catch (error) {
      await api?.close();
      api = null;
      openCodeUnavailableReason = _openCodeFailureDetail(error);
      if (error is ProcessException) openCodeAvailability = 'notInstalled';
    }
    CodexApi? codex;
    String? codexUnavailableReason;
    var codexAvailability = 'unavailable';
    try {
      codex = await CodexApi.start(
        projectDirectory: directory.path,
        executable: codexExecutable,
      );
    } catch (error) {
      codexUnavailableReason = 'Codex app-server 启动失败：$error';
      if (error is AgentExecutableNotFoundException) {
        codexAvailability = 'notInstalled';
        codexUnavailableReason = '未找到 Codex CLI（$codexExecutable）。';
      }
    }
    ClaudeCodeApi? claude = claudeApi;
    String? claudeUnavailableReason;
    var claudeAvailability = 'unavailable';
    if (claude == null) {
      try {
        claude = await ClaudeCodeApi.start(executable: claudeExecutable);
      } catch (error) {
        claudeUnavailableReason = 'Claude Code 未启动：$error';
        if (error is AgentExecutableNotFoundException) {
          claudeAvailability = 'notInstalled';
          claudeUnavailableReason = '未找到 Claude Code CLI（$claudeExecutable）。';
        }
      }
    }
    final normalizedPublicHostUrl = _normalizePublicHostUrl(publicHostUrl);
    final hookBroker = CodexHookBroker();
    try {
      final bridge = AgentBridge._(
        projectDirectory: directory.path,
        openCodeExecutable: executable,
        openCodeCommandRunner: openCodeCommandRunner,
        openCodeDiscoveryRetryInterval: openCodeDiscoveryRetryInterval,
        api: api,
        codex: codex,
        openCodeVersion: version,
        openCodeUnavailableReason: openCodeUnavailableReason,
        openCodeUnavailableAvailability: openCodeAvailability,
        codexUnavailableReason: codexUnavailableReason,
        codexUnavailableAvailability: codexAvailability,
        claude: claude,
        claudeUnavailableReason: claudeUnavailableReason,
        claudeUnavailableAvailability: claudeAvailability,
        pairingToken: pairingToken ?? _randomSecret(),
        uploads: UploadStore(directory.path),
        hookBroker: hookBroker,
        hookToken: _randomSecret(),
        websocketPort: websocketPort,
        bindAddress: bindAddress,
        publicHostEnabled: publicHostEnabled,
        publicHostUrl: normalizedPublicHostUrl,
        publicAllowedOrigins: Set.unmodifiable(publicAllowedOrigins),
        allowLocalDevConfig: allowLocalDevConfig,
        securityContext: securityContext,
      );
      bridge._server = await _RemoteSocketServer.bind(
        port: websocketPort,
        bindAddress: bindAddress,
        securityContext: securityContext,
        bridge: bridge,
        onLocalDevShutdown: onLocalDevShutdown,
      );
      await bridge._loadPairedDevices();
      if (codex != null) {
        try {
          await writeCodexHookRuntime(
            port: websocketPort,
            projectDirectory: directory.path,
            token: bridge.hookToken,
          );
          bridge._hookRuntimeReady = true;
        } catch (_) {
          // Desktop hooks remain optional if the runtime file is unavailable.
        }
      }
      bridge._startBackgroundTasks();
      return bridge;
    } catch (_) {
      await hookBroker.close();
      await api?.close();
      await codex?.close();
      rethrow;
    }
  }

  String get pairingTokenValue => pairingToken;
  List<String> get lanAddresses => _server.lanAddresses;
  bool get codexHookRuntimeReady => _hookRuntimeReady;
  String? get codexVersion => codex?.version;
  String? get relayClientTokenValue => relayClientToken;

  void registerRelayChannel(
    String channelId, {
    required void Function(String data) sendData,
    required void Function() onDone,
  }) {
    _relayChannels[channelId] = _RelayChannelBinding(
      sendData: sendData,
      onDone: onDone,
    );
  }

  void unregisterRelayChannel(String channelId) {
    _relayChannels.remove(channelId);
  }

  void setRelayConnection({
    required String url,
    required String room,
    required String clientToken,
    required bool connected,
  }) {
    final wasConnected = relayConnected;
    final changed =
        wasConnected != connected || relayUrl != url || relayRoom != room;
    relayUrl = url;
    relayRoom = room;
    relayClientToken = clientToken;
    relayConnected = connected;
    if (connected && !wasConnected) relayConnectedAt = DateTime.now().toUtc();
    if (connected) relayHeartbeatAt = DateTime.now().toUtc();
    if (!connected) {
      relayHeartbeatAt = null;
      relayTopology = null;
    }
    if (changed) {
      _server.markTopologyChanged();
      _server.broadcastTopology();
    }
  }

  void setRelayTopology(Map<String, dynamic>? topology) {
    relayTopology = topology == null
        ? null
        : Map<String, Object?>.from(topology);
    _server.markTopologyChanged();
    _server.broadcastTopology();
  }

  Future<Map<String, Object>> createPairingInvite() async {
    _pairingInvite = _randomSecret();
    _pairingInviteExpiresAt = DateTime.now().add(const Duration(minutes: 5));
    return {
      'invite': _pairingInvite!,
      'expiresAt': _pairingInviteExpiresAt!.toUtc().toIso8601String(),
    };
  }

  List<Map<String, String>> get pendingPairings => [
    for (final entry in _pendingPairings.entries)
      {'id': entry.key, 'name': entry.value.pairingDeviceName ?? '手机设备'},
  ];

  List<Map<String, String>> get pairedDevices => [
    for (final entry in _pairedDevices.entries)
      {'id': entry.key, 'name': entry.value['name'] ?? '手机设备'},
  ];

  Future<bool> resolvePairing(String id, {required bool approve}) async {
    final client = _pendingPairings.remove(id);
    if (client == null) return false;
    _pairingInvite = null;
    _pairingInviteExpiresAt = null;
    if (approve) {
      final token = client.pairingDeviceToken;
      if (token == null) {
        _pendingPairings.remove(id);
        await client.close();
        return false;
      }
      _pairedDevices[id] = {
        'name': client.pairingDeviceName ?? '手机设备',
        'token': token,
      };
      await _savePairedDevices();
      _completeClientHandshake(client, pairedDeviceId: id);
    } else {
      client.sendEvent('command.error', {'message': '电脑主机拒绝了此设备的配对请求。'});
      await client.close();
    }
    return true;
  }

  Future<void> revokePairedDevice(String id) async {
    final removed = _pairedDevices.remove(id) != null;
    await _savePairedDevices();
    if (removed) await _server.disconnectPairedDevice(id);
  }

  Future<void> _loadPairedDevices() async {
    final file = File(
      '$projectDirectory${Platform.pathSeparator}.remoteaisync'
      '${Platform.pathSeparator}paired-devices.json',
    );
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.value is Map) {
            final data = (entry.value as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            );
            if ((data['token'] ?? '').length >= 32) {
              _pairedDevices[entry.key.toString()] = data;
            }
          }
        }
      }
    } on FormatException {
      // Ignore damaged development pairing data; new devices can pair again.
    }
  }

  Future<void> _savePairedDevices() async {
    final file = File(
      '$projectDirectory${Platform.pathSeparator}.remoteaisync'
      '${Platform.pathSeparator}paired-devices.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_pairedDevices), flush: true);
  }

  List<Map<String, Object?>> get agentStatuses => [
    _agentStatus(
      id: 'opencode',
      name: 'OpenCode',
      availability: api == null
          ? openCodeUnavailableAvailability
          : _openCodeReachable
          ? 'available'
          : 'degraded',
      version: openCodeVersion,
      detail: api == null
          ? openCodeUnavailableReason ?? 'OpenCode 状态未知'
          : _openCodeReachable
          ? 'OpenCode 本地服务连接正常'
          : 'OpenCode 本地服务暂不可访问',
    ),
    _agentStatus(
      id: 'codex',
      name: 'Codex CLI',
      availability: codex == null
          ? codexUnavailableAvailability
          : _codexReachable
          ? 'available'
          : 'degraded',
      version: codexVersion,
      detail: codex == null
          ? codexUnavailableReason ?? 'Codex 状态未知'
          : _codexReachable
          ? 'Codex app-server 已启动'
          : 'Codex app-server 暂不可访问',
    ),
    _agentStatus(
      id: 'claude',
      name: 'Claude Code CLI',
      availability: claude == null
          ? claudeUnavailableAvailability
          : 'available',
      version: claude?.version,
      detail: claude == null
          ? claudeUnavailableReason ?? 'Claude Code 不可用'
          : 'Claude Code CLI 与本地会话记录可用',
    ),
  ];

  Map<String, Object?> _agentStatus({
    required String id,
    required String name,
    required String availability,
    required String? version,
    required String detail,
  }) => {
    'id': id,
    'name': name,
    'availability': availability,
    'version': version,
    'detail': detail,
  };

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _eventDebounce?.cancel();
    _refreshTimer.cancel();
    await hookBroker.close();
    await _server.close();
    _relayChannels.clear();
    if (_hookRuntimeReady) {
      await deleteCodexHookRuntimeIfOwned(
        port: websocketPort,
        token: hookToken,
      );
    }
    await uploads.close();
    await api?.close();
    await codex?.close();
  }

  Future<void> _watchCodexEvents() async {
    await for (final _ in codex!.events) {
      if (_closed) return;
      _scheduleRefresh();
    }
  }

  Future<void> _watchHookEvents() async {
    await for (final _ in hookBroker.events) {
      if (_closed) return;
      _scheduleRefresh();
    }
  }

  Future<void> _watchEvents() async {
    while (!_closed) {
      final source = api;
      if (source == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      try {
        await for (final event in source.events()) {
          if (_closed) return;
          if (!identical(source, api)) break;
          final eventType = event['type']?.toString();
          if (eventType == 'session.idle' && event['properties'] is Map) {
            final properties = event['properties'] as Map;
            final sessionId = properties['sessionID']?.toString();
            if (sessionId != null) _runningOpenCodeSessions.remove(sessionId);
          }
          if (eventType != null && eventType != 'server.connected') {
            _scheduleRefresh();
          }
        }
      } catch (_) {
        if (_closed) return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _scheduleRefresh() {
    if (_closed) return;
    _eventRefreshQueued = true;
    if (_eventDebounce?.isActive == true) return;
    _eventDebounce = Timer(const Duration(milliseconds: 250), () {
      _eventDebounce = null;
      if (_refreshTask != null) return;
      _eventRefreshQueued = false;
      unawaited(_refresh());
    });
  }

  Future<void> _refresh({bool forceSessions = false}) async {
    if (_closed) return Future<void>.value();
    if (forceSessions) {
      final running = _refreshTask;
      if (running != null) await running;
      codex?.invalidateSessionCache();
    }
    return _refreshTask ??= _performRefresh().whenComplete(() {
      _refreshTask = null;
      if (_eventRefreshQueued) _scheduleRefresh();
    });
  }

  Future<void> _performRefresh() async {
    try {
      await _maybeDiscoverOpenCode();
      List<OpenCodeSession>? openCodeSessions;
      if (api != null) {
        try {
          openCodeSessions = await api!.listSessions(
            directory: _workspaceDirectory,
            global: _allSessions,
          );
          _openCodeReachable = true;
        } catch (_) {
          _openCodeReachable = false;
        }
      }
      List<HostSession>? codexSessions;
      if (codex != null) {
        try {
          codex!.setSessionScopeDirectory(
            _allSessions ? '*' : _workspaceDirectory,
          );
          codexSessions = await codex!.listSessions();
          _codexReachable = true;
        } catch (_) {
          _codexReachable = false;
        }
      }
      List<HostSession> claudeSessions = _sessions
          .where((session) => session.agentId == 'claude')
          .toList(growable: false);
      if (claude != null) {
        try {
          claudeSessions = await claude!.listSessions(
            directory: _workspaceDirectory,
            global: _allSessions,
          );
        } catch (_) {
          // Keep the last known Claude sessions during transient file errors.
        }
      }
      final openCodeHostSessions = openCodeSessions == null
          ? _sessions.where((session) => session.agentId == 'opencode')
          : openCodeSessions.map(
              (session) => HostSession(
                id: session.id,
                title: session.title,
                updatedAt: session.updatedAt,
                directory: session.directory,
              ),
            );
      _sessions = [
        ...openCodeHostSessions,
        ...(codexSessions ??
            _sessions.where((session) => session.agentId == 'codex')),
        ...claudeSessions,
      ];
      _messages.clear();
      final selectedIds = _server.readyClients
          .map((client) => client.selectedSessionId)
          .whereType<String>()
          .where((id) => _sessions.any((session) => session.id == id))
          .toSet();
      for (final id in selectedIds) {
        try {
          final values = await _loadSession(id);
          _messages[id] = values[0] as List<AgentMessage>;
          _forms[id] = values[1] as List<AgentForm>;
          _permissions[id] = values[2] as List<AgentPermission>;
          _queuedMessages[id] = values[3] as List<AgentQueuedMessage>;
        } catch (_) {
          // A failed selection does not block other selected sessions.
        }
      }
      _queuedMessages.removeWhere((id, _) => !selectedIds.contains(id));
      _queueWarnings.removeWhere((id, _) => !selectedIds.contains(id));
      for (final client in _server.readyClients) {
        _sendHostSnapshot(client);
        final selectedId = client.selectedSessionId;
        if (selectedId != null && _messages.containsKey(selectedId)) {
          _sendSessionSnapshot(client, selectedId);
        }
      }
    } catch (error) {
      for (final client in _server.readyClients) {
        client.sendEvent('host.warning', {'message': _safeError(error)});
      }
    }
  }

  Future<void> _maybeDiscoverOpenCode() async {
    if (_closed || (api != null && _openCodeReachable)) return;
    final now = DateTime.now();
    final lastAttempt = _lastOpenCodeDiscoveryAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < openCodeDiscoveryRetryInterval) {
      return;
    }
    _lastOpenCodeDiscoveryAttempt = now;

    OpenCodeApi? candidate;
    try {
      final service = await OpenCodeServiceConnection.discover(
        executable: openCodeExecutable,
        workingDirectory: projectDirectory,
        commandRunner: openCodeCommandRunner,
      );
      candidate = OpenCodeApi(
        baseUri: service.baseUri,
        password: service.password,
        projectDirectory: projectDirectory,
        executable: openCodeExecutable,
      );
      final version = await candidate.version();
      final previous = api;
      api = candidate;
      candidate = null;
      openCodeVersion = version;
      openCodeUnavailableReason = null;
      _openCodeReachable = true;
      await previous?.close();
    } catch (error) {
      await candidate?.close();
      openCodeUnavailableReason = _openCodeFailureDetail(error);
      openCodeUnavailableAvailability = error is ProcessException
          ? 'notInstalled'
          : 'unavailable';
    }
  }

  Future<List<Object>> _loadSession(String id) {
    if (id.startsWith('codex:')) {
      final adapter = codex;
      if (adapter == null) throw const CodexApiException('Codex 适配器未运行。');
      return Future.wait<Object>([
        adapter.listMessages(id),
        Future.value(adapter.listForms(id)),
        Future.value([
          ...adapter.listPermissions(id),
          ...hookBroker.listPermissions(id),
        ]),
        _sessions.any((session) => session.id == id && !session.remoteManaged)
            ? _listDesktopQueue(adapter, id)
            : Future.value(const <AgentQueuedMessage>[]),
      ]);
    }
    if (id.startsWith('claude:')) {
      final adapter = claude;
      if (adapter == null) {
        throw const ClaudeCodeException('Claude Code 适配器未运行。');
      }
      return Future.wait<Object>([
        adapter.listMessages(id),
        Future.value(const <AgentForm>[]),
        Future.value(const <AgentPermission>[]),
        Future.value(const <AgentQueuedMessage>[]),
      ]);
    }
    final adapter = api;
    if (adapter == null) throw const OpenCodeApiException('OpenCode 适配器未运行。');
    final directory = _sessionDirectory(id);
    return Future.wait<Object>([
      adapter.listMessages(id, directory: directory),
      adapter.listForms(id, directory: directory),
      adapter.listPermissions(id, directory: directory),
      Future.value(const <AgentQueuedMessage>[]),
    ]);
  }

  String _sessionDirectory(String sessionId) {
    final match = _sessions.where((session) => session.id == sessionId);
    return match.isNotEmpty && match.first.directory != null
        ? match.first.directory!
        : _workspaceDirectory;
  }

  Future<List<AgentQueuedMessage>> _listDesktopQueue(
    CodexApi adapter,
    String sessionId,
  ) async {
    try {
      final queued = await adapter.listQueuedMessages(sessionId);
      _queueWarnings.remove(sessionId);
      return queued;
    } catch (error) {
      _queueWarnings[sessionId] = _safeError(error);
      return _queuedMessages[sessionId] ?? const [];
    }
  }

  void _sendHostSnapshot(_RemoteClient client) {
    client.sendEvent('host.snapshot', {
      'workspaceDirectory': _workspaceDirectory,
      'allSessions': _allSessions,
      'agents': agentStatuses,
      'connectedClients': _server.connectedClientCount,
      'topology': _server.topologySnapshot(),
      'sessions': _sessions
          .map(
            (session) => {
              'id': session.id,
              'agentId': session.agentId,
              'remoteManaged': session.remoteManaged,
              'pendingCount': session.agentId == 'codex'
                  ? (codex?.pendingCountFor(session.id) ?? 0) +
                        hookBroker.pendingCountFor(session.id)
                  : 0,
              'title': session.title,
              'updatedAt': session.updatedAt,
              'directory': session.directory,
            },
          )
          .toList(),
    });
  }

  void _sendSessionSnapshot(
    _RemoteClient client,
    String sessionId, {
    int? selectionGeneration,
  }) {
    final matching = _sessions.where((item) => item.id == sessionId);
    final session = matching.isEmpty ? null : matching.first;
    if (session == null) return;
    client.sendEvent('session.snapshot', {
      'sessionId': session.id,
      'title': session.title,
      'messages': (_messages[sessionId] ?? const [])
          .map(_messageToJson)
          .toList(),
      'forms': (_forms[sessionId] ?? const []).map(_formToJson).toList(),
      'permissions': (_permissions[sessionId] ?? const [])
          .map(_permissionToJson)
          .toList(),
      'queuedMessages': (_queuedMessages[sessionId] ?? const [])
          .map(
            (item) => {
              'id': item.id,
              'text': item.text,
              'imageCount': item.imageCount,
            },
          )
          .toList(),
      'queueWarning': _queueWarnings[sessionId],
      'messageLimit': 100,
      'selectionGeneration': selectionGeneration ?? client.selectionGeneration,
    }, sessionId: sessionId);
  }

  Future<void> _handleMessage(
    _RemoteClient client,
    Map<String, dynamic> frame,
  ) async {
    final commandId = frame['commandId']?.toString();
    final kind = frame['kind']?.toString();
    final payload = frame['payload'];
    final schemaVersion = frame['schemaVersion'];
    if ((schemaVersion != 1 && schemaVersion != 2) ||
        kind == null ||
        payload is! Map) {
      client.sendEvent('command.error', {
        'commandId': commandId,
        'message': '无效的协议消息。',
      });
      return;
    }

    if (kind == 'client.hello') {
      client.protocolVersion =
          (payload['protocolVersion'] as num?)?.toInt() ?? 1;
      final deviceId = payload['deviceId']?.toString() ?? '';
      final deviceToken = payload['deviceToken']?.toString() ?? '';
      final deviceName = payload['deviceName']?.toString().trim();
      final pairedToken = _pairedDevices[deviceId]?['token'];
      if (deviceId.isNotEmpty &&
          pairedToken != null &&
          _constantTimeEquals(deviceToken, pairedToken)) {
        _completeClientHandshake(client, pairedDeviceId: deviceId);
        return;
      }
      final invite = payload['pairingToken']?.toString() ?? '';
      final inviteValid =
          _pairingInvite != null &&
          _pairingInviteExpiresAt?.isAfter(DateTime.now()) == true &&
          _constantTimeEquals(invite, _pairingInvite!);
      final pendingDeviceId = _pendingPairings.keys.firstOrNull;
      if (!inviteValid ||
          (pendingDeviceId != null && pendingDeviceId != deviceId) ||
          deviceId.length < 12 ||
          deviceToken.length < 32 ||
          deviceName == null ||
          deviceName.isEmpty) {
        final pairingRequired = invite.isEmpty;
        client.sendEvent('command.error', {
          'commandId': commandId,
          'code': pairingRequired
              ? 'pairing_required'
              : 'pairing_invite_invalid',
          'message': pairingRequired
              ? '此设备尚未配对或已被主机撤销，请扫描新的主机配对二维码。'
              : '配对邀请无效或已过期，请在电脑端重新生成。',
        });
        await client.close();
        return;
      }
      final previous = _pendingPairings[deviceId];
      if (previous != null && !identical(previous, client)) {
        await previous.close();
      }
      client
        ..pairingDeviceId = deviceId
        ..pairingDeviceToken = deviceToken
        ..pairingDeviceName = deviceName;
      _pendingPairings[deviceId] = client;
      client.sendEvent('pairing.pending', {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'message': '等待电脑主机批准此设备。',
      });
      return;
    }
    if (!client.isReady) {
      client.sendEvent('command.error', {
        'commandId': commandId,
        'message': '请先完成协议握手。',
      });
      return;
    }

    final data = payload.cast<String, dynamic>();
    switch (kind) {
      case 'topology.pong':
        client.recordHeartbeat(data['sentAt']?.toString());
        _server.markTopologyChanged();
        return;
      case 'workspace.list':
        try {
          final requested = data['path']?.toString();
          final roots = requested == '@roots';
          final directory = roots
              ? null
              : requested == null || requested.isEmpty
              ? Directory(_workspaceDirectory)
              : Directory(p.normalize(p.absolute(requested)));
          if (directory != null && !await directory.exists()) {
            throw const FileSystemException('此目录不存在。');
          }
          final entries = <Map<String, Object?>>[];
          if (roots && Platform.isWindows) {
            for (var code = 65; code <= 90; code++) {
              final letter = String.fromCharCode(code);
              final root = '$letter:${Platform.pathSeparator}';
              if (await Directory(root).exists()) {
                entries.add({
                  'name': '$letter:',
                  'path': root,
                  'isDirectory': true,
                });
              }
            }
          } else if (directory != null) {
            await for (final entity in directory.list(followLinks: false)) {
              try {
                final stat = await entity.stat();
                final isDirectory = stat.type == FileSystemEntityType.directory;
                entries.add({
                  'name': p.basename(entity.path),
                  'path': p.normalize(p.absolute(entity.path)),
                  'isDirectory': isDirectory,
                  if (!isDirectory) 'sizeBytes': stat.size,
                  'modifiedAt': stat.modified.toIso8601String(),
                });
              } on FileSystemException {
                continue;
              }
            }
          }
          entries.sort((a, b) {
            if (a['isDirectory'] != b['isDirectory']) {
              return a['isDirectory'] == true ? -1 : 1;
            }
            return (a['name'] as String).toLowerCase().compareTo(
              (b['name'] as String).toLowerCase(),
            );
          });
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'path': directory?.path ?? '@roots',
            'entries': entries,
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'workspace.read':
        try {
          final file = File(
            p.normalize(p.absolute(data['path']?.toString() ?? '')),
          );
          if (!await file.exists()) throw const FileSystemException('文件不存在。');
          final extension = p.extension(file.path).toLowerCase();
          final imageTypes = const {
            '.png': 'image/png',
            '.jpg': 'image/jpeg',
            '.jpeg': 'image/jpeg',
            '.gif': 'image/gif',
            '.webp': 'image/webp',
            '.bmp': 'image/bmp',
          };
          final isPdf = extension == '.pdf';
          final isImage = imageTypes.containsKey(extension);
          final stat = await file.stat();
          if (isPdf || isImage) {
            if (stat.size > 15 * 1024 * 1024) {
              throw const FileSystemException('预览仅支持不超过 15 MiB 的图片或 PDF。');
            }
            client.sendEvent('command.result', {
              'commandId': commandId,
              'ok': true,
              'previewKind': isPdf ? 'pdf' : 'image',
              'mimeType': isPdf ? 'application/pdf' : imageTypes[extension],
              'bytes': base64Encode(await file.readAsBytes()),
            });
            return;
          }
          if (stat.size > 1024 * 1024) {
            throw const FileSystemException('仅支持预览不超过 1 MiB 的文本文件。');
          }
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'path': file.path,
            'previewKind': 'text',
            'text': await file.readAsString(),
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'workspace.download':
        try {
          final path = p.normalize(p.absolute(data['path']?.toString() ?? ''));
          final offset = data['offset'];
          final length = data['length'];
          if (offset is! int ||
              offset < 0 ||
              length is! int ||
              length < 1 ||
              length > 256 * 1024) {
            throw const FileSystemException('下载位置无效。');
          }
          final file = File(path);
          if (!await file.exists() ||
              await FileSystemEntity.type(path, followLinks: false) !=
                  FileSystemEntityType.file) {
            throw const FileSystemException('只能下载可访问的普通文件。');
          }
          final stat = await file.stat();
          if (offset > stat.size) {
            throw const FileSystemException('下载位置超出文件大小。');
          }
          final end = (offset + length).clamp(0, stat.size).toInt();
          final bytes = await file
              .openRead(offset, end)
              .expand((part) => part)
              .toList();
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'fileName': p.basename(path),
            'totalBytes': stat.size,
            'offset': offset,
            'data': base64Encode(bytes),
            'done': end >= stat.size,
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'workspace.write':
        try {
          final path = p.normalize(p.absolute(data['path']?.toString() ?? ''));
          final content = data['content'];
          if (content is! String || utf8.encode(content).length > 1024 * 1024) {
            throw const FileSystemException('仅支持保存不超过 1 MiB 的文本文件。');
          }
          final file = File(path);
          if (!await file.exists()) {
            throw const FileSystemException('只能保存已存在的文件。');
          }
          final existing = await file.readAsBytes();
          if (existing.length > 1024 * 1024 ||
              existing.any(
                (byte) =>
                    (byte < 9) ||
                    (byte > 10 && byte < 32 && byte != 13) ||
                    byte == 127,
              )) {
            throw const FileSystemException('仅支持保存不超过 1 MiB 的文本文件。');
          }
          try {
            utf8.decode(existing);
          } on FormatException {
            throw const FileSystemException('目标文件不是 UTF-8 文本，拒绝覆盖。');
          }
          await file.writeAsString(content, flush: true);
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'workspace.delete':
        try {
          final path = p.normalize(p.absolute(data['path']?.toString() ?? ''));
          if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw const FileSystemException('只能删除普通文件，不支持删除目录或链接。');
          }
          await File(path).delete();
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'workspace.mkdir':
        try {
          final parent = p.normalize(
            p.absolute(data['parent']?.toString() ?? ''),
          );
          final name = data['name']?.toString().trim() ?? '';
          if (name.isEmpty ||
              name == '.' ||
              name == '..' ||
              p.basename(name) != name) {
            throw const FileSystemException('文件夹名称无效。');
          }
          await Directory(p.join(parent, name)).create();
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'workspace.select':
        try {
          final directory = p.normalize(
            p.absolute(data['path']?.toString() ?? ''),
          );
          if (!await Directory(directory).exists()) {
            throw const FileSystemException('工作目录不存在。');
          }
          final scopeChanged = _allSessions != (data['sessionScope'] == 'all');
          _workspaceDirectory = directory;
          _allSessions = data['sessionScope'] == 'all';
          api?.setProjectDirectory(directory);
          codex?.setSessionScopeDirectory(
            data['sessionScope'] == 'all' ? '*' : directory,
          );
          await _refresh(forceSessions: true);
          if (scopeChanged) {
            for (final ready in _server.readyClients) {
              _sendHostSnapshot(ready);
            }
          }
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'attachment.begin':
        final sessionId = data['sessionId']?.toString();
        final size = data['sizeBytes'];
        if (sessionId == null ||
            sessionId != client.selectedSessionId ||
            !_sessions.any((session) => session.id == sessionId) ||
            size is! int ||
            data['name'] is! String) {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': '请先选择会话，并提供有效的文件信息。',
          });
          return;
        }
        try {
          final uploadId = await uploads.begin(
            clientId: client.id,
            sessionId: sessionId,
            name: data['name'] as String,
            sizeBytes: size,
            mimeType: data['mimeType']?.toString(),
          );
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'uploadId': uploadId,
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'attachment.chunk':
        final uploadId = data['uploadId'];
        final offset = data['offset'];
        final bytes = data['data'];
        if (uploadId is! String || offset is! int || bytes is! String) {
          _sendCommandError(
            client,
            commandId,
            const UploadException('文件块信息无效。'),
          );
          return;
        }
        try {
          final received = await uploads.append(
            clientId: client.id,
            uploadId: uploadId,
            offset: offset,
            data: bytes,
          );
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'receivedBytes': received,
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'attachment.finish':
        final uploadId = data['uploadId'];
        if (uploadId is! String) {
          _sendCommandError(
            client,
            commandId,
            const UploadException('上传任务 ID 无效。'),
          );
          return;
        }
        try {
          final file = await uploads.finish(
            clientId: client.id,
            uploadId: uploadId,
          );
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'attachmentId': file.id,
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'attachment.cancel':
        final uploadId = data['uploadId'];
        if (uploadId is! String) {
          _sendCommandError(
            client,
            commandId,
            const UploadException('上传任务 ID 无效。'),
          );
          return;
        }
        try {
          await uploads.cancel(clientId: client.id, uploadId: uploadId);
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.create':
        final agentId = data['agentId']?.toString() ?? '';
        final useDefaultDirectory =
            agentId == 'codex' && data['useDefaultDirectory'] == true;
        final sessionDirectory = p.normalize(
          p.absolute(data['directory']?.toString() ?? _workspaceDirectory),
        );
        if (!useDefaultDirectory &&
            !await Directory(sessionDirectory).exists()) {
          _sendCommandError(
            client,
            commandId,
            const FileSystemException('工作目录不存在。'),
          );
          return;
        }
        if (!useDefaultDirectory) _workspaceDirectory = sessionDirectory;
        if (agentId == 'opencode' && api == null) {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': 'OpenCode 适配器未运行。',
          });
          return;
        }
        if (agentId == 'codex' && codex == null) {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': 'Codex 适配器未运行。',
          });
          return;
        }
        if (agentId == 'claude' && claude == null) {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': 'Claude Code CLI 不可用。',
          });
          return;
        }
        if (agentId != 'codex' &&
            agentId != 'opencode' &&
            agentId != 'claude') {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': '当前主机不支持此 Agent。',
          });
          return;
        }
        try {
          if (agentId == 'codex') {
            final sessionId = await codex!.createSession(
              ephemeral: data['ephemeral'] == true,
              directory: useDefaultDirectory ? null : sessionDirectory,
            );
            _announceSession(
              client,
              commandId,
              HostSession(
                id: sessionId,
                agentId: 'codex',
                remoteManaged: true,
                title: '新建 Codex 会话',
                updatedAt: _currentTimeLabel(),
                directory: useDefaultDirectory ? null : sessionDirectory,
              ),
            );
          } else if (agentId == 'opencode') {
            final session = await api!.createSession(
              title: '新建 OpenCode 会话',
              directory: sessionDirectory,
            );
            _announceSession(
              client,
              commandId,
              HostSession(
                id: session.id,
                agentId: 'opencode',
                title: session.title,
                updatedAt: session.updatedAt,
                directory: sessionDirectory,
              ),
            );
          } else {
            final sessionId = await claude!.createSession(sessionDirectory);
            _announceSession(
              client,
              commandId,
              HostSession(
                id: sessionId,
                agentId: 'claude',
                remoteManaged: true,
                title: '新建 Claude Code 会话',
                updatedAt: _currentTimeLabel(),
                directory: sessionDirectory,
              ),
            );
          }
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.controls':
        final sessionId = data['sessionId']?.toString();
        final selected = _sessions.where((item) => item.id == sessionId);
        if (sessionId == null ||
            sessionId != client.selectedSessionId ||
            selected.isEmpty) {
          _sendCommandError(
            client,
            commandId,
            const OpenCodeApiException('请先选择 Agent 会话。'),
          );
          return;
        }
        try {
          late final List<Map<String, Object?>> models;
          late final List<String> skills;
          late final Map<String, Object?> settings;
          if (selected.first.agentId == 'codex' && codex != null) {
            models = await codex!.listModels();
            skills = await codex!.listSkills(
              directory: selected.first.directory,
            );
            try {
              settings = await codex!.readSettings(sessionId);
            } catch (_) {
              settings = {'model': null, 'effort': null, 'running': false};
            }
          } else if (selected.first.agentId == 'opencode' && api != null) {
            final controls = await api!.listControls();
            models = controls.models
                .map(
                  (model) => <String, Object?>{
                    'id': model.id,
                    'name': model.name,
                    'efforts': model.efforts,
                    'defaultEffort': model.defaultEffort,
                  },
                )
                .toList(growable: false);
            skills = const [];
            settings = {
              'model': controls.model,
              'effort': controls.effort,
              'running': _runningOpenCodeSessions.contains(sessionId),
            };
          } else if (selected.first.agentId == 'claude' && claude != null) {
            final controls = await claude!.controls(sessionId);
            models = (controls['models'] as List).cast<Map<String, Object?>>();
            skills = const [];
            settings = (controls['settings'] as Map).cast<String, Object?>();
          } else {
            throw const OpenCodeApiException('当前 Agent 不支持模型设置。');
          }
          client.sendEvent('command.result', {
            'commandId': commandId,
            'ok': true,
            'models': models,
            'skills': skills,
            'settings': settings,
          });
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.settings.update':
        final sessionId = data['sessionId']?.toString();
        final selected = _sessions.where((item) => item.id == sessionId);
        if (sessionId == null ||
            sessionId != client.selectedSessionId ||
            selected.isEmpty ||
            !selected.first.remoteManaged) {
          _sendCommandError(
            client,
            commandId,
            const OpenCodeApiException('当前会话不支持远程切换模型。'),
          );
          return;
        }
        try {
          if (selected.first.agentId == 'claude' && claude != null) {
            claude!.updateSettings(
              sessionId,
              model: data['model']?.toString() ?? '',
              effort: data['effort']?.toString() ?? '',
            );
          } else if (selected.first.agentId == 'codex' && codex != null) {
            await codex!.updateSettings(
              sessionId,
              model: data['model']?.toString() ?? '',
              effort: data['effort']?.toString() ?? '',
            );
          } else {
            throw const OpenCodeApiException('当前 Agent 不支持远程切换模型。');
          }
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.action':
        final sessionId = data['sessionId']?.toString();
        if (codex == null ||
            sessionId == null ||
            sessionId != client.selectedSessionId ||
            !_sessions.any(
              (session) =>
                  session.id == sessionId &&
                  session.agentId == 'codex' &&
                  session.remoteManaged,
            )) {
          _sendCommandError(
            client,
            commandId,
            const CodexApiException('此操作仅适用于 RemoteAISync 控制的 Codex 会话。'),
          );
          return;
        }
        try {
          if (kind == 'session.action') {
            switch (data['action']) {
              case 'compact':
                await codex!.compact(sessionId);
                break;
              case 'review':
                await codex!.reviewUncommitted(sessionId);
                break;
              default:
                throw const CodexApiException('不支持此 Codex 操作。');
            }
          } else {
            final model = data['model']?.toString() ?? '';
            final effort = data['effort']?.toString() ?? '';
            await codex!.updateSettings(
              sessionId,
              model: model,
              effort: effort,
            );
          }
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.interrupt':
        final sessionId = data['sessionId']?.toString();
        final session = _sessions.where((item) => item.id == sessionId);
        if (sessionId == null ||
            sessionId != client.selectedSessionId ||
            session.isEmpty ||
            (session.first.agentId == 'claude' &&
                !session.first.remoteManaged) ||
            (session.first.agentId != 'codex' &&
                session.first.agentId != 'opencode' &&
                session.first.agentId != 'claude')) {
          _sendCommandError(
            client,
            commandId,
            const OpenCodeApiException('当前会话不支持远程停止。'),
          );
          return;
        }
        try {
          if (session.first.agentId == 'opencode') {
            await api!.abortSession(
              sessionId,
              directory: _sessionDirectory(sessionId),
            );
            _runningOpenCodeSessions.remove(sessionId);
          } else if (session.first.agentId == 'codex') {
            await codex!.interruptIfRunning(sessionId);
          } else {
            await claude!.interruptSession(sessionId);
          }
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.select':
        final sessionId = data['sessionId']?.toString();
        if (sessionId == null ||
            !_sessions.any((session) => session.id == sessionId)) {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': '找不到此 Agent 会话。',
          });
          return;
        }
        final requestedGeneration = data['selectionGeneration'];
        final selectionGeneration = requestedGeneration is num
            ? requestedGeneration.toInt()
            : client.selectionGeneration + 1;
        client.selectedSessionId = sessionId;
        client.selectionGeneration = selectionGeneration;
        try {
          final values = await _loadSession(sessionId);
          _messages[sessionId] = values[0] as List<AgentMessage>;
          _forms[sessionId] = values[1] as List<AgentForm>;
          _permissions[sessionId] = values[2] as List<AgentPermission>;
          _queuedMessages[sessionId] = values[3] as List<AgentQueuedMessage>;
          if (client.selectedSessionId == sessionId &&
              client.selectionGeneration == selectionGeneration) {
            _sendSessionSnapshot(
              client,
              sessionId,
              selectionGeneration: selectionGeneration,
            );
          }
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.refresh':
        await _refresh(forceSessions: true);
        _sendCommandResult(client, commandId);
        return;
      case 'session.reply':
        await _sendReply(client, commandId, data);
        return;
      case 'session.queue.delete':
        await _deleteQueuedMessage(client, commandId, data);
        return;
      case 'session.form.reply':
        await _replyToForm(client, commandId, data);
        return;
      case 'session.permission.reply':
        await _replyToPermission(client, commandId, data);
        return;
      default:
        client.sendEvent('command.error', {
          'commandId': commandId,
          'message': '当前主机不支持此操作。',
        });
    }
  }

  void _completeClientHandshake(
    _RemoteClient client, {
    required String pairedDeviceId,
  }) {
    for (final previous
        in _server.readyClients
            .where((candidate) => candidate.pairedDeviceId == pairedDeviceId)
            .toList(growable: false)) {
      previous.isReady = false;
      unawaited(previous.close());
    }
    client.pairedDeviceId = pairedDeviceId;
    final previousConnections =
        _server._deviceConnectionCounts[pairedDeviceId] ?? 0;
    client.reconnects = previousConnections;
    _server._deviceConnectionCounts[pairedDeviceId] = previousConnections + 1;
    client.isReady = true;
    client.sendEvent('host.ready', {
      'protocolVersion': 1,
      'transportProtocolVersion': 2,
      'pairedDeviceId': pairedDeviceId,
      'workspaceDirectory': _workspaceDirectory,
      'allSessions': _allSessions,
      'agents': agentStatuses,
      'connectedClients': _server.connectedClientCount,
      'topology': _server.topologySnapshot(),
      'openCodeVersion': openCodeVersion,
      'codexVersion': codex?.version,
      'capabilities': {
        'sessionRead': true,
        'sessionReply': true,
        'forms': true,
        'approvals': true,
        'codexDesktopHookApprovals': _hookRuntimeReady,
        'attachments': true,
        'remoteAccess': false,
      },
    });
    _server.markTopologyChanged();
    _server.broadcastTopology();
    unawaited(_refresh());
  }

  Future<void> _sendReply(
    _RemoteClient client,
    String? commandId,
    Map<String, dynamic> data,
  ) async {
    final sessionId = data['sessionId']?.toString();
    final text = data['text']?.toString().trim() ?? '';
    final rawIds = data['attachmentIds'];
    if (rawIds != null &&
        (rawIds is! List || rawIds.any((id) => id is! String))) {
      _sendCommandError(
        client,
        commandId,
        const UploadException('附件 ID 列表无效。'),
      );
      return;
    }
    final attachmentIds = (rawIds as List? ?? const []).cast<String>();
    if (sessionId == null ||
        sessionId != client.selectedSessionId ||
        !_sessions.any((session) => session.id == sessionId)) {
      _sendCommandError(
        client,
        commandId,
        const OpenCodeApiException('会话未选中或已不存在。'),
      );
      return;
    }
    final desktopCodex = _sessions.any(
      (session) =>
          session.id == sessionId &&
          session.agentId == 'codex' &&
          !session.remoteManaged,
    );
    final claudeSession = _sessions.any(
      (session) =>
          session.id == sessionId &&
          session.agentId == 'claude' &&
          session.remoteManaged,
    );
    if (text.isEmpty && attachmentIds.isEmpty) {
      client.sendEvent('command.error', {
        'commandId': commandId,
        'message': '请输入回复或选择文件。',
      });
      return;
    }
    try {
      final attachments = uploads.resolve(
        clientId: client.id,
        sessionId: sessionId,
        attachmentIds: attachmentIds,
      );
      final replyText = _replyWithAttachmentPaths(text, attachments);
      String? queuedId;
      if (sessionId.startsWith('codex:')) {
        if (desktopCodex) {
          queuedId = await codex!.sendDesktopMessage(
            sessionId,
            replyText,
            directory: _sessionDirectory(sessionId),
            localImages: attachments
                .where((attachment) => attachment.isCodexImage)
                .map((attachment) => attachment.path)
                .toList(),
          );
        } else {
          await codex!.sendReply(
            sessionId,
            replyText,
            directory: _sessionDirectory(sessionId),
            localImages: attachments
                .where((attachment) => attachment.isCodexImage)
                .map((attachment) => attachment.path)
                .toList(),
          );
        }
      } else if (claudeSession) {
        await claude!.sendMessage(
          sessionId,
          replyText,
          directory: _sessionDirectory(sessionId),
          onTranscriptChanged: _scheduleRefresh,
        );
      } else {
        await api!.sendReply(
          sessionId,
          replyText,
          model: data['model']?.toString(),
          variant: data['effort']?.toString(),
          directory: _sessionDirectory(sessionId),
        );
        _runningOpenCodeSessions.add(sessionId);
      }
      if (desktopCodex) {
        client.sendEvent('command.result', {
          'commandId': commandId,
          'ok': true,
          'delivery': queuedId == null ? 'sent' : 'queued',
          'queuedSubmissionId': ?queuedId,
        });
      } else {
        _sendCommandResult(client, commandId);
      }
      _scheduleRefresh();
    } catch (error) {
      _sendCommandError(client, commandId, error);
    }
  }

  Future<void> _deleteQueuedMessage(
    _RemoteClient client,
    String? commandId,
    Map<String, dynamic> data,
  ) async {
    final sessionId = data['sessionId'];
    final queuedId = data['queuedSubmissionId'];
    if (sessionId is! String ||
        sessionId != client.selectedSessionId ||
        !_sessions.any(
          (session) =>
              session.id == sessionId &&
              session.agentId == 'codex' &&
              !session.remoteManaged,
        ) ||
        queuedId is! String ||
        queuedId.isEmpty) {
      _sendCommandError(
        client,
        commandId,
        const CodexApiException('只能撤回当前选中桌面会话的排队消息。'),
      );
      return;
    }
    try {
      final deleted = await codex!.deleteQueuedMessage(sessionId, queuedId);
      if (!deleted) {
        throw const CodexApiException('消息已被 Codex 处理或撤回，无法再次撤回。');
      }
      _queuedMessages[sessionId] = (_queuedMessages[sessionId] ?? const [])
          .where((item) => item.id != queuedId)
          .toList(growable: false);
      for (final ready in _server.readyClients) {
        if (ready.selectedSessionId == sessionId) {
          _sendSessionSnapshot(ready, sessionId);
        }
      }
      _sendCommandResult(client, commandId);
    } catch (error) {
      _sendCommandError(client, commandId, error);
    } finally {
      _scheduleRefresh();
    }
  }

  Future<void> _replyToForm(
    _RemoteClient client,
    String? commandId,
    Map<String, dynamic> data,
  ) async {
    final sessionId = data['sessionId']?.toString();
    final formId = data['formId']?.toString();
    final answer = data['answer'];
    final formIsPending =
        sessionId != null &&
        (_forms[sessionId] ?? const []).any((form) => form.id == formId);
    if (sessionId == null ||
        sessionId != client.selectedSessionId ||
        !_sessions.any((session) => session.id == sessionId) ||
        formId == null ||
        !formIsPending ||
        answer is! Map) {
      _sendCommandError(
        client,
        commandId,
        const OpenCodeApiException('此表单已过期或不属于当前会话。'),
      );
      return;
    }
    try {
      if (sessionId.startsWith('codex:')) {
        await codex!.replyToForm(
          sessionId,
          formId,
          answer.cast<String, Object?>(),
        );
      } else {
        await api!.replyToForm(
          sessionId,
          formId,
          answer.cast<String, Object?>(),
          directory: _sessionDirectory(sessionId),
        );
      }
      _sendCommandResult(client, commandId);
      _scheduleRefresh();
    } catch (error) {
      _sendCommandError(client, commandId, error);
    }
  }

  Future<void> _replyToPermission(
    _RemoteClient client,
    String? commandId,
    Map<String, dynamic> data,
  ) async {
    final sessionId = data['sessionId']?.toString();
    final requestId = data['requestId']?.toString();
    final decision = data['decision']?.toString();
    final requestIsPending =
        sessionId != null &&
        (_permissions[sessionId] ?? const []).any(
          (permission) => permission.id == requestId,
        );
    if (sessionId == null ||
        sessionId != client.selectedSessionId ||
        !_sessions.any((session) => session.id == sessionId) ||
        requestId == null ||
        !requestIsPending ||
        (decision != 'once' && decision != 'reject')) {
      _sendCommandError(
        client,
        commandId,
        const OpenCodeApiException('此审批已过期或不属于当前会话。'),
      );
      return;
    }
    try {
      if (sessionId.startsWith('codex:')) {
        if (hookBroker.hasRequest(sessionId, requestId)) {
          if (!hookBroker.resolve(
            sessionId,
            requestId,
            allow: decision == 'once',
          )) {
            throw const CodexApiException('此桌面审批已失效。');
          }
        } else {
          await codex!.replyToPermission(
            sessionId,
            requestId,
            decision: decision!,
          );
        }
      } else {
        await api!.replyToPermission(
          sessionId,
          requestId,
          decision: decision!,
          directory: _sessionDirectory(sessionId),
        );
      }
      _sendCommandResult(client, commandId);
      _scheduleRefresh();
    } catch (error) {
      _sendCommandError(client, commandId, error);
    }
  }

  Future<void> _handleCodexHookApproval(HttpRequest request) async {
    final response = request.response;
    Future<void> reply(String decision, {int status = HttpStatus.ok}) async {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'decision': decision}));
      await response.close();
    }

    try {
      if (request.connectionInfo?.remoteAddress.isLoopback != true) {
        await reply('fallback', status: HttpStatus.notFound);
        return;
      }
      final suppliedToken =
          request.headers.value('x-remoteaisync-hook-token') ?? '';
      if (!_constantTimeEquals(suppliedToken, hookToken)) {
        await reply('fallback', status: HttpStatus.forbidden);
        return;
      }
      if (request.contentLength > 1024 * 1024) {
        await reply('fallback', status: HttpStatus.requestEntityTooLarge);
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          await reply('fallback', status: HttpStatus.requestEntityTooLarge);
          return;
        }
        bytes.addAll(chunk);
      }
      final input = jsonDecode(utf8.decode(bytes));
      if (input is! Map || input['hook_event_name'] != 'PermissionRequest') {
        await reply('fallback', status: HttpStatus.badRequest);
        return;
      }
      final threadId = input['session_id']?.toString() ?? '';
      final cwd = input['cwd']?.toString() ?? '';
      final toolName = input['tool_name']?.toString() ?? '';
      if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(threadId) ||
          toolName.isEmpty ||
          codex == null ||
          !_sameProjectDirectory(cwd, codex!.projectDirectory) ||
          _server.readyClients.isEmpty) {
        await reply('fallback');
        return;
      }
      await _refresh(forceSessions: true);
      final sessionId = 'codex:$threadId';
      if (!_sessions.any((session) => session.id == sessionId)) {
        await reply('fallback');
        return;
      }
      final allow = await hookBroker.request(
        sessionId: sessionId,
        toolName: toolName,
        toolInput: input['tool_input'],
      );
      await reply(
        allow == null
            ? 'fallback'
            : allow
            ? 'allow'
            : 'deny',
      );
    } catch (_) {
      try {
        await reply('fallback', status: HttpStatus.badRequest);
      } catch (_) {
        // The hook process may have exited while waiting for a decision.
      }
    }
  }

  void _announceSession(
    _RemoteClient client,
    String? commandId,
    HostSession session,
  ) {
    _sessions = [session, ..._sessions.where((item) => item.id != session.id)];
    for (final readyClient in _server.readyClients) {
      _sendHostSnapshot(readyClient);
    }
    client.sendEvent('command.result', {
      'commandId': commandId,
      'ok': true,
      'sessionId': session.id,
    });
    _scheduleRefresh();
  }

  void _sendCommandResult(_RemoteClient client, String? commandId) {
    client.sendEvent('command.result', {'commandId': commandId, 'ok': true});
  }

  void _sendCommandError(
    _RemoteClient client,
    String? commandId,
    Object error,
  ) {
    client.sendEvent('command.error', {
      'commandId': commandId,
      'code': _errorCode(error),
      'message': _safeError(error),
    });
  }
}

String? _normalizePublicHostUrl(String? value) {
  if (value == null || value.trim().isEmpty) return value;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) return value;
  if (uri.path.isEmpty || uri.path == '/') {
    return uri.replace(path: '/ws').toString();
  }
  return value.trim();
}

String _errorCode(Object error) => switch (error) {
  UploadException() => 'attachment_error',
  ClaudeCodeException() => 'agent_unavailable',
  CodexApiException() => 'agent_unavailable',
  OpenCodeApiException() => 'agent_unavailable',
  StateError() => 'invalid_state',
  _ => 'internal_error',
};

String _currentTimeLabel() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}

class _RemoteSocketServer {
  _RemoteSocketServer._({
    required this.httpServer,
    required this.bridge,
    required this.allowedOriginHosts,
    required this.lanAddresses,
    required this.onLocalDevShutdown,
    required this.secure,
  }) {
    httpServer.listen(_handleRequest);
  }

  final HttpServer httpServer;
  final AgentBridge bridge;
  Set<String> allowedOriginHosts;
  List<String> lanAddresses;
  final Future<void> Function()? onLocalDevShutdown;
  final bool secure;
  final Set<_RemoteClient> _clients = {};
  final Map<String, int> _sequences = {};
  final Map<String, int> _deviceConnectionCounts = {};
  Timer? _networkRefreshTimer;
  Timer? _heartbeatTimer;
  int _topologyRevision = 0;

  Iterable<_RemoteClient> get readyClients sync* {
    final latestByDevice = <String, _RemoteClient>{};
    for (final client in _clients.where((client) => client.isReady)) {
      final deviceId = client.pairedDeviceId;
      final key = deviceId == null ? 'socket:${client.id}' : 'device:$deviceId';
      final previous = latestByDevice[key];
      if (previous == null ||
          client.connectedAt.isAfter(previous.connectedAt)) {
        latestByDevice[key] = client;
      }
    }
    yield* latestByDevice.values;
  }

  int get connectedClientCount => readyClients.length;

  void markTopologyChanged() {
    _topologyRevision++;
  }

  Map<String, Object?> topologySnapshot() {
    final now = DateTime.now().toUtc();
    final clients = readyClients.toList(growable: false);
    final relayClientsByChannel = <String, _RemoteClient>{
      for (final client in clients)
        if (client.route == 'relay' && client.routeId != null)
          client.routeId!: client,
    };
    final upstream = bridge.relayTopology;
    final upstreamNodes = (upstream?['nodes'] as List? ?? const [])
        .whereType<Map>()
        .map((node) => node.cast<String, dynamic>())
        .toList(growable: false);
    final upstreamLinks = (upstream?['links'] as List? ?? const [])
        .whereType<Map>()
        .map((link) => link.cast<String, dynamic>())
        .toList(growable: false);
    final relayNodes = upstreamNodes.where((node) => node['id'] == 'relay');
    final upstreamRelay = relayNodes.isEmpty ? null : relayNodes.first;
    final nodes = <Map<String, Object?>>[
      {
        'id': 'host',
        'role': 'host',
        'online': true,
        'protocol': secure
            ? 'wss'
            : bridge.publicHostEnabled
            ? 'ws+wss'
            : 'ws',
        'address': bridge.publicHostUrl ?? 'local:${bridge.websocketPort}',
        'heartbeatAt': now.toIso8601String(),
        'health': 'healthy',
      },
      if (bridge.relayUrl != null && bridge.relayUrl!.isNotEmpty)
        {
          ...?upstreamRelay,
          'id': 'relay',
          'role': 'relay',
          'online': bridge.relayConnected && upstreamRelay?['online'] != false,
          'protocol': _protocolLabel(bridge.relayUrl),
          'address': bridge.relayUrl,
          'connectedAt': bridge.relayConnectedAt?.toIso8601String(),
          if (upstreamRelay?['heartbeatAt'] == null &&
              bridge.relayHeartbeatAt != null)
            'heartbeatAt': bridge.relayHeartbeatAt!.toIso8601String(),
          'route': 'relay',
          'health': !bridge.relayConnected
              ? 'offline'
              : upstreamRelay?['health']?.toString() ?? 'healthy',
        },
      for (final client in clients)
        {
          'id': 'client:${client.pairedDeviceId ?? client.id}',
          'role': 'client',
          'online': true,
          'protocol': client.protocolLabel,
          'route': client.route,
          'connectedAt': client.connectedAt.toIso8601String(),
          'heartbeatAt': client.lastHeartbeatAt?.toIso8601String(),
          'rttMs': client.rttMs,
          'bytesIn': client.bytesIn,
          'bytesOut': client.bytesOut,
          'reconnects': client.reconnects,
          'health': client.healthy ? 'healthy' : 'degraded',
        },
    ];
    final links = <Map<String, Object?>>[];
    for (final client in clients.where((client) => client.route == 'direct')) {
      final clientId = 'client:${client.pairedDeviceId ?? client.id}';
      links.add({
        'id': 'host-client:${client.pairedDeviceId ?? client.id}',
        'from': 'host',
        'to': clientId,
        'online': true,
        'protocol': client.protocolLabel,
        'route': 'direct',
        'rttMs': client.rttMs,
        'bytesIn': client.bytesIn,
        'bytesOut': client.bytesOut,
        'reconnects': client.reconnects,
        'health': client.healthy ? 'healthy' : 'degraded',
      });
    }
    for (final upstreamLink in upstreamLinks) {
      final from = _mapRelayTopologyNode(
        upstreamLink['from']?.toString(),
        relayClientsByChannel,
      );
      final to = _mapRelayTopologyNode(
        upstreamLink['to']?.toString(),
        relayClientsByChannel,
      );
      if (from == null || to == null) continue;
      links.add({
        ...upstreamLink,
        'id': from == 'host' && to == 'relay'
            ? 'host-relay'
            : 'relay-client:$to',
        'from': from,
        'to': to,
        'route': 'relay',
      });
    }
    for (final client in clients.where((client) => client.route == 'relay')) {
      final clientId = 'client:${client.pairedDeviceId ?? client.id}';
      if (links.any(
        (link) => link['from'] == 'relay' && link['to'] == clientId,
      )) {
        continue;
      }
      links.add({
        'id': 'relay-client:$clientId',
        'from': 'relay',
        'to': clientId,
        'online': bridge.relayConnected,
        'protocol': client.protocolLabel,
        'route': 'relay',
        'rttMs': client.rttMs,
        'bytesIn': client.bytesIn,
        'bytesOut': client.bytesOut,
        'reconnects': client.reconnects,
        'health': bridge.relayConnected && client.healthy
            ? 'healthy'
            : 'degraded',
      });
    }
    if (bridge.relayUrl != null &&
        bridge.relayUrl!.isNotEmpty &&
        !links.any((link) => link['from'] == 'host' && link['to'] == 'relay')) {
      links.add({
        'id': 'host-relay',
        'from': 'host',
        'to': 'relay',
        'online': bridge.relayConnected,
        'protocol': _protocolLabel(bridge.relayUrl),
        'route': 'relay',
        'health': bridge.relayConnected ? 'healthy' : 'offline',
      });
    }
    return {
      'revision': _topologyRevision,
      'updatedAt': now.toIso8601String(),
      'nodes': nodes,
      'links': links,
    };
  }

  String? _mapRelayTopologyNode(
    String? upstreamId,
    Map<String, _RemoteClient> relayClientsByChannel,
  ) {
    if (upstreamId == 'relay') return 'relay';
    if (upstreamId == 'host' || upstreamId == 'host:${bridge.relayRoom}') {
      return 'host';
    }
    final room = bridge.relayRoom;
    if (upstreamId == null || room == null) return null;
    final prefix = 'client:$room:';
    if (!upstreamId.startsWith(prefix)) return null;
    final channelId = upstreamId.substring(prefix.length);
    final client = relayClientsByChannel[channelId];
    return client == null
        ? null
        : 'client:${client.pairedDeviceId ?? client.id}';
  }

  void broadcastTopology() {
    for (final client in readyClients) {
      client.sendEvent('topology.snapshot', {
        'topology': topologySnapshot(),
      }, channel: 'telemetry');
    }
  }

  Future<void> disconnectPairedDevice(String deviceId) async {
    final clients = _clients
        .where((client) => client.pairedDeviceId == deviceId)
        .toList();
    for (final client in clients) {
      await client.close();
    }
  }

  void _onClientClosed(_RemoteClient client) {
    _clients.remove(client);
    bridge._pendingPairings.removeWhere((_, value) => identical(value, client));
  }

  static Future<_RemoteSocketServer> bind({
    required int port,
    required AgentBridge bridge,
    InternetAddress? bindAddress,
    Future<void> Function()? onLocalDevShutdown,
    SecurityContext? securityContext,
  }) async {
    final address = bindAddress ?? InternetAddress.anyIPv4;
    final httpServer = securityContext == null
        ? await HttpServer.bind(address, port)
        : await HttpServer.bindSecure(address, port, securityContext);
    final server = _RemoteSocketServer._(
      httpServer: httpServer,
      bridge: bridge,
      allowedOriginHosts: {
        'localhost',
        '127.0.0.1',
        '::1',
        ...bridge.publicAllowedOrigins
            .map((origin) => Uri.tryParse(origin)?.host.toLowerCase())
            .whereType<String>(),
      },
      lanAddresses: const [],
      onLocalDevShutdown: onLocalDevShutdown,
      secure: securityContext != null,
    );
    await server._refreshNetworkAddresses();
    server._networkRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(server._refreshNetworkAddresses()),
    );
    server._heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      for (final client in server.readyClients) {
        client.sendEvent('topology.ping', {
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        }, channel: 'telemetry');
      }
      server.broadcastTopology();
    });
    return server;
  }

  Future<void> _refreshNetworkAddresses() async {
    try {
      final localHosts = <String>{'localhost', '127.0.0.1', '::1'};
      localHosts.addAll(
        bridge.publicAllowedOrigins
            .map((origin) => Uri.tryParse(origin)?.host.toLowerCase())
            .whereType<String>(),
      );
      final addresses = <String>[];
      // A loopback-only host (the recommended public WSS deployment) must not
      // advertise LAN addresses that the socket is not actually listening on.
      if (bridge.bindAddress?.isLoopback != true) {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final interface in interfaces) {
          for (final address in interface.addresses) {
            if (_isLanAddress(address)) {
              localHosts.add(address.address.toLowerCase());
              addresses.add(address.address);
            }
          }
        }
      }
      allowedOriginHosts = localHosts;
      lanAddresses = addresses.toSet().toList()..sort();
    } on SocketException {
      // A transient network enumeration failure should not stop the host.
    }
  }

  void _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/dev-config' && request.method == 'GET') {
      await _handleLocalDevConfig(request);
      return;
    }
    if (request.uri.path == '/dev-shutdown' && request.method == 'POST') {
      await _handleLocalDevShutdown(request);
      return;
    }
    if (request.uri.path.startsWith('/pairing/')) {
      await _handlePairingAdmin(request);
      return;
    }
    if (request.uri.path == '/health' && request.method == 'GET') {
      await _refreshNetworkAddresses();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'status': 'ok',
            'protocolVersion': 1,
            'connectedClients': connectedClientCount,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path == '/status' && request.method == 'GET') {
      if (request.connectionInfo?.remoteAddress.isLoopback != true) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      await _refreshNetworkAddresses();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set('Cache-Control', 'no-store')
        ..write(
          jsonEncode({
            'status': 'ok',
            'protocolVersion': 1,
            'connectedClients': connectedClientCount,
            'agents': bridge.agentStatuses,
            'openCodeVersion': bridge.openCodeVersion,
            'codexVersion': bridge.codexVersion,
            'codexHookRuntimeReady': bridge.codexHookRuntimeReady,
            'lanAddresses': lanAddresses,
            'relay': {
              'connected': bridge.relayConnected,
              'url': bridge.relayUrl,
              'room': bridge.relayRoom,
              'clientToken': bridge.relayClientToken,
            },
            'pendingPairings': bridge.pendingPairings,
            'pairedDevices': bridge.pairedDevices,
            'publicHost': {
              'enabled': bridge.publicHostEnabled,
              'url': bridge.publicHostUrl,
            },
            'topology': topologySnapshot(),
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path == '/codex-hook/approval' &&
        request.method == 'POST') {
      await bridge._handleCodexHookApproval(request);
      return;
    }
    final pathSegments = request.uri.pathSegments;
    if (pathSegments.length == 2 && pathSegments.first == 'relay-channel') {
      final remoteAddress = request.connectionInfo?.remoteAddress;
      final channelId = pathSegments.last;
      final binding = bridge._relayChannels[channelId];
      if (request.method != 'GET' ||
          remoteAddress?.isLoopback != true ||
          binding == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      attachSocket(
        socket,
        sendData: binding.sendData,
        protocolLabel: _protocolLabel(bridge.relayUrl),
        route: 'relay',
        routeId: channelId,
        onDone: () {
          bridge.unregisterRelayChannel(channelId);
          binding.onDone();
        },
      );
      return;
    }
    if (request.uri.path != '/ws' ||
        request.method != 'GET' ||
        !isHostTransportPeerAllowed(
          privateNetworkPeer: _isLanAddress(
            request.connectionInfo?.remoteAddress,
          ),
          tlsListener: secure,
          publicHostEnabled: bridge.publicHostEnabled,
        ) ||
        !_isAllowedOrigin(
          request.headers.value('origin'),
          allowedOriginHosts,
        )) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    final forwardedProtocol = request.headers
        .value('x-forwarded-proto')
        ?.split(',')
        .first
        .trim()
        .toLowerCase();
    final trustedProxy =
        request.connectionInfo?.remoteAddress.isLoopback == true;
    attachSocket(
      socket,
      protocolLabel: secure || (trustedProxy && forwardedProtocol == 'https')
          ? 'wss'
          : 'ws',
    );
  }

  void attachSocket(
    WebSocket socket, {
    void Function(String data)? sendData,
    String? protocolLabel,
    String route = 'direct',
    String? routeId,
    void Function()? onDone,
  }) {
    final client = _RemoteClient(
      socket,
      _nextSequence,
      sendData: sendData,
      protocolLabel: protocolLabel ?? (secure ? 'wss' : 'ws'),
      route: route,
      routeId: routeId,
    );
    _clients.add(client);
    markTopologyChanged();
    socket.listen(
      (data) {
        client.recordBytesIn(data);
        _receive(client, data);
      },
      onDone: () {
        _onClientClosed(client);
        onDone?.call();
        if (readyClients.isEmpty) bridge.hookBroker.fallBackPending();
        unawaited(bridge.uploads.discardPendingForClient(client.id));
        markTopologyChanged();
        broadcastTopology();
      },
      onError: (_) {
        _onClientClosed(client);
        onDone?.call();
        if (readyClients.isEmpty) bridge.hookBroker.fallBackPending();
        unawaited(bridge.uploads.discardPendingForClient(client.id));
        markTopologyChanged();
        broadcastTopology();
      },
      cancelOnError: true,
    );
  }

  Future<void> _handleLocalDevConfig(HttpRequest request) async {
    final origin = request.headers.value('origin');
    final parsedOrigin = Uri.tryParse(origin ?? '');
    final remoteAddress = request.connectionInfo?.remoteAddress;
    final isAllowedOrigin =
        origin == null ||
        (parsedOrigin != null &&
            parsedOrigin.scheme == 'http' &&
            const {
              'localhost',
              '127.0.0.1',
              '::1',
            }.contains(parsedOrigin.host.toLowerCase()) &&
            const {8888, 8911, 8912}.contains(parsedOrigin.port));
    if (!bridge.allowLocalDevConfig ||
        remoteAddress == null ||
        !remoteAddress.isLoopback ||
        !isAllowedOrigin) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set('Access-Control-Allow-Origin', origin ?? 'null')
      ..headers.set('Vary', 'Origin')
      ..headers.set('Cache-Control', 'no-store')
      ..write(
        jsonEncode({
          'port': bridge.websocketPort,
          'pairingToken': bridge.pairingToken,
          'openCodeVersion': bridge.openCodeVersion,
          'codexVersion': bridge.codexVersion,
          'codexHookRuntimeReady': bridge.codexHookRuntimeReady,
          'lanAddresses': bridge.lanAddresses,
          'relay': {
            'connected': bridge.relayConnected,
            'url': bridge.relayUrl,
            'room': bridge.relayRoom,
            'clientToken': bridge.relayClientToken,
          },
          'publicHost': {
            'enabled': bridge.publicHostEnabled,
            'url': bridge.publicHostUrl,
          },
        }),
      );
    await request.response.close();
  }

  Future<void> _handlePairingAdmin(HttpRequest request) async {
    final isLocal = request.connectionInfo?.remoteAddress.isLoopback == true;
    final isAllowedOrigin =
        request.headers.value('origin') == null ||
        request.headers.value('origin')!.startsWith('http://localhost:') ||
        request.headers.value('origin')!.startsWith('http://127.0.0.1:');
    if (!bridge.allowLocalDevConfig ||
        !isLocal ||
        !isAllowedOrigin ||
        request.headers.value('x-remoteaisync-token') != bridge.pairingToken) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/pairing/invite') {
      final invite = await bridge.createPairingInvite();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set('Cache-Control', 'no-store')
        ..write(jsonEncode(invite));
      await request.response.close();
      return;
    }
    final id = request.uri.queryParameters['id'] ?? '';
    if (request.method == 'POST' && path == '/pairing/approve') {
      final found = await bridge.resolvePairing(id, approve: true);
      request.response.statusCode = found ? HttpStatus.ok : HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': found}));
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && path == '/pairing/reject') {
      final found = await bridge.resolvePairing(id, approve: false);
      request.response.statusCode = found ? HttpStatus.ok : HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': found}));
      await request.response.close();
      return;
    }
    if (request.method == 'DELETE' && path == '/pairing/device') {
      await bridge.revokePairedDevice(id);
      request.response.statusCode = HttpStatus.ok;
      request.response.write(jsonEncode({'ok': true}));
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _handleLocalDevShutdown(HttpRequest request) async {
    final origin = request.headers.value('origin');
    final parsedOrigin = Uri.tryParse(origin ?? '');
    final remoteAddress = request.connectionInfo?.remoteAddress;
    final isLoopbackOrigin =
        origin == null ||
        (parsedOrigin != null &&
            parsedOrigin.scheme == 'http' &&
            const {
              'localhost',
              '127.0.0.1',
              '::1',
            }.contains(parsedOrigin.host.toLowerCase()));
    final authorized =
        bridge.allowLocalDevConfig &&
        remoteAddress?.isLoopback == true &&
        isLoopbackOrigin &&
        request.headers.value('x-remoteaisync-token') == bridge.pairingToken;
    if (!authorized || onLocalDevShutdown == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.accepted
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'status': 'stopping'}));
    await request.response.close();
    unawaited(onLocalDevShutdown!());
  }

  void _receive(_RemoteClient client, Object? raw) async {
    if (raw is! String || raw.length > 1024 * 1024) {
      client.sendEvent('command.error', {
        'message': '仅支持不超过 1 MiB 的 JSON 控制消息。',
      });
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Expected object.');
      await bridge._handleMessage(client, decoded.cast<String, dynamic>());
    } on FormatException {
      client.sendEvent('command.error', {'message': 'JSON 消息格式无效。'});
    } catch (error) {
      client.sendEvent('command.error', {'message': _safeError(error)});
    }
  }

  int _nextSequence(String sessionId) {
    final next = (_sequences[sessionId] ?? 0) + 1;
    _sequences[sessionId] = next;
    return next;
  }

  Future<void> close() async {
    _networkRefreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    for (final client in _clients.toList()) {
      await client.close();
    }
    await httpServer.close(force: true);
  }
}

class _RelayChannelBinding {
  const _RelayChannelBinding({required this.sendData, required this.onDone});

  final void Function(String data) sendData;
  final void Function() onDone;
}

class _RemoteClient {
  _RemoteClient(
    this.socket,
    this._nextSequence, {
    this.sendData,
    required this.protocolLabel,
    required this.route,
    this.routeId,
  });

  final WebSocket socket;
  final void Function(String data)? sendData;
  final String protocolLabel;
  final String route;
  final String? routeId;
  final String id = _newId();
  final int Function(String sessionId) _nextSequence;
  final DateTime connectedAt = DateTime.now().toUtc();
  DateTime? lastHeartbeatAt;
  int? rttMs;
  int bytesIn = 0;
  int bytesOut = 0;
  int reconnects = 0;
  int protocolVersion = 1;
  bool healthy = true;
  bool isReady = false;
  String? pairedDeviceId;
  String? selectedSessionId;
  int selectionGeneration = 0;
  String? pairingDeviceId;
  String? pairingDeviceToken;
  String? pairingDeviceName;

  void recordBytesIn(Object? data) {
    if (data is String) bytesIn += utf8.encode(data).length;
    if (data is List<int>) bytesIn += data.length;
  }

  void recordHeartbeat(String? sentAt) {
    final sent = DateTime.tryParse(sentAt ?? '');
    final now = DateTime.now().toUtc();
    lastHeartbeatAt = now;
    rttMs = sent == null ? null : now.difference(sent).inMilliseconds;
    healthy = rttMs == null || rttMs! < 5000;
  }

  void sendEvent(
    String kind,
    Map<String, Object?> payload, {
    String sessionId = '',
    String channel = 'control',
  }) {
    if (socket.readyState != WebSocket.open) return;
    final sequence = _nextSequence(sessionId);
    final now = DateTime.now().toUtc();
    final data = jsonEncode({
      'schemaVersion': protocolVersion >= 2 ? 2 : 1,
      'eventId': _newId(),
      'messageId': _newId(),
      'deviceId': 'remoteaisync-host',
      'sessionId': sessionId,
      'seq': sequence,
      if (protocolVersion >= 2) 'sequence': sequence,
      'createdAt': now.toIso8601String(),
      if (protocolVersion >= 2) 'timestamp': now.toIso8601String(),
      if (protocolVersion >= 2) 'channel': channel,
      'kind': kind,
      'payload': payload,
    });
    final sender = sendData;
    bytesOut += utf8.encode(data).length;
    if (sender == null) {
      socket.add(data);
    } else {
      sender(data);
    }
  }

  Future<void> close() async {
    if (socket.readyState == WebSocket.open) await socket.close();
  }
}

String _protocolLabel(String? value) {
  final scheme = Uri.tryParse(value ?? '')?.scheme.toLowerCase();
  return scheme == 'wss' ? 'wss' : 'ws';
}

Map<String, Object?> _messageToJson(AgentMessage message) => {
  'id': message.id,
  'author': message.author.name,
  'text': message.text,
  'time': message.time,
  if (message.groupId != null) 'groupId': message.groupId,
};

Map<String, Object?> _formToJson(AgentForm form) => {
  'id': form.id,
  'sessionID': form.sessionId,
  'title': form.title,
  'fields': form.fields
      .map(
        (field) => {
          'key': field.key,
          'type': field.type.name,
          'title': field.title,
          'description': field.description,
          'required': field.required,
          'format': field.format,
          'placeholder': field.placeholder,
          'url': field.url,
          'minimum': field.minimum,
          'maximum': field.maximum,
          'minLength': field.minLength,
          'maxLength': field.maxLength,
          'minItems': field.minItems,
          'maxItems': field.maxItems,
          'default': field.defaultValue,
          'options': field.options
              .map(
                (option) => {
                  'value': option.value,
                  'label': option.label,
                  'description': option.description,
                },
              )
              .toList(),
          'when': field.conditions
              .map(
                (condition) => {
                  'key': condition.key,
                  'op': condition.operator,
                  'value': condition.value,
                },
              )
              .toList(),
          'custom': field.custom,
        },
      )
      .toList(),
};

Map<String, Object?> _permissionToJson(AgentPermission permission) => {
  'id': permission.id,
  'sessionID': permission.sessionId,
  'action': permission.action,
  'resources': permission.resources,
  'message': permission.message,
  'toolId': permission.toolId,
};

String _replyWithAttachmentPaths(
  String text,
  List<StagedAttachment> attachments,
) {
  if (attachments.isEmpty) return text;
  return [
    if (text.isNotEmpty) text,
    '附件文件（已保存到当前工作区）：',
    for (final attachment in attachments)
      '- ${p.basename(attachment.path)}：${attachment.path}',
  ].join('\n');
}

String _safeError(Object error) {
  if (error is OpenCodeApiException) return error.message;
  if (error is CodexApiException) return error.message;
  if (error is UploadException) return error.message;
  return '无法完成操作，请检查本机 Agent 服务。';
}

bool _isAllowedOrigin(String? origin, Set<String> localHosts) {
  if (origin == null) return true;
  final uri = Uri.tryParse(origin);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return localHosts.contains(uri.host.toLowerCase());
}

bool _isLanAddress(InternetAddress? address) {
  if (address == null) return false;
  if (address.isLoopback) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  if (address.type == InternetAddressType.IPv6) {
    return (bytes[0] & 0xfe) == 0xfc;
  }
  return false;
}

bool _constantTimeEquals(String left, String right) {
  var difference = left.length ^ right.length;
  final length = max(left.length, right.length);
  for (var i = 0; i < length; i++) {
    final a = i < left.length ? left.codeUnitAt(i) : 0;
    final b = i < right.length ? right.codeUnitAt(i) : 0;
    difference |= a ^ b;
  }
  return difference == 0;
}

bool _sameProjectDirectory(String left, String right) {
  if (left.isEmpty) return false;
  final normalizedLeft = p.normalize(p.absolute(left)).replaceAll('\\', '/');
  final normalizedRight = p.normalize(p.absolute(right)).replaceAll('\\', '/');
  return Platform.isWindows
      ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
      : normalizedLeft == normalizedRight;
}

String _randomSecret() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String _openCodeFailureDetail(Object error) {
  if (error is OpenCodeApiException) {
    if (error.message.contains('后台服务未运行')) {
      return '未发现 OpenCode 本地服务，启动后主机会自动重试。';
    }
    return 'OpenCode 本地服务连接失败，将自动重试。原因：${error.message}';
  }
  return 'OpenCode 本地服务发现失败，主机会自动重试。';
}

String _newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

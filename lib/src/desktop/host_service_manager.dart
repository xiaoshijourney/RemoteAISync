import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import '../domain/transport_protocol.dart';

enum HostRuntimeMode { host, relay }

class HostServiceSnapshot {
  const HostServiceSnapshot({
    this.reachable = false,
    this.mode = HostRuntimeMode.host,
    this.healthStatus,
    this.connectedClients,
    this.relayRooms,
    this.relayHosts,
    this.relayClients,
    this.pairingToken,
    this.relayRoom,
    this.relayClientToken,
    this.relayConnected = false,
    this.pairingInvite,
    this.pairingInviteExpiresAt,
    this.pendingPairings = const [],
    this.pairedDevices = const [],
    this.openCodeVersion,
    this.codexVersion,
    this.agentStatuses = const {},
    this.topology = TopologySnapshot.empty,
    this.codexHookRuntimeReady = false,
    this.lanAddresses = const [],
    this.publicHostUrl,
    this.publicHostEnabled = false,
    this.lastChecked,
    this.error,
  });

  final bool reachable;
  final HostRuntimeMode mode;
  final String? healthStatus;
  final int? connectedClients;
  final int? relayRooms;
  final int? relayHosts;
  final int? relayClients;
  final String? pairingToken;
  final String? relayRoom;
  final String? relayClientToken;
  final bool relayConnected;
  final String? pairingInvite;
  final String? pairingInviteExpiresAt;
  final List<Map<String, String>> pendingPairings;
  final List<Map<String, String>> pairedDevices;
  final String? openCodeVersion;
  final String? codexVersion;
  final Map<String, AgentRuntimeStatus> agentStatuses;
  final TopologySnapshot topology;
  final bool codexHookRuntimeReady;
  final List<String> lanAddresses;
  final String? publicHostUrl;
  final bool publicHostEnabled;
  final DateTime? lastChecked;
  final String? error;

  HostServiceSnapshot copyWith({
    bool? reachable,
    HostRuntimeMode? mode,
    String? healthStatus,
    int? connectedClients,
    int? relayRooms,
    int? relayHosts,
    int? relayClients,
    String? pairingToken,
    String? relayRoom,
    String? relayClientToken,
    bool? relayConnected,
    String? pairingInvite,
    String? pairingInviteExpiresAt,
    List<Map<String, String>>? pendingPairings,
    List<Map<String, String>>? pairedDevices,
    String? openCodeVersion,
    String? codexVersion,
    Map<String, AgentRuntimeStatus>? agentStatuses,
    TopologySnapshot? topology,
    bool? codexHookRuntimeReady,
    List<String>? lanAddresses,
    String? publicHostUrl,
    bool? publicHostEnabled,
    DateTime? lastChecked,
    String? error,
  }) {
    return HostServiceSnapshot(
      reachable: reachable ?? this.reachable,
      mode: mode ?? this.mode,
      healthStatus: healthStatus ?? this.healthStatus,
      connectedClients: connectedClients ?? this.connectedClients,
      relayRooms: relayRooms ?? this.relayRooms,
      relayHosts: relayHosts ?? this.relayHosts,
      relayClients: relayClients ?? this.relayClients,
      pairingToken: pairingToken ?? this.pairingToken,
      relayRoom: relayRoom ?? this.relayRoom,
      relayClientToken: relayClientToken ?? this.relayClientToken,
      relayConnected: relayConnected ?? this.relayConnected,
      pairingInvite: pairingInvite ?? this.pairingInvite,
      pairingInviteExpiresAt:
          pairingInviteExpiresAt ?? this.pairingInviteExpiresAt,
      pendingPairings: pendingPairings ?? this.pendingPairings,
      pairedDevices: pairedDevices ?? this.pairedDevices,
      openCodeVersion: openCodeVersion ?? this.openCodeVersion,
      codexVersion: codexVersion ?? this.codexVersion,
      agentStatuses: agentStatuses ?? this.agentStatuses,
      topology: topology ?? this.topology,
      codexHookRuntimeReady:
          codexHookRuntimeReady ?? this.codexHookRuntimeReady,
      lanAddresses: lanAddresses ?? this.lanAddresses,
      publicHostUrl: publicHostUrl ?? this.publicHostUrl,
      publicHostEnabled: publicHostEnabled ?? this.publicHostEnabled,
      lastChecked: lastChecked ?? this.lastChecked,
      error: error,
    );
  }
}

class HostServiceManager extends ChangeNotifier {
  static String newRelayRoomId() => base64Url
      .encode(List<int>.generate(18, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '')
      .replaceAll('+', '-')
      .replaceAll('/', '_');

  HostServiceManager({
    this.port = 8910,
    this.relayPort = 8920,
    this.mode = HostRuntimeMode.host,
    bool monitor = true,
    http.Client? client,
    HostServiceSnapshot? initialSnapshot,
  }) : _httpClient = client ?? http.Client(),
       _snapshot = initialSnapshot ?? const HostServiceSnapshot() {
    _restoreRelayHostCredentials();
    if (monitor) {
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(refresh());
      });
      unawaited(refresh());
    }
  }

  final int port;
  int relayPort;
  HostRuntimeMode mode;
  String relayUrl = '';
  String relayRoom = '';
  String relayClientToken = '';
  String relayHostToken = '';
  String publicHostUrl = '';
  String publicAllowedOrigin = '';
  bool publicHostEnabled = false;
  final http.Client _httpClient;
  final List<String> _logs = <String>[];
  Timer? _timer;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  HostServiceSnapshot _snapshot;
  bool _busy = false;
  ServiceState _serviceState = ServiceState.stopped;
  bool _refreshing = false;
  bool _disposed = false;

  HostServiceSnapshot get snapshot => _snapshot;
  List<String> get logs => List.unmodifiable(_logs);
  bool get busy => _busy;
  ServiceState get serviceState => _serviceState;
  bool get ownsProcess => _process != null;
  String get endpoint => 'http://127.0.0.1:$port';
  int get activePort => mode == HostRuntimeMode.relay ? relayPort : port;
  String get activeEndpoint => 'http://127.0.0.1:$activePort';

  void updateRuntimeConfig({
    required HostRuntimeMode mode,
    required int relayPort,
    required String relayUrl,
    required String relayRoom,
    required String relayClientToken,
    required String relayHostToken,
    String publicHostUrl = '',
    String publicAllowedOrigin = '',
    bool publicHostEnabled = false,
  }) {
    this.mode = mode;
    this.relayPort = relayPort;
    this.relayUrl = relayUrl.trim();
    if (relayRoom.trim().isNotEmpty) this.relayRoom = relayRoom.trim();
    if (relayClientToken.trim().isNotEmpty) {
      this.relayClientToken = relayClientToken.trim();
    }
    if (relayHostToken.trim().isNotEmpty) {
      this.relayHostToken = relayHostToken.trim();
    }
    this.publicHostUrl = _normalizePublicHostUrl(publicHostUrl.trim());
    this.publicAllowedOrigin = publicAllowedOrigin.trim();
    this.publicHostEnabled = publicHostEnabled;
  }

  Future<void> selectMode(HostRuntimeMode nextMode) async {
    if (mode == nextMode) return;
    if (_process != null) await stop();
    mode = nextMode;
    _snapshot = HostServiceSnapshot(
      mode: nextMode,
      lanAddresses: _snapshot.lanAddresses,
      error: '已切换模式，请启动对应服务。',
    );
    notifyListeners();
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    try {
      final health = await _httpClient
          .get(Uri.parse('$activeEndpoint/health'))
          .timeout(const Duration(milliseconds: 900));
      if (health.statusCode != HttpStatus.ok) {
        _setOffline('主机返回 HTTP ${health.statusCode}');
        return;
      }
      if (_disposed) return;

      Map<String, dynamic> healthData = const <String, dynamic>{};
      int? connectedClients;
      try {
        final decodedHealth = jsonDecode(health.body);
        if (decodedHealth is Map) {
          healthData = decodedHealth.cast<String, dynamic>();
          final value = healthData['connectedClients'];
          if (value is num && value >= 0) {
            connectedClients = value.toInt();
          }
        }
      } on FormatException {
        // Older hosts expose health without a client count.
      }

      if (mode == HostRuntimeMode.relay) {
        var relayStatusData = healthData;
        try {
          final response = await _httpClient
              .get(Uri.parse('$activeEndpoint/status'))
              .timeout(const Duration(milliseconds: 900));
          if (response.statusCode == HttpStatus.ok) {
            final decoded = jsonDecode(response.body);
            if (decoded is Map) {
              relayStatusData = decoded.cast<String, dynamic>();
            }
          }
        } catch (_) {
          // Older relay builds may expose aggregate health only.
        }
        _serviceState = ServiceState.running;
        _snapshot = HostServiceSnapshot(
          reachable: true,
          mode: mode,
          healthStatus: healthData['status']?.toString() ?? 'ok',
          relayRooms: (healthData['rooms'] as num?)?.toInt(),
          relayHosts: (healthData['hosts'] as num?)?.toInt(),
          relayClients: (healthData['clients'] as num?)?.toInt(),
          topology: _decodeTopology(relayStatusData['topology']),
          lastChecked: DateTime.now(),
        );
        if (!_disposed) notifyListeners();
        return;
      }

      Map<String, dynamic> statusData = healthData;
      try {
        final response = await _httpClient
            .get(Uri.parse('$activeEndpoint/status'))
            .timeout(const Duration(milliseconds: 900));
        if (response.statusCode == HttpStatus.ok) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            statusData = decoded.cast<String, dynamic>();
            final value = statusData['connectedClients'];
            if (value is num && value >= 0) connectedClients = value.toInt();
          }
        }
      } catch (_) {
        // Older hosts continue to expose only health and development config.
      }

      Map<String, dynamic> config = const <String, dynamic>{};
      try {
        final response = await _httpClient
            .get(
              Uri.parse('$activeEndpoint/dev-config'),
              headers: const <String, String>{
                'origin': 'http://localhost:8888',
              },
            )
            .timeout(const Duration(milliseconds: 900));
        if (response.statusCode == HttpStatus.ok) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            config = decoded.cast<String, dynamic>();
          }
        }
      } catch (_) {
        // A host started without --persist-token can still report healthy.
      }
      final relayData = config['relay'] is Map
          ? (config['relay'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final publicHostData =
          (statusData['publicHost'] ?? config['publicHost']) is Map
          ? ((statusData['publicHost'] ?? config['publicHost']) as Map)
                .cast<String, dynamic>()
          : const <String, dynamic>{};
      if (_disposed) return;

      final configuredLanAddresses =
          ((statusData['lanAddresses'] ?? config['lanAddresses']) as List? ??
                  const [])
              .map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toList(growable: false);
      final lanAddresses = configuredLanAddresses.isNotEmpty
          ? configuredLanAddresses
          : await _discoverLanAddresses();
      final agents = _decodeAgentStatuses(statusData['agents']);
      final openCodeVersion =
          agents['opencode']?.version ??
          statusData['openCodeVersion']?.toString() ??
          config['openCodeVersion']?.toString();
      final codexVersion =
          agents['codex']?.version ??
          statusData['codexVersion']?.toString() ??
          config['codexVersion']?.toString();
      final savedInvite = _snapshot.pairingInvite;
      final savedInviteExpiresAt = _snapshot.pairingInviteExpiresAt;
      final inviteStillValid =
          savedInvite != null &&
          savedInvite.isNotEmpty &&
          savedInviteExpiresAt != null &&
          DateTime.tryParse(savedInviteExpiresAt)?.isAfter(DateTime.now()) ==
              true;

      _snapshot = HostServiceSnapshot(
        reachable: true,
        mode: mode,
        healthStatus: statusData['status']?.toString() ?? 'ok',
        connectedClients: connectedClients,
        relayRooms: (healthData['rooms'] as num?)?.toInt(),
        relayHosts: (healthData['hosts'] as num?)?.toInt(),
        relayClients: (healthData['clients'] as num?)?.toInt(),
        pairingToken: config['pairingToken']?.toString(),
        relayRoom: relayData['room']?.toString(),
        relayClientToken: relayData['clientToken']?.toString(),
        relayConnected: relayData['connected'] == true,
        publicHostUrl:
            publicHostData['url']?.toString() ??
            (publicHostUrl.isNotEmpty ? publicHostUrl : null),
        publicHostEnabled:
            publicHostData['enabled'] == true ||
            (publicHostEnabled && publicHostUrl.isNotEmpty),
        pairingInvite: inviteStillValid ? savedInvite : null,
        pairingInviteExpiresAt: inviteStillValid ? savedInviteExpiresAt : null,
        pendingPairings: _decodeNamedEntries(statusData['pendingPairings']),
        pairedDevices: _decodeNamedEntries(statusData['pairedDevices']),
        openCodeVersion: openCodeVersion,
        codexVersion: codexVersion,
        agentStatuses: agents,
        topology: _decodeTopology(
          statusData['topology'] ?? healthData['topology'],
        ),
        codexHookRuntimeReady:
            statusData['codexHookRuntimeReady'] == true ||
            config['codexHookRuntimeReady'] == true,
        lanAddresses: lanAddresses,
        lastChecked: DateTime.now(),
      );
      _serviceState = ServiceState.running;
      if (!_disposed) notifyListeners();
    } catch (error) {
      if (!_disposed) {
        _setOffline(_process == null ? '等待主机服务启动' : '正在启动主机服务');
      }
    } finally {
      _refreshing = false;
    }
  }

  Map<String, AgentRuntimeStatus> _decodeAgentStatuses(Object? value) {
    if (value is! List) return const {};
    return {
      for (final item in value.whereType<Map>())
        if (item['id']?.toString().isNotEmpty == true)
          item['id'].toString(): AgentRuntimeStatus.fromJson(item),
    };
  }

  TopologySnapshot _decodeTopology(Object? value) {
    return value is Map
        ? TopologySnapshot.fromJson(value)
        : TopologySnapshot.empty;
  }

  List<Map<String, String>> _decodeNamedEntries(Object? value) => [
    for (final item in value is List ? value.whereType<Map>() : const <Map>[])
      {
        'id': item['id']?.toString() ?? '',
        'name': item['name']?.toString() ?? '手机设备',
      },
  ];

  Future<void> createPairingInvite() async {
    final token = snapshot.pairingToken;
    if (token == null || token.isEmpty) {
      throw StateError('主机服务尚未开放本机配对管理。');
    }
    final response = await _httpClient.post(
      Uri.parse('$endpoint/pairing/invite'),
      headers: {'x-remoteaisync-token': token},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('生成手机配对邀请失败（HTTP ${response.statusCode}）。');
    }
    final data = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    _snapshot = _snapshot.copyWith(
      pairingInvite: data['invite']?.toString(),
      pairingInviteExpiresAt: data['expiresAt']?.toString(),
    );
    notifyListeners();
  }

  Future<void> resolvePairing(String id, {required bool approve}) async {
    final token = snapshot.pairingToken;
    if (token == null) throw StateError('主机服务未连接。');
    final action = approve ? 'approve' : 'reject';
    final response = await _httpClient.post(
      Uri.parse('$endpoint/pairing/$action?id=${Uri.encodeQueryComponent(id)}'),
      headers: {'x-remoteaisync-token': token},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('处理配对请求失败（HTTP ${response.statusCode}）。');
    }
    await refresh();
  }

  Future<void> revokeDevice(String id) async {
    final token = snapshot.pairingToken;
    if (token == null) throw StateError('主机服务未连接。');
    final response = await _httpClient.delete(
      Uri.parse('$endpoint/pairing/device?id=${Uri.encodeQueryComponent(id)}'),
      headers: {'x-remoteaisync-token': token},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('撤销设备失败（HTTP ${response.statusCode}）。');
    }
    await refresh();
  }

  Future<List<String>> _discoverLanAddresses() async {
    try {
      final preferred = <String>[];
      final other = <String>[];
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        final isPreferred =
            name.contains('wlan') ||
            name.contains('wi-fi') ||
            name.contains('wifi') ||
            name.contains('wireless') ||
            name.contains('ethernet') ||
            name.contains('以太网') ||
            name.contains('无线');
        for (final address in interface.addresses) {
          if (!_isPrivateIpv4(address)) continue;
          (isPreferred ? preferred : other).add(address.address);
        }
      }
      return {...preferred, ...other}.toList(growable: false);
    } on SocketException {
      return const [];
    }
  }

  bool _isPrivateIpv4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
      return false;
    }
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }

  Future<void> start() async {
    if (_process != null || snapshot.reachable) {
      await refresh();
      return;
    }
    _busy = true;
    _serviceState = ServiceState.starting;
    notifyListeners();
    try {
      final project = _findProjectDirectory() ?? Directory.current.absolute;
      final script = File(
        '${project.path}${Platform.pathSeparator}host${Platform.pathSeparator}'
        'bin${Platform.pathSeparator}remotaisync_host.dart',
      );
      final runtime = _findBundledRuntime(project);
      if (runtime == null && !script.existsSync()) {
        throw StateError('找不到服务端运行时。请安装发行包或从项目根目录启动开发版 GUI。');
      }
      _validateRuntimeConfig();
      if (mode == HostRuntimeMode.host &&
          relayUrl.isNotEmpty &&
          (relayRoom.isEmpty || relayClientToken.isEmpty)) {
        await _registerHostWithRelay(project);
      }
      final arguments = <String>[
        if (runtime == null) ...['run', script.path],
        if (mode == HostRuntimeMode.relay) ...[
          '--mode',
          'relay',
          '--bind-address',
          '0.0.0.0',
          '--port',
          '$relayPort',
          '--relay-token',
          relayClientToken,
          '--relay-host-token',
          relayHostToken.isEmpty ? _createLocalSecret() : relayHostToken,
        ] else ...[
          '--project',
          project.path,
          '--port',
          '$port',
          '--persist-token',
          if (publicHostEnabled) ...[
            '--allow-public-host',
            '--public-host-url',
            publicHostUrl,
            if (publicAllowedOrigin.isNotEmpty) ...[
              '--allowed-origin',
              publicAllowedOrigin,
            ],
          ],
          if (relayUrl.isNotEmpty) ...[
            '--relay-url',
            relayUrl,
            '--relay-room',
            relayRoom,
            '--relay-host-token',
            relayHostToken,
          ],
        ],
      ];
      _addLog(
        '启动${mode == HostRuntimeMode.relay ? '中继服务器' : '电脑主机'}：${runtime?.path ?? script.path}',
      );
      final process = await Process.start(
        runtime?.path ?? 'dart',
        arguments,
        workingDirectory: project.path,
        runInShell: true,
      );
      _process = process;
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_addLog);
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _addLog('错误：$line'));
      unawaited(_watchProcess(process));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await refresh();
    } catch (error) {
      _addLog('启动失败：$error');
      _serviceState = ServiceState.failed;
      _setOffline('启动失败，请查看下方日志');
    } finally {
      _busy = false;
      if (_serviceState == ServiceState.starting && snapshot.reachable) {
        _serviceState = ServiceState.running;
      }
      notifyListeners();
      unawaited(refresh());
    }
  }

  Future<void> stop() async {
    final process = _process;
    if (mode == HostRuntimeMode.relay && process == null) {
      _addLog('中继由外部进程启动，请在该进程所在终端停止。');
      return;
    }
    final token = _snapshot.pairingToken;
    if (mode == HostRuntimeMode.host && (token == null || token.isEmpty)) {
      _addLog('此服务未开放本机开发控制接口，无法通过 GUI 停止。');
      return;
    }
    _busy = true;
    _serviceState = ServiceState.stopping;
    notifyListeners();
    _addLog('正在停止主机服务。');
    try {
      if (mode == HostRuntimeMode.relay) {
        process!.kill();
        await process.exitCode.timeout(const Duration(seconds: 2));
      } else {
        final response = await _httpClient
            .post(
              Uri.parse('$activeEndpoint/dev-shutdown'),
              headers: <String, String>{'x-remoteaisync-token': token!},
            )
            .timeout(const Duration(seconds: 2));
        if (response.statusCode != HttpStatus.accepted) {
          _addLog('停止请求被拒绝（HTTP ${response.statusCode}）。');
          if (process != null) process.kill();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (identical(_process, process)) _process = null;
      await refresh();
      _serviceState = snapshot.reachable
          ? ServiceState.failed
          : ServiceState.stopped;
    } catch (error) {
      _addLog('停止请求失败：$error');
      _serviceState = ServiceState.failed;
      if (process != null) process.kill();
    } finally {
      _busy = false;
      if (_serviceState == ServiceState.stopping) {
        _serviceState = ServiceState.stopped;
      }
      notifyListeners();
      unawaited(refresh());
    }
  }

  Future<void> restart() async {
    if (_process != null) await stop();
    await start();
  }

  Future<void> configureAndStart({
    required HostRuntimeMode mode,
    required int relayPort,
    required String relayUrl,
    required String relayRoom,
    required String relayClientToken,
    required String relayHostToken,
    String publicHostUrl = '',
    String publicAllowedOrigin = '',
    bool publicHostEnabled = false,
  }) async {
    if (_process != null) {
      await stop();
    } else if (_snapshot.reachable) {
      throw StateError('当前服务由外部进程启动，请先在原窗口停止它。');
    }
    updateRuntimeConfig(
      mode: mode,
      relayPort: relayPort,
      relayUrl: relayUrl,
      relayRoom: relayRoom,
      relayClientToken: relayClientToken,
      relayHostToken: relayHostToken,
      publicHostUrl: publicHostUrl,
      publicAllowedOrigin: publicAllowedOrigin,
      publicHostEnabled: publicHostEnabled,
    );
    await start();
  }

  void _validateRuntimeConfig() {
    if (mode == HostRuntimeMode.relay) {
      if (relayClientToken.length < 32) {
        throw StateError('中继服务器需要至少 32 位的中继管理密钥。');
      }
      return;
    }
    if (relayUrl.isNotEmpty) {
      final uri = Uri.tryParse(relayUrl);
      if (uri == null ||
          !{'ws', 'wss'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw StateError('中继地址必须是 ws:// 或 wss:// 地址。');
      }
      if (uri.scheme == 'ws' && !_isPrivateOrLoopbackHost(uri.host)) {
        throw StateError('公网中继必须使用 wss:// 加密连接。');
      }
      if (relayHostToken.length < 32) {
        throw StateError('请输入中继管理员签发的一次性主机注册码。');
      }
    }
    if (publicHostEnabled) {
      final publicUri = Uri.tryParse(publicHostUrl);
      if (publicUri == null ||
          publicUri.scheme != 'wss' ||
          publicUri.host.isEmpty ||
          (publicUri.path.isNotEmpty && publicUri.path != '/ws')) {
        throw StateError('公网主机地址必须是 wss://host.example.com/ws。');
      }
      if (publicAllowedOrigin.isNotEmpty) {
        final origin = Uri.tryParse(publicAllowedOrigin);
        if (origin == null ||
            !{'http', 'https'}.contains(origin.scheme) ||
            origin.host.isEmpty) {
          throw StateError('浏览器 Origin 必须是 http(s):// 地址。');
        }
      }
    }
  }

  bool _isPrivateOrLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    if (const {'localhost', '127.0.0.1', '::1'}.contains(normalized)) {
      return true;
    }
    final octets = normalized.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((part) => part == null)) return false;
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1]! >= 16 && octets[1]! <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  String _createLocalSecret() => base64Url
      .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Future<Map<String, String>> issueRelayRegistrationCode() async {
    if (mode != HostRuntimeMode.relay) {
      throw StateError('请先切换到中继服务器模式。');
    }
    final response = await _httpClient
        .post(
          Uri.parse('http://127.0.0.1:$relayPort/admin/registration-code'),
          headers: {'x-remoteaisync-admin-token': relayClientToken},
        )
        .timeout(const Duration(seconds: 3));
    if (response.statusCode != HttpStatus.created) {
      throw StateError('创建主机注册码失败（HTTP ${response.statusCode}）。');
    }
    final decoded = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    return {
      'id': decoded['id']?.toString() ?? '',
      'code': decoded['code']?.toString() ?? '',
      'expiresAt': decoded['expiresAt']?.toString() ?? '',
    };
  }

  Future<void> revokeRelayRegistrationCode(String id) async {
    final response = await _httpClient
        .delete(
          Uri.parse(
            'http://127.0.0.1:$relayPort/admin/registration-code?id=${Uri.encodeQueryComponent(id)}',
          ),
          headers: {'x-remoteaisync-admin-token': relayClientToken},
        )
        .timeout(const Duration(seconds: 3));
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('撤销主机注册码失败（HTTP ${response.statusCode}）。');
    }
  }

  Future<void> _registerHostWithRelay(Directory project) async {
    final code = relayHostToken;
    final relayUri = Uri.parse(relayUrl);
    final registrationUri = relayUri.replace(
      scheme: relayUri.scheme == 'wss' ? 'https' : 'http',
      path: '/register-host',
      query: null,
    );
    final response = await _httpClient
        .post(
          registrationUri,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'registrationCode': code}),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != HttpStatus.created) {
      final detail = response.body.isEmpty ? '' : ': ${response.body}';
      throw StateError('主机向中继注册失败（HTTP ${response.statusCode}）$detail');
    }
    final data = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    relayRoom = data['room']?.toString() ?? '';
    relayHostToken = data['hostToken']?.toString() ?? '';
    relayClientToken = data['clientToken']?.toString() ?? '';
    if (relayRoom.isEmpty ||
        relayHostToken.length < 32 ||
        relayClientToken.length < 32) {
      throw StateError('中继返回的主机凭据不完整。');
    }
    final file = File(
      '${project.path}${Platform.pathSeparator}.remoteaisync'
      '${Platform.pathSeparator}relay-host-credentials.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'url': relayUrl,
        'room': relayRoom,
        'hostToken': relayHostToken,
        'clientToken': relayClientToken,
      }),
      flush: true,
    );
    _addLog('中继已分配专属房间与设备凭据。');
  }

  void _restoreRelayHostCredentials() {
    final projectPath = _findProjectDirectory()?.path ?? Directory.current.path;
    final file = File(
      '$projectPath${Platform.pathSeparator}.remoteaisync'
      '${Platform.pathSeparator}relay-host-credentials.json',
    );
    if (!file.existsSync()) return;
    try {
      final data = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, dynamic>();
      relayUrl = data['url']?.toString() ?? '';
      relayRoom = data['room']?.toString() ?? '';
      relayHostToken = data['hostToken']?.toString() ?? '';
      relayClientToken = data['clientToken']?.toString() ?? '';
    } catch (_) {
      // The user can register this host again if its local credential file is damaged.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _httpClient.close();
    super.dispose();
  }

  Future<void> _watchProcess(Process process) async {
    final exitCode = await process.exitCode;
    if (identical(_process, process)) {
      _process = null;
      _addLog('主机进程已退出（代码 $exitCode）。');
      await refresh();
      notifyListeners();
    }
  }

  Directory? _findProjectDirectory() {
    final candidates = <Directory>[
      Directory.current,
      Directory(File(Platform.resolvedExecutable).parent.path),
      Directory('${Directory.current.path}${Platform.pathSeparator}..'),
    ];
    for (final candidate in candidates) {
      final root = candidate.absolute;
      final script = File(
        '${root.path}${Platform.pathSeparator}host${Platform.pathSeparator}'
        'bin${Platform.pathSeparator}remotaisync_host.dart',
      );
      if (script.existsSync()) return root;
    }
    return null;
  }

  File? _findBundledRuntime(Directory project) {
    if (!Platform.isWindows) return null;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      File(
        '$executableDirectory${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}remotaisync_host.exe',
      ),
      File('$executableDirectory${Platform.pathSeparator}remotaisync_host.exe'),
      File(
        '${project.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}remotaisync_host.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  void _setOffline(String message) {
    if (_serviceState != ServiceState.starting &&
        _serviceState != ServiceState.stopping) {
      _serviceState = ServiceState.stopped;
    }
    _snapshot = HostServiceSnapshot(
      reachable: false,
      mode: mode,
      lastChecked: DateTime.now(),
      error: message,
    );
    notifyListeners();
  }

  void _addLog(String message) {
    final stamp = DateTime.now().toLocal().toString().substring(11, 19);
    _logs.insert(0, '[$stamp] $message');
    if (_logs.length > 80) _logs.removeLast();
    notifyListeners();
  }
}

String _normalizePublicHostUrl(String value) {
  if (value.isEmpty) return '';
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) return value;
  if (uri.path.isEmpty || uri.path == '/') {
    return uri.replace(path: '/ws').toString();
  }
  return value;
}

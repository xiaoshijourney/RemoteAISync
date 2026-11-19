import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../application/demo_controller.dart';
import '../../domain/models.dart';
import '../../domain/pairing_profile.dart';
import '../../domain/transport_protocol.dart';
import '../components/glass_surface.dart';
import '../shad_theme.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({required this.controller, super.key});

  final DemoController controller;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  static const _secureStorage = FlutterSecureStorage();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8910');
  final _tokenController = TextEditingController();
  final _directUrlController = TextEditingController();
  final _relayUrlController = TextEditingController();
  final _relayRoomController = TextEditingController();
  final _relayTokenController = TextEditingController();
  final _formKey = GlobalKey<ShadFormState>();
  String? _validationMessage;
  bool _relayMode = false;
  bool _forceRelay = false;
  bool _showPairingInvite = false;
  List<String> _lanAddresses = const [];
  bool _hasSavedDeviceIdentity = false;

  @override
  void initState() {
    super.initState();
    _hostController.text = '127.0.0.1';
    unawaited(_loadSavedConnection());
    unawaited(_loadLocalDevConfig());
  }

  Future<void> _loadSavedConnection() async {
    try {
      final host = await _secureStorage.read(key: 'remoteaisync.route.host');
      final port = await _secureStorage.read(key: 'remoteaisync.route.port');
      final lan = await _secureStorage.read(key: 'remoteaisync.route.lan');
      final relayUrl = await _secureStorage.read(
        key: 'remoteaisync.route.relayUrl',
      );
      final directUrl = await _secureStorage.read(
        key: 'remoteaisync.route.directUrl',
      );
      final relayRoom = await _secureStorage.read(
        key: 'remoteaisync.route.relayRoom',
      );
      final relayToken = await _secureStorage.read(
        key: 'remoteaisync.route.relayToken',
      );
      final deviceId = await _secureStorage.read(key: 'remoteaisync.deviceId');
      final forceRelay = await _secureStorage.read(
        key: 'remoteaisync.route.forceRelay',
      );
      if (!mounted || host == null || port == null) return;
      final parsedPort = int.tryParse(port);
      if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) return;
      final decodedLan = lan == null ? const <String>[] : jsonDecode(lan);
      setState(() {
        _hostController.text = host;
        _portController.text = parsedPort.toString();
        _directUrlController.text = directUrl ?? '';
        _lanAddresses = decodedLan is List
            ? decodedLan.map((value) => value.toString()).toList()
            : const [];
        _relayUrlController.text = relayUrl ?? '';
        _relayRoomController.text = relayRoom ?? '';
        _relayTokenController.text = relayToken ?? '';
        _relayMode = _relayUrlController.text.isNotEmpty;
        _forceRelay = forceRelay == 'true';
        _hasSavedDeviceIdentity = deviceId?.isNotEmpty == true;
      });
      if (_hasSavedDeviceIdentity) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !widget.controller.isLive) unawaited(_connect());
        });
      }
    } catch (_) {
      // Secure storage can be unavailable on web builds and restricted devices.
    }
  }

  Future<void> _saveConnection() async {
    try {
      await _secureStorage.write(
        key: 'remoteaisync.route.host',
        value: _hostController.text.trim(),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.port',
        value: _portController.text.trim(),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.lan',
        value: jsonEncode(_lanAddresses),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.relayUrl',
        value: _relayUrlController.text.trim(),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.directUrl',
        value: _directUrlController.text.trim(),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.relayRoom',
        value: _relayRoomController.text.trim(),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.relayToken',
        value: _relayTokenController.text.trim(),
      );
      await _secureStorage.write(
        key: 'remoteaisync.route.forceRelay',
        value: _forceRelay.toString(),
      );
    } catch (_) {
      // Keep the active connection even if route persistence is unavailable.
    }
  }

  Future<void> _loadLocalDevConfig() async {
    if (!kIsWeb) return;
    final pageUri = Uri.base;
    if (!_isLoopbackHost(pageUri.host)) return;
    final requestedPort = int.tryParse(
      pageUri.queryParameters['hostPort'] ?? '8910',
    );
    if (requestedPort == null || requestedPort < 1 || requestedPort > 65535) {
      return;
    }
    try {
      final apiHost = pageUri.host.toLowerCase() == 'localhost'
          ? '127.0.0.1'
          : pageUri.host;
      final response = await http.get(
        Uri(
          scheme: 'http',
          host: apiHost,
          port: requestedPort,
          path: '/dev-config',
        ),
      );
      if (response.statusCode != 200) return;
      final config = jsonDecode(response.body);
      if (config is! Map<String, dynamic>) return;
      final port = int.tryParse(config['port']?.toString() ?? '');
      if (port == null || port < 1 || port > 65535) {
        return;
      }
      if (!mounted) return;
      _portController.text = port.toString();
      _validationMessage = '本地调试配置已检测到。旧版长期配对令牌已停用，请在主机 GUI 生成新的配对邀请。';
    } catch (_) {
      // Automatic pairing is optional; manual connection remains available.
    }
  }

  bool _isLoopbackHost(String host) =>
      const {'localhost', '127.0.0.1', '::1'}.contains(host.toLowerCase());

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    _directUrlController.dispose();
    _relayUrlController.dispose();
    _relayRoomController.dispose();
    _relayTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          final compact = constraints.maxWidth < 420;
          final status = _ConnectionStatus(controller: widget.controller);
          final form = GlassSurface(
            padding: EdgeInsets.all(compact ? 14 : 18),
            radius: 20,
            blur: 8,
            shadow: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设备配对',
                  style: compact
                      ? Theme.of(context).textTheme.titleMedium
                      : Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '扫描主机二维码，或手动填写配对信息。首次连接需在电脑端批准。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ShadTabs<bool>(
                  key: const Key('connection-route-tabs'),
                  value: _relayMode,
                  gap: 0,
                  onChanged: (relayMode) => setState(() {
                    _relayMode = relayMode;
                    _forceRelay = relayMode;
                  }),
                  tabs: const [
                    ShadTab<bool>(
                      value: false,
                      content: SizedBox.shrink(),
                      leading: Icon(LucideIcons.wifi, size: 14),
                      child: Text('局域网直连'),
                    ),
                    ShadTab<bool>(
                      value: true,
                      content: SizedBox.shrink(),
                      leading: Icon(LucideIcons.network, size: 14),
                      child: Text('自托管中继'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ShadForm(
                  key: _formKey,
                  child: Column(
                    children: [
                      if (_relayMode) ...[
                        ShadInputFormField(
                          key: const Key('connection-relay-url'),
                          id: 'relay-url',
                          controller: _relayUrlController,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          label: const Text('中继服务器地址'),
                          leading: const Icon(LucideIcons.globe),
                          placeholder: const Text('wss://relay.example.com'),
                          validator: _validateRelayUrl,
                        ),
                        const SizedBox(height: 12),
                        ShadInputFormField(
                          key: const Key('connection-relay-room'),
                          id: 'relay-room',
                          controller: _relayRoomController,
                          autocorrect: false,
                          label: const Text('房间 ID'),
                          leading: const Icon(LucideIcons.hash),
                          validator: (value) =>
                              RegExp(
                                r'^[A-Za-z0-9_-]{12,96}$',
                              ).hasMatch(value.trim())
                              ? null
                              : '请输入 12–96 位房间 ID',
                        ),
                        const SizedBox(height: 12),
                        ShadInputFormField(
                          key: const Key('connection-relay-token'),
                          id: 'relay-token',
                          controller: _relayTokenController,
                          obscureText: true,
                          autocorrect: false,
                          label: const Text('中继访问密钥'),
                          leading: const Icon(LucideIcons.keyRound),
                          validator: (value) =>
                              value.trim().length < 32 ? '请输入中继配置的完整密钥' : null,
                        ),
                        const SizedBox(height: 12),
                        if (widget.controller.isLive && _hasSavedDeviceIdentity)
                          const _PairingSavedStatus()
                        else ...[
                          ShadInputFormField(
                            key: const Key('connection-host-token'),
                            id: 'host-token',
                            controller: _tokenController,
                            autocorrect: false,
                            enableSuggestions: false,
                            obscureText: !_showPairingInvite,
                            trailing: _pairingInviteVisibilityButton(),
                            label: const Text('电脑主机配对令牌'),
                            leading: const Icon(LucideIcons.lockKeyhole),
                            validator: (value) => value.trim().length < 32
                                ? '请输入主机生成的限时配对邀请'
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '这是一次性邀请；连接成功后会自动清空，设备凭据已保存。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ] else ...[
                        ShadInputFormField(
                          key: const Key('connection-host'),
                          id: 'host',
                          controller: _hostController,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          label: const Text('主机地址'),
                          leading: const Icon(LucideIcons.laptop),
                          placeholder: const Text('127.0.0.1'),
                          validator: _validateHost,
                        ),
                        const SizedBox(height: 12),
                        ShadInputFormField(
                          key: const Key('connection-port'),
                          id: 'port',
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          label: const Text('端口'),
                          leading: const Icon(LucideIcons.radio),
                          validator: _validatePort,
                        ),
                        const SizedBox(height: 12),
                        if (widget.controller.isLive && _hasSavedDeviceIdentity)
                          const _PairingSavedStatus()
                        else ...[
                          ShadInputFormField(
                            key: const Key('connection-token'),
                            id: 'token',
                            controller: _tokenController,
                            autocorrect: false,
                            enableSuggestions: false,
                            obscureText: !_showPairingInvite,
                            trailing: _pairingInviteVisibilityButton(),
                            label: const Text('主机配对邀请'),
                            leading: const Icon(LucideIcons.keyRound),
                            validator: (value) => value.trim().length < 32
                                ? '请输入主机生成的限时配对邀请'
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '这是一次性邀请；连接成功后会自动清空，设备凭据已保存。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        ShadInputFormField(
                          key: const Key('connection-direct-url'),
                          id: 'direct-url',
                          controller: _directUrlController,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          label: const Text('公网主机 WSS（可选）'),
                          leading: const Icon(LucideIcons.globe2),
                          placeholder: const Text('wss://host.example.com/ws'),
                          validator: _validateDirectUrl,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: widget.controller.isLive
                          ? ShadButton.outline(
                              key: const Key('disconnect-local-host'),
                              onPressed: _disconnect,
                              leading: const Icon(LucideIcons.unlink),
                              child: const Text('断开连接'),
                            )
                          : ShadButton(
                              key: const Key('connect-local-host'),
                              onPressed:
                                  widget.controller.connectionStatus ==
                                      HostConnectionStatus.connecting
                                  ? null
                                  : _connect,
                              leading:
                                  widget.controller.connectionStatus ==
                                      HostConnectionStatus.connecting
                                  ? const SizedBox(
                                      width: 18,
                                      child: ShadProgress(minHeight: 2),
                                    )
                                  : const Icon(LucideIcons.link),
                              child: Text(
                                widget.controller.connectionStatus ==
                                        HostConnectionStatus.connecting
                                    ? '正在连接'
                                    : '连接本机主机',
                              ),
                            ),
                    ),
                    if (compact)
                      Tooltip(
                        message: '扫描主机配对二维码',
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: ShadIconButton.outline(
                            key: const Key('scan-pairing-qr'),
                            onPressed: _scanPairingCode,
                            icon: const Icon(LucideIcons.scanLine),
                          ),
                        ),
                      ),
                    if (!compact)
                      ShadButton.outline(
                        key: const Key('scan-pairing-qr'),
                        onPressed: _scanPairingCode,
                        leading: const Icon(LucideIcons.scanLine),
                        child: const Text('扫描主机配对二维码'),
                      ),
                  ],
                ),
                if (_validationMessage != null) ...[
                  const SizedBox(height: 12),
                  _ValidationResult(message: _validationMessage!),
                ],
              ],
            ),
          );
          final routes = GlassSurface(
            padding: EdgeInsets.all(compact ? 14 : 18),
            radius: 20,
            blur: 8,
            shadow: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('连接路径', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                _RouteRow(
                  icon: LucideIcons.wifi,
                  title: '局域网 / 本机直连',
                  status: widget.controller.connectionRoute == '局域网直连'
                      ? '当前路线'
                      : '优先尝试',
                  color: widget.controller.connectionRoute == '局域网直连'
                      ? shadSuccess
                      : shadMuted,
                ),
                _RouteRow(
                  icon: LucideIcons.globe,
                  title: 'IPv6 / 点对点直连',
                  status: '暂不可用',
                  color: shadMuted,
                ),
                _RouteRow(
                  icon: LucideIcons.network,
                  title: '自托管 WebSocket 中继',
                  status: widget.controller.connectionRoute == '中继'
                      ? '当前路线'
                      : _relayMode
                      ? '手动优先'
                      : '自动兜底',
                  color: widget.controller.connectionRoute == '中继'
                      ? shadSuccess
                      : shadMuted,
                ),
                const SizedBox(height: 14),
                const _SecurityNote(),
              ],
            ),
          );

          return ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 18,
              compact ? 12 : 20,
              compact ? 14 : 18,
              compact ? 16 : 24,
            ),
            children: [
              if (wide)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: form),
                        const SizedBox(width: 18),
                        Expanded(
                          flex: 5,
                          child: Column(
                            children: [
                              status,
                              const SizedBox(height: 14),
                              routes,
                              const SizedBox(height: 14),
                              _TopologyPanel(
                                topology: widget.controller.topology,
                              ),
                              const SizedBox(height: 12),
                              const _AgentAccessAbout(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                Text(
                  '连接设备',
                  style: compact
                      ? Theme.of(context).textTheme.titleLarge
                      : Theme.of(context).textTheme.headlineSmall,
                ),
                SizedBox(height: compact ? 8 : 12),
                status,
                SizedBox(height: compact ? 10 : 14),
                form,
                SizedBox(height: compact ? 10 : 14),
                routes,
                SizedBox(height: compact ? 10 : 14),
                _TopologyPanel(topology: widget.controller.topology),
                SizedBox(height: compact ? 10 : 14),
                const _AgentAccessAbout(),
              ],
            ],
          );
        },
      ),
    );
  }

  String? _validateHost(String value) {
    final host = value.trim();
    if (host.isEmpty && _directUrlController.text.trim().isNotEmpty) {
      return null;
    }
    if (_directUrlController.text.trim().isNotEmpty &&
        !host.contains(RegExp(r'[\s/]'))) {
      return null;
    }
    if (const {'localhost', '127.0.0.1', '::1'}.contains(host) ||
        (host.contains(':') && RegExp(r'^[0-9a-fA-F:.%]+$').hasMatch(host))) {
      return null;
    }
    final octets = host.split('.').map(int.tryParse).toList();
    if (octets.length != 4 ||
        octets.any((part) => part == null || part < 0 || part > 255)) {
      return '请输入电脑的 IPv4 地址';
    }
    final first = octets[0]!;
    final second = octets[1]!;
    final isPrivate =
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
    return isPrivate ? null : '当前版本仅允许本机或局域网地址';
  }

  String? _validatePort(String value) {
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) return '端口需为 1–65535';
    return null;
  }

  String? _validateRelayUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return '请输入 ws:// 或 wss:// 中继地址';
    }
    if (kIsWeb && Uri.base.scheme == 'https' && uri.scheme != 'wss') {
      return 'HTTPS 网页必须使用 WSS 中继地址';
    }
    if (!const {'localhost', '127.0.0.1', '::1'}.contains(uri.host) &&
        uri.scheme != 'wss') {
      return '公网中继必须使用 WSS';
    }
    return uri.path.isEmpty || uri.path == '/' || uri.path == '/relay'
        ? null
        : '中继地址路径请留空或使用 /relay';
  }

  String? _validateDirectUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) {
      return '公网主机必须使用 wss:// 地址';
    }
    return uri.path.isEmpty || uri.path == '/ws' ? null : '公网主机地址路径必须是 /ws';
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    final valid = _formKey.currentState?.saveAndValidate() ?? false;
    if (!valid) {
      setState(() => _validationMessage = null);
      return;
    }
    final port = int.tryParse(_portController.text.trim()) ?? 8910;
    final invitation = _tokenController.text.trim();
    if (invitation.isNotEmpty && _hasSavedDeviceIdentity) {
      await widget.controller.host.clearSavedPairing();
      _hasSavedDeviceIdentity = false;
    }
    try {
      await widget.controller.connect(
        address: _hostController.text,
        port: port,
        pairingToken: invitation,
        directUrl: _directUrlController.text.trim().isEmpty
            ? null
            : _directUrlController.text.trim(),
        relayUrl: _relayUrlController.text.trim().isEmpty
            ? null
            : _relayUrlController.text.trim(),
        relayRoom: _relayRoomController.text.trim().isEmpty
            ? null
            : _relayRoomController.text.trim(),
        relayToken: _relayTokenController.text.trim().isEmpty
            ? null
            : _relayTokenController.text.trim(),
        lanAddresses: _lanAddresses,
        forceRelay: _forceRelay,
      );
      _tokenController.clear();
      _hasSavedDeviceIdentity = true;
      await _saveConnection();
    } catch (_) {
      // The status panel displays the host client's sanitized error.
    }
    if (!mounted) return;
    setState(() {
      if (widget.controller.host.errorCode == 'pairing_required') {
        _hasSavedDeviceIdentity = false;
      }
      _validationMessage = widget.controller.isLive
          ? '已连接电脑主机。可选择 OpenCode、Codex 或 Claude Code 会话。'
          : widget.controller.connectionError ?? '连接未建立。';
    });
  }

  Widget _pairingInviteVisibilityButton() => Tooltip(
    message: _showPairingInvite ? '隐藏配对邀请' : '显示配对邀请',
    child: ShadIconButton.ghost(
      key: const Key('toggle-pairing-invite-visibility'),
      onPressed: () => setState(() => _showPairingInvite = !_showPairingInvite),
      icon: Icon(
        _showPairingInvite ? LucideIcons.eyeOff : LucideIcons.eye,
        size: 16,
      ),
    ),
  );

  Future<void> _scanPairingCode() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('扫描主机配对二维码'),
        content: SizedBox(
          width: 320,
          height: 320,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: MobileScanner(
              onDetect: (capture) {
                final value = capture.barcodes
                    .map((barcode) => barcode.rawValue)
                    .whereType<String>()
                    .firstOrNull;
                if (value != null) Navigator.of(dialogContext).pop(value);
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (raw == null || !mounted) return;
    try {
      final profile = PairingProfile.parse(raw);
      setState(() {
        _tokenController.text = profile.invite;
        _portController.text = profile.port.toString();
        _directUrlController.text = profile.directUrl ?? '';
        _lanAddresses = profile.lanAddresses;
        if (profile.lanAddresses.isNotEmpty) {
          _hostController.text = profile.lanAddresses.first;
        }
        _relayUrlController.text = profile.relayUrl ?? '';
        _relayRoomController.text = profile.relayRoom ?? '';
        _relayTokenController.text = profile.relayToken ?? '';
        _relayMode = _relayUrlController.text.isNotEmpty;
        _forceRelay = false;
        _validationMessage = '二维码已识别，正在按局域网优先连接。首次连接需在电脑端批准。';
      });
      // Use the imported route immediately. The host still controls approval;
      // this only removes the redundant manual "连接" tap after scanning.
      await _connect();
    } on FormatException catch (error) {
      setState(() => _validationMessage = '二维码无效：${error.message}');
    } catch (_) {
      setState(() => _validationMessage = '无法读取配对二维码，请检查二维码后重试。');
    }
  }

  Future<void> _disconnect() async {
    await widget.controller.disconnect();
    if (!mounted) return;
    setState(() => _validationMessage = null);
  }
}

class _PairingSavedStatus extends StatelessWidget {
  const _PairingSavedStatus();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('pairing-device-saved'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    decoration: BoxDecoration(
      color: shadSuccess.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: shadSuccess.withValues(alpha: .2)),
    ),
    child: Row(
      children: [
        const Icon(LucideIcons.shieldCheck, color: shadSuccess, size: 18),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设备已配对', style: Theme.of(context).textTheme.bodyMedium),
              Text(
                '一次性邀请已使用，设备凭据已保存，可自动重连。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.controller});

  final DemoController controller;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 420;
    final connected =
        controller.connectionStatus == HostConnectionStatus.connected;
    final connecting =
        controller.connectionStatus == HostConnectionStatus.connecting;
    final reconnecting =
        controller.transportState == TransportState.reconnecting;
    final error = controller.connectionStatus == HostConnectionStatus.error;
    final waitingApproval =
        controller.pairingState == PairingState.waitingApproval;
    final statusColor = connected
        ? shadSuccess
        : error
        ? shadError
        : waitingApproval || connecting
        ? shadWarning
        : shadMuted;
    final title = connected
        ? '主机已连接'
        : waitingApproval
        ? '等待主机批准'
        : reconnecting
        ? '正在恢复连接'
        : connecting
        ? '正在连接主机'
        : error
        ? '连接失败'
        : '尚未连接';
    final subtitle = connected
        ? controller.connectionError ?? '设备凭据已保存 · Agent 状态已同步'
        : waitingApproval
        ? '请在电脑端的配对设备列表中批准此手机。'
        : controller.connectionError ?? '请在电脑上启动 RemoteAISync 主机程序';
    return GlassSurface(
      padding: EdgeInsets.all(compact ? 12 : 15),
      radius: 20,
      blur: 10,
      shadow: false,
      child: Row(
        children: [
          Container(
            width: compact ? 36 : 42,
            height: compact ? 36 : 42,
            decoration: BoxDecoration(
              color: shadMutedBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(LucideIcons.laptop, color: statusColor),
          ),
          SizedBox(width: compact ? 9 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: compact
                      ? Theme.of(context).textTheme.titleSmall
                      : Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          ShadBadge.secondary(
            child: Text(
              connected
                  ? '在线'
                  : waitingApproval
                  ? '待批准'
                  : reconnecting
                  ? '恢复中'
                  : connecting
                  ? '连接中'
                  : error
                  ? '错误'
                  : '离线',
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({
    required this.icon,
    required this.title,
    required this.status,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: shadLine)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(status, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ValidationResult extends StatelessWidget {
  const _ValidationResult({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ShadAlert(
      icon: const Icon(LucideIcons.info),
      title: const Text('连接信息'),
      description: Text(message),
    );
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.lockKeyhole, color: shadSuccess, size: 17),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '公网中继使用 WSS 反向代理可加密传输。当前中继仅转发 Agent WebSocket 消息，尚不转发 WebRTC 视频流。',
            style: TextStyle(color: shadMuted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _AgentAccessAbout extends StatelessWidget {
  const _AgentAccessAbout();

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      radius: 18,
      blur: 8,
      shadow: false,
      child: ShadAccordion<String>(
        children: [
          ShadAccordionItem<String>(
            key: const Key('agent-access-about'),
            value: 'agent-access-about',
            padding: const EdgeInsets.symmetric(vertical: 11),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            title: const Row(
              children: [
                Icon(LucideIcons.info, size: 16),
                SizedBox(width: 8),
                Text('关于 Agent 接入'),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AgentAccessLine(
                    title: 'OpenCode',
                    detail: '通过本机 Server API 创建和继续会话，支持模型设置、停止、提问与审批。',
                  ),
                  SizedBox(height: 10),
                  _AgentAccessLine(
                    title: 'Codex',
                    detail:
                        'RemoteAISync 创建的会话可完整控制。桌面历史线程会先尝试直接发送；若 Codex 正由桌面进程写入，消息会进入 Codex 队列。',
                  ),
                  SizedBox(height: 10),
                  _AgentAccessLine(
                    title: 'Claude Code',
                    detail: '远程新建与继续通过 CLI；本机已有记录可同步查看。可用操作取决于会话来源。',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentAccessLine extends StatelessWidget {
  const _AgentAccessLine({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 2),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _TopologyPanel extends StatelessWidget {
  const _TopologyPanel({required this.topology});

  final TopologySnapshot topology;

  @override
  Widget build(BuildContext context) {
    final nodes = topology.nodes;
    final links = topology.links;
    return GlassSurface(
      padding: const EdgeInsets.all(16),
      radius: 20,
      blur: 8,
      shadow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: shadMutedBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: shadLine),
                ),
                child: const Icon(LucideIcons.activity, size: 16),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '链路状态',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (topology.revision > 0)
                Text(
                  '更新 #${topology.revision}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (nodes.isEmpty)
            const Text(
              '连接后显示主机、中继和客户端的实时状态。',
              style: TextStyle(color: shadMuted, fontSize: 12),
            )
          else
            Column(
              children: [
                for (final node in nodes) ...[
                  _TopologyNodeRow(node: node),
                  if (node != nodes.last) const SizedBox(height: 8),
                ],
              ],
            ),
          if (links.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '${links.where((link) => link.online).length}/${links.length} 条链路健康',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final link in links) ...[
              _TopologyLinkRow(
                link: link,
                fromLabel: _labelFor(link.from),
                toLabel: _labelFor(link.to),
              ),
              if (link != links.last) const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }

  String _labelFor(String id) {
    if (id == 'host') return '主机';
    if (id == 'relay') return '中继';
    if (id.startsWith('client:')) return '手机';
    return id;
  }
}

class _TopologyNodeRow extends StatefulWidget {
  const _TopologyNodeRow({required this.node});

  final TopologyNode node;

  @override
  State<_TopologyNodeRow> createState() => _TopologyNodeRowState();
}

class _TopologyNodeRowState extends State<_TopologyNodeRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final color = node.online && node.health == 'healthy'
        ? shadSuccess
        : node.online
        ? shadWarning
        : shadMuted;
    final icon = switch (node.role) {
      'host' => LucideIcons.laptop,
      'relay' => LucideIcons.network,
      'client' => LucideIcons.smartphone,
      _ => LucideIcons.circle,
    };
    final details = <String>[
      if (node.protocol?.isNotEmpty == true) node.protocol!.toUpperCase(),
      if (node.route == 'relay') '经中继',
      if (node.route == 'direct') '直连',
      if (node.rttMs != null) '${node.rttMs} ms',
      if (node.connectedAt != null) '已连 ${_elapsed(node.connectedAt!)}',
      if (node.heartbeatAt != null) '心跳 ${_elapsed(node.heartbeatAt!)} 前',
      if (node.bytesIn > 0 || node.bytesOut > 0)
        '${_bytes(node.bytesIn)} ↓ / ${_bytes(node.bytesOut)} ↑',
      if (node.reconnects > 0) '重连 ${node.reconnects} 次',
      if (node.address?.isNotEmpty == true) node.address!,
    ].join(' · ');
    return ShadButton.raw(
      key: Key('topology-node-${node.id}'),
      variant: ShadButtonVariant.ghost,
      width: double.infinity,
      padding: EdgeInsets.zero,
      mainAxisAlignment: MainAxisAlignment.start,
      onPressed: () => setState(() => _expanded = !_expanded),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: color.withValues(alpha: .25)),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nodeLabel(node),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (details.isNotEmpty)
                  AnimatedSize(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    alignment: Alignment.topLeft,
                    child: Text(
                      details,
                      maxLines: _expanded ? null : 1,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            node.online ? (node.health == 'healthy' ? '在线' : '降级') : '离线',
            style: TextStyle(color: color, fontSize: 12),
          ),
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: _expanded ? .5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(LucideIcons.chevronDown, size: 15),
          ),
        ],
      ),
    );
  }

  String _nodeLabel(TopologyNode node) {
    if (node.id == 'host') return '电脑主机';
    if (node.id == 'relay') return '中继服务器';
    if (node.role == 'client') return '手机客户端';
    return node.id;
  }

  String _elapsed(DateTime value) {
    final seconds = DateTime.now().toUtc().difference(value.toUtc()).inSeconds;
    if (seconds < 60) return '$seconds 秒';
    if (seconds < 3600) return '${seconds ~/ 60} 分';
    if (seconds < 86400) return '${seconds ~/ 3600} 小时';
    return '${seconds ~/ 86400} 天';
  }

  String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _TopologyLinkRow extends StatefulWidget {
  const _TopologyLinkRow({
    required this.link,
    required this.fromLabel,
    required this.toLabel,
  });

  final TopologyLink link;
  final String fromLabel;
  final String toLabel;

  @override
  State<_TopologyLinkRow> createState() => _TopologyLinkRowState();
}

class _TopologyLinkRowState extends State<_TopologyLinkRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final fromLabel = widget.fromLabel;
    final toLabel = widget.toLabel;
    final healthy = link.online && link.health == 'healthy';
    final color = healthy
        ? shadSuccess
        : link.online
        ? shadWarning
        : shadMuted;
    final details = <String>[
      if (link.protocol?.isNotEmpty == true) link.protocol!.toUpperCase(),
      if (link.route == 'relay') '经中继',
      if (link.route == 'direct') '直连',
      if (link.rttMs != null) '${link.rttMs} ms',
      if (link.bytesIn > 0 || link.bytesOut > 0)
        '${link.bytesIn} B ↓ / ${link.bytesOut} B ↑',
      if (link.reconnects > 0) '重连 ${link.reconnects} 次',
    ].join(' · ');
    return ShadButton.raw(
      key: Key('topology-link-${link.from}-${link.to}'),
      variant: ShadButtonVariant.ghost,
      width: double.infinity,
      padding: EdgeInsets.zero,
      mainAxisAlignment: MainAxisAlignment.start,
      onPressed: () => setState(() => _expanded = !_expanded),
      child: Row(
        children: [
          Icon(LucideIcons.arrowRight, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$fromLabel → $toLabel${details.isEmpty ? '' : ' · $details'}',
              maxLines: _expanded ? null : 1,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            healthy
                ? '健康'
                : link.online
                ? '降级'
                : '断开',
            style: TextStyle(color: color, fontSize: 11),
          ),
          const SizedBox(width: 3),
          AnimatedRotation(
            turns: _expanded ? .5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(LucideIcons.chevronDown, size: 13),
          ),
        ],
      ),
    );
  }
}

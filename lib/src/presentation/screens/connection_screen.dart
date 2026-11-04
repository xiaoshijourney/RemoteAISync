import 'package:flutter/material.dart';

import '../../application/demo_controller.dart';
import '../../domain/models.dart';
import '../theme.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({required this.controller, super.key});

  final DemoController controller;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8787');
  final _tokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    _hostController.text = '127.0.0.1';
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 24),
        children: [
          Text('连接设备', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 5),
          Text(
            '连接同一台电脑上的 OpenCode 主机服务。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          _ConnectionStatus(controller: widget.controller),
          const SizedBox(height: 20),
          Text('本机连接', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 11),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _hostController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '主机地址',
                    prefixIcon: Icon(Icons.computer_outlined),
                  ),
                  readOnly: true,
                  validator: _validateHost,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '端口'),
                  validator: _validatePort,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _tokenController,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '本次运行的配对令牌',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                  validator: (value) => (value?.trim().length ?? 0) < 32
                      ? '请输入主机终端显示的完整令牌'
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (widget.controller.isLive)
            OutlinedButton.icon(
              key: const Key('disconnect-local-host'),
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('断开连接'),
            )
          else
            FilledButton.icon(
              key: const Key('connect-local-host'),
              onPressed:
                  widget.controller.connectionStatus ==
                      HostConnectionStatus.connecting
                  ? null
                  : _connect,
              icon:
                  widget.controller.connectionStatus ==
                      HostConnectionStatus.connecting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(
                widget.controller.connectionStatus ==
                        HostConnectionStatus.connecting
                    ? '正在连接'
                    : '连接本机主机',
              ),
            ),
          if (_validationMessage != null) ...[
            const SizedBox(height: 10),
            _ValidationResult(message: _validationMessage!),
          ],
          const SizedBox(height: 20),
          const Divider(height: 1, color: appLine),
          const SizedBox(height: 17),
          Text('连接策略', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 9),
          _RouteRow(
            icon: Icons.wifi,
            title: '本机回环连接',
            status: widget.controller.isLive ? '已连接' : '仅本机访问',
            color: widget.controller.isLive ? appGreen : appMuted,
          ),
          const _RouteRow(
            icon: Icons.public,
            title: 'IPv6 / 点对点直连',
            status: '下一阶段',
            color: appMuted,
          ),
          const _RouteRow(
            icon: Icons.hub_outlined,
            title: '自托管中继',
            status: '下一阶段',
            color: appMuted,
          ),
          const SizedBox(height: 14),
          const _SecurityNote(),
        ],
      ),
    );
  }

  String? _validateHost(String? value) {
    final host = value?.trim() ?? '';
    if (!const {'127.0.0.1', 'localhost', '::1'}.contains(host)) {
      return '当前版本只允许本机连接';
    }
    return null;
  }

  String? _validatePort(String? value) {
    final port = int.tryParse(value ?? '');
    if (port == null || port < 1 || port > 65535) return '端口需为 1–65535';
    return null;
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) {
      setState(() => _validationMessage = null);
      return;
    }
    final port = int.parse(_portController.text.trim());
    try {
      await widget.controller.connect(
        address: _hostController.text,
        port: port,
        pairingToken: _tokenController.text.trim(),
      );
      _tokenController.clear();
    } catch (_) {
      // The status panel displays the host client's sanitized error.
    }
    if (!mounted) return;
    setState(() {
      _validationMessage = widget.controller.isLive
          ? '已连接 OpenCode ${widget.controller.hostVersion}。当前仅允许本机访问。'
          : widget.controller.connectionError ?? '连接未建立。';
    });
  }

  Future<void> _disconnect() async {
    await widget.controller.disconnect();
    if (!mounted) return;
    setState(() => _validationMessage = null);
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.controller});

  final DemoController controller;

  @override
  Widget build(BuildContext context) {
    final connected =
        controller.connectionStatus == HostConnectionStatus.connected;
    final connecting =
        controller.connectionStatus == HostConnectionStatus.connecting;
    final error = controller.connectionStatus == HostConnectionStatus.error;
    final statusColor = connected
        ? appGreen
        : error
        ? appRed
        : appMuted;
    final title = connected
        ? '已连接 OpenCode ${controller.hostVersion ?? ''}'
        : connecting
        ? '正在连接主机'
        : error
        ? '连接失败'
        : '尚未连接';
    final subtitle = connected
        ? controller.connectionError ?? '127.0.0.1 · 本机回环连接'
        : controller.connectionError ?? '请在电脑上启动 RemoteAISync 主机程序';
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appLine),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: connected
                  ? const Color(0xFFE8F1ED)
                  : const Color(0xFFF0F2F1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.laptop_chromebook_outlined, color: statusColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          _StatusBadge(
            label: connected
                ? '在线'
                : connecting
                ? '连接中'
                : error
                ? '错误'
                : '离线',
            color: statusColor,
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: color, size: 7),
          SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
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
        border: Border(bottom: BorderSide(color: appLine)),
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
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF2EE),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: appGreen, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: appGreen,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
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
        Icon(Icons.lock_outline, color: appGreen, size: 17),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '当前主机只绑定 127.0.0.1，不接受局域网访问。手机配对和远程网络连接将在后续阶段实现。',
            style: TextStyle(color: appMuted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

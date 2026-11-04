import 'package:flutter/material.dart';

import '../theme.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8787');
  final _pairingController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _showPairingCode = false;
  String? _validationMessage;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _pairingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 24),
      children: [
        Text('连接设备', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 5),
        Text(
          '配置电脑主机地址。当前版本尚未接入主机服务。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        const _ConnectionStatus(),
        const SizedBox(height: 20),
        Text('手动配对', style: Theme.of(context).textTheme.titleLarge),
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
                  labelText: '电脑 IP 或主机名',
                  hintText: '例如 192.168.1.20',
                  prefixIcon: Icon(Icons.computer_outlined),
                ),
                validator: _validateHost,
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 118,
                    child: TextFormField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '端口'),
                      validator: _validatePort,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _pairingController,
                      obscureText: !_showPairingCode,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: '一次性配对码',
                        hintText: '由电脑端生成',
                        suffixIcon: IconButton(
                          tooltip: _showPairingCode ? '隐藏配对码' : '显示配对码',
                          onPressed: () => setState(
                            () => _showPairingCode = !_showPairingCode,
                          ),
                          icon: Icon(
                            _showPairingCode
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _checkConfiguration,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('检查连接配置'),
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
        const _RouteRow(
          icon: Icons.wifi,
          title: '局域网直连',
          status: '未连接',
          color: appMuted,
        ),
        const _RouteRow(
          icon: Icons.public,
          title: 'IPv6 / 点对点直连',
          status: '尚未探测',
          color: appMuted,
        ),
        const _RouteRow(
          icon: Icons.hub_outlined,
          title: '自托管中继',
          status: '尚未配置',
          color: appMuted,
        ),
        const SizedBox(height: 14),
        const _SecurityNote(),
      ],
    );
  }

  String? _validateHost(String? value) {
    final host = value?.trim() ?? '';
    if (host.isEmpty) return '请输入电脑 IP 或主机名';
    final isIpv4 = _isValidIpv4(host);
    final isIpv6 =
        host.contains(':') && RegExp(r'^[0-9a-fA-F:.%]+$').hasMatch(host);
    final isHostName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(host);
    if (!isIpv4 && !isIpv6 && !isHostName) return '地址格式不正确';
    return null;
  }

  bool _isValidIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final value = int.tryParse(part);
      return value != null && value >= 0 && value <= 255;
    });
  }

  String? _validatePort(String? value) {
    final port = int.tryParse(value ?? '');
    if (port == null || port < 1 || port > 65535) return '端口需为 1–65535';
    return null;
  }

  void _checkConfiguration() {
    FocusScope.of(context).unfocus();
    final valid = _formKey.currentState?.validate() ?? false;
    setState(() {
      _validationMessage = valid ? '地址格式有效。主机端服务尚未接入，当前没有建立连接。' : null;
    });
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus();

  @override
  Widget build(BuildContext context) {
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
              color: const Color(0xFFF0F2F1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.laptop_chromebook_outlined,
              color: appMuted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('尚未连接', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '没有向任何主机发送请求',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const _StatusBadge(),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: appMuted, size: 7),
          SizedBox(width: 6),
          Text('离线', style: TextStyle(color: appMuted, fontSize: 12)),
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
            '配对码应由电脑端短时生成。连接能力尚未接入前，此表单只检查输入格式。',
            style: TextStyle(color: appMuted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

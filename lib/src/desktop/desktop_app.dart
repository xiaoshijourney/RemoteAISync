import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../domain/models.dart';
import '../domain/transport_protocol.dart';
import '../presentation/components/agent_brand_mark.dart';
import '../presentation/shad_theme.dart';
import 'host_service_manager.dart';

class DesktopApp extends StatefulWidget {
  const DesktopApp({this.manager, super.key});

  final HostServiceManager? manager;

  @override
  State<DesktopApp> createState() => _DesktopAppState();
}

class _DesktopAppState extends State<DesktopApp> {
  late final HostServiceManager _manager;
  late final bool _ownsManager;
  int _section = 0;

  @override
  void initState() {
    super.initState();
    _ownsManager = widget.manager == null;
    _manager = widget.manager ?? HostServiceManager();
  }

  @override
  void dispose() {
    if (_ownsManager) _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _manager,
      builder: (context, _) => Scaffold(
        backgroundColor: shadCanvas,
        body: Row(
          children: [
            _Sidebar(
              selectedIndex: _section,
              mode: _manager.mode,
              online: _manager.snapshot.reachable,
              onSelected: (index) => setState(() => _section = index),
              onModeChanged: (mode) async {
                await _manager.selectMode(mode);
                if (mounted) setState(() => _section = 0);
              },
            ),
            Expanded(child: _buildContent(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final snapshot = _manager.snapshot;
    return Column(
      children: [
        _TopBar(
          online: snapshot.reachable,
          mode: _manager.mode,
          connectedClients: snapshot.connectedClients,
          relayHosts: snapshot.relayHosts,
          relayClients: snapshot.relayClients,
          relayRooms: snapshot.relayRooms,
          busy: _manager.busy,
          onRefresh: _manager.refresh,
        ),
        Expanded(
          child: _section == 0
              ? _Overview(manager: _manager)
              : _section == 1
              ? _manager.mode == HostRuntimeMode.host
                    ? _AgentPanel(manager: _manager)
                    : _RelayConnectionsPanel(manager: _manager)
              : _section == 2
              ? _ConnectionInfoPanel(
                  snapshot: snapshot,
                  port: _manager.activePort,
                  mode: _manager.mode,
                  relayUrl: _manager.relayUrl,
                  relayRoom: _manager.relayRoom,
                  relayClientToken: _manager.relayClientToken,
                  relayHostToken: _manager.relayHostToken,
                  onCopy: (value, label) => _copyValue(context, value, label),
                  onCreatePairingInvite: _manager.createPairingInvite,
                  onResolvePairing: _manager.resolvePairing,
                  onRevokeDevice: _manager.revokeDevice,
                )
              : _SettingsPanel(manager: _manager),
        ),
      ],
    );
  }

  Future<void> _copyValue(
    BuildContext context,
    String value,
    String label,
  ) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ShadToaster.of(context).show(ShadToast(title: Text('$label 已复制到剪贴板')));
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selectedIndex,
    required this.mode,
    required this.online,
    required this.onSelected,
    required this.onModeChanged,
  });

  final int selectedIndex;
  final HostRuntimeMode mode;
  final bool online;
  final ValueChanged<int> onSelected;
  final ValueChanged<HostRuntimeMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 232,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShadBadge(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(8),
                child: const Icon(
                  LucideIcons.refreshCw,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'RemoteAISync',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          const Padding(
            padding: EdgeInsets.only(left: 44),
            child: Text(
              '主机控制台',
              style: TextStyle(color: shadMuted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 18),
          ShadTabs<HostRuntimeMode>(
            key: const Key('desktop-mode-tabs'),
            value: mode,
            gap: 0,
            onChanged: onModeChanged,
            tabs: [
              ShadTab<HostRuntimeMode>(
                value: HostRuntimeMode.host,
                content: const SizedBox.shrink(),
                leading: const Icon(LucideIcons.monitor, size: 14),
                child: const Text('主机'),
              ),
              ShadTab<HostRuntimeMode>(
                value: HostRuntimeMode.relay,
                content: const SizedBox.shrink(),
                leading: const Icon(LucideIcons.network, size: 14),
                child: const Text('中继'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SideItem(
            icon: LucideIcons.layoutDashboard,
            label: '概览',
            selected: selectedIndex == 0,
            onPressed: () => onSelected(0),
          ),
          _SideItem(
            icon: LucideIcons.bot,
            label: mode == HostRuntimeMode.host ? 'Agent 状态' : '接入状态',
            selected: selectedIndex == 1,
            onPressed: () => onSelected(1),
          ),
          _SideItem(
            icon: LucideIcons.network,
            label: '连接信息',
            selected: selectedIndex == 2,
            onPressed: () => onSelected(2),
          ),
          _SideItem(
            icon: LucideIcons.settings2,
            label: '设置',
            selected: selectedIndex == 3,
            onPressed: () => onSelected(3),
          ),
          const Spacer(),
          ShadBadge.secondary(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            backgroundColor: online
                ? shadSuccess.withValues(alpha: .1)
                : shadMutedBackground,
            foregroundColor: online ? shadSuccess : shadMuted,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  online ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                  size: 15,
                ),
                const SizedBox(width: 7),
                Text(online ? '服务在线' : '服务离线'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ShadButton.ghost(
        onPressed: onPressed,
        leading: Icon(icon, size: 17),
        backgroundColor: selected ? shadMutedBackground : null,
        hoverBackgroundColor: shadMutedBackground,
        foregroundColor: selected ? shadInk : shadMuted,
        hoverForegroundColor: shadInk,
        width: double.infinity,
        mainAxisAlignment: MainAxisAlignment.start,
        child: Text(label),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.online,
    required this.mode,
    required this.connectedClients,
    required this.relayHosts,
    required this.relayClients,
    required this.relayRooms,
    required this.busy,
    required this.onRefresh,
  });

  final bool online;
  final HostRuntimeMode mode;
  final int? connectedClients;
  final int? relayHosts;
  final int? relayClients;
  final int? relayRooms;
  final bool busy;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 650;
        return Container(
          height: 76,
          padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 30),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: shadLine)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode == HostRuntimeMode.host ? '电脑主机状态' : '中继服务器状态',
                      style: TextStyle(
                        fontSize: compact ? 17 : 19,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 3),
                      Text(
                        mode == HostRuntimeMode.host
                            ? '管理本机 Agent 桥接与客户端连接'
                            : '管理 RemoteAISync 自托管 WebSocket 中继',
                        style: const TextStyle(fontSize: 12, color: shadMuted),
                      ),
                    ],
                  ],
                ),
              ),
              ShadBadge.secondary(
                backgroundColor: online
                    ? shadSuccess.withValues(alpha: .1)
                    : shadMutedBackground,
                foregroundColor: online ? shadSuccess : shadMuted,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online ? shadSuccess : shadMuted,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(online ? '在线' : '离线'),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ShadBadge.secondary(
                backgroundColor:
                    ((mode == HostRuntimeMode.relay
                                ? relayClients
                                : connectedClients) ??
                            0) >
                        0
                    ? shadSuccess.withValues(alpha: .1)
                    : shadMutedBackground,
                foregroundColor:
                    ((mode == HostRuntimeMode.relay
                                ? relayClients
                                : connectedClients) ??
                            0) >
                        0
                    ? shadSuccess
                    : shadMuted,
                child: Tooltip(
                  message: mode == HostRuntimeMode.relay
                      ? '当前房间 ${relayRooms ?? 0} 个，主机 ${relayHosts ?? 0} 台，客户端 ${relayClients ?? 0} 个'
                      : online && connectedClients == null
                      ? '主机服务在线，但当前版本未上报客户端数量。重启服务后可显示客户端数；当前连接信息仍可使用。'
                      : '已完成配对并保持连接的手机客户端数量',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        mode == HostRuntimeMode.relay
                            ? LucideIcons.network
                            : LucideIcons.smartphone,
                        size: 13,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        !online
                            ? mode == HostRuntimeMode.relay
                                  ? '中继离线'
                                  : '等待主机'
                            : mode == HostRuntimeMode.relay
                            ? '${relayRooms ?? 0} 个房间 · ${relayHosts ?? 0} 台主机 · ${relayClients ?? 0} 个客户端'
                            : connectedClients == null
                            ? '客户端数未知'
                            : connectedClients == 0
                            ? '无客户端'
                            : '$connectedClients 个客户端',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (compact)
                Tooltip(
                  message: '刷新状态',
                  child: ShadIconButton.ghost(
                    onPressed: busy ? null : onRefresh,
                    icon: Icon(
                      busy ? LucideIcons.loaderCircle : LucideIcons.refreshCw,
                      size: 17,
                    ),
                  ),
                )
              else
                ShadButton.outline(
                  onPressed: busy ? null : onRefresh,
                  leading: Icon(
                    busy ? LucideIcons.loaderCircle : LucideIcons.refreshCw,
                    size: 16,
                  ),
                  child: const Text('刷新状态'),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    return _desktopScrollPage(
      maxWidth: 1120,
      builder: (context, width) {
        final cardWidth = width >= 760 ? (width - 16) / 2 : width;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: width,
              child: _StatusHero(manager: manager),
            ),
            const SizedBox(height: 16),
            if (width >= 760)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: _ServiceCard(manager: manager),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: cardWidth,
                      child: _AgentSummary(manager: manager),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  SizedBox(
                    width: width,
                    child: _ServiceCard(manager: manager),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: width,
                    child: _AgentSummary(manager: manager),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: width,
              child: _ActivityCard(manager: manager),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: width,
              child: _DesktopTopologyPanel(topology: manager.snapshot.topology),
            ),
          ],
        );
      },
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    final online = manager.snapshot.reachable;
    final shadTheme = ShadTheme.of(context);
    final title = manager.mode == HostRuntimeMode.host
        ? online
              ? 'RemoteAISync 主机正在运行'
              : 'RemoteAISync 主机未运行'
        : online
        ? 'RemoteAISync 中继正在运行'
        : 'RemoteAISync 中继未运行';
    final description = online
        ? manager.mode == HostRuntimeMode.host
              ? '手机端可以通过 WebSocket 连接到这台电脑。'
              : '中继已接入 ${manager.snapshot.relayRooms ?? 0} 个房间和 ${manager.snapshot.relayClients ?? 0} 个客户端。'
        : manager.snapshot.error ?? '从设置中选择运行模式并启动服务。';
    return ShadCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          ShadBadge.secondary(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(10),
            backgroundColor: online
                ? shadSuccess.withValues(alpha: .1)
                : shadMutedBackground,
            foregroundColor: online ? shadSuccess : shadMuted,
            child: Icon(
              online ? LucideIcons.server : LucideIcons.serverOff,
              size: 23,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: shadTheme.textTheme.h3.copyWith(
                    color: shadTheme.colorScheme.cardForeground,
                  ),
                ),
                Text(
                  description,
                  style: shadTheme.textTheme.muted.fallback(
                    color: shadTheme.colorScheme.mutedForeground,
                  ),
                ),
                if (online &&
                    manager.mode == HostRuntimeMode.host &&
                    manager.snapshot.publicHostEnabled &&
                    manager.snapshot.publicHostUrl?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  Text(
                    '公网主机 WSS 已启用：${manager.snapshot.publicHostUrl}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: shadMuted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          ShadBadge.secondary(
            backgroundColor: online
                ? shadSuccess.withValues(alpha: .1)
                : shadMutedBackground,
            foregroundColor: online ? shadSuccess : shadMuted,
            child: Text(online ? '健康检查通过' : '等待启动'),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    final stateLabel = switch (manager.serviceState) {
      ServiceState.stopped => '已停止',
      ServiceState.starting => '正在启动',
      ServiceState.running => '运行中',
      ServiceState.stopping => '正在停止',
      ServiceState.failed => '启动失败',
    };
    return _Panel(
      icon: LucideIcons.power,
      title: '服务控制',
      subtitle: '主机服务可以独立于此界面运行。',
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                ShadBadge.secondary(child: Text(stateLabel)),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    manager.ownsProcess ? '由此控制台启动' : '外部进程或尚未启动',
                    style: const TextStyle(fontSize: 12, color: shadMuted),
                  ),
                ),
              ],
            ),
          ),
          if (!manager.snapshot.reachable)
            ShadButton(
              onPressed: manager.busy ? null : manager.start,
              leading: const Icon(LucideIcons.play, size: 15),
              child: const Text('启动'),
            )
          else ...[
            ShadButton.outline(
              onPressed:
                  manager.busy ||
                      (manager.mode == HostRuntimeMode.host &&
                          manager.snapshot.pairingToken == null) ||
                      (manager.mode == HostRuntimeMode.relay &&
                          !manager.ownsProcess)
                  ? null
                  : manager.stop,
              leading: const Icon(LucideIcons.square, size: 15),
              child: const Text('停止'),
            ),
            const SizedBox(width: 8),
            ShadButton.outline(
              onPressed:
                  manager.busy ||
                      manager.mode == HostRuntimeMode.relay ||
                      manager.snapshot.pairingToken == null
                  ? null
                  : manager.restart,
              leading: const Icon(LucideIcons.rotateCw, size: 15),
              child: const Text('重启'),
            ),
          ],
        ],
      ),
    );
  }
}

class _AgentSummary extends StatelessWidget {
  const _AgentSummary({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    final snapshot = manager.snapshot;
    if (snapshot.mode == HostRuntimeMode.relay) {
      return _Panel(
        icon: LucideIcons.network,
        title: '两端接入状态',
        subtitle: '中继只转发连接；主机负责运行 Agent，客户端负责远程操作。',
        child: Wrap(
          spacing: 26,
          runSpacing: 14,
          children: [
            _KeyValue(
              label: '主机端',
              value: !snapshot.reachable
                  ? '中继离线'
                  : (snapshot.relayHosts ?? 0) > 0
                  ? '${snapshot.relayHosts} 台已连接'
                  : '等待电脑主机',
            ),
            _KeyValue(
              label: '客户端端',
              value: !snapshot.reachable
                  ? '中继离线'
                  : '${snapshot.relayClients ?? 0} 个已连接',
            ),
            _KeyValue(label: '活动房间', value: '${snapshot.relayRooms ?? 0}'),
          ],
        ),
      );
    }
    return _Panel(
      icon: LucideIcons.bot,
      title: 'Agent 适配状态',
      subtitle: '按 Agent 汇总实际接入方式；状态表示 RemoteAISync 适配可用，不代表桌面程序正在运行。',
      child: Column(
        children: [
          _AgentRow(
            name: 'OpenCode',
            agentId: 'opencode',
            version: snapshot.openCodeVersion,
            status: snapshot.agentStatuses['opencode'],
            hostReachable: snapshot.reachable,
          ),
          const SizedBox(height: 10),
          _AgentRow(
            name: 'Codex CLI / app-server',
            agentId: 'codex',
            version: snapshot.codexVersion,
            status: snapshot.agentStatuses['codex'],
            suffix: snapshot.codexHookRuntimeReady
                ? '桌面线程共用 · Hook 已启用'
                : '桌面线程共用',
            hostReachable: snapshot.reachable,
          ),
          const SizedBox(height: 10),
          _AgentRow(
            name: 'Claude Code CLI + 本地记录',
            agentId: 'claude',
            status: snapshot.agentStatuses['claude'],
            suffix: 'JSONL 会话同步',
            hostReachable: snapshot.reachable,
          ),
        ],
      ),
    );
  }
}

class _RelayConnectionsPanel extends StatelessWidget {
  const _RelayConnectionsPanel({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    final snapshot = manager.snapshot;
    final relayOnline = snapshot.reachable;
    final hostCount = snapshot.relayHosts ?? 0;
    final clientCount = snapshot.relayClients ?? 0;
    return _desktopScrollPage(
      maxWidth: 1000,
      builder: (context, width) {
        final hostCard = _RelayEndpointCard(
          icon: LucideIcons.laptop,
          title: '电脑主机端',
          description: '运行 Agent 并注册到中继房间。',
          status: !relayOnline
              ? '中继离线'
              : hostCount > 0
              ? '$hostCount 台主机已接入'
              : '等待主机接入',
          online: relayOnline && hostCount > 0,
        );
        final clientCard = _RelayEndpointCard(
          icon: LucideIcons.smartphone,
          title: '手机客户端',
          description: '通过房间与电脑主机建立会话。',
          status: !relayOnline
              ? '中继离线'
              : clientCount > 0
              ? '$clientCount 个客户端已接入'
              : '等待客户端接入',
          online: relayOnline && clientCount > 0,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('接入状态', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            const Text(
              '分别查看电脑主机和手机客户端是否接入当前中继。',
              style: TextStyle(color: shadMuted),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: width,
              child: _StatusHero(manager: manager),
            ),
            const SizedBox(height: 16),
            if (width >= 700)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: hostCard),
                    const SizedBox(width: 14),
                    Expanded(child: clientCard),
                  ],
                ),
              )
            else
              Column(
                children: [
                  SizedBox(width: width, child: hostCard),
                  const SizedBox(height: 14),
                  SizedBox(width: width, child: clientCard),
                ],
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: width,
              child: _Panel(
                icon: LucideIcons.network,
                title: '中继监听',
                subtitle: '中继只负责转发配对后的 WebSocket 数据。',
                child: Wrap(
                  spacing: 28,
                  runSpacing: 12,
                  children: [
                    _KeyValue(label: '监听端口', value: '${manager.relayPort}'),
                    _KeyValue(
                      label: '活动房间',
                      value: '${snapshot.relayRooms ?? 0}',
                    ),
                    _KeyValue(label: '主机连接', value: '$hostCount'),
                    _KeyValue(label: '客户端连接', value: '$clientCount'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: width,
              child: _DesktopTopologyPanel(topology: snapshot.topology),
            ),
          ],
        );
      },
    );
  }
}

class _RelayEndpointCard extends StatelessWidget {
  const _RelayEndpointCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.online,
  });

  final IconData icon;
  final String title;
  final String description;
  final String status;
  final bool online;

  @override
  Widget build(BuildContext context) => ShadCard(
    padding: const EdgeInsets.all(18),
    child: Row(
      children: [
        _DesktopIconTile(
          key: Key('relay-endpoint-icon-$title'),
          icon: icon,
          size: 42,
          iconSize: 19,
          color: online ? shadPrimary : shadMuted,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: shadInk,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: shadMuted,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: ShadBadge.secondary(
                  backgroundColor: online
                      ? shadSuccess.withValues(alpha: .1)
                      : shadMutedBackground,
                  foregroundColor: online ? shadSuccess : shadMuted,
                  child: Text(
                    status,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _DesktopIconTile extends StatelessWidget {
  const _DesktopIconTile({
    super.key,
    required this.icon,
    this.size = 30,
    this.iconSize = 15,
    this.color = shadMuted,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: shadMutedBackground,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: shadLine),
    ),
    child: Icon(icon, size: iconSize, color: color),
  );
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.name,
    required this.agentId,
    this.version,
    this.status,
    required this.hostReachable,
    this.suffix,
  });

  final String name;
  final String agentId;
  final String? version;
  final AgentRuntimeStatus? status;
  final bool hostReachable;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final available = status?.isAvailable ?? (version?.isNotEmpty == true);
    return Row(
      children: [
        Opacity(
          opacity: available ? 1 : .55,
          child: AgentBrandMark(agentId: agentId, size: 19),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          ),
        ),
        if (suffix != null) ...[
          Text(suffix!, style: const TextStyle(color: shadMuted, fontSize: 11)),
          const SizedBox(width: 8),
        ],
        ShadBadge.secondary(
          backgroundColor: available
              ? shadSuccess.withValues(alpha: .1)
              : shadMutedBackground,
          foregroundColor: available ? shadSuccess : shadMuted,
          child: Text(
            _agentBadgeText(
              reachable: hostReachable,
              status: status,
              version: version,
            ),
          ),
        ),
      ],
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: LucideIcons.activity,
      title: '最近日志',
      subtitle: '用于快速判断主机和 Agent 的启动状态。',
      child: SizedBox(
        height: 220,
        child: manager.logs.isEmpty
            ? const Center(
                child: Text('暂无日志', style: TextStyle(color: shadMuted)),
              )
            : ListView.separated(
                itemCount: manager.logs.length > 20 ? 20 : manager.logs.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    manager.logs[index],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                      color: shadMuted,
                    ),
                  ),
                ),
                separatorBuilder: (context, index) =>
                    const ShadSeparator.horizontal(),
              ),
      ),
    );
  }
}

class _DesktopTopologyPanel extends StatelessWidget {
  const _DesktopTopologyPanel({required this.topology});

  final TopologySnapshot topology;

  @override
  Widget build(BuildContext context) {
    final onlineNodes = topology.nodes.where((node) => node.online).length;
    final onlineLinks = topology.links.where((link) => link.online).length;
    return _Panel(
      icon: LucideIcons.activity,
      title: '全链路状态',
      subtitle: '显示当前主机、中继和客户端的在线状态、协议、延迟与流量。',
      child: topology.nodes.isEmpty
          ? const Text('服务连接后会显示完整拓扑。', style: TextStyle(color: shadMuted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 22,
                  runSpacing: 10,
                  children: [
                    _KeyValue(
                      label: '在线节点',
                      value: '$onlineNodes/${topology.nodes.length}',
                    ),
                    _KeyValue(
                      label: '健康链路',
                      value: '$onlineLinks/${topology.links.length}',
                    ),
                    _KeyValue(label: '快照版本', value: '${topology.revision}'),
                  ],
                ),
                const SizedBox(height: 14),
                for (final node in topology.nodes) ...[
                  _DesktopTopologyNodeRow(node: node),
                  if (node != topology.nodes.last)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: ShadSeparator.horizontal(),
                    ),
                ],
                if (topology.links.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const ShadSeparator.horizontal(),
                  const SizedBox(height: 10),
                  for (final link in topology.links) ...[
                    _DesktopTopologyLinkRow(link: link),
                    if (link != topology.links.last) const SizedBox(height: 8),
                  ],
                ],
              ],
            ),
    );
  }
}

class _DesktopTopologyNodeRow extends StatelessWidget {
  const _DesktopTopologyNodeRow({required this.node});

  final TopologyNode node;

  @override
  Widget build(BuildContext context) {
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
    final metrics = <String>[
      if (node.protocol?.isNotEmpty == true) node.protocol!.toUpperCase(),
      if (node.route == 'relay') '经中继',
      if (node.route == 'direct') '直连',
      if (node.rttMs != null) '${node.rttMs} ms',
      if (node.connectedAt != null) '已连 ${_elapsed(node.connectedAt!)}',
      if (node.heartbeatAt != null) '心跳 ${_elapsed(node.heartbeatAt!)} 前',
      if (node.bytesIn > 0 || node.bytesOut > 0)
        '${_formatBytes(node.bytesIn)} ↓ / ${_formatBytes(node.bytesOut)} ↑',
      if (node.reconnects > 0) '重连 ${node.reconnects} 次',
    ].join(' · ');
    return Row(
      children: [
        _DesktopIconTile(icon: icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _label(node),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (metrics.isNotEmpty)
                Text(
                  metrics,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: shadMuted),
                ),
            ],
          ),
        ),
        ShadBadge.secondary(
          backgroundColor: color.withValues(alpha: .1),
          foregroundColor: color,
          child: Text(
            node.online ? (node.health == 'healthy' ? '在线' : '降级') : '离线',
          ),
        ),
      ],
    );
  }

  String _label(TopologyNode node) {
    if (node.id == 'host') return '电脑主机';
    if (node.id == 'relay') return '中继服务器';
    if (node.role == 'client') return '手机客户端';
    return node.id;
  }

  String _formatBytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _elapsed(DateTime value) {
    final seconds = DateTime.now().toUtc().difference(value.toUtc()).inSeconds;
    if (seconds < 60) return '$seconds 秒';
    if (seconds < 3600) return '${seconds ~/ 60} 分';
    if (seconds < 86400) return '${seconds ~/ 3600} 小时';
    return '${seconds ~/ 86400} 天';
  }
}

class _DesktopTopologyLinkRow extends StatelessWidget {
  const _DesktopTopologyLinkRow({required this.link});

  final TopologyLink link;

  @override
  Widget build(BuildContext context) {
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
        '${_formatBytes(link.bytesIn)} ↓ / ${_formatBytes(link.bytesOut)} ↑',
      if (link.reconnects > 0) '重连 ${link.reconnects} 次',
    ].join(' · ');
    return Row(
      children: [
        Icon(LucideIcons.arrowRight, size: 14, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            '${_label(link.from)} → ${_label(link.to)}${details.isEmpty ? '' : ' · $details'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: shadMuted),
          ),
        ),
        ShadBadge.secondary(
          backgroundColor: color.withValues(alpha: .1),
          foregroundColor: color,
          child: Text(
            healthy
                ? '健康'
                : link.online
                ? '降级'
                : '断开',
          ),
        ),
      ],
    );
  }

  String _label(String id) {
    if (id == 'host') return '主机';
    if (id == 'relay') return '中继';
    if (id.startsWith('client:')) return '客户端';
    return id;
  }

  String _formatBytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _AgentPanel extends StatelessWidget {
  const _AgentPanel({required this.manager});

  final HostServiceManager manager;

  @override
  Widget build(BuildContext context) {
    final snapshot = manager.snapshot;
    if (manager.mode == HostRuntimeMode.relay) {
      return _desktopScrollPage(
        maxWidth: 900,
        builder: (context, width) => SizedBox(
          width: width,
          child: const ShadAlert(
            icon: Icon(LucideIcons.network),
            title: Text('中继模式不启动本地 Agent'),
            description: Text('中继只负责转发已配对客户端与电脑主机之间的 WebSocket 消息。'),
          ),
        ),
      );
    }
    return _desktopScrollPage(
      maxWidth: 900,
      builder: (context, width) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Agent 状态', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text(
            '状态只说明 RemoteAISync 的本机接入路径可用。桌面端创建的会话可能出现在历史中，但当前不会单独探测桌面程序。',
            style: TextStyle(color: shadMuted),
          ),
          const SizedBox(height: 18),
          _AgentDetailCard(
            name: 'OpenCode',
            description: '通过本地服务读取会话、消息、工具调用和文件附件。',
            agentId: 'opencode',
            version: snapshot.openCodeVersion,
            status: snapshot.agentStatuses['opencode'],
            hostReachable: snapshot.reachable,
          ),
          const SizedBox(height: 12),
          _AgentDetailCard(
            name: 'Codex CLI / app-server',
            description:
                'RemoteAISync 通过本机 Codex CLI 启动 app-server 管理会话；历史线程可能来自 CLI 或桌面端，当前不检测 Codex Desktop 是否运行。',
            agentId: 'codex',
            version: snapshot.codexVersion,
            status: snapshot.agentStatuses['codex'],
            extra: snapshot.codexHookRuntimeReady
                ? '审批 Hook 运行中'
                : '审批 Hook 未启用',
            hostReachable: snapshot.reachable,
          ),
          const SizedBox(height: 12),
          _AgentDetailCard(
            name: 'Claude Code CLI + 本地记录',
            description:
                '新建和远程续聊由 Claude Code CLI 执行，同时扫描本机 JSONL 会话记录；不单独读取 Desktop 会话列表。',
            agentId: 'claude',
            status: snapshot.agentStatuses['claude'],
            extra: 'JSONL 会话同步',
            hostReachable: snapshot.reachable,
          ),
          const SizedBox(height: 12),
          _AgentDetailCard(
            name: 'Claude Code Desktop',
            description:
                'RemoteAISync 当前不单独接入 Desktop 会话列表或检测桌面进程；可通过 CLI 适配器管理的会话仍显示在上方。',
            agentId: 'claude',
            status: AgentRuntimeStatus(
              id: 'claude-desktop',
              availability: AgentAvailability.unsupported,
              detail: '没有独立的 Claude Code Desktop 适配器。',
            ),
            statusLabel: '未单独接入',
            hostReachable: snapshot.reachable,
          ),
          const SizedBox(height: 18),
          SizedBox(width: width, child: const _AgentInstallLinks()),
        ],
      ),
    );
  }
}

class _AgentInstallLinks extends StatelessWidget {
  const _AgentInstallLinks();

  static const _links = [
    (
      id: 'opencode',
      brandId: 'opencode',
      name: 'OpenCode',
      description: '安装或查看 OpenCode 官方下载页面',
      url: 'https://opencode.ai/download',
    ),
    (
      id: 'codex',
      brandId: 'codex',
      name: 'Codex CLI',
      description: '查看 Codex CLI 官方安装与使用文档',
      url: 'https://developers.openai.com/codex/cli/',
    ),
    (
      id: 'codex-desktop',
      brandId: 'codex',
      name: 'Codex Desktop',
      description: '官方桌面应用；RemoteAISync 当前不单独检测其运行状态',
      url: 'https://openai.com/codex/',
    ),
    (
      id: 'claude',
      brandId: 'claude',
      name: 'Claude Code CLI',
      description: '查看 Claude Code CLI 官方安装文档',
      url: 'https://code.claude.com/docs/en/overview',
    ),
    (
      id: 'claude-desktop',
      brandId: 'claude',
      name: 'Claude Code Desktop',
      description: '官方桌面应用；RemoteAISync 当前不单独检测其运行状态',
      url: 'https://code.claude.com/docs/en/desktop',
    ),
  ];

  Future<void> _open(BuildContext context, String name, String url) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ShadToaster.of(context).show(ShadToast(title: Text('无法打开 $name 的安装页面')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadCard(
      padding: const EdgeInsets.all(18),
      leading: const Icon(LucideIcons.download, size: 20),
      title: const Text('快速安装支持的 Agent'),
      description: const Text('当前电脑未安装某个 Agent 时，可从官方页面完成安装。'),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final link in _links)
              ShadButton.outline(
                key: Key('install-agent-${link.id}'),
                onPressed: () => _open(context, link.name, link.url),
                leading: AgentBrandMark(agentId: link.brandId, size: 16),
                child: Text(link.name),
              ),
          ],
        ),
      ),
    );
  }
}

class _AgentDetailCard extends StatelessWidget {
  const _AgentDetailCard({
    required this.name,
    required this.description,
    required this.agentId,
    this.version,
    this.status,
    required this.hostReachable,
    this.extra,
    this.statusLabel,
  });

  final String name;
  final String description;
  final String agentId;
  final String? version;
  final AgentRuntimeStatus? status;
  final bool hostReachable;
  final String? extra;
  final String? statusLabel;

  @override
  Widget build(BuildContext context) {
    final available = status?.isAvailable ?? (version?.isNotEmpty == true);
    return ShadCard(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          ShadBadge.secondary(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(10),
            child: Opacity(
              opacity: available ? 1 : .55,
              child: AgentBrandMark(agentId: agentId, size: 22),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ShadBadge.secondary(
                backgroundColor: available
                    ? shadSuccess.withValues(alpha: .1)
                    : shadMutedBackground,
                foregroundColor: available ? shadSuccess : shadMuted,
                child: Text(
                  statusLabel ??
                      _agentBadgeText(
                        reachable: hostReachable,
                        status: status,
                        version: version,
                      ),
                ),
              ),
              if (hostReachable && status?.detail != null) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: 210,
                  child: ShadAlert(
                    icon: const Icon(LucideIcons.info, size: 14),
                    title: const SizedBox.shrink(),
                    description: Text(
                      status!.detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              if (extra != null) ...[
                const SizedBox(height: 6),
                Text(
                  extra!,
                  style: const TextStyle(fontSize: 11, color: shadMuted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

String _agentBadgeText({
  required bool reachable,
  required AgentRuntimeStatus? status,
  required String? version,
}) {
  if (!reachable) return '等待主机';
  if (status == null) {
    return version?.isNotEmpty == true ? version! : '状态未知';
  }
  return switch (status.availability) {
    AgentAvailability.available =>
      status.version?.isNotEmpty == true ? status.version! : '可用',
    AgentAvailability.degraded => '连接异常',
    AgentAvailability.notInstalled => '未安装',
    AgentAvailability.unavailable => '探测不到',
    AgentAvailability.unsupported => '未接入',
    AgentAvailability.unknown => '状态未知',
  };
}

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({required this.manager});

  final HostServiceManager manager;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  late final TextEditingController _portController;
  late final TextEditingController _urlController;
  late final TextEditingController _roomController;
  late final TextEditingController _clientTokenController;
  late final TextEditingController _hostTokenController;
  late final TextEditingController _publicHostController;
  late final TextEditingController _publicOriginController;
  late bool _relayTunnelEnabled;
  late bool _publicHostEnabled;
  String? _registrationCode;
  String? _registrationId;
  String? _registrationExpiresAt;

  HostServiceManager get manager => widget.manager;

  @override
  void initState() {
    super.initState();
    _relayTunnelEnabled = manager.relayUrl.isNotEmpty;
    _publicHostEnabled = manager.publicHostEnabled;
    _portController = TextEditingController(text: '${manager.relayPort}');
    _urlController = TextEditingController(text: manager.relayUrl);
    _roomController = TextEditingController(text: manager.relayRoom);
    _clientTokenController = TextEditingController(
      text: manager.relayClientToken,
    );
    _hostTokenController = TextEditingController(text: manager.relayHostToken);
    _publicHostController = TextEditingController(text: manager.publicHostUrl);
    _publicOriginController = TextEditingController(
      text: manager.publicAllowedOrigin,
    );
  }

  @override
  void dispose() {
    _portController.dispose();
    _urlController.dispose();
    _roomController.dispose();
    _clientTokenController.dispose();
    _hostTokenController.dispose();
    _publicHostController.dispose();
    _publicOriginController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _desktopScrollPage(
      maxWidth: 900,
      builder: (context, width) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const SizedBox(height: 18),
          SizedBox(
            width: width,
            child: _Panel(
              icon: manager.mode == HostRuntimeMode.host
                  ? LucideIcons.laptop
                  : LucideIcons.network,
              title: manager.mode == HostRuntimeMode.host
                  ? '电脑主机配置'
                  : '中继服务器配置',
              subtitle: manager.mode == HostRuntimeMode.host
                  ? '管理本机 Agent 服务及可选中继隧道。'
                  : '配置供电脑主机与手机客户端连接的中继入口。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (manager.mode == HostRuntimeMode.host) ...[
                    _ConfigSummaryRow(
                      label: '本机服务端口',
                      value: '${manager.port}',
                      icon: LucideIcons.radio,
                    ),
                    const ShadSeparator.horizontal(),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '异地连接 / 自建中继',
                                style: TextStyle(fontWeight: FontWeight.w500),
                              ),
                              SizedBox(height: 3),
                              Text(
                                '仅本机或同一 Wi-Fi 使用时无需开启。',
                                style: TextStyle(
                                  color: shadMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          fit: FlexFit.loose,
                          child: SizedBox(
                            width: 132,
                            child: ShadTabs<bool>(
                              key: const Key('desktop-relay-tunnel-switch'),
                              value: _relayTunnelEnabled,
                              gap: 0,
                              onChanged: (enabled) =>
                                  setState(() => _relayTunnelEnabled = enabled),
                              tabs: const [
                                ShadTab<bool>(
                                  value: false,
                                  content: SizedBox.shrink(),
                                  width: 66,
                                  child: Text('关闭'),
                                ),
                                ShadTab<bool>(
                                  value: true,
                                  content: SizedBox.shrink(),
                                  width: 66,
                                  child: Text('启用'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: _relayTunnelEnabled
                          ? Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Column(
                                children: [
                                  _ConfigInput(
                                    controller: _urlController,
                                    id: 'desktop-relay-url',
                                    label: '中继服务器地址',
                                    placeholder: 'wss://relay.example.com',
                                  ),
                                  const SizedBox(height: 10),
                                  _ConfigInput(
                                    controller: _roomController,
                                    id: 'desktop-relay-room',
                                    label: '主机专属房间 ID（由中继分配）',
                                    readOnly: true,
                                  ),
                                  const SizedBox(height: 10),
                                  _ConfigInput(
                                    controller: _hostTokenController,
                                    id: 'desktop-relay-host-secret',
                                    label: '一次性主机注册码（由中继端生成）',
                                    secret: true,
                                  ),
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ] else ...[
                    _ConfigInput(
                      controller: _portController,
                      id: 'desktop-relay-port',
                      label: '监听端口',
                      numeric: true,
                    ),
                    const SizedBox(height: 10),
                    _ConfigInput(
                      controller: _clientTokenController,
                      id: 'desktop-relay-client-secret',
                      label: '中继管理密钥（仅保留在中继端）',
                      secret: true,
                    ),
                    const SizedBox(height: 12),
                    ShadButton.outline(
                      key: const Key('issue-relay-registration-code'),
                      onPressed: manager.busy ? null : _issueRegistrationCode,
                      leading: const Icon(LucideIcons.keyRound, size: 15),
                      child: const Text('创建一次性主机注册码'),
                    ),
                    if (_registrationCode != null) ...[
                      const SizedBox(height: 10),
                      SelectableText(_registrationCode!),
                      const SizedBox(height: 4),
                      Text(
                        '有效期至 ${_registrationExpiresAt ?? '10 分钟内'}，仅交给需要注册的电脑主机。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      ShadButton.ghost(
                        onPressed: _registrationId == null
                            ? null
                            : _revokeRegistrationCode,
                        child: const Text('撤销注册码'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '公网请通过 TLS 反向代理提供 WSS。中继只转发 RemoteAISync WebSocket 消息。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '公网主机 WSS',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            SizedBox(height: 3),
                            Text(
                              '适合 Ubuntu/VPS 直接运行 Agent，由反向代理提供 HTTPS/WSS。',
                              style: TextStyle(color: shadMuted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        fit: FlexFit.loose,
                        child: SizedBox(
                          width: 132,
                          child: ShadTabs<bool>(
                            key: const Key('desktop-public-host-switch'),
                            value: _publicHostEnabled,
                            gap: 0,
                            onChanged: (enabled) =>
                                setState(() => _publicHostEnabled = enabled),
                            tabs: const [
                              ShadTab<bool>(
                                value: false,
                                content: SizedBox.shrink(),
                                width: 66,
                                child: Text('关闭'),
                              ),
                              ShadTab<bool>(
                                value: true,
                                content: SizedBox.shrink(),
                                width: 66,
                                child: Text('启用'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _publicHostEnabled
                        ? Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Column(
                              children: [
                                _ConfigInput(
                                  controller: _publicHostController,
                                  id: 'desktop-public-host-url',
                                  label: '公网主机地址',
                                  placeholder: 'wss://host.example.com/ws',
                                ),
                                const SizedBox(height: 10),
                                _ConfigInput(
                                  controller: _publicOriginController,
                                  id: 'desktop-public-host-origin',
                                  label: '浏览器 Origin（可选）',
                                  placeholder: 'https://client.example.com',
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      ShadButton(
                        onPressed:
                            manager.busy ||
                                (manager.snapshot.reachable &&
                                    !manager.ownsProcess &&
                                    manager.mode == HostRuntimeMode.relay)
                            ? null
                            : _startSelectedMode,
                        leading: Icon(
                          manager.snapshot.reachable
                              ? LucideIcons.replace
                              : LucideIcons.play,
                          size: 15,
                        ),
                        child: Text(
                          !manager.snapshot.reachable
                              ? '应用并启动'
                              : manager.ownsProcess
                              ? '保存并重启'
                              : '服务由外部终端运行',
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (manager.snapshot.reachable &&
                          (manager.ownsProcess ||
                              (manager.mode == HostRuntimeMode.host &&
                                  manager.snapshot.pairingToken != null)))
                        ShadButton.outline(
                          onPressed: manager.busy ? null : manager.stop,
                          leading: const Icon(LucideIcons.square, size: 15),
                          child: const Text('停止当前服务'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: width,
            child: _Panel(
              icon: LucideIcons.shieldCheck,
              title: manager.mode == HostRuntimeMode.host ? '本地优先' : '中继安全',
              subtitle: manager.mode == HostRuntimeMode.host
                  ? '同一 Wi-Fi 下直接配对即可；异地访问才需要配置中继。'
                  : '中继服务器只转发配对会话，不读取 Agent 项目文件。',
              child: Text(
                manager.mode == HostRuntimeMode.host
                    ? '开启自建中继后，会话数据经过该服务器转发。公网服务请使用 WSS/TLS，并分别保管访问密钥与主机配对令牌。'
                    : '公网部署请使用 WSS/TLS。手机客户端访问密钥与主机注册密钥必须分开设置。',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startSelectedMode() async {
    FocusScope.of(context).unfocus();
    final relayPort = int.tryParse(_portController.text.trim()) ?? 0;
    if (manager.mode == HostRuntimeMode.relay &&
        (relayPort < 1 || relayPort > 65535)) {
      _showMessage('端口必须是 1 到 65535 之间的数字。');
      return;
    }
    try {
      await manager.configureAndStart(
        mode: manager.mode,
        relayPort: relayPort > 0 ? relayPort : manager.relayPort,
        relayUrl: _relayTunnelEnabled ? _urlController.text : '',
        relayRoom: _roomController.text,
        relayClientToken: _clientTokenController.text,
        relayHostToken: _hostTokenController.text,
        publicHostUrl: _publicHostController.text,
        publicAllowedOrigin: _publicOriginController.text,
        publicHostEnabled: _publicHostEnabled,
      );
      if (manager.mode == HostRuntimeMode.host && _relayTunnelEnabled) {
        _roomController.text = manager.relayRoom;
        _clientTokenController.text = manager.relayClientToken;
        _hostTokenController.clear();
      }
    } catch (error) {
      _showMessage(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _issueRegistrationCode() async {
    try {
      final issued = await manager.issueRelayRegistrationCode();
      if (!mounted) return;
      setState(() {
        _registrationCode = issued['code'];
        _registrationId = issued['id'];
        _registrationExpiresAt = issued['expiresAt'];
      });
    } catch (error) {
      _showMessage(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _revokeRegistrationCode() async {
    final id = _registrationId;
    if (id == null) return;
    try {
      await manager.revokeRelayRegistrationCode(id);
      if (!mounted) return;
      setState(() {
        _registrationCode = null;
        _registrationId = null;
        _registrationExpiresAt = null;
      });
    } catch (error) {
      _showMessage(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ShadToaster.of(context).show(ShadToast(title: Text(message)));
  }
}

class _ConfigSummaryRow extends StatelessWidget {
  const _ConfigSummaryRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        _DesktopIconTile(icon: icon, size: 28, iconSize: 14),
        const SizedBox(width: 9),
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(color: shadMuted)),
      ],
    ),
  );
}

class _ConfigInput extends StatelessWidget {
  const _ConfigInput({
    required this.controller,
    required this.id,
    required this.label,
    this.placeholder,
    this.secret = false,
    this.numeric = false,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final String id;
  final String label;
  final String? placeholder;
  final bool secret;
  final bool numeric;
  final bool readOnly;

  @override
  Widget build(BuildContext context) => ShadInputFormField(
    id: id,
    controller: controller,
    label: Text(label),
    placeholder: placeholder == null ? null : Text(placeholder!),
    obscureText: secret,
    readOnly: readOnly,
    autocorrect: false,
    enableSuggestions: !secret,
    keyboardType: numeric ? TextInputType.number : TextInputType.text,
  );
}

class _ConnectionInfoPanel extends StatelessWidget {
  const _ConnectionInfoPanel({
    required this.snapshot,
    required this.port,
    required this.mode,
    required this.relayUrl,
    required this.relayRoom,
    required this.relayClientToken,
    required this.relayHostToken,
    required this.onCopy,
    required this.onCreatePairingInvite,
    required this.onResolvePairing,
    required this.onRevokeDevice,
  });

  final HostServiceSnapshot snapshot;
  final int port;
  final HostRuntimeMode mode;
  final String relayUrl;
  final String relayRoom;
  final String relayClientToken;
  final String relayHostToken;
  final void Function(String value, String label) onCopy;
  final Future<void> Function() onCreatePairingInvite;
  final Future<void> Function(String id, {required bool approve})
  onResolvePairing;
  final Future<void> Function(String id) onRevokeDevice;

  @override
  Widget build(BuildContext context) {
    return _desktopScrollPage(
      maxWidth: 900,
      builder: (context, width) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('连接信息', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            mode == HostRuntimeMode.host
                ? '在手机上扫描主机生成的一次性配对二维码，首次连接需由主机批准。'
                : '将中继地址、客户端密钥配置到手机；主机注册密钥仅交给电脑主机。',
            style: TextStyle(color: shadMuted),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: width,
            child: ShadCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  if (mode == HostRuntimeMode.relay) ...[
                    _CopyValueRow(
                      label: '监听端口',
                      value: '$port',
                      onCopy: onCopy,
                    ),
                    const ShadSeparator.horizontal(),
                    _CopyValueRow(
                      label: '客户端密钥',
                      value: _maskToken(relayClientToken),
                      copyValue: relayClientToken,
                      onCopy: onCopy,
                    ),
                    const ShadSeparator.horizontal(),
                    _CopyValueRow(
                      label: '主机注册密钥',
                      value: _maskToken(relayHostToken),
                      copyValue: relayHostToken,
                      onCopy: onCopy,
                    ),
                    const ShadSeparator.horizontal(),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '局域网可使用电脑 IP 与此端口连接。公网地址由 TLS 反向代理提供；中继不使用主机配对令牌。',
                        style: TextStyle(color: shadMuted, fontSize: 12),
                      ),
                    ),
                  ] else ...[
                    if (snapshot.lanAddresses.isEmpty)
                      _CopyValueRow(label: '局域网 IP', value: '未发现局域网 IPv4 地址')
                    else
                      for (
                        var index = 0;
                        index < snapshot.lanAddresses.length;
                        index++
                      ) ...[
                        _CopyValueRow(
                          label: snapshot.lanAddresses.length == 1
                              ? '局域网 IP'
                              : '局域网 IP ${index + 1}',
                          value: snapshot.lanAddresses[index],
                          onCopy: onCopy,
                        ),
                        const ShadSeparator.horizontal(),
                      ],
                    _CopyValueRow(
                      label: '主机端口',
                      value: '$port',
                      onCopy: onCopy,
                    ),
                    const ShadSeparator.horizontal(),
                    if (snapshot.publicHostEnabled &&
                        snapshot.publicHostUrl?.isNotEmpty == true) ...[
                      _CopyValueRow(
                        label: '公网主机 WSS',
                        value: snapshot.publicHostUrl!,
                        onCopy: onCopy,
                      ),
                      const ShadSeparator.horizontal(),
                    ],
                    if (relayUrl.isNotEmpty) ...[
                      const ShadSeparator.horizontal(),
                      _CopyValueRow(
                        label: '中继状态',
                        value: snapshot.relayConnected ? '已连接' : '连接中',
                      ),
                      const ShadSeparator.horizontal(),
                      _CopyValueRow(
                        label: '中继地址',
                        value: relayUrl,
                        onCopy: onCopy,
                      ),
                      const ShadSeparator.horizontal(),
                      _CopyValueRow(
                        label: '房间 ID',
                        value: snapshot.relayRoom ?? relayRoom,
                        onCopy: onCopy,
                      ),
                      const ShadSeparator.horizontal(),
                      _CopyValueRow(
                        label: '手机客户端房间密钥',
                        value: snapshot.relayClientToken == null
                            ? '等待中继签发'
                            : _maskToken(snapshot.relayClientToken!),
                        copyValue: snapshot.relayClientToken,
                        onCopy: onCopy,
                      ),
                    ],
                    const ShadSeparator.horizontal(),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ShadButton(
                        leading: const Icon(LucideIcons.qrCode, size: 16),
                        onPressed: onCreatePairingInvite,
                        child: const Text('生成手机配对二维码'),
                      ),
                    ),
                    if (snapshot.pairingInvite != null) ...[
                      const SizedBox(height: 16),
                      _CopyValueRow(
                        label: '手机配对码',
                        value: snapshot.pairingInvite!,
                        copyValue: snapshot.pairingInvite,
                        onCopy: onCopy,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: QrImageView(
                          data: _pairingCode(),
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text(
                          '邀请仅可使用一次，5 分钟后过期。扫码后请在电脑端批准设备。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: shadMuted, fontSize: 12),
                        ),
                      ),
                    ],
                    if (snapshot.pendingPairings.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('待批准设备'),
                      ),
                      for (final device in snapshot.pendingPairings)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(LucideIcons.smartphone),
                          title: Text(device['name'] ?? '手机设备'),
                          subtitle: const Text('首次配对请求'),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              ShadButton(
                                onPressed: () => onResolvePairing(
                                  device['id']!,
                                  approve: true,
                                ),
                                child: const Text('批准'),
                              ),
                              ShadButton.destructive(
                                onPressed: () => onResolvePairing(
                                  device['id']!,
                                  approve: false,
                                ),
                                child: const Text('拒绝'),
                              ),
                            ],
                          ),
                        ),
                    ],
                    if (snapshot.pairedDevices.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('已配对设备'),
                      ),
                      for (final device in snapshot.pairedDevices)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(LucideIcons.smartphone),
                          title: Text(device['name'] ?? '手机设备'),
                          trailing: ShadButton.ghost(
                            onPressed: () => onRevokeDevice(device['id']!),
                            child: const Text('撤销'),
                          ),
                        ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _maskToken(String value) {
    if (value.isEmpty) return '未配置';
    if (value.length < 12) return '••••••••';
    return '${value.substring(0, 6)}••••${value.substring(value.length - 6)}';
  }

  String _pairingCode() {
    final relayToken = snapshot.relayClientToken;
    final profile = <String, Object?>{
      'version': 1,
      'invite': snapshot.pairingInvite,
      'port': port,
      'lanAddresses': snapshot.lanAddresses,
      if (snapshot.publicHostEnabled &&
          snapshot.publicHostUrl?.isNotEmpty == true)
        'direct': {'url': snapshot.publicHostUrl},
      if (relayUrl.isNotEmpty &&
          snapshot.relayRoom != null &&
          relayToken != null)
        'relay': {
          'url': relayUrl,
          'room': snapshot.relayRoom,
          'token': relayToken,
        },
    };
    final payload = base64Url.encode(utf8.encode(jsonEncode(profile)));
    return 'remoteaisync://pair?data=${Uri.encodeQueryComponent(payload)}';
  }
}

class _CopyValueRow extends StatelessWidget {
  const _CopyValueRow({
    required this.label,
    required this.value,
    this.copyValue,
    this.onCopy,
  });

  final String label;
  final String value;
  final String? copyValue;
  final void Function(String value, String label)? onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
          ),
        ),
        Tooltip(
          message: '复制$label',
          child: ShadIconButton.ghost(
            onPressed: copyValue == null || onCopy == null
                ? null
                : () => onCopy!(copyValue!, label),
            icon: const Icon(LucideIcons.copy, size: 16),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShadCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _DesktopIconTile(icon: icon),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 15),
          child,
        ],
      ),
    );
  }
}

Widget _desktopScrollPage({
  required double maxWidth,
  required Widget Function(BuildContext context, double width) builder,
}) {
  return SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(30, 26, 30, 30),
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) =>
                builder(context, constraints.maxWidth),
          ),
        ),
      ),
    ),
  );
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: shadMuted),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
        ),
      ],
    );
  }
}

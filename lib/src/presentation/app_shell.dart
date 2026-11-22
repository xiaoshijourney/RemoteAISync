import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../application/demo_controller.dart';
import '../application/saved_connection_profile.dart';
import '../domain/models.dart';
import 'components/glass_surface.dart';
import 'screens/connection_screen.dart';
import 'screens/files_screen.dart';
import 'screens/session_screen.dart';
import 'shad_theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({required this.controller, super.key});

  final DemoController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _keyboardOpen = false;
  double _viewportWidth = 0;
  final PageStorageBucket _pageStorageBucket = PageStorageBucket();
  late final Future<SavedConnectionProfile?> _savedConnection;
  late Widget _pageStackContent;
  late final List<Widget?> _pageWidgets = [
    SessionScreen(controller: widget.controller),
    null,
    null,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _savedConnection = SavedConnectionProfile.restore(widget.controller);
    unawaited(_savedConnection);
    _pageStackContent = _buildPageStackContent();
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      final view = views.first;
      _viewportWidth = view.physicalSize.width / view.devicePixelRatio;
      _keyboardOpen = view.viewInsets.bottom > 0;
    }
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final width = view.physicalSize.width / view.devicePixelRatio;
    final keyboardOpen = view.viewInsets.bottom > 0;
    if (_viewportWidth == width && _keyboardOpen == keyboardOpen) return;
    setState(() {
      _viewportWidth = width;
      _keyboardOpen = keyboardOpen;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _viewportWidth >= 900;
    final pageStack = _pageStack();
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: desktop
            ? _DesktopWorkspace(
                controller: widget.controller,
                selectedIndex: _selectedIndex,
                onSelected: _selectPage,
                child: pageStack,
              )
            : _MobileWorkspace(
                controller: widget.controller,
                selectedIndex: _selectedIndex,
                keyboardOpen: _keyboardOpen,
                onSelected: _selectPage,
                child: pageStack,
              ),
      ),
      bottomNavigationBar: desktop || _keyboardOpen
          ? null
          : AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => _MobileNavigation(
                selectedIndex: _selectedIndex,
                pendingCount: _pendingCount,
                onSelected: _selectPage,
              ),
            ),
    );
  }

  int get _pendingCount =>
      widget.controller.forms.length + widget.controller.permissions.length;

  void _selectPage(int index) {
    if (_selectedIndex == index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _pageWidgets[index] ??= _createPage(index);
    setState(() {
      _selectedIndex = index;
      _pageStackContent = _buildPageStackContent();
    });
  }

  Widget _createPage(int index) => switch (index) {
    0 => SessionScreen(controller: widget.controller),
    1 => FilesScreen(controller: widget.controller),
    2 => ConnectionScreen(
      controller: widget.controller,
      savedConnection: _savedConnection,
    ),
    _ => throw RangeError.index(index, _pageWidgets),
  };

  Widget _buildPageStackContent() => PageStorage(
    bucket: _pageStorageBucket,
    child: IndexedStack(
      index: _selectedIndex,
      sizing: StackFit.expand,
      children: [
        for (var index = 0; index < _pageWidgets.length; index++)
          TickerMode(
            enabled: index == _selectedIndex,
            child: KeyedSubtree(
              key: ValueKey('workspace-page-$index'),
              child: _pageWidgets[index] ?? const SizedBox.shrink(),
            ),
          ),
      ],
    ),
  );

  Widget _pageStack() => LayoutBuilder(
    builder: (context, constraints) {
      // Android can report a zero-sized viewport for one frame while the
      // Flutter surface is attached. Do not build the page stack against that
      // transient constraint; children such as ShadInput otherwise calculate
      // negative widths before the first real metrics update.
      if (!constraints.hasBoundedWidth ||
          !constraints.hasBoundedHeight ||
          constraints.maxWidth <= 0 ||
          constraints.maxHeight <= 0) {
        return const Center(
          child: SizedBox(width: 120, child: ShadProgress(minHeight: 3)),
        );
      }
      final width = constraints.maxWidth.clamp(1.0, 1440.0);
      return Center(
        child: SizedBox(
          width: width,
          height: constraints.maxHeight.clamp(1.0, double.infinity),
          // Preserve the page subtree while Scaffold resizes for the IME.
          // Only the viewport's render layout should run through keyboard frames.
          child: _pageStackContent,
        ),
      );
    },
  );
}

class _DesktopWorkspace extends StatelessWidget {
  const _DesktopWorkspace({
    required this.controller,
    required this.selectedIndex,
    required this.onSelected,
    required this.child,
  });

  final DemoController controller;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 236,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
            child: Column(
              children: [
                _BrandIdentity(),
                const SizedBox(height: 22),
                AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) => _NavigationItems(
                    selectedIndex: selectedIndex,
                    pendingCount:
                        controller.forms.length + controller.permissions.length,
                    onSelected: onSelected,
                    vertical: true,
                  ),
                ),
                const Spacer(),
                AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) =>
                      _HostStatusPanel(controller: controller),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 14, 14),
            child: Column(
              children: [
                _DesktopTopBar(
                  controller: controller,
                  selectedIndex: selectedIndex,
                ),
                AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) =>
                      !controller.isDemo && !controller.isLive
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: _ConnectionBanner(
                            controller: controller,
                            onPressed: () => onSelected(2),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    final count =
                        controller.forms.length + controller.permissions.length;
                    return selectedIndex != 0 && count > 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: _PendingBanner(
                              count: count,
                              onPressed: () => onSelected(0),
                            ),
                          )
                        : const SizedBox.shrink();
                  },
                ),
                const SizedBox(height: 10),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileWorkspace extends StatelessWidget {
  const _MobileWorkspace({
    required this.controller,
    required this.selectedIndex,
    required this.keyboardOpen,
    required this.onSelected,
    required this.child,
  });

  final DemoController controller;
  final int selectedIndex;
  final bool keyboardOpen;
  final ValueChanged<int> onSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!keyboardOpen) _MobileTopBar(controller: controller),
        if (!keyboardOpen)
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) => !controller.isDemo && !controller.isLive
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: _ConnectionBanner(
                      controller: controller,
                      onPressed: () => onSelected(2),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        if (!keyboardOpen && selectedIndex != 0)
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final count =
                  controller.forms.length + controller.permissions.length;
              return count > 0
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: _PendingBanner(
                        count: count,
                        onPressed: () => onSelected(0),
                      ),
                    )
                  : const SizedBox.shrink();
            },
          ),
        Expanded(child: child),
      ],
    );
  }
}

class _BrandIdentity extends StatelessWidget {
  const _BrandIdentity({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: shadPrimary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(LucideIcons.refreshCw, color: Colors.white, size: 17),
      ),
      SizedBox(width: compact ? 8 : 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'RemoteAISync',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: compact ? 14 : 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (!compact)
              Text('开发工作台', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ],
  );
}

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({required this.controller, required this.selectedIndex});

  final DemoController controller;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) => GlassSurface(
    radius: 20,
    blur: 12,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    child: Row(
      children: [
        Text(
          const ['会话', '文件', '连接'][selectedIndex],
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) => _ConnectionStatus(controller: controller),
        ),
      ],
    ),
  );
}

class _MobileTopBar extends StatelessWidget {
  const _MobileTopBar({required this.controller});

  final DemoController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: GlassSurface(
      radius: 20,
      blur: 12,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Expanded(child: _BrandIdentity(compact: true)),
          const SizedBox(width: 8),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) =>
                _ConnectionStatus(controller: controller, compact: true),
          ),
        ],
      ),
    ),
  );
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.controller, this.compact = false});

  final DemoController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final status = controller.connectionStatus;
    final color = switch (status) {
      HostConnectionStatus.connected => shadSuccess,
      HostConnectionStatus.connecting => shadWarning,
      HostConnectionStatus.error => shadError,
      HostConnectionStatus.disconnected => shadMuted,
    };
    final statusLabel = controller.isDemo
        ? '本地演示'
        : switch (status) {
            HostConnectionStatus.connected => '主机在线',
            HostConnectionStatus.connecting => '正在连接',
            HostConnectionStatus.error => '连接异常',
            HostConnectionStatus.disconnected => '未连接',
          };
    final route = controller.connectionRoute;
    final label = status == HostConnectionStatus.connected && route != null
        ? '$statusLabel · $route'
        : statusLabel;
    return ShadBadge.secondary(
      backgroundColor: color.withValues(alpha: .1),
      foregroundColor: color,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 11,
        vertical: compact ? 6 : 7,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            status == HostConnectionStatus.connected
                ? LucideIcons.circleCheck
                : status == HostConnectionStatus.error
                ? LucideIcons.circleAlert
                : LucideIcons.circle,
            size: 12,
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

class _HostStatusPanel extends StatelessWidget {
  const _HostStatusPanel({required this.controller});

  final DemoController controller;

  @override
  Widget build(BuildContext context) {
    final agentCount = controller.agentStatuses.values
        .where((agent) => agent.isAvailable)
        .length;
    final clientCount = controller.connectedClientCount;
    return GlassSurface(
      radius: 20,
      blur: 10,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.activity, size: 15, color: shadPrimary),
              const SizedBox(width: 7),
              Text(
                '主机状态',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StatusLine(label: '可用 Agent', value: '$agentCount'),
          const SizedBox(height: 7),
          _StatusLine(label: '已连接客户端', value: clientCount?.toString() ?? '—'),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, .2),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: Text(
          value,
          key: ValueKey(value),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: shadInk,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

class _NavigationItems extends StatelessWidget {
  const _NavigationItems({
    required this.selectedIndex,
    required this.pendingCount,
    required this.onSelected,
    required this.vertical,
  });

  final int selectedIndex;
  final int pendingCount;
  final ValueChanged<int> onSelected;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    const labels = ['会话', '文件', '连接'];
    const icons = [
      LucideIcons.messagesSquare,
      LucideIcons.folder,
      LucideIcons.network,
    ];
    return vertical
        ? Column(
            children: [
              for (var index = 0; index < labels.length; index++)
                _NavigationItem(
                  label: labels[index],
                  icon: icons[index],
                  selected: selectedIndex == index,
                  pendingCount: index == 0 ? pendingCount : 0,
                  vertical: true,
                  onPressed: () => onSelected(index),
                ),
            ],
          )
        : Row(
            children: [
              for (var index = 0; index < labels.length; index++)
                Expanded(
                  child: _NavigationItem(
                    label: labels[index],
                    icon: icons[index],
                    selected: selectedIndex == index,
                    pendingCount: index == 0 ? pendingCount : 0,
                    vertical: false,
                    onPressed: () => onSelected(index),
                  ),
                ),
            ],
          );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.pendingCount,
    required this.vertical,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final int pendingCount;
  final bool vertical;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: vertical ? 5 : 0),
    child: ShadButton.raw(
      key: Key('navigation-$label'),
      variant: selected ? ShadButtonVariant.secondary : ShadButtonVariant.ghost,
      width: vertical ? 208 : null,
      height: vertical ? 42 : 40,
      padding: EdgeInsets.symmetric(horizontal: vertical ? 12 : 8),
      mainAxisAlignment: vertical
          ? MainAxisAlignment.start
          : MainAxisAlignment.center,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: vertical ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(icon, size: 17),
          if (vertical) const SizedBox(width: 10),
          if (vertical || MediaQuery.sizeOf(context).width >= 390) ...[
            if (!vertical) const SizedBox(width: 5),
            Text(label),
          ],
          if (pendingCount > 0) ...[
            const SizedBox(width: 8),
            _CountPill(count: pendingCount),
          ],
        ],
      ),
    ),
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 180),
    transitionBuilder: (child, animation) => ScaleTransition(
      scale: animation,
      child: FadeTransition(opacity: animation, child: child),
    ),
    child: count == 0
        ? const SizedBox.shrink()
        : ShadBadge.destructive(
            key: ValueKey(count),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text('$count'),
          ),
  );
}

class _MobileNavigation extends StatelessWidget {
  const _MobileNavigation({
    required this.selectedIndex,
    required this.pendingCount,
    required this.onSelected,
  });

  final int selectedIndex;
  final int pendingCount;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: SafeArea(
      top: false,
      child: GlassSurface(
        radius: 20,
        blur: 12,
        padding: const EdgeInsets.all(4),
        child: _NavigationItems(
          selectedIndex: selectedIndex,
          pendingCount: pendingCount,
          onSelected: onSelected,
          vertical: false,
        ),
      ),
    ),
  );
}

class _PendingBanner extends StatelessWidget {
  const _PendingBanner({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ShadAlert(
    icon: const Icon(LucideIcons.bellRing, color: shadWarning),
    title: Text('Agent 有 $count 项问题或操作待处理'),
    trailing: ShadButton.ghost(
      onPressed: onPressed,
      leading: const Icon(LucideIcons.arrowRight, size: 15),
      child: const Text('查看'),
    ),
  );
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.controller, required this.onPressed});

  final DemoController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final waiting = controller.pairingState == PairingState.waitingApproval;
    final reconnecting =
        controller.transportState == TransportState.reconnecting;
    final title = waiting
        ? '等待电脑批准此设备'
        : reconnecting
        ? '正在恢复电脑连接'
        : '尚未连接电脑主机';
    final description = waiting
        ? '配对请求已经发出，批准后会自动同步 Agent 状态。'
        : reconnecting
        ? '连接中断，RemoteAISync 会自动尝试恢复当前路线。'
        : controller.connectionError ?? '连接主机后才能查看会话、文件和待处理请求。';
    return ShadAlert(
      icon: Icon(
        waiting || reconnecting ? LucideIcons.clock3 : LucideIcons.link,
        color: waiting || reconnecting ? shadWarning : shadMuted,
      ),
      title: Text(title),
      description: Text(description),
      trailing: ShadButton.ghost(
        onPressed: onPressed,
        leading: const Icon(LucideIcons.arrowRight, size: 15),
        child: const Text('打开连接'),
      ),
    );
  }
}

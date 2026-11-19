import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/desktop/desktop_app.dart';
import 'package:remote_ai_sync/src/desktop/host_service_manager.dart';
import 'package:remote_ai_sync/src/domain/models.dart';
import 'package:remote_ai_sync/src/presentation/shad_theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('desktop console renders host status and navigation', (
    tester,
  ) async {
    final manager = HostServiceManager(monitor: false);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      ShadApp.custom(
        theme: buildShadTheme(),
        appBuilder: (context) => MaterialApp(
          home: DesktopApp(manager: manager),
          theme: buildShadMaterialTheme(),
          builder: (context, child) => ShadAppBuilder(child: child),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('电脑主机状态'), findsOneWidget);
    expect(find.text('等待主机'), findsNWidgets(4));
    expect(find.text('服务控制'), findsOneWidget);
    expect(find.text('Agent 适配状态'), findsOneWidget);
    expect(find.text('连接信息'), findsOneWidget);
    expect(find.text('等待主机'), findsNWidgets(4));

    await tester.tap(find.text('连接信息'));
    await tester.pumpAndSettle();
    expect(find.text('连接信息'), findsNWidgets(2));
    expect(find.text('局域网 IP'), findsOneWidget);
    expect(find.text('主机端口'), findsOneWidget);
    expect(find.text('生成手机配对二维码'), findsOneWidget);
    expect(find.byTooltip('复制主机端口'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('overview cards align in columns and stack on narrow windows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = HostServiceManager(monitor: false);
    addTearDown(manager.dispose);

    for (final size in const [Size(1600, 1000), Size(1000, 1000)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        ShadApp.custom(
          theme: buildShadTheme(),
          appBuilder: (context) => MaterialApp(
            home: DesktopApp(manager: manager),
            theme: buildShadMaterialTheme(),
            builder: (context, child) => ShadAppBuilder(child: child),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final serviceCard = find
          .ancestor(of: find.text('服务控制'), matching: find.byType(ShadCard))
          .first;
      final agentCard = find
          .ancestor(
            of: find.text('Agent 适配状态'),
            matching: find.byType(ShadCard),
          )
          .first;
      final serviceRect = tester.getRect(serviceCard);
      final agentRect = tester.getRect(agentCard);
      expect(serviceRect.width, closeTo(agentRect.width, 0.1));

      if (size.width >= 1500) {
        expect(serviceRect.top, closeTo(agentRect.top, 0.1));
        expect(serviceRect.right, lessThanOrEqualTo(agentRect.left));
        expect(serviceRect.height, closeTo(agentRect.height, 0.1));
      } else {
        expect(agentRect.top, greaterThanOrEqualTo(serviceRect.bottom));
      }
      expect(tester.takeException(), isNull, reason: 'viewport: $size');
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('relay endpoint cards share a row on wide windows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = HostServiceManager(
      mode: HostRuntimeMode.relay,
      monitor: false,
      initialSnapshot: const HostServiceSnapshot(mode: HostRuntimeMode.relay),
    );
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      ShadApp.custom(
        theme: buildShadTheme(),
        appBuilder: (context) => MaterialApp(
          home: DesktopApp(manager: manager),
          theme: buildShadMaterialTheme(),
          builder: (context, child) => ShadAppBuilder(child: child),
        ),
      ),
    );
    await tester.tap(find.text('接入状态').first);
    await tester.pumpAndSettle();

    final hostCard = find
        .ancestor(of: find.text('电脑主机端'), matching: find.byType(ShadCard))
        .first;
    final clientCard = find
        .ancestor(of: find.text('手机客户端'), matching: find.byType(ShadCard))
        .first;
    final hostRect = tester.getRect(hostCard);
    final clientRect = tester.getRect(clientCard);
    expect(hostRect.width, closeTo(clientRect.width, 0.1));
    expect(hostRect.height, closeTo(clientRect.height, 0.1));
    expect(hostRect.top, closeTo(clientRect.top, 0.1));
    expect(hostRect.right, lessThanOrEqualTo(clientRect.left));
    final hostIcon = tester.getRect(
      find.byKey(const Key('relay-endpoint-icon-电脑主机端')),
    );
    final hostTitle = tester.getRect(find.text('电脑主机端'));
    expect(hostTitle.left, greaterThan(hostIcon.right));
    expect(hostTitle.center.dy, lessThan(hostRect.center.dy));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'desktop console labels missing adapters and shows install links',
    (tester) async {
      final manager = HostServiceManager(
        monitor: false,
        initialSnapshot: const HostServiceSnapshot(
          reachable: true,
          connectedClients: 1,
          agentStatuses: {
            'opencode': AgentRuntimeStatus(
              id: 'opencode',
              availability: AgentAvailability.available,
              version: '2.1.0',
            ),
            'codex': AgentRuntimeStatus(
              id: 'codex',
              availability: AgentAvailability.notInstalled,
              detail: 'Codex CLI 未安装',
            ),
            'claude': AgentRuntimeStatus(
              id: 'claude',
              availability: AgentAvailability.unsupported,
              detail: 'Claude Code 适配器尚未接入',
            ),
          },
        ),
      );
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        ShadApp.custom(
          theme: buildShadTheme(),
          appBuilder: (context) => MaterialApp(
            home: DesktopApp(manager: manager),
            theme: buildShadMaterialTheme(),
            builder: (context, child) => ShadAppBuilder(child: child),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('2.1.0'), findsOneWidget);
      expect(find.text('未安装'), findsOneWidget);
      expect(find.text('未接入'), findsOneWidget);
      expect(find.text('1 个客户端'), findsOneWidget);

      await tester.tap(find.text('Agent 状态'));
      await tester.pumpAndSettle();
      expect(find.text('Codex CLI / app-server'), findsWidgets);
      expect(find.text('Claude Code CLI + 本地记录'), findsWidgets);
      expect(find.text('Claude Code Desktop'), findsWidgets);
      expect(find.text('未单独接入'), findsOneWidget);
      expect(find.textContaining('当前不检测 Codex Desktop 是否运行'), findsOneWidget);
      expect(find.text('快速安装支持的 Agent'), findsOneWidget);
      expect(find.byKey(const Key('install-agent-opencode')), findsOneWidget);
      expect(find.byKey(const Key('install-agent-codex')), findsOneWidget);
      expect(
        find.byKey(const Key('install-agent-codex-desktop')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('install-agent-claude')), findsOneWidget);
      expect(
        find.byKey(const Key('install-agent-claude-desktop')),
        findsOneWidget,
      );
    },
  );

  testWidgets('persistent mode switch replaces host tabs with relay tabs', (
    tester,
  ) async {
    final manager = HostServiceManager(monitor: false);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      ShadApp.custom(
        theme: buildShadTheme(),
        appBuilder: (context) => MaterialApp(
          home: DesktopApp(manager: manager),
          theme: buildShadMaterialTheme(),
          builder: (context, child) => ShadAppBuilder(child: child),
        ),
      ),
    );
    expect(find.byKey(const Key('desktop-mode-tabs')), findsOneWidget);
    expect(find.text('Agent 状态'), findsOneWidget);
    expect(find.text('连接信息'), findsOneWidget);

    await tester.tap(find.text('中继'));
    await tester.pumpAndSettle();
    expect(manager.mode, HostRuntimeMode.relay);
    expect(find.text('Agent 状态'), findsNothing);
    expect(find.text('接入状态'), findsWidgets);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('中继服务器配置'), findsOneWidget);
    expect(find.text('监听端口'), findsOneWidget);
    expect(find.text('中继管理密钥（仅保留在中继端）'), findsOneWidget);
    expect(find.text('创建一次性主机注册码'), findsOneWidget);
    expect(find.text('应用并启动'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('host settings render without unbounded width layout errors', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = HostServiceManager(monitor: false);
    addTearDown(manager.dispose);

    for (final size in const [
      Size(700, 700),
      Size(900, 700),
      Size(1600, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        ShadApp.custom(
          theme: buildShadTheme(),
          appBuilder: (context) => MaterialApp(
            home: DesktopApp(manager: manager),
            theme: buildShadMaterialTheme(),
            builder: (context, child) => ShadAppBuilder(child: child),
          ),
        ),
      );
      await tester.tap(find.text('设置').first);
      await tester.pumpAndSettle();

      expect(find.text('电脑主机配置'), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-relay-tunnel-switch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('desktop-public-host-switch')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: 'viewport: $size');

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('desktop-relay-tunnel-switch')),
          matching: find.text('启用'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('中继服务器地址'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'viewport: $size');
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('relay view reports host and client access separately', (
    tester,
  ) async {
    final manager = HostServiceManager(
      mode: HostRuntimeMode.relay,
      monitor: false,
      initialSnapshot: const HostServiceSnapshot(
        reachable: true,
        mode: HostRuntimeMode.relay,
        relayRooms: 2,
        relayHosts: 1,
        relayClients: 3,
      ),
    );
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      ShadApp.custom(
        theme: buildShadTheme(),
        appBuilder: (context) => MaterialApp(
          home: DesktopApp(manager: manager),
          theme: buildShadMaterialTheme(),
          builder: (context, child) => ShadAppBuilder(child: child),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('接入状态').first);
    await tester.pumpAndSettle();
    expect(find.text('电脑主机端'), findsOneWidget);
    expect(find.text('1 台主机已接入'), findsOneWidget);
    expect(find.text('手机客户端'), findsOneWidget);
    expect(find.text('3 个客户端已接入'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

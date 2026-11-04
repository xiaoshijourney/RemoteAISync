import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/main.dart';
import 'package:remote_ai_sync/src/application/demo_controller.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  testWidgets('navigation opens files and connection views', (tester) async {
    await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));

    expect(find.text('等待人工审批'), findsOneWidget);
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('浏览项目产物，预览源码或请求电脑打开程序。'), findsOneWidget);
    expect(find.text('main.py'), findsOneWidget);

    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接本机主机'), findsOneWidget);
  });

  testWidgets('approval buttons update the displayed local demo status', (
    tester,
  ) async {
    final controller = DemoController();
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('approve-approval-1')));
    await tester.pumpAndSettle();

    expect(find.text('已允许（本地演示）'), findsOneWidget);
  });

  testWidgets('session timeline lists non-previewable attachments', (
    tester,
  ) async {
    final controller = DemoController();
    controller.sendReply(
      '',
      attachments: const [
        AgentAttachment(
          id: 'archive-1',
          name: 'source_bundle.zip',
          sizeBytes: 2048,
        ),
      ],
    );
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await tester.pumpAndSettle();

    expect(find.text('source_bundle.zip'), findsOneWidget);
    expect(find.textContaining('暂不支持预览'), findsOneWidget);
    expect(find.textContaining('尚未传至电脑 Agent'), findsOneWidget);
  });

  testWidgets('connection form validates port and pairing token', (
    tester,
  ) async {
    await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), '70000');
    await tester.tap(find.byKey(const Key('connect-local-host')));
    await tester.pumpAndSettle();
    expect(find.text('端口需为 1–65535'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), '8787');
    await tester.tap(find.byKey(const Key('connect-local-host')));
    await tester.pumpAndSettle();
    expect(find.text('请输入主机终端显示的完整令牌'), findsOneWidget);
    expect(find.text('尚未连接'), findsOneWidget);
  });

  testWidgets('live host mode does not expose demo interactions', (
    tester,
  ) async {
    late HttpServer server;
    late StreamSubscription<HttpRequest> serverSubscription;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {
          socket.add(
            jsonEncode({
              'schemaVersion': 1,
              'kind': 'host.ready',
              'payload': {'openCodeVersion': '2.0.6'},
            }),
          );
          socket.add(
            jsonEncode({
              'schemaVersion': 1,
              'kind': 'host.snapshot',
              'payload': {'sessions': []},
            }),
          );
        });
      });
    });
    final controller = DemoController();
    try {
      await tester.runAsync(
        () => controller.connect(
          address: '127.0.0.1',
          port: server.port,
          pairingToken: 'x' * 40,
        ),
      );

      await tester.pumpWidget(RemoteAISyncApp(controller: controller));
      await tester.pumpAndSettle();

      expect(controller.isDemo, isFalse);
      expect(find.text('等待人工审批'), findsNothing);
      expect(find.text('请选择一个端口。'), findsNothing);
      expect(find.textContaining('演示数据'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-composer')))
            .enabled,
        isFalse,
      );
    } finally {
      await tester.runAsync(() async {
        await controller.disconnect();
        await serverSubscription.cancel();
        await server.close(force: true);
      });
      controller.dispose();
    }
  });
}

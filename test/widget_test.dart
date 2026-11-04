import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/main.dart';
import 'package:remote_ai_sync/src/application/demo_controller.dart';

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
    expect(find.text('检查连接配置'), findsOneWidget);
    expect(find.text('局域网直连'), findsOneWidget);
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
}

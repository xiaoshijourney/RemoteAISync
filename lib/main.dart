import 'package:flutter/material.dart';

import 'src/application/demo_controller.dart';
import 'src/presentation/app_shell.dart';
import 'src/presentation/theme.dart';

void main() {
  runApp(RemoteAISyncApp(controller: DemoController()));
}

class RemoteAISyncApp extends StatelessWidget {
  const RemoteAISyncApp({required this.controller, super.key});

  final DemoController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteAISync',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AppShell(controller: controller),
    );
  }
}

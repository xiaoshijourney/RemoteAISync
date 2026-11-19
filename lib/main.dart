import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'src/application/demo_controller.dart';
import 'src/presentation/app_shell.dart';
import 'src/presentation/shad_theme.dart';

void main() {
  runApp(RemoteAISyncApp(controller: DemoController(demo: false)));
}

class RemoteAISyncApp extends StatelessWidget {
  const RemoteAISyncApp({required this.controller, super.key});

  final DemoController controller;

  @override
  Widget build(BuildContext context) {
    return ShadApp.custom(
      theme: buildShadTheme(),
      appBuilder: (context) => MaterialApp(
        title: 'RAS',
        debugShowCheckedModeBanner: false,
        theme: buildShadMaterialTheme(),
        builder: (context, child) => ShadAppBuilder(child: child),
        home: AppShell(controller: controller),
      ),
    );
  }
}

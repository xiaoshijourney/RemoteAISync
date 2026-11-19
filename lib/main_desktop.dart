import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'src/desktop/desktop_app.dart';
import 'src/presentation/shad_theme.dart';

const _desktopFontFamily = 'Microsoft YaHei UI';

void main() {
  runApp(
    ShadApp.custom(
      theme: buildShadTheme(
        fontFamily: _desktopFontFamily,
        uniformWeight: true,
      ),
      appBuilder: (context) => MaterialApp(
        title: 'RAS',
        debugShowCheckedModeBanner: false,
        theme: buildShadMaterialTheme(fontFamily: _desktopFontFamily),
        builder: (context, child) => ShadAppBuilder(child: child),
        home: const DesktopApp(),
      ),
    ),
  );
}

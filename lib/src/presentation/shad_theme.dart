import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const shadPrimary = Color(0xFF18181B);
const shadInk = Color(0xFF18181B);
const shadMuted = Color(0xFF71717A);
const shadLine = Color(0xFFE4E4E7);
const shadCanvas = Color(0xFFFAFAFA);
const shadMutedBackground = Color(0xFFF4F4F5);
const shadSuccess = Color(0xFF68816F);
const shadWarning = Color(0xFF9A7955);
const shadError = Color(0xFFA65F5F);
const shadGlass = Color(0xFFFFFFFF);
const shadGlassBorder = Color(0xFFE4E4E7);

ShadThemeData buildShadTheme({
  String fontFamily = 'Roboto',
  bool uniformWeight = false,
}) {
  TextStyle normalize(TextStyle style) =>
      style.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0);

  final desktopTextTheme = ShadTextTheme(
    family: fontFamily,
    h1Large: normalize(ShadTextDefaultTheme.h1Large(family: fontFamily)),
    h1: normalize(ShadTextDefaultTheme.h1(family: fontFamily)),
    h2: normalize(ShadTextDefaultTheme.h2(family: fontFamily)),
    h3: normalize(ShadTextDefaultTheme.h3(family: fontFamily)),
    h4: normalize(ShadTextDefaultTheme.h4(family: fontFamily)),
    p: normalize(ShadTextDefaultTheme.p(family: fontFamily)),
    blockquote: normalize(ShadTextDefaultTheme.blockquote(family: fontFamily)),
    table: normalize(ShadTextDefaultTheme.table(family: fontFamily)),
    list: normalize(ShadTextDefaultTheme.list(family: fontFamily)),
    lead: normalize(ShadTextDefaultTheme.lead(family: fontFamily)),
    large: normalize(ShadTextDefaultTheme.large(family: fontFamily)),
    small: normalize(ShadTextDefaultTheme.small(family: fontFamily)),
    muted: normalize(ShadTextDefaultTheme.muted(family: fontFamily)),
  );

  return ShadThemeData(
    brightness: Brightness.light,
    colorScheme: const ShadZincColorScheme.light(
      primary: shadPrimary,
      primaryForeground: Colors.white,
      ring: shadPrimary,
    ),
    radius: BorderRadius.circular(12),
    cardTheme: const ShadCardTheme(
      padding: EdgeInsets.all(20),
      radius: BorderRadius.all(Radius.circular(20)),
    ),
    primaryToastTheme: const ShadToastTheme(
      alignment: Alignment.topRight,
      offset: Offset(0, 16),
      duration: Duration(seconds: 3),
    ),
    destructiveToastTheme: const ShadToastTheme(
      alignment: Alignment.topRight,
      offset: Offset(0, 16),
      duration: Duration(seconds: 3),
    ),
    textTheme: uniformWeight
        ? desktopTextTheme
        : ShadTextTheme(family: fontFamily),
  );
}

ThemeData buildShadMaterialTheme({String fontFamily = 'Roboto'}) {
  return ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF52525B),
          brightness: Brightness.light,
        ).copyWith(
          primary: shadPrimary,
          onPrimary: Colors.white,
          surface: Colors.white,
          error: shadError,
        ),
    scaffoldBackgroundColor: shadCanvas,
    fontFamily: fontFamily,
    dividerColor: shadLine,
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        color: shadInk,
        fontSize: 22,
        fontWeight: FontWeight.w500,
        height: 1.2,
      ),
      titleLarge: TextStyle(
        color: shadInk,
        fontSize: 18,
        fontWeight: FontWeight.w500,
      ),
      titleMedium: TextStyle(
        color: shadInk,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      bodyLarge: TextStyle(
        color: shadInk,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.45,
      ),
      bodyMedium: TextStyle(
        color: shadInk,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        height: 1.4,
      ),
      bodySmall: TextStyle(
        color: shadMuted,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.35,
      ),
      labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    ),
  );
}

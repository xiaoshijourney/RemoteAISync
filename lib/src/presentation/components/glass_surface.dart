import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../shad_theme.dart';

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    required this.child,
    this.padding,
    this.margin,
    this.radius = 20,
    this.blur = 14,
    this.tint = shadGlass,
    this.borderColor = shadGlassBorder,
    this.shadow = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double blur;
  final Color tint;
  final Color borderColor;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: ShadCard(
        padding: padding,
        backgroundColor: tint,
        radius: BorderRadius.circular(radius),
        border: ShadBorder.all(
          color: borderColor,
          radius: BorderRadius.circular(radius),
        ),
        shadows: shadow ? theme.cardTheme.shadows : const [],
        child: child,
      ),
    );
  }
}

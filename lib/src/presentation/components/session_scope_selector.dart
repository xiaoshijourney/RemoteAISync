import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SessionScopeSelector extends StatelessWidget {
  const SessionScopeSelector({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width < 380 ? 196.0 : 228.0;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final radius = BorderRadius.circular(13);
    final thumbRadius = BorderRadius.circular(17);
    return SizedBox(
      width: width,
      height: 52,
      child: ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: radius,
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                AnimatedAlign(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: .5,
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: thumbRadius,
                          boxShadow: ShadShadows.sm,
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    _ScopeButton(
                      label: '当前文件夹',
                      selected: !value,
                      onPressed: () => onChanged(false),
                    ),
                    _ScopeButton(
                      label: '全局',
                      selected: value,
                      onPressed: () => onChanged(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScopeButton extends StatelessWidget {
  const _ScopeButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      selected: selected,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        height: 46,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        mainAxisAlignment: MainAxisAlignment.center,
        foregroundColor: selected
            ? Theme.of(context).colorScheme.onSurface
            : Theme.of(context).colorScheme.onSurfaceVariant,
        child: Text(label),
      ),
    ),
  );
}

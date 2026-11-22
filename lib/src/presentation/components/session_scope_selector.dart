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
    return SizedBox(
      width: width,
      height: 52,
      child: ShadTabs<bool>(
        key: const Key('session-scope-tabs'),
        value: value,
        gap: 0,
        onChanged: onChanged,
        tabs: const [
          ShadTab<bool>(
            value: false,
            content: SizedBox.shrink(),
            child: Text('当前文件夹'),
          ),
          ShadTab<bool>(
            value: true,
            content: SizedBox.shrink(),
            child: Text('全局'),
          ),
        ],
      ),
    );
  }
}

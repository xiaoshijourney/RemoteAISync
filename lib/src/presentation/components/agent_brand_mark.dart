import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../shad_theme.dart';

class AgentBrandMark extends StatelessWidget {
  const AgentBrandMark({
    required this.agentId,
    this.size = 24,
    this.backgroundColor = shadMutedBackground,
    super.key,
  });

  final String agentId;
  final double size;
  final Color backgroundColor;

  static const _assets = {
    'codex': 'assets/agents/codex.svg',
    'opencode': 'assets/agents/opencode.svg',
    'claude': 'assets/agents/claude.svg',
  };

  static const _labels = {
    'codex': 'Codex',
    'opencode': 'OpenCode',
    'claude': 'Claude Code',
  };

  @override
  Widget build(BuildContext context) {
    final asset = _assets[agentId];
    if (asset == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(size * .28),
          border: Border.all(color: shadLine, width: 1.1),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(LucideIcons.bot, size: size * .58, color: shadMuted),
        ),
      );
    }
    return Semantics(
      image: true,
      label: _labels[agentId],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(size * .28),
          border: Border.all(color: shadLine, width: 1.1),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Padding(
            padding: EdgeInsets.all(size * .16),
            child: SvgPicture.asset(
              asset,
              fit: BoxFit.contain,
              allowDrawingOutsideViewBox: false,
            ),
          ),
        ),
      ),
    );
  }
}

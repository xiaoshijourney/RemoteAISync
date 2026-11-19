import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../domain/models.dart';
import 'agent_brand_mark.dart';
import '../shad_theme.dart';

class AgentMessageScroller extends StatefulWidget {
  const AgentMessageScroller({
    required this.children,
    required this.messageCount,
    this.sessionKey,
    super.key,
  });

  final List<Widget> children;
  final int messageCount;
  final String? sessionKey;

  @override
  State<AgentMessageScroller> createState() => _AgentMessageScrollerState();
}

class _AgentMessageScrollerState extends State<AgentMessageScroller> {
  final _scrollController = ScrollController();
  bool _pinnedToBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updatePinnedState);
    if (widget.sessionKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  void didUpdateWidget(covariant AgentMessageScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sessionKey != oldWidget.sessionKey) {
      if (widget.sessionKey != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
      return;
    }
    if (widget.messageCount > oldWidget.messageCount && _pinnedToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animate: true);
      });
    }
  }

  void _scrollToBottom({bool animate = false}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
    _pinnedToBottom = true;
  }

  void _updatePinnedState() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _pinnedToBottom = position.maxScrollExtent - position.pixels < 88;
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_updatePinnedState)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
      itemCount: widget.children.length,
      itemBuilder: (context, index) => widget.children[index],
    );
  }
}

class AgentMessageMarker extends StatelessWidget {
  const AgentMessageMarker({
    required this.label,
    required this.time,
    required this.icon,
    this.color = shadMuted,
    super.key,
  });

  final String label;
  final String time;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: 7),
        Text(time, maxLines: 1, style: style),
      ],
    );
  }
}

class AgentThinkingMarker extends StatefulWidget {
  const AgentThinkingMarker({super.key});

  @override
  State<AgentThinkingMarker> createState() => _AgentThinkingMarkerState();
}

class _AgentThinkingMarkerState extends State<AgentThinkingMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimationWithAccessibility();
  }

  void _syncAnimationWithAccessibility() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final progress = reducedMotion ? .5 : _animation.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.sparkles, size: 15, color: shadPrimary),
            const SizedBox(width: 7),
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment(-1.5 + progress * 3, 0),
                end: Alignment(-.5 + progress * 3, 0),
                colors: const [shadMuted, shadPrimary, shadMuted],
                stops: const [0, .5, 1],
              ).createShader(bounds),
              child: const Text(
                'Agent 正在思考',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 34,
              height: 2,
              decoration: BoxDecoration(
                color: shadLine,
                borderRadius: BorderRadius.circular(99),
              ),
              alignment: Alignment(progress * 2 - 1, 0),
              child: Container(
                width: 11,
                decoration: BoxDecoration(
                  color: shadPrimary,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class AgentMessageTile extends StatelessWidget {
  const AgentMessageTile({
    required this.message,
    this.agentId = 'opencode',
    this.onOpenAttachment,
    super.key,
  });

  final AgentMessage message;
  final String agentId;
  final ValueChanged<AgentAttachment>? onOpenAttachment;

  @override
  Widget build(BuildContext context) {
    if (message.author == MessageAuthor.system) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: ShadAlert(
          icon: const Icon(LucideIcons.circleCheck),
          title: const Text('系统事件'),
          description: Text(message.text),
        ),
      );
    }

    if (message.author == MessageAuthor.tool) {
      return AgentToolCallGroup(messages: [message]);
    }

    if (message.author == MessageAuthor.user) {
      return Padding(
        padding: const EdgeInsets.only(left: 34, bottom: 14),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: shadMutedBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: shadLine),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.text.isNotEmpty)
                      AgentRichMessage(text: message.text),
                    for (final attachment in message.attachments) ...[
                      if (message.text.isNotEmpty) const SizedBox(height: 8),
                      AgentAttachmentCard(
                        attachment: attachment,
                        onPressed: isAgentAttachmentPreviewable(attachment.name)
                            ? () => onOpenAttachment?.call(attachment)
                            : null,
                      ),
                    ],
                    const SizedBox(height: 8),
                    AgentMessageMarker(
                      label: '你',
                      time: message.time,
                      icon: LucideIcons.userRound,
                      color: shadPrimary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgentBrandMark(agentId: agentId, size: 28),
          const SizedBox(width: 9),
          Expanded(
            child: _CollapsibleMessageContent(
              key: ValueKey('assistant-${message.id}'),
              initiallyCollapsed: false,
              preview: message.text,
              toggleKey: Key('toggle-message-${message.id}'),
              header: AgentMessageMarker(
                label: 'Agent',
                time: message.time,
                icon: LucideIcons.sparkles,
                color: shadPrimary,
              ),
              content: AgentRichMessage(text: message.text),
            ),
          ),
        ],
      ),
    );
  }
}

class AgentToolCallGroup extends StatefulWidget {
  const AgentToolCallGroup({required this.messages, super.key});

  final List<AgentMessage> messages;

  @override
  State<AgentToolCallGroup> createState() => _AgentToolCallGroupState();
}

class _AgentToolCallGroupState extends State<AgentToolCallGroup> {
  @override
  Widget build(BuildContext context) {
    final first = widget.messages.first;
    final count = widget.messages.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShadCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ShadAccordion<String>(
          children: [
            ShadAccordionItem<String>(
              key: Key('toggle-tool-group-${first.id}'),
              value: first.id,
              padding: const EdgeInsets.symmetric(vertical: 8),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              separator: const SizedBox.shrink(),
              title: Row(
                children: [
                  const Icon(LucideIcons.terminal, size: 16, color: shadMuted),
                  const SizedBox(width: 9),
                  Expanded(
                    child: AgentMessageMarker(
                      label: '执行轨迹 · $count 步',
                      time: first.time,
                      icon: LucideIcons.wrench,
                    ),
                  ),
                  ShadBadge.secondary(child: Text('$count 步')),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 5, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < count; index++) ...[
                      _TraceStep(
                        index: index,
                        count: count,
                        message: widget.messages[index],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TraceStep extends StatelessWidget {
  const _TraceStep({
    required this.index,
    required this.count,
    required this.message,
  });

  final int index;
  final int count;
  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    final lines = message.text.split('\n');
    final title = lines.first.trim().isEmpty ? '工具调用' : lines.first.trim();
    final detail = lines.length == 1 ? '' : lines.skip(1).join('\n').trim();
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: index == count - 1 ? shadPrimary : shadMuted,
                  ),
                ),
                if (index < count - 1)
                  Expanded(child: Container(width: 1, color: shadLine)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: index == count - 1 ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelLarge),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    SelectableText(
                      detail,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleMessageContent extends StatefulWidget {
  const _CollapsibleMessageContent({
    required this.header,
    required this.preview,
    required this.content,
    required this.initiallyCollapsed,
    required this.toggleKey,
    super.key,
  });

  final Widget header;
  final String preview;
  final Widget content;
  final bool initiallyCollapsed;
  final Key toggleKey;

  @override
  State<_CollapsibleMessageContent> createState() =>
      _CollapsibleMessageContentState();
}

class _CollapsibleMessageContentState
    extends State<_CollapsibleMessageContent> {
  late bool _collapsed = widget.initiallyCollapsed;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview
        .replaceAll(RegExp(r'[*_`#>]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: widget.header),
            Tooltip(
              message: _collapsed ? '展开内容' : '折叠内容',
              child: ShadIconButton.ghost(
                key: widget.toggleKey,
                onPressed: () => setState(() => _collapsed = !_collapsed),
                icon: Icon(
                  _collapsed ? LucideIcons.chevronDown : LucideIcons.chevronUp,
                  size: 16,
                ),
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.topLeft,
          child: _collapsed
              ? Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    preview,
                    maxLines: widget.initiallyCollapsed ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: widget.content,
                ),
        ),
      ],
    );
  }
}

class AgentRichMessage extends StatelessWidget {
  const AgentRichMessage({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final fence = RegExp(r'```([^\r\n`]*)\r?\n([\s\S]*?)```');
    final parts = <Widget>[];
    var cursor = 0;
    for (final match in fence.allMatches(text)) {
      final before = text.substring(cursor, match.start).trimRight();
      if (before.isNotEmpty) parts.add(_paragraph(context, before));
      parts.add(
        AgentCodeBlock(
          code: match.group(2) ?? '',
          language: match.group(1)?.trim() ?? '',
        ),
      );
      cursor = match.end;
    }
    final remainder = text.substring(cursor).trim();
    if (remainder.isNotEmpty) parts.add(_paragraph(context, remainder));
    if (parts.isEmpty) parts.add(_paragraph(context, text));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < parts.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          parts[index],
        ],
      ],
    );
  }

  Widget _paragraph(BuildContext context, String value) {
    return SelectableText(value, style: Theme.of(context).textTheme.bodyMedium);
  }
}

class AgentCodeBlock extends StatelessWidget {
  const AgentCodeBlock({required this.code, this.language = '', super.key});

  final String code;
  final String language;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ShadToaster.of(context).show(const ShadToast(title: Text('代码已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF18181B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 5, 5, 5),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'CODE' : language.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: '复制代码',
                  child: ShadIconButton.ghost(
                    height: 28,
                    width: 28,
                    padding: EdgeInsets.zero,
                    foregroundColor: const Color(0xFFD4D4D8),
                    hoverForegroundColor: Colors.white,
                    onPressed: () => _copy(context),
                    icon: const Icon(LucideIcons.copy, size: 14),
                  ),
                ),
              ],
            ),
          ),
          const ShadSeparator.horizontal(color: Color(0xFF3F3F46)),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(11),
            child: SelectableText(
              code.trimRight(),
              style: const TextStyle(
                color: Color(0xFFF4F4F5),
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AgentAttachmentCard extends StatelessWidget {
  const AgentAttachmentCard({
    required this.attachment,
    this.onPressed,
    super.key,
  });

  final AgentAttachment attachment;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final previewable = isAgentAttachmentPreviewable(attachment.name);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320, minWidth: 185),
      child: ShadCard(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: Row(
            children: [
              Icon(
                attachmentIcon(attachment.name),
                size: 19,
                color: shadPrimary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      '${formatAttachmentSize(attachment.sizeBytes)}  ·  ${previewable ? '点击预览' : '不可预览，可作为附件发送'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(
                previewable ? LucideIcons.externalLink : LucideIcons.paperclip,
                size: 15,
                color: shadMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AgentQuestionOption {
  const AgentQuestionOption({required this.value, required this.label});

  final String value;
  final String label;
}

class AgentQuestionnaire extends StatefulWidget {
  const AgentQuestionnaire({
    required this.title,
    required this.prompt,
    required this.options,
    required this.onSubmit,
    this.customPlaceholder,
    this.customValidator,
    super.key,
  });

  final String title;
  final String prompt;
  final List<AgentQuestionOption> options;
  final ValueChanged<String> onSubmit;
  final String? customPlaceholder;
  final String? Function(String)? customValidator;

  @override
  State<AgentQuestionnaire> createState() => _AgentQuestionnaireState();
}

class _AgentQuestionnaireState extends State<AgentQuestionnaire> {
  final _customController = TextEditingController();
  String? _customError;
  String? _selectedOption;

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadCard(
      padding: const EdgeInsets.all(13),
      title: Row(
        children: [
          const Icon(LucideIcons.listChecks, color: shadPrimary, size: 17),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.title)),
          const ShadBadge.secondary(child: Text('等待回复')),
        ],
      ),
      description: Text(widget.prompt),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShadRadioGroup<String>(
            key: const Key('questionnaire-options'),
            initialValue: _selectedOption,
            onChanged: (value) => setState(() => _selectedOption = value),
            items: [
              for (final option in widget.options)
                ShadRadio<String>(
                  key: Key('questionnaire-option-${option.value}'),
                  value: option.value,
                  label: Text(option.label),
                ),
            ],
          ),
          if (widget.options.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: ShadButton(
                key: const Key('questionnaire-submit-option'),
                onPressed: _selectedOption == null
                    ? null
                    : () => widget.onSubmit(_selectedOption!),
                leading: const Icon(LucideIcons.check, size: 16),
                child: const Text('提交选择'),
              ),
            ),
          ],
          if (widget.customPlaceholder != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ShadInput(
                    key: const Key('questionnaire-custom-answer'),
                    controller: _customController,
                    keyboardType: TextInputType.number,
                    placeholder: Text(widget.customPlaceholder!),
                    onChanged: (_) {
                      if (_customError != null) {
                        setState(() => _customError = null);
                      }
                    },
                    onSubmitted: _submitCustom,
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: '提交自定义答案',
                  child: ShadIconButton(
                    key: const Key('questionnaire-submit-custom'),
                    icon: const Icon(LucideIcons.arrowUp, size: 16),
                    onPressed: () => _submitCustom(_customController.text),
                  ),
                ),
              ],
            ),
            if (_customError != null) ...[
              const SizedBox(height: 6),
              Text(
                _customError!,
                style: const TextStyle(color: shadError, fontSize: 12),
              ),
            ],
          ],
        ],
      ),
    );
  }

  void _submitCustom(String value) {
    final answer = value.trim();
    if (answer.isEmpty) return;
    final error = widget.customValidator?.call(answer);
    if (error != null) {
      setState(() => _customError = error);
      return;
    }
    widget.onSubmit(answer);
  }
}

class AgentEmptyState extends StatelessWidget {
  const AgentEmptyState({
    required this.title,
    required this.description,
    this.icon = LucideIcons.inbox,
    this.mark,
    super.key,
  });

  final String title;
  final String description;
  final IconData icon;
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    return ShadCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            mark ?? Icon(icon, size: 22, color: shadMuted),
            const SizedBox(height: 9),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

bool isAgentAttachmentPreviewable(String name) =>
    _isPdf(name) || _isImage(name);

IconData attachmentIcon(String name) {
  if (_isPdf(name)) return LucideIcons.fileText;
  if (_isImage(name)) return LucideIcons.image;
  return LucideIcons.file;
}

String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

bool _isPdf(String name) => name.toLowerCase().endsWith('.pdf');

bool _isImage(String name) => const {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
}.any(name.toLowerCase().endsWith);

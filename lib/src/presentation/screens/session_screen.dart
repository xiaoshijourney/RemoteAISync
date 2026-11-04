import 'package:flutter/material.dart';

import '../../application/demo_controller.dart';
import '../../domain/models.dart';
import '../theme.dart';

class SessionScreen extends StatelessWidget {
  const SessionScreen({required this.controller, super.key});

  final DemoController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
                children: [
                  Text('会话', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 5),
                  Text(
                    '查看 Agent 进度，并处理需要你确认的事项。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 18),
                  const _DemoNotice(),
                  const SizedBox(height: 16),
                  const _SessionSummary(),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Divider(height: 1, color: appLine),
                  ),
                  for (final message in controller.messages) ...[
                    _MessageTile(message: message),
                    if (message.id == 'm2') ...[
                      const SizedBox(height: 5),
                      _ApprovalPanel(
                        approval: controller.approval,
                        onAllow: () => controller.resolveApproval(allow: true),
                        onDeny: () => controller.resolveApproval(allow: false),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                  if (controller.selectedPort == null) ...[
                    const SizedBox(height: 2),
                    _PortQuestion(onChoose: controller.choosePort),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _MessageComposer(onSend: controller.sendReply),
          ],
        );
      },
    );
  }
}

class _DemoNotice extends StatelessWidget {
  const _DemoNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8EA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF0D9AB)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: appAmber, size: 18),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              '演示数据 · 尚未连接电脑。回复和审批只更新本地界面。',
              style: TextStyle(
                color: Color(0xFF6D4B13),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appLine),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F1ED),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.terminal, color: appGreen, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OpenCode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                Text(
                  'remotaisync-demo  ·  本地样例会话',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.cloud_off_outlined, color: appMuted, size: 19),
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message});

  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.author == MessageAuthor.user) {
      return Padding(
        padding: const EdgeInsets.only(left: 38, bottom: 13),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 310),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFE7F0EC),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              message.text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    if (message.author == MessageAuthor.system) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 13),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: appGreen, size: 17),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                message.text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Text(message.time, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }

    if (message.author == MessageAuthor.tool) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: appMuted, size: 16),
            const SizedBox(width: 7),
            Text(message.text, style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            Text(message.time, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 25,
            height: 25,
            decoration: BoxDecoration(
              color: const Color(0xFFE9EEF5),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(
              Icons.smart_toy_outlined,
              color: Color(0xFF386A8C),
              size: 16,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Agent  ·  ${message.time}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  message.text,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalPanel extends StatelessWidget {
  const _ApprovalPanel({
    required this.approval,
    required this.onAllow,
    required this.onDeny,
  });

  final ToolApproval approval;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final pending = approval.status == ApprovalStatus.pending;
    final statusText = switch (approval.status) {
      ApprovalStatus.pending => '等待人工审批',
      ApprovalStatus.approved => '已允许（本地演示）',
      ApprovalStatus.rejected => '已拒绝（本地演示）',
    };

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: pending ? appAmberWash : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: pending ? const Color(0xFFE8C987) : appLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pending ? Icons.gpp_maybe_outlined : Icons.gpp_good_outlined,
                color: pending ? appAmber : appGreen,
                size: 19,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusText,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                approval.toolName,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(approval.summary, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF202824),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              approval.command,
              style: const TextStyle(
                color: Color(0xFFF4F7F4),
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(approval.target, style: Theme.of(context).textTheme.bodySmall),
          if (pending) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('deny-approval-approval-1'),
                    onPressed: onDeny,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('拒绝'),
                    style: OutlinedButton.styleFrom(foregroundColor: appRed),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('approve-approval-1'),
                    onPressed: onAllow,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('允许执行'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PortQuestion extends StatelessWidget {
  const _PortQuestion({required this.onChoose});

  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('选项确认', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 5),
          Text('请选择预览端口。', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => onChoose('4173'),
                child: const Text('使用 4173'),
              ),
              OutlinedButton(
                onPressed: () => onChoose('3000'),
                child: const Text('使用 3000'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessageComposer extends StatefulWidget {
  const _MessageComposer({required this.onSend});

  final ValueChanged<String> onSend;

  @override
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _send() {
    final value = _textController.text;
    if (value.trim().isEmpty) return;
    widget.onSend(value);
    _textController.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: appLine)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('message-composer'),
              controller: _textController,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: '回复 Agent…',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const Key('send-reply'),
            tooltip: '发送回复（本地演示）',
            onPressed: _send,
            icon: const Icon(Icons.arrow_upward),
          ),
        ],
      ),
    );
  }
}

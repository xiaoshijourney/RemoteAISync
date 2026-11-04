import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../application/demo_controller.dart';
import '../../domain/models.dart';
import '../theme.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({required this.controller, super.key});

  final DemoController controller;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final Map<String, XFile> _localFiles = {};

  void _sendMessage(String text, List<_SelectedAttachment> selected) {
    for (final item in selected) {
      _localFiles[item.attachment.id] = item.file;
    }
    widget.controller.sendReply(
      text,
      attachments: selected.map((item) => item.attachment).toList(),
    );
  }

  void _openAttachment(AgentAttachment attachment) {
    final file = _localFiles[attachment.id];
    if (file == null || !_isPreviewable(attachment.name)) return;
    _showAttachmentPreview(context, attachment, file);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
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
                  for (final message in widget.controller.messages) ...[
                    _MessageTile(
                      message: message,
                      onOpenAttachment: _openAttachment,
                    ),
                    if (message.id == 'm2') ...[
                      const SizedBox(height: 5),
                      _ApprovalPanel(
                        approval: widget.controller.approval,
                        onAllow: () =>
                            widget.controller.resolveApproval(allow: true),
                        onDeny: () =>
                            widget.controller.resolveApproval(allow: false),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                  if (widget.controller.selectedPort == null) ...[
                    const SizedBox(height: 2),
                    _PortQuestion(onChoose: widget.controller.choosePort),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _MessageComposer(onSend: _sendMessage),
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
  const _MessageTile({required this.message, required this.onOpenAttachment});

  final AgentMessage message;
  final ValueChanged<AgentAttachment> onOpenAttachment;

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.text.isNotEmpty)
                  Text(
                    message.text,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                for (final attachment in message.attachments) ...[
                  if (message.text.isNotEmpty) const SizedBox(height: 8),
                  _AttachmentTile(
                    attachment: attachment,
                    onTap: _isPreviewable(attachment.name)
                        ? () => onOpenAttachment(attachment)
                        : null,
                  ),
                ],
              ],
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

  final void Function(String text, List<_SelectedAttachment> attachments)
  onSend;

  @override
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final _textController = TextEditingController();
  final List<_SelectedAttachment> _attachments = [];
  bool _isPicking = false;
  int _nextAttachmentId = 0;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    setState(() => _isPicking = true);
    try {
      final files = await openFiles();
      if (!mounted || files.isEmpty) return;
      final selected = <_SelectedAttachment>[];
      for (final file in files) {
        selected.add(
          _SelectedAttachment(
            attachment: AgentAttachment(
              id: 'local-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}',
              name: file.name,
              sizeBytes: await file.length(),
              mimeType: file.mimeType,
            ),
            file: file,
          ),
        );
      }
      setState(() => _attachments.addAll(selected));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法读取所选文件，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _send() {
    final value = _textController.text;
    if (value.trim().isEmpty && _attachments.isEmpty) return;
    widget.onSend(value, List.of(_attachments));
    _textController.clear();
    setState(_attachments.clear);
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_attachments.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (context, index) {
                  final selected = _attachments[index];
                  return _PendingAttachmentTile(
                    selected: selected,
                    onRemove: () =>
                        setState(() => _attachments.removeAt(index)),
                    onPreview: () {
                      if (_isPreviewable(selected.attachment.name)) {
                        _showAttachmentPreview(
                          context,
                          selected.attachment,
                          selected.file,
                        );
                      }
                    },
                  );
                },
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                key: const Key('add-attachment'),
                tooltip: '添加附件',
                onPressed: _isPicking ? null : _pickFiles,
                icon: _isPicking
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.attach_file),
              ),
              Expanded(
                child: TextField(
                  key: const Key('message-composer'),
                  controller: _textController,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: '回复 Agent 或添加附件…',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const Key('send-reply'),
                tooltip: '发送消息（本地演示）',
                onPressed: _send,
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectedAttachment {
  const _SelectedAttachment({required this.attachment, required this.file});

  final AgentAttachment attachment;
  final XFile file;
}

class _PendingAttachmentTile extends StatelessWidget {
  const _PendingAttachmentTile({
    required this.selected,
    required this.onRemove,
    required this.onPreview,
  });

  final _SelectedAttachment selected;
  final VoidCallback onRemove;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final attachment = selected.attachment;
    return Container(
      width: 205,
      padding: const EdgeInsets.only(left: 9, right: 4),
      decoration: BoxDecoration(
        color: appCanvas,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: appLine),
      ),
      child: Row(
        children: [
          Icon(_attachmentIcon(attachment.name), color: appGreen, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: _isPreviewable(attachment.name) ? onPreview : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    _formatFileSize(attachment.sizeBytes),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '移除附件',
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 17),
          ),
        ],
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.attachment, required this.onTap});

  final AgentAttachment attachment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final previewable = _isPreviewable(attachment.name);
    return Material(
      color: Colors.white.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_attachmentIcon(attachment.name), size: 19, color: appGreen),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      '${_formatFileSize(attachment.sizeBytes)} · ${previewable ? '点击预览' : '暂不支持预览'}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                previewable ? Icons.open_in_new : Icons.attach_file,
                size: 15,
                color: appMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showAttachmentPreview(
  BuildContext context,
  AgentAttachment attachment,
  XFile file,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 850),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭预览',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isPdf(attachment.name)
                  ? (kIsWeb
                        ? PdfViewer.uri(Uri.parse(file.path))
                        : PdfViewer.file(file.path))
                  : _ImageAttachmentPreview(file: file),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ImageAttachmentPreview extends StatelessWidget {
  const _ImageAttachmentPreview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Image.network(
        file.path,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const _PreviewError(),
      );
    }
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const _PreviewError();
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Image.memory(snapshot.data!, fit: BoxFit.contain);
      },
    );
  }
}

class _PreviewError extends StatelessWidget {
  const _PreviewError();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('无法预览此文件。文件仍可作为附件发送。'));
}

bool _isPreviewable(String name) => _isPdf(name) || _isImage(name);

bool _isPdf(String name) => name.toLowerCase().endsWith('.pdf');

bool _isImage(String name) => const {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
}.any(name.toLowerCase().endsWith);

IconData _attachmentIcon(String name) {
  if (_isPdf(name)) return Icons.picture_as_pdf_outlined;
  if (_isImage(name)) return Icons.image_outlined;
  return Icons.insert_drive_file_outlined;
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

import 'package:flutter/foundation.dart';

import '../domain/models.dart';

class DemoController extends ChangeNotifier {
  final List<AgentMessage> _messages = [
    const AgentMessage(
      id: 'm1',
      author: MessageAuthor.assistant,
      text: '参数解析和页面代码已经完成。我准备启动本地预览，检查移动端布局。',
      time: '14:32',
    ),
    const AgentMessage(
      id: 'm2',
      author: MessageAuthor.tool,
      text: '准备执行命令',
      time: '14:33',
    ),
    const AgentMessage(
      id: 'm3',
      author: MessageAuthor.assistant,
      text: '预览服务建议使用 4173 端口。请选择一个端口。',
      time: '14:33',
    ),
  ];

  ToolApproval _approval = const ToolApproval(
    id: 'approval-1',
    toolName: 'Terminal',
    summary: '启动项目预览服务',
    command: 'npm run preview -- --host 0.0.0.0',
    target: '项目目录 / demo-app',
    status: ApprovalStatus.pending,
  );

  int _nextMessageId = 4;
  String? _selectedPort;

  List<AgentMessage> get messages => List.unmodifiable(_messages);
  ToolApproval get approval => _approval;
  String? get selectedPort => _selectedPort;

  void sendReply(
    String rawText, {
    List<AgentAttachment> attachments = const [],
  }) {
    final text = rawText.trim();
    if (text.isEmpty && attachments.isEmpty) return;

    _messages.add(
      AgentMessage(
        id: 'm${_nextMessageId++}',
        author: MessageAuthor.user,
        text: text,
        time: _timeNow(),
        attachments: List.unmodifiable(attachments),
      ),
    );
    _messages.add(
      AgentMessage(
        id: 'm${_nextMessageId++}',
        author: MessageAuthor.assistant,
        text: attachments.isEmpty
            ? '已记录你的回复。这是本地演示，尚未连接电脑上的 Agent。'
            : '已记录你的回复和 ${attachments.length} 个附件。当前是本地演示，附件内容尚未传至电脑 Agent。',
        time: _timeNow(),
      ),
    );
    notifyListeners();
  }

  void choosePort(String port) {
    _selectedPort = port;
    _messages.add(
      AgentMessage(
        id: 'm${_nextMessageId++}',
        author: MessageAuthor.user,
        text: '预览端口使用 $port',
        time: _timeNow(),
      ),
    );
    notifyListeners();
  }

  void resolveApproval({required bool allow}) {
    if (_approval.status != ApprovalStatus.pending) return;

    _approval = _approval.copyWith(
      status: allow ? ApprovalStatus.approved : ApprovalStatus.rejected,
    );
    _messages.add(
      AgentMessage(
        id: 'm${_nextMessageId++}',
        author: MessageAuthor.system,
        text: allow ? '已允许该操作（本地演示）' : '已拒绝该操作（本地演示）',
        time: _timeNow(),
      ),
    );
    notifyListeners();
  }

  String _timeNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }
}

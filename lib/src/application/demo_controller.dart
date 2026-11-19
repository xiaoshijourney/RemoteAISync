import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';

import 'host_client.dart';
import '../domain/models.dart';
import '../domain/transport_protocol.dart';

class DemoController extends ChangeNotifier {
  DemoController({bool demo = true}) : _demoMode = demo {
    host.addListener(_notify);
  }

  final HostClient host = HostClient();
  bool _disposed = false;
  final List<AgentMessage> _messages = [
    const AgentMessage(
      id: 'm1',
      author: MessageAuthor.assistant,
      text:
          '参数解析和页面代码已经完成。我准备启动本地预览，检查移动端布局。\n\n```shell\nflutter run -d web-server --web-port 4173\n```',
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
  bool _demoMode;
  AttachmentTransferState _attachmentState = AttachmentTransferState.delivered;
  bool _lastReplyWasQueued = false;

  List<AgentMessage> get messages =>
      _demoMode ? List.unmodifiable(_messages) : host.messages;
  List<HostSession> get sessions => host.sessions;
  List<AgentForm> get forms => isLive ? host.forms : const [];
  List<AgentPermission> get permissions => isLive ? host.permissions : const [];
  List<AgentQueuedMessage> get queuedMessages =>
      isLive ? host.queuedMessages : const [];
  String? get queueWarning => isLive ? host.queueWarning : null;
  String? get selectedSessionId => host.selectedSessionId;
  bool get sessionLoaded => host.sessionLoaded;
  String? get connectionError => host.errorMessage;
  String? get hostVersion => host.hostVersion;
  String? get codexVersion => host.codexVersion;
  String? get workspaceDirectory => host.workspaceDirectory;
  bool get allSessionsScope => host.allSessionsScope;
  Map<String, AgentRuntimeStatus> get agentStatuses => host.agentStatuses;
  AgentRuntimeStatus? agentStatus(String id) => host.agentStatus(id);
  TopologySnapshot get topology => host.topology;
  int? get connectedClientCount => host.connectedClientCount;
  HostConnectionStatus get connectionStatus => host.status;
  TransportState get transportState => host.transportState;
  PairingState get pairingState => host.pairingState;
  String? get connectionRoute => host.connectionRoute;
  bool get isLive => host.status == HostConnectionStatus.connected;
  bool get isDemo => _demoMode;
  HostSession? get selectedSession => host.selectedSession;
  AgentCapabilityProfile? get selectedCapabilities => host.selectedCapabilities;

  SessionRunState get selectedSessionState {
    if (!isLive || selectedSession == null) return SessionRunState.stale;
    if (forms.isNotEmpty) return SessionRunState.waitingInput;
    if (permissions.isNotEmpty) return SessionRunState.waitingApproval;
    if (queuedMessages.isNotEmpty) return SessionRunState.queued;
    if (!sessionLoaded) return SessionRunState.loading;
    return SessionRunState.idle;
  }

  ToolApproval get approval => _approval;
  String? get selectedPort => _selectedPort;
  AttachmentTransferState get attachmentState => _attachmentState;
  bool get lastReplyWasQueued => _lastReplyWasQueued;

  Future<void> connect({
    required String address,
    required String pairingToken,
    int port = 8910,
    String? directUrl,
    String? relayUrl,
    String? relayRoom,
    String? relayToken,
    List<String> lanAddresses = const [],
    bool forceRelay = false,
  }) {
    _demoMode = false;
    _notify();
    return host.connect(
      address: address,
      port: port,
      pairingToken: pairingToken,
      directUrl: directUrl,
      relayUrl: relayUrl,
      relayRoom: relayRoom,
      relayToken: relayToken,
      lanAddresses: lanAddresses,
      forceRelay: forceRelay,
    );
  }

  Future<void> disconnect() => host.disconnect();

  Future<void> selectSession(HostSession session) =>
      host.selectSession(session);

  Future<void> refreshSessions() => host.refreshSessions();

  Future<void> refreshSelectedSession() => host.refreshSelectedSession();

  Future<void> createCodexSession() => host.createCodexSession();
  Future<void> createAgentSession(
    String agentId, {
    String? directory,
    bool ephemeral = false,
    bool useDefaultDirectory = false,
  }) => host.createAgentSession(
    agentId,
    directory: directory,
    ephemeral: ephemeral,
    useDefaultDirectory: useDefaultDirectory,
  );

  Future<List<HostFileEntry>> listWorkspace([String? path]) =>
      host.listWorkspace(path);
  Future<WorkspaceFileContent> readWorkspaceFile(String path) =>
      host.readWorkspaceFile(path);
  Future<void> writeWorkspaceFile(String path, String content) =>
      host.writeWorkspaceFile(path, content);
  Future<WorkspaceFileDownload> downloadWorkspaceFile(String path) =>
      host.downloadWorkspaceFile(path);
  Future<void> deleteWorkspaceFile(String path) =>
      host.deleteWorkspaceFile(path);
  Future<void> createWorkspaceDirectory(String parent, String name) =>
      host.createWorkspaceDirectory(parent, name);
  Future<void> selectWorkspace(String path, {bool allSessions = false}) =>
      host.selectWorkspace(path, allSessions: allSessions);
  Future<CodexControls> loadCodexControls() => host.loadCodexControls();
  Future<void> updateCodexSettings({
    required String model,
    required String effort,
  }) => host.updateCodexSettings(model: model, effort: effort);

  Future<void> updateClaudeSettings({
    required String model,
    required String effort,
  }) => host.updateClaudeSettings(model: model, effort: effort);
  Future<void> interruptCodex() => host.interruptCodex();
  Future<void> interruptSelectedSession() => host.interruptSelectedSession();
  Future<void> runCodexAction(String action) => host.runCodexAction(action);

  Future<void> withdrawQueuedMessage(
    AgentQueuedMessage queued, {
    String? expectedSessionId,
  }) =>
      host.withdrawQueuedMessage(queued, expectedSessionId: expectedSessionId);

  Future<void> replyToForm(AgentForm form, Map<String, Object?> answer) =>
      host.replyToForm(form, answer);

  Future<void> replyToPermission(
    AgentPermission permission, {
    required bool allow,
  }) => host.replyToPermission(permission, allow: allow);

  Future<String?> sendReply(
    String rawText, {
    List<AgentAttachment> attachments = const [],
    List<XFile> files = const [],
    String? model,
    String? effort,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty && attachments.isEmpty) return null;
    if (!isDemo && !isLive) {
      return connectionError ?? '请先连接电脑主机，再发送消息。';
    }
    _lastReplyWasQueued = false;
    if (isLive) {
      if (attachments.length != files.length) {
        return '所选文件信息不完整，请重新选择附件。';
      }
      try {
        if (files.isNotEmpty) {
          _attachmentState = AttachmentTransferState.uploading;
          _notify();
        }
        final targetSessionId = host.selectedSessionId;
        final attachmentIds = <String>[];
        for (final file in files) {
          attachmentIds.add(await host.uploadAttachment(file));
        }
        if (files.isNotEmpty) {
          _attachmentState = AttachmentTransferState.uploaded;
          _notify();
        }
        _attachmentState = AttachmentTransferState.sending;
        _notify();
        _lastReplyWasQueued = await host.sendReply(
          text,
          attachmentIds: attachmentIds,
          expectedSessionId: targetSessionId,
          model: model,
          effort: effort,
        );
        _attachmentState = AttachmentTransferState.delivered;
        _notify();
      } catch (error) {
        _attachmentState = AttachmentTransferState.failed;
        _notify();
        return error.toString().replaceFirst('Bad state: ', '');
      }
      return null;
    }

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
    _notify();
    return null;
  }

  void choosePort(String port) {
    if (!isDemo) return;
    _selectedPort = port;
    _messages.add(
      AgentMessage(
        id: 'm${_nextMessageId++}',
        author: MessageAuthor.user,
        text: '预览端口使用 $port',
        time: _timeNow(),
      ),
    );
    _notify();
  }

  void resolveApproval({required bool allow}) {
    if (!isDemo || _approval.status != ApprovalStatus.pending) return;

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
    _notify();
  }

  String _timeNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    host.removeListener(_notify);
    host.dispose();
    super.dispose();
  }
}

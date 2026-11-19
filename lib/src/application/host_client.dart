import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/models.dart';
import '../domain/transport_protocol.dart';

class HostClient extends ChangeNotifier {
  static const _secureStorage = FlutterSecureStorage();
  HostConnectionStatus _status = HostConnectionStatus.disconnected;
  TransportState _transportState = TransportState.disconnected;
  PairingState _pairingState = PairingState.none;
  List<HostSession> _sessions = const [];
  List<AgentMessage> _messages = const [];
  List<AgentForm> _forms = const [];
  List<AgentPermission> _permissions = const [];
  List<AgentQueuedMessage> _queuedMessages = const [];
  String? _queueWarning;
  String? _selectedSessionId;
  bool _sessionLoaded = false;
  String? _errorMessage;
  String? _errorCode;
  String? _hostVersion;
  String? _codexVersion;
  String? _workspaceDirectory;
  bool _allSessionsScope = false;
  Map<String, AgentRuntimeStatus> _agentStatuses = const {};
  TopologySnapshot _topology = TopologySnapshot.empty;
  int? _connectedClientCount;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _handshake;
  String? _handshakeFailureCode;
  int _connectionAttempt = 0;
  int _nextCommandId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingCommands = {};
  final Map<String, int> _lastEventSequences = {};
  final Set<String> _resyncingSessions = {};
  int _selectionGeneration = 0;
  bool _relayMode = false;
  String? _connectionRoute;
  String? _deviceId;
  String? _deviceToken;
  Completer<void>? _relayHandshake;
  Timer? _reconnectTimer;
  bool _allowReconnect = false;
  int _reconnectAttempts = 0;
  String? _lastAddress;
  String? _lastPairingToken;
  int _lastPort = 8910;
  String? _lastRelayUrl;
  String? _lastRelayRoom;
  String? _lastRelayToken;
  String? _lastDirectUrl;
  List<String> _lastLanAddresses = const [];
  bool _lastForceRelay = false;

  HostConnectionStatus get status => _status;
  TransportState get transportState => _transportState;
  PairingState get pairingState => _pairingState;
  List<HostSession> get sessions => _sessions;
  List<AgentMessage> get messages => _messages;
  List<AgentForm> get forms => _forms;
  List<AgentPermission> get permissions => _permissions;
  List<AgentQueuedMessage> get queuedMessages => _queuedMessages;
  String? get queueWarning => _queueWarning;
  String? get selectedSessionId => _selectedSessionId;
  bool get sessionLoaded => _sessionLoaded;
  String? get errorMessage => _errorMessage;
  String? get errorCode => _errorCode;
  String? get hostVersion => _hostVersion;
  String? get codexVersion => _codexVersion;
  String? get workspaceDirectory => _workspaceDirectory;
  bool get allSessionsScope => _allSessionsScope;
  Map<String, AgentRuntimeStatus> get agentStatuses =>
      Map.unmodifiable(_agentStatuses);
  int? get connectedClientCount => _connectedClientCount;
  String? get connectionRoute => _connectionRoute;
  AgentRuntimeStatus? agentStatus(String id) => _agentStatuses[id];
  TopologySnapshot get topology => _topology;

  HostSession? get selectedSession {
    final id = _selectedSessionId;
    if (id == null) return null;
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  AgentCapabilityProfile? get selectedCapabilities {
    final session = selectedSession;
    return session == null ? null : AgentCapabilityProfile.forSession(session);
  }

  Future<List<HostFileEntry>> listWorkspace([String? path]) async {
    final result = await _sendCommand(
      'workspace.list',
      {'path': ?path},
      timeout: const Duration(seconds: 8),
      timeoutMessage: '目录读取超时。请检查主机连接后重试。',
    );
    return (result['entries'] as List? ?? const [])
        .whereType<Map>()
        .map(HostFileEntry.fromJson)
        .toList(growable: false);
  }

  Future<WorkspaceFileContent> readWorkspaceFile(String path) async {
    final result = await _sendCommand('workspace.read', {'path': path});
    return WorkspaceFileContent.fromJson(result);
  }

  Future<void> writeWorkspaceFile(String path, String content) async {
    await _sendCommand('workspace.write', {'path': path, 'content': content});
  }

  Future<WorkspaceFileDownload> downloadWorkspaceFile(String path) async {
    const chunkSize = 256 * 1024;
    final bytes = BytesBuilder(copy: false);
    String? fileName;
    int? totalBytes;
    var offset = 0;
    while (totalBytes == null || offset < totalBytes) {
      final result = await _sendCommand('workspace.download', {
        'path': path,
        'offset': offset,
        'length': chunkSize,
      });
      final nextTotal = result['totalBytes'];
      final nextOffset = result['offset'];
      if (nextTotal is! int ||
          nextOffset != offset ||
          (totalBytes != null && totalBytes != nextTotal)) {
        throw StateError('主机返回的文件下载信息不一致。');
      }
      totalBytes = nextTotal;
      fileName ??= result['fileName']?.toString();
      final data = result['data'];
      if (data is! String) throw StateError('主机未返回文件数据。');
      final chunk = base64Decode(data);
      if (chunk.isEmpty && offset < totalBytes) {
        throw StateError('文件下载提前结束。');
      }
      bytes.add(chunk);
      offset += chunk.length;
      if (offset > totalBytes ||
          (result['done'] == true) != (offset == totalBytes)) {
        throw StateError('文件下载长度与主机记录不一致。');
      }
      if (totalBytes == 0 || offset == totalBytes) break;
    }
    return WorkspaceFileDownload(
      name: fileName?.isNotEmpty == true
          ? fileName!
          : path.split(RegExp(r'[/\\]')).last,
      bytes: bytes.takeBytes(),
    );
  }

  Future<void> deleteWorkspaceFile(String path) async {
    await _sendCommand('workspace.delete', {'path': path});
  }

  Future<void> createWorkspaceDirectory(String parent, String name) async {
    await _sendCommand('workspace.mkdir', {'parent': parent, 'name': name});
  }

  Future<void> selectWorkspace(String path, {bool allSessions = false}) async {
    await _sendCommand('workspace.select', {
      'path': path,
      'sessionScope': allSessions ? 'all' : 'directory',
    });
  }

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
    bool isReconnect = false,
  }) async {
    final attempt = ++_connectionAttempt;
    _lastAddress = address;
    _lastPairingToken = pairingToken;
    _lastPort = port;
    _lastDirectUrl = directUrl;
    _lastRelayUrl = relayUrl;
    _lastRelayRoom = relayRoom;
    _lastRelayToken = relayToken;
    _lastLanAddresses = List.unmodifiable(lanAddresses);
    _lastForceRelay = forceRelay;
    if (!isReconnect) {
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    await _disconnectTransport();
    if (attempt != _connectionAttempt) {
      throw StateError('连接请求已被新的配对操作替换。');
    }
    _allowReconnect = true;
    await _loadOrCreateDeviceIdentity();
    _handshakeFailureCode = null;
    _pairingState = pairingToken.trim().isEmpty
        ? PairingState.none
        : PairingState.invitationImported;
    _setState(status: HostConnectionStatus.connecting, errorMessage: null);
    final routes = <({Uri uri, bool relay, String label})>[];
    final directHosts = <String>{};
    for (final host in [...lanAddresses, address]) {
      final normalized = host.trim().replaceAll(RegExp(r'^\[|\]$'), '');
      if (normalized.isEmpty || !directHosts.add(normalized)) continue;
      routes.add((
        uri: Uri(scheme: 'ws', host: normalized, port: port, path: '/ws'),
        relay: false,
        label: '局域网主机',
      ));
    }
    if (directUrl != null && directUrl.trim().isNotEmpty) {
      final directUri = Uri.tryParse(directUrl.trim());
      if (directUri != null && directUri.scheme == 'wss') {
        final normalizedDirectUri = normalizeWebSocketUri(
          directUri,
          path: '/ws',
          allowInsecurePublic: false,
        );
        routes.add((uri: normalizedDirectUri, relay: false, label: '公网主机 WSS'));
      }
    }
    if (relayUrl != null && relayRoom != null && relayToken != null) {
      final relayUri = Uri.tryParse(relayUrl);
      if (relayUri == null) throw const FormatException('中继地址无效。');
      routes.add((
        uri: normalizeWebSocketUri(
          relayUri,
          path: '/relay',
          allowInsecurePublic:
              relayUri.scheme != 'ws' || isPrivateWebSocketHost(relayUri.host),
        ),
        relay: true,
        label: '中继',
      ));
    }
    if (forceRelay) routes.removeWhere((route) => !route.relay);
    Object? lastError;
    for (final route in routes) {
      _relayMode = route.relay;
      final channel = WebSocketChannel.connect(route.uri);
      _channel = channel;
      try {
        await channel.ready.timeout(
          Duration(seconds: route.label == '公网主机 WSS' ? 8 : 5),
        );
        if (attempt != _connectionAttempt) {
          await channel.sink.close();
          throw StateError('连接请求已被新的配对操作替换。');
        }
        _subscription = channel.stream.listen(
          (raw) {
            if (attempt == _connectionAttempt) _receiveTransportFrame(raw);
          },
          onError: (Object error) {
            if (attempt == _connectionAttempt) _fail(_toUserError(error));
          },
          onDone: () {
            if (attempt == _connectionAttempt) _onDisconnected();
          },
        );
        if (_relayMode) {
          final relayHandshake = Completer<void>();
          _relayHandshake = relayHandshake;
          _sendRelayFrame({
            'kind': 'relay.hello',
            'role': 'client',
            'room': relayRoom,
            'token': relayToken,
            if (_deviceId != null) 'peerId': _deviceId,
          });
          await relayHandshake.future.timeout(const Duration(seconds: 10));
        }
        final handshake = Completer<void>();
        _handshake = handshake;
        _sendFrame('client.hello', {
          'protocolVersion': 2,
          'pairingToken': pairingToken,
          'deviceId': _deviceId,
          'deviceToken': _deviceToken,
          'deviceName': _deviceName,
        });
        await handshake.future.timeout(const Duration(minutes: 2));
        if (attempt != _connectionAttempt) {
          throw StateError('连接请求已被新的配对操作替换。');
        }
        _connectionRoute = route.label;
        _reconnectAttempts = 0;
        return;
      } catch (error) {
        if (attempt != _connectionAttempt) {
          throw StateError('连接请求已被新的配对操作替换。');
        }
        lastError = error;
        final message = error is StateError
            ? error.message.toString()
            : _toUserError(error);
        await _subscription?.cancel();
        _subscription = null;
        try {
          await channel.sink.close().timeout(const Duration(milliseconds: 250));
        } catch (_) {}
        if (identical(_channel, channel)) _channel = null;
        _handshake = null;
        _relayHandshake = null;
        _errorMessage = message;
        if (_isPairingFailure(_handshakeFailureCode)) break;
      }
    }
    if (attempt != _connectionAttempt) {
      throw StateError('连接请求已被新的配对操作替换。');
    }
    final message = lastError is StateError
        ? lastError.message.toString()
        : lastError == null
        ? '没有可用的连接路线。'
        : _toUserError(lastError);
    final failureCode = _handshakeFailureCode;
    if (_isPairingFailure(failureCode)) {
      _allowReconnect = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      if (failureCode == 'pairing_required') {
        await clearSavedPairing();
      }
    }
    _fail(message, code: failureCode ?? 'transport_error');
    if (_allowReconnect) _scheduleReconnect();
    throw StateError(_errorMessage ?? '无法连接电脑主机。');
  }

  void _receiveTransportFrame(dynamic raw) {
    if (_relayMode && raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['kind'] == 'relay.ready') {
          final relayHandshake = _relayHandshake;
          if (relayHandshake != null && !relayHandshake.isCompleted) {
            relayHandshake.complete();
            return;
          }
        }
        if (decoded is Map && decoded['kind'] == 'relay.ping') {
          _sendRelayFrame({
            'kind': 'relay.pong',
            if (decoded['sentAt'] != null) 'sentAt': decoded['sentAt'],
          });
          return;
        }
        if (decoded is Map && decoded['kind'] == 'relay.pong') return;
        if (decoded is Map && decoded['kind'] == 'relay.error') {
          final message = decoded['message']?.toString() ?? '中继连接失败。';
          if (_relayHandshake case final relay? when !relay.isCompleted) {
            relay.completeError(StateError(message));
          }
          if (_handshake case final handshake? when !handshake.isCompleted) {
            handshake.completeError(StateError(message));
          }
          return;
        }
        if (decoded is Map && decoded['kind'] == 'relay.data') {
          _receiveEvent(decoded['data']);
          return;
        }
      } catch (_) {
        // The regular protocol parser reports malformed host messages.
      }
    }
    _receiveEvent(raw);
  }

  Future<void> disconnect() async {
    _connectionAttempt++;
    await _disconnectTransport();
  }

  Future<void> _disconnectTransport() async {
    _allowReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    try {
      await channel?.sink.close();
    } catch (_) {
      // The peer may already have closed the socket.
    }
    for (final pending in _pendingCommands.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('连接已断开。'));
      }
    }
    _pendingCommands.clear();
    if (_handshake case final handshake? when !handshake.isCompleted) {
      handshake.completeError(StateError('连接已断开。'));
    }
    _sessions = const [];
    _messages = const [];
    _forms = const [];
    _permissions = const [];
    _queuedMessages = const [];
    _queueWarning = null;
    _selectedSessionId = null;
    _sessionLoaded = false;
    _hostVersion = null;
    _connectionRoute = null;
    _codexVersion = null;
    _workspaceDirectory = null;
    _allSessionsScope = false;
    _agentStatuses = const {};
    _topology = TopologySnapshot.empty;
    _connectedClientCount = null;
    _lastEventSequences.clear();
    _resyncingSessions.clear();
    _selectionGeneration = 0;
    _pairingState = PairingState.none;
    _setState(status: HostConnectionStatus.disconnected, errorMessage: null);
  }

  Future<void> selectSession(HostSession session) async {
    final generation = ++_selectionGeneration;
    _selectedSessionId = session.id;
    _sessionLoaded = false;
    _messages = const [];
    _forms = const [];
    _permissions = const [];
    _queuedMessages = const [];
    _queueWarning = null;
    notifyListeners();
    await _sendCommand('session.select', {
      'sessionId': session.id,
      'selectionGeneration': generation,
    });
  }

  Future<void> refreshSessions() async {
    await _sendCommand('session.refresh', {});
  }

  Future<void> refreshSelectedSession() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) throw StateError('请先选择会话。');
    await _sendCommand('session.select', {
      'sessionId': sessionId,
      'selectionGeneration': _selectionGeneration,
    });
  }

  Future<void> createCodexSession() async {
    await createAgentSession('codex');
  }

  Future<void> createAgentSession(
    String agentId, {
    String? directory,
    bool ephemeral = false,
    bool useDefaultDirectory = false,
  }) async {
    if (agentId != 'codex' && agentId != 'opencode' && agentId != 'claude') {
      throw ArgumentError.value(agentId, 'agentId', '当前主机不支持此 Agent。');
    }
    final result = await _sendCommand('session.create', {
      'agentId': agentId,
      if (directory != null && directory.isNotEmpty) 'directory': directory,
      if (ephemeral) 'ephemeral': true,
      if (useDefaultDirectory) 'useDefaultDirectory': true,
    });
    await _selectCreatedSession(result);
  }

  Future<CodexControls> loadCodexControls() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_sessions.any(
          (session) =>
              session.id == sessionId &&
              (session.agentId == 'codex' ||
                  session.agentId == 'opencode' ||
                  session.agentId == 'claude'),
        )) {
      throw StateError('请先选择支持模型设置的 Agent 会话。');
    }
    final result = await _sendCommand('session.controls', {
      'sessionId': sessionId,
    });
    if (_selectedSessionId != sessionId) {
      throw StateError('会话已切换，请重新打开控制面板。');
    }
    return CodexControls.fromJson(result);
  }

  Future<void> updateCodexSettings({
    required String model,
    required String effort,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_sessions.any(
          (session) =>
              session.id == sessionId &&
              session.agentId == 'codex' &&
              session.remoteManaged,
        )) {
      throw StateError('此操作仅适用于 RemoteAISync 控制的 Codex 会话。');
    }
    await _sendCommand('session.settings.update', {
      'sessionId': sessionId,
      'model': model,
      'effort': effort,
    });
  }

  Future<void> updateClaudeSettings({
    required String model,
    required String effort,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_sessions.any(
          (session) =>
              session.id == sessionId &&
              session.agentId == 'claude' &&
              session.remoteManaged,
        )) {
      throw StateError('本地 Claude Code 历史会话不支持远程切换模型。');
    }
    await _sendCommand('session.settings.update', {
      'sessionId': sessionId,
      'model': model,
      'effort': effort,
    });
  }

  Future<void> interruptCodex() async {
    await interruptSelectedSession();
  }

  Future<void> interruptSelectedSession() async {
    final sessionId = _selectedSessionId;
    final selected = _sessions.where((session) => session.id == sessionId);
    if (sessionId == null || selected.isEmpty) {
      throw StateError('请先选择 Agent 会话。');
    }
    final session = selected.first;
    final canInterrupt =
        session.agentId == 'opencode' ||
        (session.agentId == 'claude' && session.remoteManaged) ||
        (session.agentId == 'codex' && session.remoteManaged);
    if (!canInterrupt) {
      throw StateError(
        session.agentId == 'claude'
            ? '本地 Claude Code 历史会话只能查看，请在电脑端继续。'
            : '桌面版 Codex 原会话请在电脑端停止。',
      );
    }
    await _sendCommand('session.interrupt', {'sessionId': sessionId});
  }

  Future<void> runCodexAction(String action) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_sessions.any(
          (session) =>
              session.id == sessionId &&
              session.agentId == 'codex' &&
              session.remoteManaged,
        )) {
      throw StateError('此操作仅适用于 RemoteAISync 控制的 Codex 会话。');
    }
    if (action != 'compact' && action != 'review') {
      throw ArgumentError.value(action, 'action', '不支持此 Codex 操作。');
    }
    await _sendCommand('session.action', {
      'sessionId': sessionId,
      'action': action,
    });
  }

  Future<void> _selectCreatedSession(Map<String, dynamic> result) async {
    final id = result['sessionId']?.toString();
    final matches = _sessions.where((session) => session.id == id);
    if (matches.isEmpty) throw StateError('会话已创建，但尚未同步到列表。');
    await selectSession(matches.first);
  }

  Future<String> uploadAttachment(XFile file) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) throw StateError('请先选择 Agent 会话。');
    final size = await file.length();
    final started = await _sendCommand('attachment.begin', {
      'sessionId': sessionId,
      'name': file.name,
      'sizeBytes': size,
      'mimeType': file.mimeType,
    });
    final uploadId = started['uploadId']?.toString();
    if (uploadId == null || uploadId.isEmpty) {
      throw StateError('主机未返回上传任务 ID。');
    }
    try {
      var sent = 0;
      await for (final bytes in file.openRead()) {
        for (var offset = 0; offset < bytes.length; offset += 512 * 1024) {
          final part = bytes.sublist(
            offset,
            min(offset + 512 * 1024, bytes.length),
          );
          final result = await _sendCommand('attachment.chunk', {
            'uploadId': uploadId,
            'offset': sent,
            'data': base64Encode(part),
          });
          sent += part.length;
          if (result['receivedBytes'] != sent) {
            throw StateError('主机接收的文件字节数不一致。');
          }
        }
      }
      if (sent != size) throw StateError('文件在上传过程中发生变化。');
      final finished = await _sendCommand('attachment.finish', {
        'uploadId': uploadId,
      });
      final attachmentId = finished['attachmentId']?.toString();
      if (attachmentId == null || attachmentId.isEmpty) {
        throw StateError('主机未确认附件上传完成。');
      }
      return attachmentId;
    } catch (_) {
      try {
        await _sendCommand('attachment.cancel', {'uploadId': uploadId});
      } catch (_) {
        // The connection may already be gone; the host cleans pending chunks.
      }
      rethrow;
    }
  }

  Future<bool> sendReply(
    String text, {
    List<String> attachmentIds = const [],
    String? expectedSessionId,
    String? model,
    String? effort,
  }) async {
    final sessionId = _selectedSessionId;
    final reply = text.trim();
    if (expectedSessionId != null && sessionId != expectedSessionId) {
      throw StateError('上传期间会话已切换，请重新选择文件。');
    }
    if (sessionId == null || (reply.isEmpty && attachmentIds.isEmpty)) {
      throw StateError('请先选择会话并输入回复或选择文件。');
    }
    final result = await _sendCommand('session.reply', {
      'sessionId': sessionId,
      'text': reply,
      if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
      if (model != null && model.isNotEmpty) 'model': model,
      if (effort != null && effort.isNotEmpty) 'effort': effort,
    });
    return result['delivery'] == 'queued';
  }

  Future<void> withdrawQueuedMessage(
    AgentQueuedMessage queued, {
    String? expectedSessionId,
  }) async {
    final sessionId = _selectedSessionId;
    if (expectedSessionId != null && sessionId != expectedSessionId) {
      throw StateError('会话已切换，请重新选择排队消息。');
    }
    if (sessionId == null ||
        !_sessions.any(
          (session) =>
              session.id == sessionId &&
              session.agentId == 'codex' &&
              !session.remoteManaged,
        ) ||
        !_queuedMessages.any((item) => item.id == queued.id)) {
      throw StateError('这条消息已不在当前桌面会话的待处理队列中。');
    }
    await _sendCommand('session.queue.delete', {
      'sessionId': sessionId,
      'queuedSubmissionId': queued.id,
    });
  }

  Future<void> replyToForm(AgentForm form, Map<String, Object?> answer) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null || form.sessionId != sessionId) {
      throw StateError('表单不属于当前会话。');
    }
    await _sendCommand('session.form.reply', {
      'sessionId': sessionId,
      'formId': form.id,
      'answer': answer,
    });
  }

  Future<void> replyToPermission(
    AgentPermission permission, {
    required bool allow,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null || permission.sessionId != sessionId) {
      throw StateError('审批不属于当前会话。');
    }
    await _sendCommand('session.permission.reply', {
      'sessionId': sessionId,
      'requestId': permission.id,
      'decision': allow ? 'once' : 'reject',
    });
  }

  void _receiveEvent(dynamic raw) {
    if (raw is! String) return;
    try {
      final event = jsonDecode(raw);
      if (event is! Map ||
          (event['schemaVersion'] != 1 && event['schemaVersion'] != 2)) {
        return;
      }
      final sequence = event['sequence'] ?? event['seq'];
      if (sequence is num) {
        final sessionId = event['sessionId']?.toString() ?? '';
        final value = sequence.toInt();
        final previous = _lastEventSequences[sessionId] ?? 0;
        if (value <= previous) return;
        if (previous > 0 &&
            value > previous + 1 &&
            sessionId == _selectedSessionId) {
          _queueWarning = '检测到事件缺口，正在重新同步当前会话。';
          notifyListeners();
          _resyncSelectedSession();
        }
        _lastEventSequences[sessionId] = value;
      }
      final kind = event['kind']?.toString();
      final payload = event['payload'];
      if (payload is! Map) return;
      final data = payload.cast<String, dynamic>();
      switch (kind) {
        case 'topology.ping':
          _sendFrame('topology.pong', {
            'sentAt': data['sentAt']?.toString(),
          }, channel: 'telemetry');
          break;
        case 'topology.snapshot':
          _readTopology(data['topology']);
          break;
        case 'host.ready':
          if (_deviceId != null && _deviceToken != null) {
            unawaited(_persistDeviceIdentity());
          }
          _hostVersion = data['openCodeVersion']?.toString();
          _codexVersion = data['codexVersion']?.toString();
          _readHostStatus(data);
          _readTopology(data['topology']);
          _pairingState = PairingState.paired;
          _setState(status: HostConnectionStatus.connected, errorMessage: null);
          if (_handshake case final handshake? when !handshake.isCompleted) {
            handshake.complete();
          }
          break;
        case 'pairing.pending':
          _pairingState = PairingState.waitingApproval;
          _errorMessage = '等待电脑主机批准此设备';
          notifyListeners();
          break;
        case 'host.snapshot':
          _readHostStatus(data);
          _readTopology(data['topology']);
          _sessions = (data['sessions'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (item) => HostSession(
                  id: item['id']?.toString() ?? '',
                  title: item['title']?.toString() ?? '未命名会话',
                  updatedAt: item['updatedAt']?.toString() ?? '',
                  agentId: item['agentId']?.toString() ?? 'opencode',
                  remoteManaged: item['remoteManaged'] == true,
                  pendingCount: item['pendingCount'] is num
                      ? (item['pendingCount'] as num).toInt()
                      : 0,
                  directory: item['directory']?.toString(),
                ),
              )
              .where((session) => session.id.isNotEmpty)
              .toList(growable: false);
          if (_selectedSessionId != null &&
              !_sessions.any((session) => session.id == _selectedSessionId)) {
            _selectedSessionId = null;
            _sessionLoaded = false;
            _selectionGeneration++;
            _messages = const [];
            _forms = const [];
            _permissions = const [];
            _queuedMessages = const [];
            _queueWarning = null;
          }
          notifyListeners();
          break;
        case 'session.snapshot':
          if (data['sessionId']?.toString() != _selectedSessionId) return;
          final generation = data['selectionGeneration'];
          if (generation != null &&
              (generation is! num ||
                  generation.toInt() != _selectionGeneration)) {
            return;
          }
          _sessionLoaded = true;
          _messages = (data['messages'] as List? ?? const [])
              .whereType<Map>()
              .map(_messageFromJson)
              .toList(growable: false);
          _forms = (data['forms'] as List? ?? const [])
              .whereType<Map>()
              .map(AgentForm.fromJson)
              .where((form) => form.id.isNotEmpty)
              .toList(growable: false);
          _permissions = (data['permissions'] as List? ?? const [])
              .whereType<Map>()
              .map(AgentPermission.fromJson)
              .where((permission) => permission.id.isNotEmpty)
              .toList(growable: false);
          _queuedMessages = (data['queuedMessages'] as List? ?? const [])
              .whereType<Map>()
              .map(AgentQueuedMessage.fromJson)
              .where((item) => item.id.isNotEmpty)
              .toList(growable: false);
          _queueWarning = data['queueWarning']?.toString();
          if (_selectedSessionId != null) {
            _resyncingSessions.remove(_selectedSessionId!);
          }
          notifyListeners();
          break;
        case 'command.result':
          final id = data['commandId']?.toString();
          final completer = id == null ? null : _pendingCommands.remove(id);
          if (completer != null && !completer.isCompleted) {
            completer.complete(data);
          }
          _errorMessage = null;
          break;
        case 'command.error':
        case 'host.warning':
          final id = data['commandId']?.toString();
          final completer = id == null ? null : _pendingCommands.remove(id);
          final message = data['message']?.toString() ?? '主机服务返回错误。';
          _errorCode = data['code']?.toString();
          final pendingHandshake = _handshake;
          if (kind == 'command.error' &&
              pendingHandshake != null &&
              !pendingHandshake.isCompleted) {
            final code = _errorCode;
            if (_isPairingFailure(code)) {
              _handshakeFailureCode = code;
              _allowReconnect = false;
              _reconnectTimer?.cancel();
              _reconnectTimer = null;
            }
          }
          _errorMessage = message;
          if (_handshake case final handshake? when !handshake.isCompleted) {
            handshake.completeError(StateError(message));
          }
          if (completer != null && !completer.isCompleted) {
            completer.completeError(StateError(message));
          }
          notifyListeners();
          break;
      }
    } on FormatException {
      _fail('主机返回了无法识别的消息。');
    }
  }

  Future<void> _loadOrCreateDeviceIdentity() async {
    try {
      _deviceId ??= await _secureStorage.read(key: 'remoteaisync.deviceId');
      _deviceToken ??= await _secureStorage.read(
        key: 'remoteaisync.deviceToken',
      );
    } catch (_) {
      // Flutter tests and restricted browser contexts may not have secure storage.
    }
    if (_deviceId == null || _deviceToken == null) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      _deviceId = base64Url.encode(bytes).replaceAll('=', '');
      final tokenBytes = List<int>.generate(
        32,
        (_) => Random.secure().nextInt(256),
      );
      _deviceToken = base64Url.encode(tokenBytes).replaceAll('=', '');
    }
  }

  Future<void> _persistDeviceIdentity() async {
    try {
      await _secureStorage.write(
        key: 'remoteaisync.deviceId',
        value: _deviceId,
      );
      await _secureStorage.write(
        key: 'remoteaisync.deviceToken',
        value: _deviceToken,
      );
    } catch (_) {
      // Keep the current pairing usable if secure storage is unavailable.
    }
  }

  Future<void> clearSavedPairing() async {
    try {
      await _secureStorage.delete(key: 'remoteaisync.deviceId');
      await _secureStorage.delete(key: 'remoteaisync.deviceToken');
    } catch (_) {
      // Clearing is best effort on platforms without secure storage.
    }
    _deviceId = null;
    _deviceToken = null;
  }

  String get _deviceName => kIsWeb
      ? 'RemoteAISync Web'
      : 'RemoteAISync ${defaultTargetPlatform.name}';

  void _readHostStatus(Map<String, dynamic> data) {
    final directory = data['workspaceDirectory']?.toString();
    if (directory != null && directory.isNotEmpty) {
      _workspaceDirectory = directory;
    }
    _allSessionsScope = data['allSessions'] == true;
    final count = data['connectedClients'];
    if (count is num && count >= 0) {
      _connectedClientCount = count.toInt();
    }
    final rawAgents = data['agents'];
    if (rawAgents is List) {
      _agentStatuses = {
        for (final item in rawAgents.whereType<Map>())
          if (item['id']?.toString().isNotEmpty == true)
            item['id'].toString(): AgentRuntimeStatus.fromJson(item),
      };
      _hostVersion ??= _agentStatuses['opencode']?.version;
      _codexVersion ??= _agentStatuses['codex']?.version;
      return;
    }

    // Keep old hosts usable while they only report version fields.
    final legacy = <String, AgentRuntimeStatus>{};
    final openCodeVersion = data['openCodeVersion']?.toString();
    final codexVersion = data['codexVersion']?.toString();
    if (openCodeVersion?.isNotEmpty == true) {
      legacy['opencode'] = AgentRuntimeStatus(
        id: 'opencode',
        name: 'OpenCode',
        availability: AgentAvailability.available,
        version: openCodeVersion,
      );
    }
    if (codexVersion?.isNotEmpty == true) {
      legacy['codex'] = AgentRuntimeStatus(
        id: 'codex',
        name: 'Codex',
        availability: AgentAvailability.available,
        version: codexVersion,
      );
    }
    if (legacy.isNotEmpty) _agentStatuses = legacy;
  }

  void _readTopology(Object? value) {
    if (value is! Map) return;
    _topology = TopologySnapshot.fromJson(value);
    notifyListeners();
  }

  Future<Map<String, dynamic>> _sendCommand(
    String kind,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 20),
    String timeoutMessage = '主机没有及时确认操作。',
  }) {
    if (_channel == null || _status != HostConnectionStatus.connected) {
      return Future.error(StateError('当前未连接电脑主机。'));
    }
    final commandId = 'cmd-${_nextCommandId++}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingCommands[commandId] = completer;
    _sendFrame(kind, payload, commandId: commandId);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingCommands.remove(commandId);
        throw TimeoutException(timeoutMessage);
      },
    );
  }

  void _resyncSelectedSession() {
    final sessionId = _selectedSessionId;
    if (sessionId == null || !_resyncingSessions.add(sessionId)) return;
    unawaited(
      _sendCommand('session.select', {
        'sessionId': sessionId,
        'selectionGeneration': _selectionGeneration,
      }).catchError((_) {
        _resyncingSessions.remove(sessionId);
        return <String, dynamic>{};
      }),
    );
  }

  void _sendFrame(
    String kind,
    Map<String, Object?> payload, {
    String? commandId,
    String channel = 'control',
  }) {
    final frame = {
      'schemaVersion': 2,
      'commandId': commandId ?? 'hello-${_nextCommandId++}',
      'messageId': 'msg-${_nextCommandId++}',
      'sessionId': _selectedSessionId ?? '',
      'kind': kind,
      'channel': channel,
      'expectedRevision': 0,
      'payload': payload,
    };
    if (_relayMode) {
      _sendRelayFrame({'kind': 'relay.data', 'data': jsonEncode(frame)});
    } else {
      _channel?.sink.add(jsonEncode(frame));
    }
  }

  void _sendRelayFrame(Map<String, Object?> frame) {
    _channel?.sink.add(jsonEncode(frame));
  }

  void _onDisconnected() {
    _failPendingCommands(StateError('电脑主机连接已断开。'));
    if (_status == HostConnectionStatus.disconnected) return;
    _channel = null;
    _subscription = null;
    _clearHostData();
    _pairingState = PairingState.none;
    if (_isPairingFailure(_handshakeFailureCode)) {
      _allowReconnect = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _errorCode = _handshakeFailureCode;
      _setState(
        status: HostConnectionStatus.error,
        errorMessage: _errorMessage ?? '需要重新扫描主机配对二维码。',
      );
      return;
    }
    if (!_allowReconnect || _status == HostConnectionStatus.error) {
      _setState(
        status: HostConnectionStatus.disconnected,
        errorMessage: _errorMessage,
      );
      return;
    }
    _setState(
      status: HostConnectionStatus.connecting,
      errorMessage: '电脑主机已断开，正在尝试恢复连接。',
    );
    _errorCode = 'transport_error';
    _transportState = TransportState.reconnecting;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_allowReconnect || _reconnectTimer != null || _lastAddress == null) {
      return;
    }
    final delaySeconds = min(30, 3 * (1 << min(_reconnectAttempts, 4)));
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      _reconnectTimer = null;
      if (!_allowReconnect || _lastAddress == null) return;
      try {
        await connect(
          address: _lastAddress!,
          pairingToken: _lastPairingToken ?? '',
          port: _lastPort,
          directUrl: _lastDirectUrl,
          relayUrl: _lastRelayUrl,
          relayRoom: _lastRelayRoom,
          relayToken: _lastRelayToken,
          lanAddresses: _lastLanAddresses,
          forceRelay: _lastForceRelay,
          isReconnect: true,
        );
      } catch (_) {
        if (_allowReconnect) _scheduleReconnect();
      }
    });
  }

  bool _isPairingFailure(String? code) =>
      code == 'pairing_required' || code == 'pairing_invite_invalid';

  void _fail(String message, {String code = 'transport_error'}) {
    _failPendingCommands(StateError(message));
    if (_handshake case final handshake? when !handshake.isCompleted) {
      handshake.completeError(StateError(message));
    }
    _channel?.sink.close();
    _channel = null;
    _clearHostData();
    _pairingState = PairingState.none;
    if (_isPairingFailure(_handshakeFailureCode)) {
      _allowReconnect = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    _errorCode = _isPairingFailure(_handshakeFailureCode)
        ? _handshakeFailureCode
        : code;
    _setState(status: HostConnectionStatus.error, errorMessage: message);
  }

  void _failPendingCommands(Object error) {
    for (final pending in _pendingCommands.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pendingCommands.clear();
  }

  void _clearHostData() {
    _sessions = const [];
    _messages = const [];
    _forms = const [];
    _permissions = const [];
    _queuedMessages = const [];
    _queueWarning = null;
    _selectedSessionId = null;
    _sessionLoaded = false;
    _hostVersion = null;
    _codexVersion = null;
    _lastEventSequences.clear();
    _resyncingSessions.clear();
    _selectionGeneration = 0;
    for (final pending in _pendingCommands.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('电脑主机已断开。'));
      }
    }
    _pendingCommands.clear();
  }

  void _setState({
    required HostConnectionStatus status,
    required String? errorMessage,
  }) {
    _status = status;
    _transportState = switch (status) {
      HostConnectionStatus.disconnected => TransportState.disconnected,
      HostConnectionStatus.connecting => TransportState.connecting,
      HostConnectionStatus.connected => TransportState.connected,
      HostConnectionStatus.error => TransportState.failed,
    };
    _errorMessage = errorMessage;
    if (errorMessage == null) _errorCode = null;
    notifyListeners();
  }

  String _toUserError(Object error) {
    if (error is TimeoutException) return '连接超时，请确认电脑主机已启动。';
    return '无法连接电脑主机，请检查地址、端口和主机运行状态。';
  }

  AgentMessage _messageFromJson(Map item) {
    final author = switch (item['author']?.toString()) {
      'user' => MessageAuthor.user,
      'tool' => MessageAuthor.tool,
      'system' => MessageAuthor.system,
      _ => MessageAuthor.assistant,
    };
    return AgentMessage(
      id: item['id']?.toString() ?? '',
      author: author,
      text: item['text']?.toString() ?? '',
      time: item['time']?.toString() ?? '',
      groupId: item['groupId']?.toString(),
    );
  }

  @override
  void dispose() {
    _connectionAttempt++;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}

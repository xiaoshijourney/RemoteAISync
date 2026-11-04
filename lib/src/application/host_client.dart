import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/models.dart';

class HostClient extends ChangeNotifier {
  HostConnectionStatus _status = HostConnectionStatus.disconnected;
  List<HostSession> _sessions = const [];
  List<AgentMessage> _messages = const [];
  String? _selectedSessionId;
  String? _errorMessage;
  String? _hostVersion;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _handshake;
  int _nextCommandId = 0;
  final Map<String, Completer<void>> _pendingCommands = {};

  HostConnectionStatus get status => _status;
  List<HostSession> get sessions => _sessions;
  List<AgentMessage> get messages => _messages;
  String? get selectedSessionId => _selectedSessionId;
  String? get errorMessage => _errorMessage;
  String? get hostVersion => _hostVersion;

  Future<void> connect({
    required String address,
    required String pairingToken,
    int port = 8787,
  }) async {
    await disconnect();
    _setState(status: HostConnectionStatus.connecting, errorMessage: null);
    final uri = Uri(
      scheme: 'ws',
      host: address.trim().replaceAll(RegExp(r'^\[|\]$'), ''),
      port: port,
      path: '/ws',
    );
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    try {
      await channel.ready.timeout(const Duration(seconds: 5));
      _subscription = channel.stream.listen(
        _receiveEvent,
        onError: (Object error) => _fail(_toUserError(error)),
        onDone: _onDisconnected,
      );
      final handshake = Completer<void>();
      _handshake = handshake;
      _sendFrame('client.hello', {'pairingToken': pairingToken});
      await handshake.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      final message = error is StateError
          ? error.message.toString()
          : _toUserError(error);
      _fail(message);
      throw StateError(_errorMessage ?? '无法连接电脑主机。');
    } finally {
      _handshake = null;
    }
  }

  Future<void> disconnect() async {
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
    _selectedSessionId = null;
    _hostVersion = null;
    _setState(status: HostConnectionStatus.disconnected, errorMessage: null);
  }

  Future<void> selectSession(HostSession session) async {
    _selectedSessionId = session.id;
    _messages = const [];
    notifyListeners();
    await _sendCommand('session.select', {'sessionId': session.id});
  }

  Future<void> sendReply(String text) async {
    final sessionId = _selectedSessionId;
    final reply = text.trim();
    if (sessionId == null || reply.isEmpty) {
      throw StateError('请先选择会话并输入回复。');
    }
    await _sendCommand('session.reply', {
      'sessionId': sessionId,
      'text': reply,
    });
  }

  void _receiveEvent(dynamic raw) {
    if (raw is! String) return;
    try {
      final event = jsonDecode(raw);
      if (event is! Map || event['schemaVersion'] != 1) return;
      final kind = event['kind']?.toString();
      final payload = event['payload'];
      if (payload is! Map) return;
      final data = payload.cast<String, dynamic>();
      switch (kind) {
        case 'host.ready':
          _hostVersion = data['openCodeVersion']?.toString();
          _setState(status: HostConnectionStatus.connected, errorMessage: null);
          if (_handshake case final handshake? when !handshake.isCompleted) {
            handshake.complete();
          }
          break;
        case 'host.snapshot':
          _sessions = (data['sessions'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (item) => HostSession(
                  id: item['id']?.toString() ?? '',
                  title: item['title']?.toString() ?? '未命名会话',
                  updatedAt: item['updatedAt']?.toString() ?? '',
                ),
              )
              .where((session) => session.id.isNotEmpty)
              .toList(growable: false);
          if (_selectedSessionId != null &&
              !_sessions.any((session) => session.id == _selectedSessionId)) {
            _selectedSessionId = null;
            _messages = const [];
          }
          notifyListeners();
          break;
        case 'session.snapshot':
          if (data['sessionId']?.toString() != _selectedSessionId) return;
          _messages = (data['messages'] as List? ?? const [])
              .whereType<Map>()
              .map(_messageFromJson)
              .toList(growable: false);
          notifyListeners();
          break;
        case 'command.result':
          final id = data['commandId']?.toString();
          final completer = id == null ? null : _pendingCommands.remove(id);
          if (completer != null && !completer.isCompleted) completer.complete();
          _errorMessage = null;
          break;
        case 'command.error':
        case 'host.warning':
          final id = data['commandId']?.toString();
          final completer = id == null ? null : _pendingCommands.remove(id);
          final message = data['message']?.toString() ?? '主机服务返回错误。';
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

  Future<void> _sendCommand(String kind, Map<String, Object?> payload) {
    if (_channel == null || _status != HostConnectionStatus.connected) {
      return Future<void>.error(StateError('当前未连接电脑主机。'));
    }
    final commandId = 'cmd-${_nextCommandId++}';
    final completer = Completer<void>();
    _pendingCommands[commandId] = completer;
    _sendFrame(kind, payload, commandId: commandId);
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pendingCommands.remove(commandId);
        throw TimeoutException('主机没有及时确认操作。');
      },
    );
  }

  void _sendFrame(
    String kind,
    Map<String, Object?> payload, {
    String? commandId,
  }) {
    _channel?.sink.add(
      jsonEncode({
        'schemaVersion': 1,
        'commandId': commandId ?? 'hello-${_nextCommandId++}',
        'sessionId': _selectedSessionId ?? '',
        'kind': kind,
        'expectedRevision': 0,
        'payload': payload,
      }),
    );
  }

  void _onDisconnected() {
    if (_status == HostConnectionStatus.disconnected) return;
    _channel = null;
    _subscription = null;
    _clearHostData();
    if (_status == HostConnectionStatus.error) return;
    _setState(
      status: HostConnectionStatus.disconnected,
      errorMessage: '电脑主机已断开。',
    );
  }

  void _fail(String message) {
    if (_handshake case final handshake? when !handshake.isCompleted) {
      handshake.completeError(StateError(message));
    }
    _channel?.sink.close();
    _channel = null;
    _clearHostData();
    _setState(status: HostConnectionStatus.error, errorMessage: message);
  }

  void _clearHostData() {
    _sessions = const [];
    _messages = const [];
    _selectedSessionId = null;
    _hostVersion = null;
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
    _errorMessage = errorMessage;
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
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}

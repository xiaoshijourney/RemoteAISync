import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:remote_ai_sync/src/domain/models.dart';
import 'open_code_api.dart';

class OpenCodeBridge {
  OpenCodeBridge._({
    required this.api,
    required this.openCodeVersion,
    required this.openCodeProcess,
    required this.pairingToken,
  });

  final OpenCodeApi api;
  final String openCodeVersion;
  final String pairingToken;
  final Process openCodeProcess;
  late final _RemoteSocketServer _server;
  late final Timer _refreshTimer;
  Timer? _eventDebounce;
  bool _closed = false;
  Future<void>? _refreshTask;
  List<OpenCodeSession> _sessions = const [];
  final Map<String, List<AgentMessage>> _messages = {};

  void _startBackgroundTasks() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refresh());
    });
    unawaited(_watchEvents());
  }

  static Future<OpenCodeBridge> start({
    required String projectDirectory,
    required int websocketPort,
    String? pairingToken,
    String executable = 'opencode',
  }) async {
    final directory = Directory(projectDirectory).absolute;
    if (!await directory.exists()) {
      throw ArgumentError.value(projectDirectory, 'projectDirectory');
    }

    final apiPort = await _freeLoopbackPort();
    final password = _randomSecret();
    final process = await Process.start(
      executable,
      ['serve', '--hostname', '127.0.0.1', '--port', '$apiPort'],
      workingDirectory: directory.path,
      environment: {
        ...Platform.environment,
        'OPENCODE_SERVER_USERNAME': 'opencode',
        'OPENCODE_SERVER_PASSWORD': password,
      },
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final api = OpenCodeApi(
      baseUri: Uri.parse('http://127.0.0.1:$apiPort'),
      password: password,
      projectDirectory: directory.path,
    );
    try {
      final version = await _waitForOpenCode(api, process);
      final bridge = OpenCodeBridge._(
        api: api,
        openCodeVersion: version,
        openCodeProcess: process,
        pairingToken: pairingToken ?? _randomSecret(),
      );
      bridge._server = await _RemoteSocketServer.bind(
        port: websocketPort,
        bridge: bridge,
      );
      bridge._startBackgroundTasks();
      return bridge;
    } catch (_) {
      await api.close();
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
      rethrow;
    }
  }

  String get pairingTokenValue => pairingToken;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _eventDebounce?.cancel();
    _refreshTimer.cancel();
    await _server.close();
    await api.close();
    openCodeProcess.kill();
    await openCodeProcess.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => -1,
    );
  }

  Future<void> _watchEvents() async {
    while (!_closed) {
      try {
        await for (final event in api.events()) {
          if (_closed) return;
          if (event['type'] != 'server.connected') _scheduleRefresh();
        }
      } catch (_) {
        if (_closed) return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _scheduleRefresh() {
    _eventDebounce?.cancel();
    _eventDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() {
    if (_closed) return Future<void>.value();
    return _refreshTask ??= _performRefresh().whenComplete(() {
      _refreshTask = null;
    });
  }

  Future<void> _performRefresh() async {
    try {
      _sessions = await api.listSessions();
      _messages.clear();
      final selectedIds = _server.readyClients
          .map((client) => client.selectedSessionId)
          .whereType<String>()
          .where((id) => _sessions.any((session) => session.id == id))
          .toSet();
      for (final id in selectedIds) {
        _messages[id] = await api.listMessages(id);
      }
      for (final client in _server.readyClients) {
        _sendHostSnapshot(client);
        final selectedId = client.selectedSessionId;
        if (selectedId != null && _messages.containsKey(selectedId)) {
          _sendSessionSnapshot(client, selectedId);
        }
      }
    } catch (error) {
      for (final client in _server.readyClients) {
        client.sendEvent('host.warning', {'message': _safeError(error)});
      }
    }
  }

  void _sendHostSnapshot(_RemoteClient client) {
    client.sendEvent('host.snapshot', {
      'sessions': _sessions.map((session) => session.toJson()).toList(),
    });
  }

  void _sendSessionSnapshot(_RemoteClient client, String sessionId) {
    final matching = _sessions.where((item) => item.id == sessionId);
    final session = matching.isEmpty ? null : matching.first;
    if (session == null) return;
    client.sendEvent('session.snapshot', {
      'sessionId': session.id,
      'title': session.title,
      'messages': (_messages[sessionId] ?? const [])
          .map(_messageToJson)
          .toList(),
      'messageLimit': 100,
    }, sessionId: sessionId);
  }

  Future<void> _handleMessage(
    _RemoteClient client,
    Map<String, dynamic> frame,
  ) async {
    final commandId = frame['commandId']?.toString();
    final kind = frame['kind']?.toString();
    final payload = frame['payload'];
    if (frame['schemaVersion'] != 1 || kind == null || payload is! Map) {
      client.sendEvent('command.error', {
        'commandId': commandId,
        'message': '无效的协议消息。',
      });
      return;
    }

    if (kind == 'client.hello') {
      final suppliedToken = payload['pairingToken']?.toString() ?? '';
      if (!_constantTimeEquals(suppliedToken, pairingToken)) {
        client.sendEvent('command.error', {
          'commandId': commandId,
          'message': '配对令牌无效，请确认与本次主机启动时显示的令牌一致。',
        });
        await client.close();
        return;
      }
      client.isReady = true;
      client.sendEvent('host.ready', {
        'protocolVersion': 1,
        'openCodeVersion': openCodeVersion,
        'capabilities': {
          'sessionRead': true,
          'sessionReply': true,
          'attachments': false,
          'approvals': false,
          'remoteAccess': false,
        },
      });
      await _refresh();
      return;
    }
    if (!client.isReady) {
      client.sendEvent('command.error', {
        'commandId': commandId,
        'message': '请先完成协议握手。',
      });
      return;
    }

    final data = payload.cast<String, dynamic>();
    switch (kind) {
      case 'session.select':
        final sessionId = data['sessionId']?.toString();
        if (sessionId == null ||
            !_sessions.any((session) => session.id == sessionId)) {
          client.sendEvent('command.error', {
            'commandId': commandId,
            'message': '找不到此 OpenCode 会话。',
          });
          return;
        }
        client.selectedSessionId = sessionId;
        try {
          _messages[sessionId] = await api.listMessages(sessionId);
          _sendSessionSnapshot(client, sessionId);
          _sendCommandResult(client, commandId);
        } catch (error) {
          _sendCommandError(client, commandId, error);
        }
        return;
      case 'session.refresh':
        await _refresh();
        _sendCommandResult(client, commandId);
        return;
      case 'session.reply':
        await _sendReply(client, commandId, data);
        return;
      default:
        client.sendEvent('command.error', {
          'commandId': commandId,
          'message': '当前主机不支持此操作。',
        });
    }
  }

  Future<void> _sendReply(
    _RemoteClient client,
    String? commandId,
    Map<String, dynamic> data,
  ) async {
    final sessionId = data['sessionId']?.toString();
    final text = data['text']?.toString().trim() ?? '';
    if (sessionId == null ||
        sessionId != client.selectedSessionId ||
        !_sessions.any((session) => session.id == sessionId)) {
      _sendCommandError(
        client,
        commandId,
        const OpenCodeApiException('会话未选中或已不存在。'),
      );
      return;
    }
    if (text.isEmpty) {
      client.sendEvent('command.error', {
        'commandId': commandId,
        'message': '回复内容不能为空。',
      });
      return;
    }
    try {
      await api.sendReply(sessionId, text);
      _sendCommandResult(client, commandId);
      _scheduleRefresh();
    } catch (error) {
      _sendCommandError(client, commandId, error);
    }
  }

  void _sendCommandResult(_RemoteClient client, String? commandId) {
    client.sendEvent('command.result', {'commandId': commandId, 'ok': true});
  }

  void _sendCommandError(
    _RemoteClient client,
    String? commandId,
    Object error,
  ) {
    client.sendEvent('command.error', {
      'commandId': commandId,
      'message': _safeError(error),
    });
  }
}

class _RemoteSocketServer {
  _RemoteSocketServer._({required this.httpServer, required this.bridge}) {
    httpServer.listen(_handleRequest);
  }

  final HttpServer httpServer;
  final OpenCodeBridge bridge;
  final Set<_RemoteClient> _clients = {};
  final Map<String, int> _sequences = {};

  Iterable<_RemoteClient> get readyClients =>
      _clients.where((client) => client.isReady);

  static Future<_RemoteSocketServer> bind({
    required int port,
    required OpenCodeBridge bridge,
  }) async {
    final httpServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    return _RemoteSocketServer._(httpServer: httpServer, bridge: bridge);
  }

  void _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/health' && request.method == 'GET') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'status': 'ok', 'protocolVersion': 1}));
      await request.response.close();
      return;
    }
    if (request.uri.path != '/ws' ||
        request.method != 'GET' ||
        !_isAllowedOrigin(request.headers.value('origin'))) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    final client = _RemoteClient(socket, _nextSequence);
    _clients.add(client);
    socket.listen(
      (data) => _receive(client, data),
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
      cancelOnError: true,
    );
  }

  void _receive(_RemoteClient client, Object? raw) async {
    if (raw is! String || raw.length > 1024 * 1024) {
      client.sendEvent('command.error', {
        'message': '仅支持不超过 1 MiB 的 JSON 控制消息。',
      });
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Expected object.');
      await bridge._handleMessage(client, decoded.cast<String, dynamic>());
    } on FormatException {
      client.sendEvent('command.error', {'message': 'JSON 消息格式无效。'});
    } catch (error) {
      client.sendEvent('command.error', {'message': _safeError(error)});
    }
  }

  int _nextSequence(String sessionId) {
    final next = (_sequences[sessionId] ?? 0) + 1;
    _sequences[sessionId] = next;
    return next;
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      await client.close();
    }
    await httpServer.close(force: true);
  }
}

class _RemoteClient {
  _RemoteClient(this.socket, this._nextSequence);

  final WebSocket socket;
  final int Function(String sessionId) _nextSequence;
  bool isReady = false;
  String? selectedSessionId;

  void sendEvent(
    String kind,
    Map<String, Object?> payload, {
    String sessionId = '',
  }) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'eventId': _newId(),
        'deviceId': 'remoteaisync-host',
        'sessionId': sessionId,
        'seq': _nextSequence(sessionId),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'kind': kind,
        'payload': payload,
      }),
    );
  }

  Future<void> close() async {
    if (socket.readyState == WebSocket.open) await socket.close();
  }
}

Map<String, Object?> _messageToJson(AgentMessage message) => {
  'id': message.id,
  'author': message.author.name,
  'text': message.text,
  'time': message.time,
};

String _safeError(Object error) {
  if (error is OpenCodeApiException) return error.message;
  return '无法完成操作，请检查本机 OpenCode 服务。';
}

bool _isAllowedOrigin(String? origin) {
  if (origin == null) return true;
  final uri = Uri.tryParse(origin);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
}

bool _constantTimeEquals(String left, String right) {
  var difference = left.length ^ right.length;
  final length = max(left.length, right.length);
  for (var i = 0; i < length; i++) {
    final a = i < left.length ? left.codeUnitAt(i) : 0;
    final b = i < right.length ? right.codeUnitAt(i) : 0;
    difference |= a ^ b;
  }
  return difference == 0;
}

Future<int> _freeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<String> _waitForOpenCode(OpenCodeApi api, Process process) async {
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if (exited) throw StateError('OpenCode server exited during startup.');
    try {
      return await api.version().timeout(const Duration(seconds: 2));
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  throw TimeoutException('OpenCode server did not become ready.');
}

String _randomSecret() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String _newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

class RelayServer {
  RelayServer._(
    this._server,
    this._clientToken,
    this._hostToken,
    this._storageDirectory,
    this._registrationCodeLifetime,
    this._allowLegacyRooms,
    this._secure,
  ) {
    _server.listen(_handleRequest);
  }

  final HttpServer _server;
  final String _clientToken;
  final String _hostToken;
  final Directory? _storageDirectory;
  final Duration _registrationCodeLifetime;
  final bool _allowLegacyRooms;
  final bool _secure;
  final Map<String, _RelayRoom> _rooms = {};
  final Map<String, _RelayCredentials> _registeredRooms = {};
  final Map<String, _RegistrationCode> _registrationCodes = {};
  final Map<WebSocket, DateTime> _socketConnectedAt = {};
  final Map<WebSocket, DateTime> _socketLastSeen = {};
  final Map<WebSocket, int> _socketBytesIn = {};
  final Map<WebSocket, int> _socketBytesOut = {};
  final Map<WebSocket, int> _socketReconnects = {};
  final Map<WebSocket, String> _socketProtocols = {};
  final Map<WebSocket, DateTime> _socketPingSentAt = {};
  final Map<WebSocket, int> _socketRttMs = {};
  final Map<String, int> _peerConnectionCounts = {};
  Timer? _heartbeatTimer;

  int get port => _server.port;
  InternetAddress get address => _server.address;
  int get roomCount => _rooms.length;
  int get hostCount => _rooms.values.where((room) => room.host != null).length;
  int get clientCount =>
      _rooms.values.fold(0, (sum, room) => sum + room.clients.length);

  Map<String, Object?> topologySnapshot({String? roomId}) {
    final now = DateTime.now().toUtc();
    final rooms = _rooms.entries
        .where((entry) => roomId == null || entry.key == roomId)
        .toList(growable: false);
    final activeProtocols = <String>{};
    for (final entry in rooms) {
      if (entry.value.host case final host?) {
        final protocol = _socketProtocols[host];
        if (protocol != null) activeProtocols.add(protocol);
      }
      for (final client in entry.value.clients.values) {
        final protocol = _socketProtocols[client];
        if (protocol != null) activeProtocols.add(protocol);
      }
    }
    final relayProtocol = _secure
        ? 'wss'
        : activeProtocols.length > 1
        ? 'ws+wss'
        : activeProtocols.firstOrNull ?? 'ws';
    final nodes = <Map<String, Object?>>[
      {
        'id': 'relay',
        'role': 'relay',
        'online': true,
        'protocol': relayProtocol,
        'address': '${_server.address.address}:$port',
        'heartbeatAt': now.toIso8601String(),
        'health': 'healthy',
      },
      for (final entry in rooms)
        if (entry.value.host case final roomHost?)
          {
            'id': 'host:${entry.key}',
            'role': 'host',
            'online': roomHost.readyState == WebSocket.open,
            'protocol': _socketProtocols[roomHost] ?? (_secure ? 'wss' : 'ws'),
            'route': 'relay',
            'connectedAt': _socketConnectedAt[roomHost]?.toIso8601String(),
            'heartbeatAt': _socketLastSeen[roomHost]?.toIso8601String(),
            'rttMs': _socketRttMs[roomHost],
            'bytesIn': _socketBytesIn[roomHost] ?? 0,
            'bytesOut': _socketBytesOut[roomHost] ?? 0,
            'reconnects': _socketReconnects[roomHost] ?? 0,
            'health': _socketHealth(roomHost),
          },
      for (final entry in rooms)
        for (final client in entry.value.clients.entries)
          {
            'id': 'client:${entry.key}:${client.key}',
            'role': 'client',
            'online': client.value.readyState == WebSocket.open,
            'protocol':
                _socketProtocols[client.value] ?? (_secure ? 'wss' : 'ws'),
            'route': 'relay',
            'connectedAt': _socketConnectedAt[client.value]?.toIso8601String(),
            'heartbeatAt': _socketLastSeen[client.value]?.toIso8601String(),
            'rttMs': _socketRttMs[client.value],
            'bytesIn': _socketBytesIn[client.value] ?? 0,
            'bytesOut': _socketBytesOut[client.value] ?? 0,
            'reconnects': _socketReconnects[client.value] ?? 0,
            'health': _socketHealth(client.value),
          },
    ];
    final links = <Map<String, Object?>>[
      for (final entry in rooms)
        if (entry.value.host case final roomHost?)
          {
            'id': 'relay-host:${entry.key}',
            'from': 'host:${entry.key}',
            'to': 'relay',
            'online': roomHost.readyState == WebSocket.open,
            'protocol': _socketProtocols[roomHost] ?? (_secure ? 'wss' : 'ws'),
            'route': 'relay',
            'rttMs': _socketRttMs[roomHost],
            'bytesIn': _socketBytesIn[roomHost] ?? 0,
            'bytesOut': _socketBytesOut[roomHost] ?? 0,
            'reconnects': _socketReconnects[roomHost] ?? 0,
            'health': _socketHealth(roomHost),
          },
      for (final entry in rooms)
        for (final client in entry.value.clients.entries)
          {
            'id': 'relay-link:${entry.key}:${client.key}',
            'from': 'relay',
            'to': 'client:${entry.key}:${client.key}',
            'online': client.value.readyState == WebSocket.open,
            'protocol':
                _socketProtocols[client.value] ?? (_secure ? 'wss' : 'ws'),
            'route': 'relay',
            'rttMs': _socketRttMs[client.value],
            'bytesIn': _socketBytesIn[client.value] ?? 0,
            'bytesOut': _socketBytesOut[client.value] ?? 0,
            'reconnects': _socketReconnects[client.value] ?? 0,
            'health': _socketHealth(client.value),
          },
    ];
    return {
      'revision': now.millisecondsSinceEpoch,
      'updatedAt': now.toIso8601String(),
      'nodes': nodes,
      'links': links,
    };
  }

  static Future<RelayServer> bind({
    required int port,
    required String clientToken,
    required String hostToken,
    InternetAddress? bindAddress,
    String? storageDirectory,
    Duration registrationCodeLifetime = const Duration(minutes: 10),
    SecurityContext? securityContext,
  }) async {
    if (clientToken.length < 32 || hostToken.length < 32) {
      throw ArgumentError(
        'Relay client and host tokens must each be at least 32 characters.',
      );
    }
    if (_constantTimeEquals(clientToken, hostToken)) {
      throw ArgumentError('Relay host and client tokens must be different.');
    }
    final directory = storageDirectory == null
        ? null
        : Directory(storageDirectory);
    final relay = RelayServer._(
      securityContext == null
          ? await HttpServer.bind(
              bindAddress ?? InternetAddress.loopbackIPv4,
              port,
            )
          : await HttpServer.bindSecure(
              bindAddress ?? InternetAddress.loopbackIPv4,
              port,
              securityContext,
            ),
      clientToken,
      hostToken,
      directory,
      registrationCodeLifetime,
      storageDirectory == null,
      securityContext != null,
    );
    await relay._loadRegisteredRooms();
    relay._heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      relay._sendHeartbeats();
    });
    return relay;
  }

  void _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/admin/registration-code' &&
        request.method == 'POST') {
      if (!_isAdminRequest(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      _registrationCodes.removeWhere(
        (_, entry) => entry.expiresAt.isBefore(DateTime.now()),
      );
      final id = _newChannelId();
      final code = _newSecret();
      final expiresAt = DateTime.now().add(_registrationCodeLifetime);
      _registrationCodes[id] = _RegistrationCode(code, expiresAt);
      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'id': id,
            'code': code,
            'expiresAt': expiresAt.toUtc().toIso8601String(),
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path == '/admin/registration-code' &&
        request.method == 'DELETE') {
      if (!_isAdminRequest(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final removed =
          _registrationCodes.remove(request.uri.queryParameters['id']) != null;
      request.response
        ..statusCode = removed ? HttpStatus.ok : HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'revoked': removed}));
      await request.response.close();
      return;
    }
    if (request.uri.path == '/register-host' && request.method == 'POST') {
      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await utf8.decoder.bind(request).join());
        if (decoded is! Map) throw const FormatException();
        body = decoded.cast<String, dynamic>();
      } on FormatException {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final code = body['registrationCode']?.toString() ?? '';
      final entry = _registrationCodes.entries
          .where((candidate) => _constantTimeEquals(candidate.value.code, code))
          .firstOrNull;
      if (entry == null || !entry.value.expiresAt.isAfter(DateTime.now())) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': '注册码无效、已过期或已使用。'}));
        await request.response.close();
        return;
      }
      _registrationCodes.remove(entry.key);
      final room = _newSecret().replaceAll('-', '_');
      final credentials = _RelayCredentials(
        hostToken: _newSecret(),
        clientToken: _newSecret(),
      );
      _registeredRooms[room] = credentials;
      await _saveRegisteredRooms();
      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'room': room,
            'hostToken': credentials.hostToken,
            'clientToken': credentials.clientToken,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path == '/health' && request.method == 'GET') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'status': 'ok',
            'rooms': roomCount,
            'hosts': hostCount,
            'clients': clientCount,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path == '/status' && request.method == 'GET') {
      if (request.connectionInfo?.remoteAddress.isLoopback != true) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set('Cache-Control', 'no-store')
        ..write(
          jsonEncode({
            'status': 'ok',
            'rooms': roomCount,
            'hosts': hostCount,
            'clients': clientCount,
            'topology': topologySnapshot(),
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path != '/relay' || request.method != 'GET') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _socketConnectedAt[socket] = DateTime.now().toUtc();
    _socketLastSeen[socket] = DateTime.now().toUtc();
    _socketBytesIn[socket] = 0;
    _socketBytesOut[socket] = 0;
    final forwardedProtocol = request.headers
        .value('x-forwarded-proto')
        ?.split(',')
        .first
        .trim()
        .toLowerCase();
    final trustedProxy =
        request.connectionInfo?.remoteAddress.isLoopback == true;
    _socketProtocols[socket] =
        _secure || (trustedProxy && forwardedProtocol == 'https')
        ? 'wss'
        : 'ws';
    var authenticated = false;
    String? roomId;
    String? role;
    _RelayRoom? room;
    socket.listen(
      (raw) {
        _socketLastSeen[socket] = DateTime.now().toUtc();
        _socketBytesIn[socket] =
            (_socketBytesIn[socket] ?? 0) +
            (raw is String
                ? utf8.encode(raw).length
                : raw is List<int>
                ? raw.length
                : 0);
        if (raw is! String || raw.length > 1024 * 1024) {
          unawaited(
            socket.close(WebSocketStatus.messageTooBig, 'Invalid relay frame'),
          );
          return;
        }
        Map<String, dynamic> frame;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) throw const FormatException();
          frame = decoded.cast<String, dynamic>();
        } on FormatException {
          unawaited(
            socket.close(
              WebSocketStatus.invalidFramePayloadData,
              'Invalid JSON',
            ),
          );
          return;
        }
        if (!authenticated) {
          final token = frame['token']?.toString() ?? '';
          final candidateRoom = frame['room']?.toString() ?? '';
          final candidateRole = frame['role']?.toString() ?? '';
          final peerId = frame['peerId']?.toString();
          final validRoom = RegExp(
            r'^[A-Za-z0-9_-]{12,96}$',
          ).hasMatch(candidateRoom);
          final validRole = {'host', 'client'}.contains(candidateRole);
          final validPeerId =
              peerId != null &&
                  peerId.isNotEmpty &&
                  peerId.length <= 128 &&
                  RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(peerId)
              ? peerId
              : null;
          final credentials = _registeredRooms[candidateRoom];
          final expectedToken = candidateRole == 'host'
              ? credentials?.hostToken ?? (_allowLegacyRooms ? _hostToken : '')
              : validRoom
              ? credentials?.clientToken ??
                    (_allowLegacyRooms ? clientTokenForRoom(candidateRoom) : '')
              : '';
          if (frame['kind'] != 'relay.hello' ||
              !validRole ||
              !validRoom ||
              !_constantTimeEquals(token, expectedToken)) {
            unawaited(_reject(socket, '中继身份验证失败。'));
            return;
          }
          if (candidateRole == 'client' && !_rooms.containsKey(candidateRoom)) {
            unawaited(_reject(socket, '此房间的主机尚未注册。'));
            return;
          }
          roomId = candidateRoom;
          role = candidateRole;
          if (validPeerId != null) {
            final peerKey = '$candidateRoom:$candidateRole:$validPeerId';
            final previousConnections = _peerConnectionCounts[peerKey] ?? 0;
            _socketReconnects[socket] = previousConnections;
            _peerConnectionCounts[peerKey] = previousConnections + 1;
          }
          final currentRoom = _rooms.putIfAbsent(candidateRoom, _RelayRoom.new);
          room = currentRoom;
          if (candidateRole == 'host') {
            if (currentRoom.host != null) {
              unawaited(_reject(socket, '此房间已有主机连接。'));
              return;
            }
            currentRoom.host = socket;
            authenticated = true;
            _sendFrame(
              socket,
              jsonEncode({
                'kind': 'relay.ready',
                'role': 'host',
                'room': candidateRoom,
                'clientToken':
                    credentials?.clientToken ??
                    (_allowLegacyRooms
                        ? clientTokenForRoom(candidateRoom)
                        : ''),
                'topology': topologySnapshot(roomId: candidateRoom),
              }),
            );
            return;
          }
          if (currentRoom.host == null) {
            unawaited(_reject(socket, '主机尚未连接到中继。'));
            return;
          }
          if (validPeerId != null) {
            for (final previous
                in currentRoom.clients.entries
                    .where(
                      (entry) =>
                          currentRoom.clientPeerIds[entry.key] == validPeerId,
                    )
                    .toList(growable: false)) {
              currentRoom.clients.remove(previous.key);
              currentRoom.clientPeerIds.remove(previous.key);
              _sendFrame(
                currentRoom.host!,
                jsonEncode({'kind': 'relay.close', 'channelId': previous.key}),
              );
              if (previous.value.readyState == WebSocket.open) {
                unawaited(previous.value.close());
              }
            }
          }
          final channelId = _newChannelId();
          currentRoom.clients[channelId] = socket;
          if (validPeerId != null) {
            currentRoom.clientPeerIds[channelId] = validPeerId;
          }
          authenticated = true;
          _sendFrame(
            currentRoom.host!,
            jsonEncode({'kind': 'relay.open', 'channelId': channelId}),
          );
          _sendRoomTopology(candidateRoom);
          return;
        }

        if (frame['kind'] == 'relay.ping') {
          _sendFrame(
            socket,
            jsonEncode({
              'kind': 'relay.pong',
              if (frame['sentAt'] != null) 'sentAt': frame['sentAt'],
            }),
          );
          return;
        }
        if (frame['kind'] == 'relay.pong') {
          final sentAt = _socketPingSentAt.remove(socket);
          if (sentAt != null) {
            _socketRttMs[socket] = DateTime.now()
                .toUtc()
                .difference(sentAt)
                .inMilliseconds;
            if (roomId case final activeRoomId?) {
              _sendRoomTopology(activeRoomId);
            }
          }
          return;
        }

        if (role == 'host') {
          _handleHostFrame(room!, frame, roomId: roomId);
        } else if (frame['kind'] == 'relay.data') {
          String? channelId;
          final currentRoom = room!;
          for (final entry in currentRoom.clients.entries) {
            if (identical(entry.value, socket)) {
              channelId = entry.key;
              break;
            }
          }
          final client = channelId == null
              ? null
              : currentRoom.clients[channelId];
          final data = frame['data'];
          if (client != null && data is String && data.length <= 1024 * 1024) {
            final host = currentRoom.host;
            if (host != null) {
              _sendFrame(
                host,
                jsonEncode({
                  'kind': 'relay.data',
                  'channelId': channelId,
                  'data': data,
                }),
              );
            }
          }
        }
      },
      onDone: () {
        _removeSocket(roomId, role, room, socket);
        _forgetSocket(socket);
        if (roomId case final activeRoomId?) {
          if (_rooms.containsKey(activeRoomId)) {
            _sendRoomTopology(activeRoomId);
          }
        }
      },
      onError: (_) {
        _removeSocket(roomId, role, room, socket);
        _forgetSocket(socket);
        if (roomId case final activeRoomId?) {
          if (_rooms.containsKey(activeRoomId)) {
            _sendRoomTopology(activeRoomId);
          }
        }
      },
      cancelOnError: true,
    );
  }

  void _handleHostFrame(
    _RelayRoom room,
    Map<String, dynamic> frame, {
    required String? roomId,
  }) {
    final kind = frame['kind'];
    final channelId = frame['channelId']?.toString();
    if (kind == 'relay.ready') {
      final client = room.clients[channelId];
      if (client != null) {
        _sendFrame(client, jsonEncode({'kind': 'relay.ready'}));
      }
    } else if (kind == 'relay.data') {
      final data = frame['data'];
      if (data is String && data.length <= 1024 * 1024) {
        final client = room.clients[channelId];
        if (client != null) {
          _sendFrame(client, jsonEncode({'kind': 'relay.data', 'data': data}));
        }
      }
    } else if (kind == 'relay.close') {
      final client = room.clients.remove(channelId);
      if (channelId != null) room.clientPeerIds.remove(channelId);
      if (client != null && client.readyState == WebSocket.open) {
        unawaited(client.close());
      }
      if (roomId != null) _sendRoomTopology(roomId);
    }
  }

  void _sendHeartbeats() {
    final now = DateTime.now().toUtc();
    for (final entry in _rooms.entries) {
      final room = entry.value;
      final sockets = <WebSocket>[?room.host, ...room.clients.values];
      for (final socket in sockets) {
        final lastSeen = _socketLastSeen[socket];
        if (lastSeen == null ||
            now.difference(lastSeen) > const Duration(seconds: 20)) {
          unawaited(
            socket.close(WebSocketStatus.goingAway, 'Heartbeat timeout'),
          );
          continue;
        }
        _socketPingSentAt[socket] = now;
        _sendFrame(
          socket,
          jsonEncode({'kind': 'relay.ping', 'sentAt': now.toIso8601String()}),
        );
      }
      _sendRoomTopology(entry.key);
    }
  }

  void _sendRoomTopology(String roomId) {
    final host = _rooms[roomId]?.host;
    if (host == null || host.readyState != WebSocket.open) return;
    _sendFrame(
      host,
      jsonEncode({
        'kind': 'relay.topology',
        'topology': topologySnapshot(roomId: roomId),
      }),
    );
  }

  void _removeSocket(
    String? roomId,
    String? role,
    _RelayRoom? room,
    WebSocket socket,
  ) {
    if (room == null || roomId == null || role == null) return;
    if (role == 'host' && identical(room.host, socket)) {
      room.host = null;
      for (final client in room.clients.values) {
        if (client.readyState == WebSocket.open) unawaited(client.close());
      }
      room.clients.clear();
      room.clientPeerIds.clear();
    } else {
      room.clients.removeWhere((channelId, value) {
        final remove = identical(value, socket);
        if (remove) room.clientPeerIds.remove(channelId);
        return remove;
      });
    }
    if (room.host == null && room.clients.isEmpty) _rooms.remove(roomId);
  }

  void _forgetSocket(WebSocket socket) {
    _socketConnectedAt.remove(socket);
    _socketLastSeen.remove(socket);
    _socketBytesIn.remove(socket);
    _socketBytesOut.remove(socket);
    _socketReconnects.remove(socket);
    _socketProtocols.remove(socket);
    _socketPingSentAt.remove(socket);
    _socketRttMs.remove(socket);
  }

  String _socketHealth(WebSocket socket) {
    if (socket.readyState != WebSocket.open) return 'offline';
    final lastSeen = _socketLastSeen[socket];
    if (lastSeen == null) return 'degraded';
    return DateTime.now().toUtc().difference(lastSeen) <=
            const Duration(seconds: 15)
        ? 'healthy'
        : 'degraded';
  }

  void _sendFrame(WebSocket socket, String encoded) {
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(encoded);
    } on StateError {
      return;
    } on WebSocketException {
      return;
    }
    _socketBytesOut[socket] =
        (_socketBytesOut[socket] ?? 0) + utf8.encode(encoded).length;
  }

  Future<void> _reject(WebSocket socket, String message) async {
    if (socket.readyState == WebSocket.open) {
      _sendFrame(
        socket,
        jsonEncode({'kind': 'relay.error', 'message': message}),
      );
      await socket.close(
        WebSocketStatus.policyViolation,
        'Relay authentication failed',
      );
    }
  }

  Future<void> close() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final room in _rooms.values.toList()) {
      if (room.host?.readyState == WebSocket.open) await room.host!.close();
      for (final client in room.clients.values.toList()) {
        if (client.readyState == WebSocket.open) await client.close();
      }
    }
    _rooms.clear();
    _socketConnectedAt.clear();
    _socketLastSeen.clear();
    _socketBytesIn.clear();
    _socketBytesOut.clear();
    _socketReconnects.clear();
    _socketProtocols.clear();
    _peerConnectionCounts.clear();
    _socketPingSentAt.clear();
    _socketRttMs.clear();
    await _server.close(force: true);
  }

  bool _isAdminRequest(HttpRequest request) =>
      request.connectionInfo?.remoteAddress.isLoopback == true &&
      _constantTimeEquals(
        request.headers.value('x-remoteaisync-admin-token') ?? '',
        _clientToken,
      );

  Future<void> _loadRegisteredRooms() async {
    final directory = _storageDirectory;
    if (directory == null) return;
    final file = File(
      '${directory.path}${Platform.pathSeparator}.remoteaisync'
      '${Platform.pathSeparator}relay-rooms.json',
    );
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.value is! Map) continue;
          final data = (entry.value as Map).cast<String, dynamic>();
          final hostToken = data['hostToken']?.toString() ?? '';
          final clientToken = data['clientToken']?.toString() ?? '';
          if (hostToken.length >= 32 && clientToken.length >= 32) {
            _registeredRooms[entry.key.toString()] = _RelayCredentials(
              hostToken: hostToken,
              clientToken: clientToken,
            );
          }
        }
      }
    } on FormatException {
      // A damaged registry should not prevent the relay from starting.
    }
  }

  Future<void> _saveRegisteredRooms() async {
    final directory = _storageDirectory;
    if (directory == null) return;
    final file = File(
      '${directory.path}${Platform.pathSeparator}.remoteaisync'
      '${Platform.pathSeparator}relay-rooms.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        for (final entry in _registeredRooms.entries)
          entry.key: {
            'hostToken': entry.value.hostToken,
            'clientToken': entry.value.clientToken,
          },
      }),
      flush: true,
    );
  }

  String clientTokenForRoom(String roomId) => base64Url
      .encode(
        Hmac(
          sha256,
          utf8.encode(_clientToken),
        ).convert(utf8.encode('remoteaisync-room:$roomId')).bytes,
      )
      .replaceAll('=', '');
}

class _RelayRoom {
  WebSocket? host;
  final Map<String, WebSocket> clients = {};
  final Map<String, String> clientPeerIds = {};
}

class _RelayCredentials {
  const _RelayCredentials({required this.hostToken, required this.clientToken});
  final String hostToken;
  final String clientToken;
}

class _RegistrationCode {
  const _RegistrationCode(this.code, this.expiresAt);
  final String code;
  final DateTime expiresAt;
}

String _newChannelId() => base64Url
    .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

String _newSecret() => base64Url
    .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

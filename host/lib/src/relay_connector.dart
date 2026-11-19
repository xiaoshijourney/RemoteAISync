import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge.dart';

class RelayConnector {
  RelayConnector({
    required this.bridge,
    required this.relayUri,
    required this.roomId,
    required this.hostToken,
  });

  final AgentBridge bridge;
  final Uri relayUri;
  final String roomId;
  final String hostToken;
  final Map<String, WebSocket> _channels = {};
  bool _closed = false;
  WebSocket? _relay;

  Future<void> start() async {
    while (!_closed) {
      try {
        final uri = relayUri.replace(path: '/relay', query: null);
        final relay = await WebSocket.connect(
          uri.toString(),
        ).timeout(const Duration(seconds: 10));
        _relay = relay;
        final ready = Completer<void>();
        relay.listen(
          (raw) {
            if (raw is! String) return;
            final frame = jsonDecode(raw);
            if (frame is! Map) return;
            final message = frame.cast<String, dynamic>();
            if (message['kind'] == 'relay.ping') {
              if (relay.readyState == WebSocket.open) {
                relay.add(
                  jsonEncode({
                    'kind': 'relay.pong',
                    if (message['sentAt'] != null) 'sentAt': message['sentAt'],
                  }),
                );
              }
            } else if (message['kind'] == 'relay.topology') {
              final topology = message['topology'];
              if (topology is Map) {
                bridge.setRelayTopology(topology.cast<String, dynamic>());
              }
            } else if (message['kind'] == 'relay.ready' &&
                message['role'] == 'host') {
              final room = message['room']?.toString() ?? roomId;
              final clientToken = message['clientToken']?.toString() ?? '';
              if (clientToken.isNotEmpty) {
                bridge.setRelayConnection(
                  url: relayUri.replace(path: '', query: null).toString(),
                  room: room,
                  clientToken: clientToken,
                  connected: true,
                );
              }
              final topology = message['topology'];
              if (topology is Map) {
                bridge.setRelayTopology(topology.cast<String, dynamic>());
              }
              if (!ready.isCompleted) ready.complete();
            } else if (message['kind'] == 'relay.open') {
              unawaited(_openChannel(relay, message['channelId'].toString()));
            } else if (message['kind'] == 'relay.data') {
              final channel = _channels[message['channelId']?.toString()];
              final data = message['data'];
              if (channel?.readyState == WebSocket.open && data is String) {
                channel!.add(data);
              }
            } else if (message['kind'] == 'relay.close') {
              final channel = _channels.remove(
                message['channelId']?.toString(),
              );
              if (channel?.readyState == WebSocket.open) {
                unawaited(channel!.close());
              }
            }
          },
          onDone: () {
            bridge.setRelayConnection(
              url: bridge.relayUrl ?? relayUri.toString(),
              room: bridge.relayRoom ?? roomId,
              clientToken: bridge.relayClientToken ?? '',
              connected: false,
            );
            if (!ready.isCompleted) {
              ready.completeError(StateError('Relay disconnected'));
            }
          },
          onError: (Object error) {
            bridge.setRelayConnection(
              url: bridge.relayUrl ?? relayUri.toString(),
              room: bridge.relayRoom ?? roomId,
              clientToken: bridge.relayClientToken ?? '',
              connected: false,
            );
            if (!ready.isCompleted) ready.completeError(error);
          },
        );
        relay.add(
          jsonEncode({
            'kind': 'relay.hello',
            'role': 'host',
            'room': roomId,
            'token': hostToken,
            'peerId': 'host',
          }),
        );
        await ready.future.timeout(const Duration(seconds: 10));
        await relay.done;
      } catch (_) {
        // Reconnect below; transient network loss must not stop local agents.
      } finally {
        bridge.setRelayConnection(
          url: bridge.relayUrl ?? relayUri.toString(),
          room: bridge.relayRoom ?? roomId,
          clientToken: bridge.relayClientToken ?? '',
          connected: false,
        );
        _relay = null;
        for (final socket in _channels.values.toList()) {
          if (socket.readyState == WebSocket.open) await socket.close();
        }
        _channels.clear();
      }
      if (!_closed) await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> _openChannel(WebSocket relay, String channelId) async {
    WebSocket? local;
    try {
      bridge.registerRelayChannel(
        channelId,
        sendData: (data) {
          if (relay.readyState != WebSocket.open) return;
          try {
            relay.add(
              jsonEncode({
                'kind': 'relay.data',
                'channelId': channelId,
                'data': data,
              }),
            );
          } on StateError {
            // The relay can close between checking readyState and writing.
          }
        },
        onDone: () {
          _channels.remove(channelId);
          if (relay.readyState != WebSocket.open) return;
          try {
            relay.add(
              jsonEncode({'kind': 'relay.close', 'channelId': channelId}),
            );
          } on StateError {
            // The relay can close while a local channel is shutting down.
          }
        },
      );
      local = await WebSocket.connect(
        'ws://127.0.0.1:${bridge.websocketPort}/relay-channel/$channelId',
      );
      _channels[channelId] = local;
      relay.add(jsonEncode({'kind': 'relay.ready', 'channelId': channelId}));
    } catch (_) {
      bridge.unregisterRelayChannel(channelId);
      if (local?.readyState == WebSocket.open) await local!.close();
      if (relay.readyState == WebSocket.open) {
        relay.add(jsonEncode({'kind': 'relay.close', 'channelId': channelId}));
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    final relay = _relay;
    if (relay?.readyState == WebSocket.open) await relay!.close();
  }
}

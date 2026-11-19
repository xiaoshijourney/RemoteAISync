import 'dart:convert';

/// Transport protocol used by a WebSocket route.
enum TransportProtocol { ws, wss }

extension TransportProtocolX on TransportProtocol {
  String get scheme => name;

  bool get isSecure => this == TransportProtocol.wss;

  static TransportProtocol? fromScheme(String? scheme) {
    return switch (scheme?.toLowerCase()) {
      'ws' => TransportProtocol.ws,
      'wss' => TransportProtocol.wss,
      _ => null,
    };
  }
}

/// Normalises a host or relay WebSocket endpoint while keeping the caller's
/// TLS choice explicit. This is shared by the Flutter client and the Dart
/// runtime so route selection cannot silently downgrade a public endpoint.
Uri normalizeWebSocketUri(
  Uri input, {
  required String path,
  bool allowInsecurePublic = true,
}) {
  final protocol = TransportProtocolX.fromScheme(input.scheme);
  if (protocol == null || input.host.isEmpty) {
    throw FormatException('无效的 WebSocket 地址：$input');
  }
  if (!allowInsecurePublic &&
      protocol == TransportProtocol.ws &&
      !isPrivateWebSocketHost(input.host)) {
    throw FormatException('公网地址必须使用 wss://：$input');
  }
  final normalizedPath = path.startsWith('/') ? path : '/$path';
  return input.replace(path: normalizedPath, query: null, fragment: null);
}

/// Public peers require an explicitly advertised TLS listener; private peers
/// may use either WS or WSS.
bool isHostTransportPeerAllowed({
  required bool privateNetworkPeer,
  required bool tlsListener,
  required bool publicHostEnabled,
}) => privateNetworkPeer || (tlsListener && publicHostEnabled);

bool isPrivateWebSocketHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower == '::1') return true;
  final parts = lower.split('.');
  if (parts.length != 4) return false;
  final values = parts.map(int.tryParse).toList();
  if (values.any((value) => value == null || value < 0 || value > 255)) {
    return false;
  }
  final a = values[0]!;
  final b = values[1]!;
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}

/// Versioned message envelope. Version 1 fields remain readable so an older
/// host can still be used while a client is upgraded.
class ProtocolEnvelope {
  const ProtocolEnvelope({
    required this.kind,
    required this.payload,
    this.channel = 'control',
    this.messageId,
    this.requestId,
    this.eventId,
    this.sequence,
    this.timestamp,
    this.topologyRevision,
    this.sessionRevision,
    this.sessionId,
    this.schemaVersion = 2,
  });

  final String kind;
  final Map<String, dynamic> payload;
  final String channel;
  final String? messageId;
  final String? requestId;
  final String? eventId;
  final int? sequence;
  final DateTime? timestamp;
  final int? topologyRevision;
  final int? sessionRevision;
  final String? sessionId;
  final int schemaVersion;

  Map<String, dynamic> toJson({bool legacy = false}) {
    final data = <String, dynamic>{
      'schemaVersion': legacy ? 1 : schemaVersion,
      'kind': kind,
      'payload': payload,
      if (channel != 'control') 'channel': channel,
      if (messageId != null) 'messageId': messageId,
      if (requestId != null) 'requestId': requestId,
      if (eventId != null) 'eventId': eventId,
      if (sequence != null) 'sequence': sequence,
      if (sequence != null) 'seq': sequence,
      if (timestamp != null) 'timestamp': timestamp!.toUtc().toIso8601String(),
      if (timestamp != null) 'createdAt': timestamp!.toUtc().toIso8601String(),
      if (topologyRevision != null) 'topologyRevision': topologyRevision,
      if (sessionRevision != null) 'sessionRevision': sessionRevision,
      if (sessionId != null && sessionId!.isNotEmpty) 'sessionId': sessionId,
    };
    return data;
  }

  String encode({bool legacy = false}) => jsonEncode(toJson(legacy: legacy));

  static ProtocolEnvelope? tryParse(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = decoded.cast<String, dynamic>();
      final payload = data['payload'];
      final kind = data['kind']?.toString();
      if (kind == null || payload is! Map) return null;
      final timestamp = DateTime.tryParse(
        data['timestamp']?.toString() ?? data['createdAt']?.toString() ?? '',
      );
      final sequenceValue = data['sequence'] ?? data['seq'];
      return ProtocolEnvelope(
        schemaVersion: (data['schemaVersion'] as num?)?.toInt() ?? 1,
        kind: kind,
        payload: payload.cast<String, dynamic>(),
        channel: data['channel']?.toString() ?? 'control',
        messageId: data['messageId']?.toString(),
        requestId: data['requestId']?.toString(),
        eventId: data['eventId']?.toString(),
        sequence: sequenceValue is num ? sequenceValue.toInt() : null,
        timestamp: timestamp,
        topologyRevision: data['topologyRevision'] is num
            ? (data['topologyRevision'] as num).toInt()
            : null,
        sessionRevision: data['sessionRevision'] is num
            ? (data['sessionRevision'] as num).toInt()
            : null,
        sessionId: data['sessionId']?.toString(),
      );
    } on FormatException {
      return null;
    }
  }
}

class TopologyNode {
  const TopologyNode({
    required this.id,
    required this.role,
    required this.online,
    this.protocol,
    this.route,
    this.address,
    this.connectedAt,
    this.heartbeatAt,
    this.rttMs,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.reconnects = 0,
    this.health = 'unknown',
  });

  final String id;
  final String role;
  final bool online;
  final String? protocol;
  final String? route;
  final String? address;
  final DateTime? connectedAt;
  final DateTime? heartbeatAt;
  final int? rttMs;
  final int bytesIn;
  final int bytesOut;
  final int reconnects;
  final String health;

  factory TopologyNode.fromJson(Map json) => TopologyNode(
    id: json['id']?.toString() ?? '',
    role: json['role']?.toString() ?? 'unknown',
    online: json['online'] == true,
    protocol: json['protocol']?.toString(),
    route: json['route']?.toString(),
    address: json['address']?.toString(),
    connectedAt: DateTime.tryParse(json['connectedAt']?.toString() ?? ''),
    heartbeatAt: DateTime.tryParse(json['heartbeatAt']?.toString() ?? ''),
    rttMs: json['rttMs'] is num ? (json['rttMs'] as num).toInt() : null,
    bytesIn: json['bytesIn'] is num ? (json['bytesIn'] as num).toInt() : 0,
    bytesOut: json['bytesOut'] is num ? (json['bytesOut'] as num).toInt() : 0,
    reconnects: json['reconnects'] is num
        ? (json['reconnects'] as num).toInt()
        : 0,
    health: json['health']?.toString() ?? 'unknown',
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role,
    'online': online,
    if (protocol != null) 'protocol': protocol,
    if (route != null) 'route': route,
    if (address != null) 'address': address,
    if (connectedAt != null)
      'connectedAt': connectedAt!.toUtc().toIso8601String(),
    if (heartbeatAt != null)
      'heartbeatAt': heartbeatAt!.toUtc().toIso8601String(),
    if (rttMs != null) 'rttMs': rttMs,
    'bytesIn': bytesIn,
    'bytesOut': bytesOut,
    'reconnects': reconnects,
    'health': health,
  };
}

class TopologyLink {
  const TopologyLink({
    required this.id,
    required this.from,
    required this.to,
    required this.online,
    this.protocol,
    this.route,
    this.rttMs,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.reconnects = 0,
    this.health = 'unknown',
  });

  final String id;
  final String from;
  final String to;
  final bool online;
  final String? protocol;
  final String? route;
  final int? rttMs;
  final int bytesIn;
  final int bytesOut;
  final int reconnects;
  final String health;

  factory TopologyLink.fromJson(Map json) => TopologyLink(
    id: json['id']?.toString() ?? '',
    from: json['from']?.toString() ?? '',
    to: json['to']?.toString() ?? '',
    online: json['online'] == true,
    protocol: json['protocol']?.toString(),
    route: json['route']?.toString(),
    rttMs: json['rttMs'] is num ? (json['rttMs'] as num).toInt() : null,
    bytesIn: json['bytesIn'] is num ? (json['bytesIn'] as num).toInt() : 0,
    bytesOut: json['bytesOut'] is num ? (json['bytesOut'] as num).toInt() : 0,
    reconnects: json['reconnects'] is num
        ? (json['reconnects'] as num).toInt()
        : 0,
    health: json['health']?.toString() ?? 'unknown',
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'from': from,
    'to': to,
    'online': online,
    if (protocol != null) 'protocol': protocol,
    if (route != null) 'route': route,
    if (rttMs != null) 'rttMs': rttMs,
    'bytesIn': bytesIn,
    'bytesOut': bytesOut,
    'reconnects': reconnects,
    'health': health,
  };
}

class TopologySnapshot {
  const TopologySnapshot({
    this.revision = 0,
    this.updatedAt,
    this.nodes = const [],
    this.links = const [],
  });

  final int revision;
  final DateTime? updatedAt;
  final List<TopologyNode> nodes;
  final List<TopologyLink> links;

  factory TopologySnapshot.fromJson(Map json) => TopologySnapshot(
    revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
    updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    nodes: (json['nodes'] as List? ?? const [])
        .whereType<Map>()
        .map(TopologyNode.fromJson)
        .toList(growable: false),
    links: (json['links'] as List? ?? const [])
        .whereType<Map>()
        .map(TopologyLink.fromJson)
        .toList(growable: false),
  );

  static const empty = TopologySnapshot();
}

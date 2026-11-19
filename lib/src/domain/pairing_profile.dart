import 'dart:convert';

/// The payload embedded in a host generated `remoteaisync://pair` code.
class PairingProfile {
  const PairingProfile({
    required this.invite,
    required this.port,
    required this.lanAddresses,
    this.directUrl,
    this.relayUrl,
    this.relayRoom,
    this.relayToken,
  });

  final String invite;
  final int port;
  final List<String> lanAddresses;
  final String? directUrl;
  final String? relayUrl;
  final String? relayRoom;
  final String? relayToken;

  bool get hasRelay =>
      relayUrl?.isNotEmpty == true &&
      relayRoom?.isNotEmpty == true &&
      relayToken?.isNotEmpty == true;

  bool get hasDirectPublicRoute => directUrl?.isNotEmpty == true;

  static PairingProfile parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'remoteaisync' || uri.host != 'pair') {
      throw const FormatException('不是 RemoteAISync 配对二维码');
    }
    final encoded = uri.queryParameters['data'];
    if (encoded == null || encoded.isEmpty) {
      throw const FormatException('二维码中没有配对数据');
    }
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
    );
    if (decoded is! Map) throw const FormatException('配对数据格式错误');
    final profile = decoded.cast<String, dynamic>();
    if (profile['version'] != 1) {
      throw const FormatException('不支持此二维码版本');
    }
    final invite = profile['invite']?.toString() ?? '';
    final port = int.tryParse(profile['port']?.toString() ?? '');
    final addresses = (profile['lanAddresses'] as List? ?? const [])
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (invite.length < 32 || port == null || port < 1 || port > 65535) {
      throw const FormatException('邀请或主机端口无效');
    }
    final relay = profile['relay'] is Map
        ? (profile['relay'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final direct = profile['direct'] is Map
        ? (profile['direct'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final directUrl = direct['url']?.toString().trim();
    if (directUrl != null && directUrl.isNotEmpty) {
      final uri = Uri.tryParse(directUrl);
      if (uri == null ||
          uri.scheme != 'wss' ||
          uri.host.isEmpty ||
          uri.path != '/ws') {
        throw const FormatException('公网主机地址必须是 wss://.../ws');
      }
    }
    return PairingProfile(
      invite: invite,
      port: port,
      lanAddresses: addresses,
      directUrl: directUrl?.isEmpty == true ? null : directUrl,
      relayUrl: relay['url']?.toString(),
      relayRoom: relay['room']?.toString(),
      relayToken: relay['token']?.toString(),
    );
  }
}

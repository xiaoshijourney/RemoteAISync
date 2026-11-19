import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/pairing_profile.dart';

void main() {
  test('parses LAN and relay routes from v1 pairing code', () {
    final body = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'invite': 'a' * 40,
          'port': 8910,
          'lanAddresses': ['192.168.1.20'],
          'direct': {'url': 'wss://host.example.test/ws'},
          'relay': {
            'url': 'wss://relay.example.test',
            'room': 'room_1234567890',
            'token': 'b' * 40,
          },
        }),
      ),
    );
    final profile = PairingProfile.parse(
      'remoteaisync://pair?data=${Uri.encodeQueryComponent(body)}',
    );
    expect(profile.port, 8910);
    expect(profile.lanAddresses, ['192.168.1.20']);
    expect(profile.directUrl, 'wss://host.example.test/ws');
    expect(profile.hasDirectPublicRoute, isTrue);
    expect(profile.hasRelay, isTrue);
  });

  test('rejects an invalid or unsupported pairing code', () {
    expect(
      () => PairingProfile.parse('remoteaisync://pair?data=bad'),
      throwsA(isA<FormatException>()),
    );
  });
}

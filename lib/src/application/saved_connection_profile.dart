import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'demo_controller.dart';

class SavedConnectionProfile {
  const SavedConnectionProfile({
    required this.host,
    required this.port,
    required this.lanAddresses,
    required this.directUrl,
    required this.relayUrl,
    required this.relayRoom,
    required this.relayToken,
    required this.forceRelay,
    required this.hasDeviceIdentity,
  });

  static const _storage = FlutterSecureStorage();

  final String host;
  final int port;
  final List<String> lanAddresses;
  final String? directUrl;
  final String? relayUrl;
  final String? relayRoom;
  final String? relayToken;
  final bool forceRelay;
  final bool hasDeviceIdentity;

  static Future<SavedConnectionProfile?> restore(
    DemoController controller,
  ) async {
    try {
      final values = await Future.wait([
        _storage.read(key: 'remoteaisync.route.host'),
        _storage.read(key: 'remoteaisync.route.port'),
        _storage.read(key: 'remoteaisync.route.lan'),
        _storage.read(key: 'remoteaisync.route.directUrl'),
        _storage.read(key: 'remoteaisync.route.relayUrl'),
        _storage.read(key: 'remoteaisync.route.relayRoom'),
        _storage.read(key: 'remoteaisync.route.relayToken'),
        _storage.read(key: 'remoteaisync.route.forceRelay'),
        _storage.read(key: 'remoteaisync.deviceId'),
        _storage.read(key: 'remoteaisync.deviceToken'),
      ]);
      final host = values[0];
      final port = int.tryParse(values[1] ?? '');
      if (host == null || port == null || port < 1 || port > 65535) {
        return null;
      }
      final decodedLan = values[2] == null ? const [] : jsonDecode(values[2]!);
      final profile = SavedConnectionProfile(
        host: host,
        port: port,
        lanAddresses: decodedLan is List
            ? decodedLan
                  .map((value) => value.toString())
                  .toList(growable: false)
            : const [],
        directUrl: values[3],
        relayUrl: values[4],
        relayRoom: values[5],
        relayToken: values[6],
        forceRelay: values[7] == 'true',
        hasDeviceIdentity:
            values[8]?.isNotEmpty == true && values[9]?.isNotEmpty == true,
      );
      if (profile.hasDeviceIdentity && !controller.isLive) {
        unawaited(_connect(controller, profile));
      }
      return profile;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _connect(
    DemoController controller,
    SavedConnectionProfile profile,
  ) async {
    try {
      await controller.connect(
        address: profile.host,
        port: profile.port,
        pairingToken: '',
        directUrl: profile.directUrl,
        relayUrl: profile.relayUrl,
        relayRoom: profile.relayRoom,
        relayToken: profile.relayToken,
        lanAddresses: profile.lanAddresses,
        forceRelay: profile.forceRelay,
      );
    } catch (_) {
      // The connection page reads the sanitized error from the controller.
    }
  }
}

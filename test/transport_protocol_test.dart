import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/transport_protocol.dart';

void main() {
  test('normalizes private ws and preserves secure public routes', () {
    expect(
      normalizeWebSocketUri(
        Uri.parse('ws://192.168.1.20:8910/old'),
        path: '/ws',
        allowInsecurePublic: false,
      ).toString(),
      'ws://192.168.1.20:8910/ws',
    );
    expect(
      normalizeWebSocketUri(
        Uri.parse('wss://relay.example.test'),
        path: '/relay',
        allowInsecurePublic: false,
      ).toString(),
      'wss://relay.example.test/relay',
    );
    expect(
      () => normalizeWebSocketUri(
        Uri.parse('ws://relay.example.test'),
        path: '/relay',
        allowInsecurePublic: false,
      ),
      throwsFormatException,
    );
    expect(
      isHostTransportPeerAllowed(
        privateNetworkPeer: false,
        tlsListener: false,
        publicHostEnabled: true,
      ),
      isFalse,
    );
    expect(
      isHostTransportPeerAllowed(
        privateNetworkPeer: false,
        tlsListener: true,
        publicHostEnabled: true,
      ),
      isTrue,
    );
  });

  test('v2 envelope remains readable as a v1 compatible event', () {
    final encoded = const ProtocolEnvelope(
      kind: 'host.snapshot',
      payload: {'ok': true},
      channel: 'telemetry',
      eventId: 'evt-1',
      sequence: 4,
      topologyRevision: 3,
    ).encode();
    final decoded = ProtocolEnvelope.tryParse(encoded);
    expect(decoded?.schemaVersion, 2);
    expect(decoded?.sequence, 4);
    expect(decoded?.payload['ok'], true);
  });

  test('topology snapshot round trips node and link metadata', () {
    const snapshot = TopologySnapshot(
      revision: 7,
      nodes: [
        TopologyNode(
          id: 'host',
          role: 'host',
          online: true,
          protocol: 'wss',
          route: 'relay',
          rttMs: 18,
        ),
      ],
      links: [
        TopologyLink(
          id: 'host-client',
          from: 'host',
          to: 'client:1',
          online: true,
          protocol: 'wss',
          route: 'relay',
        ),
      ],
    );
    final decoded = TopologySnapshot.fromJson({
      'revision': snapshot.revision,
      'nodes': snapshot.nodes.map((node) => node.toJson()).toList(),
      'links': snapshot.links.map((link) => link.toJson()).toList(),
    });
    expect(decoded.revision, 7);
    expect(decoded.nodes.single.rttMs, 18);
    expect(decoded.nodes.single.route, 'relay');
    expect(decoded.links.single.protocol, 'wss');
    expect(decoded.links.single.route, 'relay');
  });
}

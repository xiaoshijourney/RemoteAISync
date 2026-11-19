import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/application/host_client.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  test('fails pending commands as soon as the host socket closes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['kind'] == 'client.hello') {
          _sendEvent(socket, 'host.ready', {'openCodeVersion': 'test'});
        } else if (frame['kind'] == 'workspace.list') {
          unawaited(socket.close());
        }
      });
    });
    final client = HostClient();
    try {
      await client.connect(
        address: '127.0.0.1',
        port: server.port,
        pairingToken: 'test-pairing-token',
      );
      await expectLater(
        client.listWorkspace().timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
    } finally {
      await client.disconnect();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'falls back to the configured relay after LAN connection fails',
    () async {
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = relay.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['kind'] == 'relay.hello') {
            socket.add(jsonEncode({'kind': 'relay.ready'}));
          } else if (frame['kind'] == 'relay.data') {
            final forwarded =
                jsonDecode((frame['data'] as String)) as Map<String, dynamic>;
            if (forwarded['kind'] == 'client.hello') {
              socket.add(
                jsonEncode({
                  'kind': 'relay.data',
                  'data': jsonEncode({
                    'schemaVersion': 1,
                    'kind': 'host.ready',
                    'payload': {'openCodeVersion': 'relay-test'},
                  }),
                }),
              );
            }
          }
        });
      });
      final unavailablePortSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final unavailablePort = unavailablePortSocket.port;
      await unavailablePortSocket.close();
      final client = HostClient();
      try {
        await client.connect(
          address: '127.0.0.1',
          port: unavailablePort,
          pairingToken: 'test-pairing-token',
          relayUrl: 'ws://127.0.0.1:${relay.port}',
          relayRoom: 'room_test_1234567890',
          relayToken: 'relay-test-token-12345678901234567890',
        );
        expect(client.status, HostConnectionStatus.connected);
        expect(client.connectionRoute, '中继');
      } finally {
        await client.disconnect();
        await subscription.cancel();
        await relay.close(force: true);
      }
    },
  );

  test('stops reconnecting when the host requires pairing again', () async {
    var helloCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['kind'] != 'client.hello') return;
        helloCount++;
        _sendEvent(socket, 'command.error', {
          'commandId': frame['commandId'],
          'code': 'pairing_required',
          'message': '此设备尚未配对或已被主机撤销。',
        });
        unawaited(socket.close());
      });
    });
    final client = HostClient();
    try {
      await expectLater(
        client.connect(
          address: '127.0.0.1',
          port: server.port,
          pairingToken: '',
        ),
        throwsA(isA<StateError>()),
      );
      // Pairing failures must remain distinct from transport failures.
      expect(client.errorCode, 'pairing_required');
      expect(client.errorMessage, contains('主机撤销'));
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(helloCount, 1);
    } finally {
      await client.disconnect();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('uploads a file in chunks before sending its attachment ID', () async {
    final temp = await Directory.systemTemp.createTemp(
      'remoteaisync-client-upload-test-',
    );
    final bytes = Uint8List.fromList(
      List<int>.generate(512 * 1024 + 3, (index) => index % 251),
    );
    final file = File('${temp.path}${Platform.pathSeparator}sample.bin');
    await file.writeAsBytes(bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uploadedBytes = <int>[];
    List? replyAttachmentIds;
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final kind = frame['kind'];
        final commandId = frame['commandId'];
        final payload = frame['payload'] as Map<String, dynamic>;
        if (kind == 'client.hello') {
          _sendEvent(socket, 'host.ready', {'codexVersion': 'codex-cli test'});
          _sendEvent(socket, 'host.snapshot', {
            'sessions': [
              {
                'id': 'codex:upload-test',
                'agentId': 'codex',
                'title': 'Upload test',
                'updatedAt': '12:00',
              },
            ],
          });
        } else if (kind == 'session.select') {
          _sendEvent(socket, 'session.snapshot', {
            'sessionId': payload['sessionId'],
            'selectionGeneration': payload['selectionGeneration'],
            'messages': [],
            'forms': [],
            'permissions': [],
          });
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        } else if (kind == 'attachment.begin') {
          expect(payload['name'], 'sample.bin');
          expect(payload['sizeBytes'], 512 * 1024 + 3);
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
            'uploadId': 'upload-test',
          });
        } else if (kind == 'attachment.chunk') {
          expect(payload['offset'], uploadedBytes.length);
          final bytes = base64Decode(payload['data'] as String);
          expect(bytes.length, lessThanOrEqualTo(512 * 1024));
          uploadedBytes.addAll(bytes);
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
            'receivedBytes': uploadedBytes.length,
          });
        } else if (kind == 'attachment.finish') {
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
            'attachmentId': 'upload-test',
          });
        } else if (kind == 'session.reply') {
          replyAttachmentIds = payload['attachmentIds'] as List?;
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        }
      });
    });
    final client = HostClient();
    try {
      await client.connect(
        address: '127.0.0.1',
        port: server.port,
        pairingToken: 'test-pairing-token',
      );
      await _waitFor(() => client.sessions.isNotEmpty);
      await client.selectSession(client.sessions.single);
      final id = await client.uploadAttachment(XFile(file.path));
      await client.sendReply('', attachmentIds: [id]);
      expect(uploadedBytes, bytes);
      expect(replyAttachmentIds, ['upload-test']);
    } finally {
      await client.disconnect();
      await subscription.cancel();
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  });

  test('completes pairing, selects a session, and forwards a reply', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final replies = <String>[];
    final formAnswers = <Map<String, dynamic>>[];
    final permissionDecisions = <String>[];
    final serverSubscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final kind = frame['kind'];
        final commandId = frame['commandId'];
        final payload = frame['payload'] as Map<String, dynamic>;

        if (kind == 'client.hello') {
          _sendEvent(socket, 'host.ready', {'openCodeVersion': '2.0.6'});
          _sendEvent(socket, 'host.snapshot', {
            'sessions': [
              {
                'id': 'ses_test',
                'title': 'Fresh project session',
                'updatedAt': '12:00',
              },
              {
                'id': 'ses_other',
                'title': 'Another session',
                'updatedAt': '11:00',
              },
            ],
          });
        } else if (kind == 'session.select') {
          final sessionId = payload['sessionId'] as String;
          if (sessionId == 'ses_other') {
            _sendEvent(
              socket,
              'session.snapshot',
              {
                'sessionId': sessionId,
                'selectionGeneration': payload['selectionGeneration'],
                'messages': [
                  {
                    'id': 'msg_other',
                    'author': 'assistant',
                    'text': 'Separate session state.',
                    'time': '11:00',
                  },
                ],
                'forms': [],
                'permissions': [],
              },
              sessionId: sessionId,
              seq: 1,
            );
            _sendEvent(
              socket,
              'session.snapshot',
              {
                'sessionId': 'ses_test',
                'selectionGeneration': 1,
                'messages': [],
                'forms': [
                  {
                    'id': 'frm_stale',
                    'sessionID': 'ses_test',
                    'title': 'Stale form',
                    'fields': [],
                  },
                ],
                'permissions': [
                  {
                    'id': 'per_stale',
                    'sessionID': 'ses_test',
                    'action': 'bash',
                    'resources': ['echo stale'],
                  },
                ],
              },
              sessionId: 'ses_test',
              seq: 12,
            );
            _sendEvent(socket, 'command.result', {
              'commandId': commandId,
              'ok': true,
            });
            return;
          }
          _sendEvent(
            socket,
            'session.snapshot',
            {
              'sessionId': sessionId,
              'selectionGeneration': payload['selectionGeneration'],
              'messages': [
                {
                  'id': 'msg_test',
                  'author': 'assistant',
                  'text': 'Bridge is ready.',
                  'time': '12:00',
                },
              ],
              'forms': [
                {
                  'id': 'frm_test',
                  'sessionID': 'ses_test',
                  'title': 'Choose a mode',
                  'fields': [
                    {
                      'key': 'mode',
                      'type': 'string',
                      'required': true,
                      'options': [
                        {'value': 'safe', 'label': 'Safe'},
                      ],
                    },
                  ],
                },
              ],
              'permissions': [
                {
                  'id': 'per_test',
                  'sessionID': 'ses_test',
                  'action': 'bash',
                  'resources': ['echo safe'],
                  'source': {'type': 'tool', 'id': 'bash'},
                },
              ],
            },
            sessionId: 'ses_test',
            seq: 10,
          );
          _sendEvent(
            socket,
            'session.snapshot',
            {
              'sessionId': payload['sessionId'],
              'selectionGeneration': 0,
              'messages': [
                {
                  'id': 'msg_stale',
                  'author': 'assistant',
                  'text': 'Stale response from an earlier selection.',
                  'time': '11:59',
                },
              ],
              'forms': [],
              'permissions': [],
            },
            sessionId: 'ses_test',
            seq: 11,
          );
          _sendEvent(
            socket,
            'session.snapshot',
            {
              'sessionId': payload['sessionId'],
              'selectionGeneration': payload['selectionGeneration'],
              'messages': [
                {
                  'id': 'msg_out_of_order',
                  'author': 'assistant',
                  'text': 'Out-of-order snapshot.',
                  'time': '11:58',
                },
              ],
              'forms': [],
              'permissions': [],
            },
            sessionId: 'ses_test',
            seq: 9,
          );
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        } else if (kind == 'session.reply') {
          replies.add(payload['text'] as String);
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        } else if (kind == 'session.form.reply') {
          formAnswers.add((payload['answer'] as Map).cast<String, dynamic>());
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        } else if (kind == 'session.permission.reply') {
          permissionDecisions.add(payload['decision'] as String);
          _sendEvent(socket, 'command.result', {
            'commandId': commandId,
            'ok': true,
          });
        }
      });
    });
    final client = HostClient();

    try {
      await client.connect(
        address: '127.0.0.1',
        port: server.port,
        pairingToken: 'test-pairing-token',
      );
      expect(client.status, HostConnectionStatus.connected);
      expect(client.transportState, TransportState.connected);
      expect(client.pairingState, PairingState.paired);
      expect(client.hostVersion, '2.0.6');
      await _waitFor(() => client.sessions.isNotEmpty);
      expect(client.sessions.first.title, 'Fresh project session');

      final testSession = client.sessions.singleWhere(
        (session) => session.id == 'ses_test',
      );
      await client.selectSession(testSession);
      await _waitFor(() => client.messages.isNotEmpty);
      await _waitFor(
        () => client.forms.isNotEmpty && client.permissions.isNotEmpty,
      );
      expect(client.messages.single.text, 'Bridge is ready.');
      expect(client.forms.single.id, 'frm_test');
      expect(client.permissions.single.id, 'per_test');

      await client.sendReply('Continue with the test suite.');
      expect(replies, ['Continue with the test suite.']);
      await client.replyToForm(client.forms.single, {'mode': 'safe'});
      expect(formAnswers, [
        {'mode': 'safe'},
      ]);
      await client.replyToPermission(client.permissions.single, allow: false);
      expect(permissionDecisions, ['reject']);

      await client.selectSession(
        const HostSession(
          id: 'ses_other',
          title: 'Another session',
          updatedAt: '11:00',
        ),
      );
      await _waitFor(() => client.messages.single.id == 'msg_other');
      expect(client.forms, isEmpty);
      expect(client.permissions, isEmpty);
      expect(client.messages.single.text, 'Separate session state.');
    } finally {
      await client.disconnect();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('creates and selects a Codex session through the bridge', () async {
    var refreshed = false;
    Map<String, dynamic>? createPayload;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final kind = frame['kind'];
        final id = frame['commandId'];
        if (kind == 'client.hello') {
          _sendEvent(socket, 'host.ready', {
            'openCodeVersion': '2.0.6',
            'codexVersion': 'codex-cli test',
            'agents': [
              {
                'id': 'opencode',
                'availability': 'available',
                'version': '2.0.6',
              },
              {
                'id': 'codex',
                'availability': 'available',
                'version': 'codex-cli test',
              },
              {
                'id': 'claude',
                'availability': 'unsupported',
                'detail': 'Claude Code 适配器尚未接入',
              },
            ],
          });
          _sendEvent(socket, 'host.snapshot', {'sessions': []});
        } else if (kind == 'session.create') {
          createPayload = (frame['payload'] as Map).cast<String, dynamic>();
          _sendEvent(socket, 'host.snapshot', {
            'sessions': [
              {
                'id': 'codex:thread-test',
                'agentId': 'codex',
                'remoteManaged': true,
                'title': 'New Codex conversation',
                'updatedAt': '12:00',
              },
            ],
          });
          _sendEvent(socket, 'command.result', {
            'commandId': id,
            'ok': true,
            'sessionId': 'codex:thread-test',
          });
        } else if (kind == 'session.select') {
          final selectedId = (frame['payload'] as Map)['sessionId'].toString();
          _sendEvent(socket, 'session.snapshot', {
            'sessionId': selectedId,
            'selectionGeneration':
                (frame['payload'] as Map)['selectionGeneration'],
            'messages': [],
            'forms': [],
            'permissions': [],
          }, sessionId: selectedId);
          _sendEvent(socket, 'command.result', {'commandId': id, 'ok': true});
        } else if (kind == 'session.refresh') {
          refreshed = true;
          _sendEvent(socket, 'command.result', {'commandId': id, 'ok': true});
        }
      });
    });
    final client = HostClient();
    try {
      await client.connect(
        address: '127.0.0.1',
        port: server.port,
        pairingToken: 'test-pairing-token',
      );
      expect(client.codexVersion, 'codex-cli test');
      expect(client.agentStatus('opencode')?.isAvailable, isTrue);
      expect(client.agentStatus('codex')?.isAvailable, isTrue);
      expect(
        client.agentStatus('claude')?.availability,
        AgentAvailability.unsupported,
      );
      await client.refreshSessions();
      expect(refreshed, isTrue);
      await client.createCodexSession();
      expect(client.sessions.single.agentId, 'codex');
      expect(client.sessions.single.remoteManaged, isTrue);
      expect(client.selectedSessionId, 'codex:thread-test');
      expect(client.sessionLoaded, isTrue);
      expect(client.messages, isEmpty);
      await client.createAgentSession('codex', useDefaultDirectory: true);
      expect(createPayload?['useDefaultDirectory'], isTrue);
    } finally {
      await client.disconnect();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('restores an established connection after the socket closes', () async {
    var connectionCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connectionCount++;
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['kind'] == 'client.hello') {
          _sendEvent(socket, 'host.ready', {
            'agents': [
              {'id': 'opencode', 'availability': 'available'},
            ],
          });
          if (connectionCount == 1) {
            Future<void>.delayed(
              const Duration(milliseconds: 100),
              () => socket.close(),
            );
          }
        }
      });
    });
    final client = HostClient();
    try {
      await client.connect(
        address: '127.0.0.1',
        port: server.port,
        pairingToken: 'test-pairing-token',
      );
      await _waitForLong(
        () =>
            connectionCount >= 2 &&
            client.status == HostConnectionStatus.connected,
      );
      expect(client.transportState, TransportState.connected);
    } finally {
      await client.disconnect();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Future<void> _waitForLong(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 7));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

void _sendEvent(
  WebSocket socket,
  String kind,
  Map<String, Object?> payload, {
  String? sessionId,
  int? seq,
}) {
  final event = <String, Object?>{
    'schemaVersion': 1,
    'kind': kind,
    'payload': payload,
    'sessionId': ?sessionId,
    'seq': ?seq,
  };
  socket.add(jsonEncode(event));
}

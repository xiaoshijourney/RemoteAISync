import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// WebSocket smoke test. Optional write uses an ephemeral Codex thread only.
Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 7) {
    stderr.writeln(
      'Usage: dart run host/bin/bridge_probe.dart <port> <token> [--create-ephemeral] [--upload-test] [--stream-test] [--refresh-test] [--inspect-live]',
    );
    exitCode = 2;
    return;
  }
  final port = int.parse(arguments[0]);
  final uploadTest = arguments.contains('--upload-test');
  final streamTest = arguments.contains('--stream-test');
  final refreshTest = arguments.contains('--refresh-test');
  final createEphemeral =
      arguments.contains('--create-ephemeral') || uploadTest || streamTest;
  final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  final events = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic>? lastHostSnapshot;
  final subscription = socket.listen((raw) {
    final event = jsonDecode(raw as String);
    if (event is Map) {
      final frame = event.cast<String, dynamic>();
      if (frame['kind'] == 'host.snapshot') lastHostSnapshot = frame;
      if (createEphemeral &&
          (frame['kind'] == 'command.error' ||
              frame['kind'] == 'command.result' ||
              (frame['kind'] == 'session.snapshot' && !streamTest))) {
        stdout.writeln(
          'Event: ${frame['kind']} ${(frame['payload'] as Map)['commandId'] ?? ''} ${frame['kind'] == 'command.error' ? (frame['payload'] as Map)['message'] ?? '' : ''}',
        );
      }
      events.add(frame);
    }
  });
  try {
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'client.hello',
        'commandId': 'probe-hello',
        'payload': {'pairingToken': arguments[1]},
      }),
    );
    final snapshot = await events.stream
        .firstWhere((event) => event['kind'] == 'host.snapshot')
        .timeout(const Duration(seconds: 15));
    final sessions = (snapshot['payload'] as Map)['sessions'] as List;
    final codex = sessions
        .whereType<Map>()
        .where((item) => item['agentId'] == 'codex')
        .toList();
    final openCode = sessions
        .whereType<Map>()
        .where((item) => item['agentId'] == 'opencode')
        .toList();
    stdout.writeln(
      'OpenCode: ${openCode.length}; Codex: ${codex.length}; Codex remote: ${codex.where((session) => session['remoteManaged'] == true).length}',
    );
    if (refreshTest) {
      final result = events.stream
          .firstWhere(
            (event) =>
                (event['payload'] as Map)['commandId'] == 'probe-refresh',
          )
          .timeout(const Duration(seconds: 20));
      socket.add(
        jsonEncode({
          'schemaVersion': 1,
          'kind': 'session.refresh',
          'commandId': 'probe-refresh',
          'payload': <String, Object?>{},
        }),
      );
      final refreshed = await result;
      if (refreshed['kind'] != 'command.result') {
        throw StateError('session.refresh failed: ${refreshed['payload']}');
      }
      stdout.writeln('Forced session refresh acknowledged by bridge.');
    }
    String? createdSessionId;
    if (createEphemeral) {
      socket.add(
        jsonEncode({
          'schemaVersion': 1,
          'kind': 'session.create',
          'commandId': 'probe-create',
          'payload': {'agentId': 'codex', 'ephemeral': true},
        }),
      );
      final created = await events.stream
          .firstWhere(
            (event) => (event['payload'] as Map)['commandId'] == 'probe-create',
          )
          .timeout(const Duration(seconds: 15));
      if (created['kind'] != 'command.result' ||
          !(created['payload'] as Map)['sessionId'].toString().startsWith(
            'codex:',
          )) {
        throw StateError('Codex session.create failed: ${created['payload']}');
      }
      createdSessionId = (created['payload'] as Map)['sessionId'].toString();
      final latestSessions =
          ((lastHostSnapshot?['payload'] as Map?)?['sessions'] as List? ??
                  const [])
              .whereType<Map>();
      if (!latestSessions.any(
        (session) =>
            session['id'] == createdSessionId &&
            session['remoteManaged'] == true,
      )) {
        throw StateError('Created Codex session is not marked remote-managed.');
      }
      stdout.writeln('Ephemeral Codex session.create acknowledged by bridge.');
    }
    if (codex.isNotEmpty || createdSessionId != null) {
      final sessionId = createdSessionId ?? codex.first['id'];
      final detailCompleter = Completer<Map<String, dynamic>>();
      final detailSubscription = events.stream.listen((event) {
        if (event['kind'] == 'session.snapshot' &&
            (event['payload'] as Map)['sessionId'] == sessionId &&
            !detailCompleter.isCompleted) {
          detailCompleter.complete(event);
        }
      });
      final selectionFuture = events.stream
          .firstWhere(
            (event) => (event['payload'] as Map)['commandId'] == 'probe-select',
          )
          .timeout(const Duration(seconds: 15));
      socket.add(
        jsonEncode({
          'schemaVersion': 1,
          'kind': 'session.select',
          'commandId': 'probe-select',
          'payload': {'sessionId': sessionId, 'selectionGeneration': 1},
        }),
      );
      final selection = await selectionFuture;
      if (selection['kind'] != 'command.result') {
        await detailSubscription.cancel();
        throw StateError(
          'Codex session.select failed: ${selection['payload']}',
        );
      }
      final detail = await detailCompleter.future.timeout(
        const Duration(seconds: 15),
      );
      await detailSubscription.cancel();
      final payload = detail['payload'] as Map;
      stdout.writeln(
        'Codex messages: ${(payload['messages'] as List).length}; forms: ${(payload['forms'] as List).length}; approvals: ${(payload['permissions'] as List).length}',
      );
      if (arguments.contains('--inspect-live')) {
        final messages = (payload['messages'] as List)
            .whereType<Map>()
            .toList();
        for (final message in messages.skip(
          messages.length > 5 ? messages.length - 5 : 0,
        )) {
          stdout.writeln(
            '  ${message['author']} ${message['id']} (${message['text']?.toString().length ?? 0} chars)',
          );
        }
      }
      if (createdSessionId != null) {
        String? attachmentId;
        if (uploadTest) {
          final bytes = utf8.encode('RemoteAISync WebSocket upload probe.');
          Future<Map<String, dynamic>> uploadCommand(
            String kind,
            String commandId,
            Map<String, Object?> payload,
          ) {
            final result = events.stream
                .firstWhere(
                  (event) =>
                      (event['payload'] as Map)['commandId'] == commandId,
                )
                .timeout(const Duration(seconds: 20));
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': kind,
                'commandId': commandId,
                'payload': payload,
              }),
            );
            return result;
          }

          final begin = await uploadCommand('attachment.begin', 'probe-begin', {
            'sessionId': sessionId,
            'name': 'remoteaisync-probe.txt',
            'sizeBytes': bytes.length,
          });
          if (begin['kind'] != 'command.result') {
            throw StateError('attachment.begin failed: ${begin['payload']}');
          }
          final uploadId = (begin['payload'] as Map)['uploadId'].toString();
          final chunk = await uploadCommand('attachment.chunk', 'probe-chunk', {
            'uploadId': uploadId,
            'offset': 0,
            'data': base64Encode(bytes),
          });
          if (chunk['kind'] != 'command.result') {
            throw StateError('attachment.chunk failed: ${chunk['payload']}');
          }
          final finish = await uploadCommand(
            'attachment.finish',
            'probe-finish',
            {'uploadId': uploadId},
          );
          if (finish['kind'] != 'command.result') {
            throw StateError('attachment.finish failed: ${finish['payload']}');
          }
          attachmentId = (finish['payload'] as Map)['attachmentId'].toString();
          stdout.writeln('Attachment upload acknowledged by bridge.');
        }
        final streamedMessage = streamTest
            ? events.stream
                  .firstWhere((event) {
                    if (event['kind'] != 'session.snapshot') return false;
                    final payload = event['payload'] as Map;
                    if (payload['sessionId'] != sessionId) return false;
                    return (payload['messages'] as List? ?? const [])
                        .whereType<Map>()
                        .any(
                          (message) =>
                              message['author'] == 'assistant' &&
                              message['text']?.toString().trim().isNotEmpty ==
                                  true,
                        );
                  })
                  .timeout(const Duration(seconds: 90))
            : null;
        socket.add(
          jsonEncode({
            'schemaVersion': 1,
            'kind': 'session.reply',
            'commandId': 'probe-reply',
            'payload': {
              'sessionId': sessionId,
              'text': 'RemoteAISync bridge smoke test: reply with OK only.',
              if (attachmentId != null) 'attachmentIds': [attachmentId],
            },
          }),
        );
        final reply = await events.stream
            .firstWhere(
              (event) =>
                  (event['payload'] as Map)['commandId'] == 'probe-reply',
            )
            .timeout(const Duration(seconds: 20));
        if (reply['kind'] != 'command.result') {
          throw StateError('Codex session.reply failed: ${reply['payload']}');
        }
        stdout.writeln('Ephemeral Codex session.reply accepted by bridge.');
        if (streamedMessage != null) {
          await streamedMessage;
          stdout.writeln('Streamed Codex item reached WebSocket snapshot.');
        }
      }
    }
  } finally {
    await subscription.cancel();
    await events.close();
    await socket.close();
  }
}

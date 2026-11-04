import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports
import '../host/lib/src/open_code_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  test('parses OpenCode v2 text and tool messages', () {
    final userMessages = OpenCodeSession.parseMessages({
      'id': 'msg_user',
      'type': 'user',
      'text': 'Check the startup flow.',
      'time': {'created': 1793764800000},
    });
    final assistantMessages = OpenCodeSession.parseMessages({
      'id': 'msg_assistant',
      'type': 'assistant',
      'time': {'created': 1793764860000},
      'content': [
        {'type': 'reasoning', 'text': 'private reasoning'},
        {'type': 'text', 'text': 'I will inspect the entry point.'},
        {
          'type': 'tool',
          'name': 'bash',
          'state': {
            'status': 'completed',
            'input': {'command': 'dart analyze'},
            'content': [
              {'type': 'text', 'text': 'No issues found.'},
            ],
          },
        },
      ],
    });

    expect(userMessages.single.author, MessageAuthor.user);
    expect(userMessages.single.text, 'Check the startup flow.');
    expect(assistantMessages, hasLength(2));
    expect(assistantMessages.first.text, 'I will inspect the entry point.');
    expect(assistantMessages.last.author, MessageAuthor.tool);
    expect(assistantMessages.last.text, contains('dart analyze'));
    expect(assistantMessages.last.text, contains('No issues found.'));
    expect(
      assistantMessages.map((message) => message.text),
      isNot(contains('private reasoning')),
    );
  });

  test('parses session metadata from the v2 schema', () {
    final session = OpenCodeSession.fromJson({
      'id': 'ses_remoteaisync',
      'title': 'RemoteAISync review',
      'time': {'updated': 1793764860000},
    });

    expect(session.id, 'ses_remoteaisync');
    expect(session.title, 'RemoteAISync review');
    expect(session.updatedAt, matches(RegExp(r'^\d{2}:\d{2}$')));
  });

  test('reads the v2 data envelope and orders the latest messages', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Uri requestedUri;
    final serverSubscription = server.listen((request) async {
      requestedUri = request.uri;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {
              'id': 'msg_new',
              'type': 'assistant',
              'time': {'created': 1793764860000},
              'content': [
                {'type': 'text', 'text': 'latest reply'},
              ],
            },
            {
              'id': 'msg_old',
              'type': 'user',
              'text': 'earlier prompt',
              'time': {'created': 1793764800000},
            },
          ],
          'cursor': {'previous': null, 'next': 'next-page'},
        }),
      );
      await request.response.close();
    });
    final api = OpenCodeApi(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      password: 'test-password',
      projectDirectory: r'C:\workspace\RemoteAISync',
    );

    try {
      final messages = await api.listMessages('ses_test');

      expect(requestedUri.path, '/api/session/ses_test/message');
      expect(requestedUri.queryParameters['limit'], '100');
      expect(requestedUri.queryParameters['order'], 'desc');
      expect(
        requestedUri.queryParameters['directory'],
        r'C:\workspace\RemoteAISync',
      );
      expect(messages.map((message) => message.text), [
        'earlier prompt',
        'latest reply',
      ]);
    } finally {
      await api.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

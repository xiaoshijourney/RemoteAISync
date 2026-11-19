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
      'location': {'directory': r'C:\workspace\RemoteAISync'},
    });

    expect(session.id, 'ses_remoteaisync');
    expect(session.title, 'RemoteAISync review');
    expect(session.updatedAt, matches(RegExp(r'^\d{2}:\d{2}$')));
    expect(session.directory, r'C:\workspace\RemoteAISync');
  });

  test('starts the OpenCode service when it is not running', () async {
    final temp = await Directory.systemTemp.createTemp(
      'remoteaisync-opencode-service-start-',
    );
    final state = Directory('${temp.path}${Platform.pathSeparator}state');
    await state.create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'version': 'test-version'}));
      await request.response.close();
    });
    final serviceFile = File(
      '${state.path}${Platform.pathSeparator}service.json',
    );
    await serviceFile.writeAsString(
      jsonEncode({
        'url': 'http://127.0.0.1:${server.port}',
        'password': 'test-password',
      }),
    );
    var started = false;
    var stoppedExitCode = 0;
    final calls = <String>[];
    Future<ProcessResult> commandRunner({
      required String executable,
      required List<String> arguments,
      required String workingDirectory,
    }) async {
      final command = arguments.join(' ');
      calls.add(command);
      if (command == 'service status') {
        return ProcessResult(
          0,
          started ? 0 : stoppedExitCode,
          started ? 'http://127.0.0.1:${server.port}' : 'stopped',
          '',
        );
      }
      if (command == 'service start') {
        started = true;
        return ProcessResult(0, 0, 'started', '');
      }
      if (command == 'debug paths state') {
        return ProcessResult(0, 0, state.path, '');
      }
      return ProcessResult(0, 1, '', 'unexpected command');
    }

    try {
      for (final exitCode in [0, 1]) {
        started = false;
        stoppedExitCode = exitCode;
        calls.clear();
        final connection = await OpenCodeServiceConnection.discover(
          executable: 'fake-opencode',
          workingDirectory: temp.path,
          commandRunner: commandRunner,
        );
        expect(connection.baseUri.port, server.port);
        expect(calls, [
          'service status',
          'service start',
          'service status',
          'debug paths state',
        ]);
      }
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  });

  test(
    'explains non-JSON OpenCode responses without exposing response bodies',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html>private server response</html>');
        await request.response.close();
      });
      final api = OpenCodeApi(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        password: 'test-password',
        projectDirectory: Directory.current.path,
      );

      try {
        await expectLater(
          api.version(),
          throwsA(
            isA<OpenCodeApiException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('GET /api/info'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('text/html'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('private server response')),
                ),
          ),
        );
      } finally {
        await api.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'global OpenCode history omits the directory filter and retains cwd',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late Uri requestedUri;
      final subscription = server.listen((request) async {
        requestedUri = request.uri;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {
                'id': 'ses_global',
                'title': 'Global session',
                'location': {'directory': r'C:\another\project'},
                'time': {'updated': 1793764860000},
              },
            ],
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
        final sessions = await api.listSessions(global: true);
        expect(requestedUri.queryParameters['directory'], isNull);
        expect(requestedUri.queryParameters['limit'], '1000');
        expect(sessions.single.directory, r'C:\another\project');
      } finally {
        await api.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

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

  test('submits replies through the OpenCode local API', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Uri requestedUri;
    late String requestBody;
    final serverSubscription = server.listen((request) async {
      requestedUri = request.uri;
      requestBody = await utf8.decoder.bind(request).join();
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    final api = OpenCodeApi(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      password: 'test-password',
      projectDirectory: r'C:\workspace\RemoteAISync',
    );

    try {
      await api.sendReply(
        'ses_test',
        'show up in the terminal',
        model: 'openai/gpt-6-sol',
        variant: 'high',
      );

      expect(requestedUri.path, '/api/session/ses_test/prompt');
      expect(
        requestedUri.queryParameters['directory'],
        r'C:\workspace\RemoteAISync',
      );
      expect(jsonDecode(requestBody), {
        'text': 'show up in the terminal',
        'model': {'providerID': 'openai', 'modelID': 'gpt-6-sol'},
        'variant': 'high',
      });
    } finally {
      await api.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'lists OpenCode model variants, creates sessions, and aborts them',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final requestBodies = <String>[];
      final subscription = server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        final requestBody = await utf8.decoder.bind(request).join();
        if (requestBody.isNotEmpty) requestBodies.add(requestBody);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/config/providers') {
          request.response.write(
            jsonEncode({
              'providers': [
                {
                  'id': 'openai',
                  'models': {
                    'gpt-6-sol': {
                      'name': 'GPT-6 Sol',
                      'variants': {'medium': {}, 'high': {}},
                      'defaultVariant': 'medium',
                    },
                  },
                },
              ],
              'default': {'openai': 'gpt-6-sol'},
            }),
          );
        } else if (request.uri.path == '/api/session') {
          request.response.write(
            jsonEncode({
              'data': {
                'id': 'ses_new',
                'title': 'New session',
                'time': {'updated': 1793764860000},
              },
            }),
          );
        } else if (request.uri.path.endsWith('/abort')) {
          request.response.write('true');
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final api = OpenCodeApi(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        password: 'test-password',
        projectDirectory: r'C:\workspace\RemoteAISync',
      );

      try {
        final controls = await api.listControls();
        expect(controls.model, 'openai/gpt-6-sol');
        expect(controls.effort, 'medium');
        expect(controls.models.single.name, 'GPT-6 Sol');
        expect(controls.models.single.efforts, ['medium', 'high']);

        final session = await api.createSession(title: 'Phone session');
        expect(session.id, 'ses_new');
        expect(jsonDecode(requestBodies.single), {
          'location': {'directory': r'C:\workspace\RemoteAISync'},
          'title': 'Phone session',
        });
        expect(await api.abortSession('ses_new'), isTrue);
        expect(requests, [
          'GET /config/providers',
          'POST /api/session',
          'POST /api/session/ses_new/abort',
        ]);
      } finally {
        await api.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('reads pending forms and permissions and replies to both', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    final bodies = <String>[];
    final serverSubscription = server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      final body = await utf8.decoder.bind(request).join();
      if (body.isNotEmpty) bodies.add(body);
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET' && request.uri.path.endsWith('/form')) {
        request.response.write(
          jsonEncode({
            'data': [
              {
                'id': 'frm_pending',
                'sessionID': 'ses_test',
                'title': 'Choose a mode',
                'fields': [
                  {
                    'key': 'mode',
                    'type': 'string',
                    'title': 'Mode',
                    'pattern': r'^(fast|safe)$',
                    'required': true,
                    'options': [
                      {'value': 'fast', 'label': 'Fast'},
                      {'value': 'safe', 'label': 'Safe'},
                    ],
                  },
                ],
              },
              {
                'id': 'frm_completed',
                'sessionID': 'ses_test',
                'title': 'Answered',
                'state': {'status': 'completed'},
                'fields': [
                  {'key': 'answer', 'type': 'string'},
                ],
              },
            ],
          }),
        );
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/permission')) {
        request.response.write(
          jsonEncode({
            'data': [
              {
                'id': 'per_pending',
                'sessionID': 'ses_test',
                'action': 'shell',
                'resources': ['echo safe'],
                'message': 'Run a harmless command?',
                'source': {'type': 'tool', 'id': 'bash'},
              },
            ],
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.noContent;
      }
      await request.response.close();
    });
    final api = OpenCodeApi(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      password: 'test-password',
      projectDirectory: r'C:\workspace\RemoteAISync',
    );

    try {
      final forms = await api.listForms('ses_test');
      final permissions = await api.listPermissions('ses_test');
      expect(forms, hasLength(1));
      expect(forms.single.id, 'frm_pending');
      expect(forms.single.fields.single.options.last.value, 'safe');
      expect(forms.single.fields.single.pattern, r'^(fast|safe)$');
      expect(permissions, hasLength(1));
      expect(permissions.single.toolId, 'bash');

      await api.replyToForm('ses_test', 'frm_pending', {'mode': 'safe'});
      await api.replyToPermission('ses_test', 'per_pending', decision: 'once');

      expect(requests, [
        'GET /api/session/ses_test/form',
        'GET /api/session/ses_test/permission',
        'POST /api/session/ses_test/form/frm_pending/reply',
        'POST /api/session/ses_test/permission/per_pending/reply',
      ]);
      final decodedBodies = bodies.map(jsonDecode).toList();
      expect(
        decodedBodies,
        contains(
          isA<Map>().having((body) => body['answer'], 'answer', {
            'mode': 'safe',
          }),
        ),
      );
      expect(
        decodedBodies,
        contains(
          isA<Map>().having((body) => body['decision'], 'decision', 'once'),
        ),
      );
    } finally {
      await api.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

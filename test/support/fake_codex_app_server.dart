import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final log = File(args.single);
  var newThreadVisible = false;
  var newThreadCount = 0;
  var newThreadRolloutEmpty = true;
  Map<String, dynamic>? queuedSubmission;
  var nextTurn = 0;
  var selectedModel = 'gpt-6-sol';
  var selectedEffort = 'medium';
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final frame = jsonDecode(line) as Map<String, dynamic>;
    final id = frame['id'];
    final method = frame['method'];
    if (method == 'initialize') {
      final capabilities = (frame['params'] as Map)['capabilities'];
      if (capabilities is! Map || capabilities['experimentalApi'] != true) {
        stdout.writeln(
          jsonEncode({
            'id': id,
            'error': {'message': 'experimentalApi capability required'},
          }),
        );
        continue;
      }
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {'userAgent': 'fake-codex'},
        }),
      );
    } else if (method == 'initialized') {
      stdout.writeln(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'item': {
              'id': 'file-1',
              'type': 'fileChange',
              'changes': <Map<String, String>>[],
            },
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'method': 'item/fileChange/patchUpdated',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'itemId': 'file-1',
            'changes': [
              {'path': 'lib/main.dart', 'kind': 'update', 'diff': '+new line'},
            ],
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'method': 'item/updated',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'item': {
              'id': 'file-1',
              'type': 'fileChange',
              'changes': <Map<String, String>>[],
            },
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'id': 41,
          'method': 'item/tool/requestUserInput',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'itemId': 'question-item',
            'isBlocking': true,
            'questions': [
              {
                'id': 'mode',
                'header': '模式',
                'question': '请选择运行模式',
                'isOther': true,
                'options': [
                  {'label': 'Safe', 'description': '保守运行'},
                  {'label': 'Fast', 'description': '快速运行'},
                ],
              },
            ],
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'method': 'turn/diff/updated',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'diff': 'diff --git a/lib/main.dart b/lib/main.dart\n+new line',
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'id': 42,
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'itemId': 'command-item',
            'kind': 'writeStdin',
            'command': 'echo test',
            'reason': '运行测试命令',
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'id': 43,
          'method': 'item/fileChange/requestApproval',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'itemId': 'file-1',
            'reason': '写入测试文件',
            'grantRoot': 'C:\\Shared',
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'id': 45,
          'method': 'item/fileChange/requestApproval',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'itemId': 'file-without-item-details',
            'reason': '写入另一测试文件',
          },
        }),
      );
      stdout.writeln(
        jsonEncode({
          'id': 44,
          'method': 'item/permissions/requestApproval',
          'params': {
            'threadId': 'fake-thread',
            'turnId': 'fake-turn',
            'itemId': 'permissions-item',
            'reason': '需要网络权限',
            'permissions': {
              'network': {'enabled': true},
            },
          },
        }),
      );
    } else if (method == 'model/list') {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'data': [
              {
                'id': 'gpt-6-sol',
                'model': 'gpt-6-sol',
                'displayName': 'GPT-6 Sol',
                'defaultReasoningEffort': 'medium',
                'supportedReasoningEfforts': [
                  {'reasoningEffort': 'medium'},
                  {'reasoningEffort': 'high'},
                ],
              },
            ],
            'nextCursor': null,
          },
        }),
      );
    } else if (method == 'skills/list') {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'data': [
              {
                'cwd': Directory.current.path,
                'skills': [
                  {
                    'name': 'review',
                    'path':
                        '${Directory.current.path}${Platform.pathSeparator}review${Platform.pathSeparator}SKILL.md',
                    'enabled': true,
                  },
                  {'name': 'disabled-skill', 'enabled': false},
                ],
                'errors': [],
              },
            ],
          },
        }),
      );
    } else if (method == 'thread/read') {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'thread': {
              'id': (frame['params'] as Map)['threadId'],
              'model': selectedModel,
              'reasoningEffort': selectedEffort,
            },
          },
        }),
      );
    } else if (method == 'thread/settings/update' ||
        method == 'turn/settings/update') {
      final params = frame['params'] as Map;
      selectedModel = params['model']?.toString() ?? selectedModel;
      selectedEffort = params['effort']?.toString() ?? selectedEffort;
      await log.writeAsString('${jsonEncode(frame)}\n', mode: FileMode.append);
      stdout.writeln(jsonEncode({'id': id, 'result': {}}));
    } else if (method == 'thread/compact/start' || method == 'review/start') {
      await log.writeAsString('${jsonEncode(frame)}\n', mode: FileMode.append);
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': method == 'review/start'
              ? {
                  'reviewThreadId': (frame['params'] as Map)['threadId'],
                  'turn': {'id': 'review-turn', 'status': 'inProgress'},
                }
              : {},
        }),
      );
    } else if (method == 'thread/queue/add') {
      final params = frame['params'] as Map;
      queuedSubmission = {
        'id': 'fake-queued-1',
        'clientUserMessageId': params['clientUserMessageId'],
        'input': params['input'],
      };
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {'queuedSubmission': queuedSubmission},
        }),
      );
    } else if (method == 'thread/queue/list') {
      final params = frame['params'] as Map;
      if (params['threadId'] == 'fake-paged-thread') {
        final secondPage = params['cursor'] == 'page-2';
        stdout.writeln(
          jsonEncode({
            'id': id,
            'result': {
              'data': [
                {
                  'id': secondPage ? 'paged-2' : 'paged-1',
                  'clientUserMessageId': 'client-paged',
                  'input': [
                    {'type': 'text', 'text': secondPage ? 'second' : 'first'},
                  ],
                },
              ],
              'nextCursor': secondPage ? null : 'page-2',
            },
          }),
        );
        continue;
      }
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'data': [?queuedSubmission],
            'nextCursor': null,
          },
        }),
      );
    } else if (method == 'thread/queue/delete') {
      final params = frame['params'] as Map;
      final deleted =
          params['threadId'] == 'fake-thread' &&
          params['queuedSubmissionId'] == queuedSubmission?['id'];
      if (deleted) queuedSubmission = null;
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {'deleted': deleted},
        }),
      );
    } else if (method == 'thread/start') {
      final startParams = frame['params'] as Map;
      await log.writeAsString('${jsonEncode(frame)}\n', mode: FileMode.append);
      if (startParams['threadSource'] != 'remoteaisync') {
        stdout.writeln(
          jsonEncode({
            'id': id,
            'error': {'message': 'missing threadSource'},
          }),
        );
        continue;
      }
      final threadId = startParams['ephemeral'] == true
          ? 'ephemeral-thread'
          : 'new-thread${newThreadCount++ == 0 ? '' : '-$newThreadCount'}';
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'thread': {'id': threadId},
          },
        }),
      );
    } else if (method == 'thread/list') {
      final params = frame['params'] as Map;
      final visible =
          params['cwd'] == null || params['cwd'] == Directory.current.path;
      final secondPage = params['cursor'] == 'page-two';
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'data': visible
                ? [
                    if (!secondPage)
                      {
                        'id': 'fake-thread',
                        'cwd': Directory.current.path,
                        'name': 'Fake Codex session',
                        'updatedAt': 1_700_000_000,
                      },
                    if (secondPage &&
                        (params['sourceKinds'] as List? ?? const []).contains(
                          'appServer',
                        ))
                      {
                        'id': 'persisted-app-server-thread',
                        'cwd': Directory.current.path,
                        'name': 'Persisted remote session',
                        'threadSource': 'remoteaisync',
                        'updatedAt': 1_700_000_002,
                      },
                    if (secondPage && newThreadVisible)
                      {
                        'id': 'new-thread',
                        'cwd': Directory.current.path,
                        'name': 'Persisted Codex session',
                        'threadSource': 'remoteaisync',
                        'updatedAt': 1_700_000_001,
                      },
                  ]
                : <Map<String, Object?>>[],
            'nextCursor': visible && !secondPage ? 'page-two' : null,
          },
        }),
      );
    } else if (method == 'thread/items/list') {
      final threadId = (frame['params'] as Map)['threadId'];
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'data': threadId == 'persisted-app-server-thread'
                ? [
                    {
                      'turnId': 'desktop-live-turn',
                      'startedAtMs': 1_700_000_100_000,
                      'completedAtMs': null,
                      'item': {
                        'id': 'desktop-live-item',
                        'type': 'agentMessage',
                        'text': 'Desktop response while running',
                      },
                    },
                    {
                      'turnId': 'desktop-live-turn',
                      'startedAtMs': 1_700_000_099_000,
                      'completedAtMs': 1_700_000_099_000,
                      'item': {
                        'id': 'desktop-live-user',
                        'type': 'userMessage',
                        'content': [
                          {'type': 'text', 'text': 'Desktop prompt'},
                        ],
                      },
                    },
                    {
                      'turnId': 'older-turn',
                      'startedAtMs': 1_700_000_000_000,
                      'completedAtMs': 1_700_000_000_000,
                      'item': {
                        'id': 'older-unlisted-item',
                        'type': 'agentMessage',
                        'text': 'Old item outside the current turn',
                      },
                    },
                  ]
                : <Map<String, Object?>>[],
            'nextCursor': null,
          },
        }),
      );
    } else if (method == 'thread/turns/list') {
      final threadId = (frame['params'] as Map)['threadId'];
      if (threadId == 'new-thread' && newThreadRolloutEmpty) {
        newThreadRolloutEmpty = false;
        stdout.writeln(
          jsonEncode({
            'id': id,
            'error': {
              'message':
                  'failed to read thread: rollout at probe.jsonl is empty',
            },
          }),
        );
        continue;
      }
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': {
            'data': threadId == 'new-thread'
                ? [
                    {
                      'id': 'stream-turn',
                      'startedAt': 1_700_000_000,
                      'items': [
                        {
                          'id': 'agent-stream',
                          'type': 'agentMessage',
                          'text': 'Hello',
                        },
                        {
                          'id': 'command-stream',
                          'type': 'commandExecution',
                          'command': 'echo stream',
                          'aggregatedOutput': '',
                        },
                      ],
                    },
                  ]
                : [
                    {
                      'id': 'fake-turn',
                      'startedAt': 1_700_000_000,
                      'status': 'failed',
                      'error': {'message': 'Model unavailable'},
                      'items': [
                        {
                          'id': 'user-1',
                          'type': 'userMessage',
                          'content': [
                            {'type': 'text', 'text': 'Hello Codex'},
                          ],
                        },
                        {
                          'id': 'agent-1',
                          'type': 'agentMessage',
                          'text': 'Hello user',
                        },
                        {
                          'id': 'command-1',
                          'type': 'commandExecution',
                          'command': 'echo test',
                          'aggregatedOutput': 'test',
                        },
                        {
                          'id': 'command-2',
                          'type': 'commandExecution',
                          'command': 'exit 2',
                          'exitCode': 2,
                          'status': 'failed',
                          'aggregatedOutput': 'denied',
                        },
                        {
                          'id': 'file-1',
                          'type': 'fileChange',
                          'status': 'completed',
                          'changes': [
                            {
                              'path': 'lib/main.dart',
                              'kind': 'update',
                              'diff': '+new line',
                            },
                          ],
                        },
                        {
                          'id': 'mcp-1',
                          'type': 'mcpToolCall',
                          'server': 'fs',
                          'tool': 'read',
                          'arguments': {'path': 'missing.txt'},
                          'error': {'message': 'not found'},
                        },
                        {
                          'id': 'dynamic-1',
                          'type': 'dynamicToolCall',
                          'namespace': 'tools',
                          'tool': 'check',
                          'arguments': {},
                          'success': true,
                          'contentItems': [
                            {'type': 'inputText', 'text': 'check complete'},
                          ],
                        },
                      ],
                    },
                  ],
          },
        }),
      );
    } else if (method == 'thread/resume' &&
        (frame['params'] as Map)['threadId'] == 'busy-thread') {
      stdout.writeln(
        jsonEncode({
          'id': id,
          'error': {
            'code': -32600,
            'message': 'thread busy-thread already has an active writer',
          },
        }),
      );
    } else if (method == 'thread/resume' ||
        method == 'turn/start' ||
        method == 'turn/steer' ||
        method == 'turn/interrupt') {
      if (method == 'turn/start' &&
          (frame['params'] as Map)['threadId'] == 'new-thread') {
        newThreadVisible = true;
        stdout.writeln(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'threadId': 'new-thread',
              'turnId': 'stream-turn',
              'item': {
                'id': 'agent-stream',
                'type': 'agentMessage',
                'text': '',
              },
            },
          }),
        );
        for (final delta in ['Hello ', 'world']) {
          stdout.writeln(
            jsonEncode({
              'method': 'item/agentMessage/delta',
              'params': {
                'threadId': 'new-thread',
                'turnId': 'stream-turn',
                'itemId': 'agent-stream',
                'delta': delta,
              },
            }),
          );
        }
        stdout.writeln(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'threadId': 'new-thread',
              'turnId': 'stream-turn',
              'item': {
                'id': 'command-stream',
                'type': 'commandExecution',
                'command': 'echo stream',
                'aggregatedOutput': null,
              },
            },
          }),
        );
        stdout.writeln(
          jsonEncode({
            'method': 'item/commandExecution/outputDelta',
            'params': {
              'threadId': 'new-thread',
              'turnId': 'stream-turn',
              'itemId': 'command-stream',
              'delta': 'done',
            },
          }),
        );
        stdout.writeln(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'threadId': 'new-thread',
              'turnId': 'stream-turn',
              'item': {
                'id': 'reasoning-stream',
                'type': 'reasoning',
                'summary': <String>[],
              },
            },
          }),
        );
        stdout.writeln(
          jsonEncode({
            'method': 'item/reasoning/summaryTextDelta',
            'params': {
              'threadId': 'new-thread',
              'turnId': 'stream-turn',
              'itemId': 'reasoning-stream',
              'summaryIndex': 0,
              'delta': 'Analyzing the request',
            },
          }),
        );
      }
      await log.writeAsString('${jsonEncode(frame)}\n', mode: FileMode.append);
      final failingTurn =
          method == 'turn/start' &&
          (frame['params'] as Map)['threadId'] == 'ephemeral-thread';
      if (method == 'turn/steer') {
        final params = frame['params'] as Map;
        stdout.writeln(
          jsonEncode({
            'method': 'turn/completed',
            'params': {
              'threadId': params['threadId'],
              'turn': {'id': params['expectedTurnId'], 'status': 'completed'},
            },
          }),
        );
      }
      stdout.writeln(
        jsonEncode({
          'id': id,
          'result': method == 'turn/start'
              ? {
                  'turn': {
                    'id': failingTurn
                        ? 'failed-turn'
                        : 'test-turn-${++nextTurn}',
                    'status': 'inProgress',
                  },
                }
              : {},
        }),
      );
      if (failingTurn) {
        stdout.writeln(
          jsonEncode({
            'method': 'turn/completed',
            'params': {
              'threadId': 'ephemeral-thread',
              'turn': {
                'id': 'failed-turn',
                'status': 'failed',
                'completedAt': 1_700_000_001,
                'error': {
                  'message': 'Transient model failure',
                  'additionalDetails': 'Retry later',
                },
              },
            },
          }),
        );
      }
    } else if (id != null && frame['result'] != null) {
      await log.writeAsString('${jsonEncode(frame)}\n', mode: FileMode.append);
    }
  }
}

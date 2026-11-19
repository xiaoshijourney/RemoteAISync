import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:remote_ai_sync/src/domain/models.dart';

typedef OpenCodeCommandRunner =
    Future<ProcessResult> Function({
      required String executable,
      required List<String> arguments,
      required String workingDirectory,
    });

class OpenCodeServiceConnection {
  const OpenCodeServiceConnection({
    required this.baseUri,
    required this.password,
  });

  final Uri baseUri;
  final String password;

  static Future<OpenCodeServiceConnection> discover({
    required String executable,
    required String workingDirectory,
    OpenCodeCommandRunner? commandRunner,
  }) async {
    var resolvedExecutable = executable;
    if (commandRunner == null && Platform.isWindows) {
      try {
        final located = await Process.run('where.exe', [executable]);
        final first = located.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty, orElse: () => '');
        if (located.exitCode == 0 && first.isNotEmpty) {
          resolvedExecutable = first;
        }
      } on ProcessException {
        // Fall back to normal PATH lookup.
      }
    }
    Future<ProcessResult> run(List<String> arguments) =>
        commandRunner?.call(
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
        ) ??
        Process.run(
          resolvedExecutable,
          arguments,
          workingDirectory: workingDirectory,
        );

    String? serviceUrlFromStatus(ProcessResult result) {
      for (final line in result.stdout.toString().split(RegExp(r'\r?\n'))) {
        final value = line.trim();
        if (value.startsWith('http://')) return value;
      }
      return null;
    }

    var status = await run(['service', 'status']);
    var serviceUrl = serviceUrlFromStatus(status);
    if (status.exitCode != 0 || serviceUrl == null) {
      final started = await run(['service', 'start']);
      if (started.exitCode == 0) {
        status = await run(['service', 'status']);
        serviceUrl = serviceUrlFromStatus(status);
      }
    }
    if (status.exitCode != 0 || serviceUrl == null) {
      throw const OpenCodeApiException('OpenCode 后台服务未运行，请先在电脑上打开 OpenCode。');
    }
    final baseUri = Uri.tryParse(serviceUrl);
    if (baseUri == null || !_isLoopback(baseUri.host)) {
      throw const OpenCodeApiException('无法安全定位 OpenCode 本机服务。');
    }

    final state = await run(['debug', 'paths', 'state']);
    final statePath = state.stdout.toString().trim();
    if (state.exitCode != 0 || statePath.isEmpty) {
      throw const OpenCodeApiException('无法读取 OpenCode 服务配置位置。');
    }
    final serviceFile = File(
      '${Directory(statePath).path}${Platform.pathSeparator}service.json',
    );
    if (!await serviceFile.exists()) {
      throw const OpenCodeApiException('OpenCode 本机服务配置不存在。');
    }
    final serviceData = jsonDecode(await serviceFile.readAsString());
    if (serviceData is! Map) {
      throw const OpenCodeApiException('OpenCode 本机服务配置格式无效。');
    }
    final configuredUrl = Uri.tryParse(serviceData['url']?.toString() ?? '');
    final password = serviceData['password']?.toString() ?? '';
    if (configuredUrl == null ||
        configuredUrl.host != baseUri.host ||
        configuredUrl.port != baseUri.port ||
        password.isEmpty) {
      throw const OpenCodeApiException('OpenCode 本机服务配置已过期。');
    }
    return OpenCodeServiceConnection(baseUri: baseUri, password: password);
  }
}

class OpenCodeApi {
  OpenCodeApi({
    required this.baseUri,
    required String password,
    required this.projectDirectory,
    this.executable = 'opencode',
    this.commandRunner,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient() {
    _authorization = 'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
  }

  final Uri baseUri;
  String projectDirectory;
  final String executable;
  final OpenCodeCommandRunner? commandRunner;
  final HttpClient _httpClient;
  late final String _authorization;

  void setProjectDirectory(String directory) => projectDirectory = directory;

  Future<String> version() async {
    final body = _asMap(await _request('GET', '/api/info'));
    final version = body['version'];
    if (version is! String || version.isEmpty) {
      throw const OpenCodeApiException('OpenCode returned no version.');
    }
    return version;
  }

  Future<List<OpenCodeSession>> listSessions({
    int? limit,
    String? directory,
    bool global = false,
  }) async {
    final query = <String, String>{
      'limit': '${limit ?? (global ? 1000 : 50)}',
      'order': 'desc',
      if (!global) 'directory': directory ?? projectDirectory,
    };
    final body = await _request(
      'GET',
      '/api/session?${Uri(queryParameters: query).query}',
    );
    return _asList(body)
        .whereType<Map>()
        .map((item) => OpenCodeSession.fromJson(item.cast<String, dynamic>()))
        .where((session) => session.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<OpenCodeSession> createSession({
    String? title,
    String? directory,
  }) async {
    final workingDirectory = directory ?? projectDirectory;
    final location = <String, Object?>{'directory': workingDirectory};
    final body = _asMap(
      await _request(
        'POST',
        _withDirectory('/api/session', directory: workingDirectory),
        body: {'location': location, 'title': ?title},
      ),
    );
    final session = OpenCodeSession.fromJson(body);
    if (session.id.isEmpty) {
      throw const OpenCodeApiException('OpenCode 未返回新会话 ID。');
    }
    return session;
  }

  Future<CodexControls> listControls() async {
    final config = _asMap(await _request('GET', '/config/providers'));
    final providers = config['providers'] is List
        ? (config['providers'] as List).whereType<Map>()
        : const <Map>[];
    final defaults = config['default'] is Map
        ? config['default'] as Map
        : const <Object?, Object?>{};
    final models = <CodexModelOption>[];
    String? selectedModel;
    String? selectedVariant;
    for (final provider in providers) {
      final providerId = provider['id']?.toString() ?? '';
      final providerModels = provider['models'];
      final Iterable<MapEntry<Object?, Object?>> entries;
      if (providerModels is Map) {
        entries = providerModels.entries.map(
          (entry) => MapEntry<Object?, Object?>(entry.key, entry.value),
        );
      } else if (providerModels is List) {
        entries = providerModels.whereType<Map>().map(
          (model) => MapEntry<Object?, Object?>(model['id'], model),
        );
      } else {
        entries = const <MapEntry<Object?, Object?>>[];
      }
      for (final entry in entries) {
        final rawValue = entry.value;
        if (rawValue is! Map) continue;
        final rawModel = rawValue;
        final modelId =
            rawModel['id']?.toString() ?? entry.key?.toString() ?? '';
        if (providerId.isEmpty || modelId.isEmpty) continue;
        final variants = rawModel['variants'];
        final efforts = variants is Map
            ? variants.keys.map((value) => value.toString()).toList()
            : const <String>[];
        final id = '$providerId/$modelId';
        models.add(
          CodexModelOption(
            id: id,
            name: rawModel['name']?.toString() ?? modelId,
            efforts: efforts,
            defaultEffort: rawModel['defaultVariant']?.toString(),
          ),
        );
        if (defaults[providerId]?.toString() == modelId &&
            selectedModel == null) {
          selectedModel = id;
        }
      }
    }
    models.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    selectedModel ??= models.isEmpty ? null : models.first.id;
    final chosen = models.where((model) => model.id == selectedModel);
    if (chosen.isNotEmpty &&
        chosen.first.efforts.contains(chosen.first.defaultEffort)) {
      selectedVariant = chosen.first.defaultEffort;
    }
    return CodexControls(
      models: models,
      skills: const [],
      model: selectedModel,
      effort: selectedVariant,
    );
  }

  Future<List<AgentMessage>> listMessages(
    String sessionId, {
    String? directory,
  }) async {
    final path = '/api/session/${Uri.encodeComponent(sessionId)}/message';
    final query = Uri(
      queryParameters: {
        'limit': '100',
        'order': 'desc',
        'directory': directory ?? projectDirectory,
      },
    ).query;
    final body = await _request('GET', '$path?$query');
    final rows = _asList(body);
    final messages = <AgentMessage>[];
    for (final row in rows.whereType<Map>().toList().reversed) {
      messages.addAll(
        OpenCodeSession.parseMessages(row.cast<String, dynamic>()),
      );
    }
    return messages;
  }

  Future<void> sendReply(
    String sessionId,
    String text, {
    String? model,
    String? variant,
    String? directory,
  }) async {
    final modelParts = model?.split('/') ?? const <String>[];
    await _request(
      'POST',
      _withDirectory(
        '/api/session/${Uri.encodeComponent(sessionId)}/prompt',
        directory: directory,
      ),
      body: {
        'text': text,
        if (modelParts.length >= 2)
          'model': {
            'providerID': modelParts.first,
            'modelID': modelParts.skip(1).join('/'),
          },
        if (variant != null && variant.isNotEmpty) 'variant': variant,
      },
    );
  }

  Future<bool> abortSession(String sessionId, {String? directory}) async {
    final result = await _request(
      'POST',
      _withDirectory(
        '/api/session/${Uri.encodeComponent(sessionId)}/abort',
        directory: directory,
      ),
    );
    return result == true;
  }

  Future<List<AgentForm>> listForms(
    String sessionId, {
    String? directory,
  }) async {
    final path = _withDirectory(
      '/api/session/${Uri.encodeComponent(sessionId)}/form',
      directory: directory,
    );
    final forms = _asList(await _request('GET', path));
    return forms
        .whereType<Map>()
        .where((item) {
          final state = item['state'];
          return state is! Map || state['status'] == 'pending';
        })
        .map(AgentForm.fromJson)
        .where((form) => form.id.isNotEmpty && form.sessionId == sessionId)
        .toList(growable: false);
  }

  Future<void> replyToForm(
    String sessionId,
    String formId,
    Map<String, Object?> answer, {
    String? directory,
  }) async {
    await _request(
      'POST',
      _withDirectory(
        '/api/session/${Uri.encodeComponent(sessionId)}/form/${Uri.encodeComponent(formId)}/reply',
        directory: directory,
      ),
      body: {'answer': answer},
    );
  }

  Future<List<AgentPermission>> listPermissions(
    String sessionId, {
    String? directory,
  }) async {
    final path = _withDirectory(
      '/api/session/${Uri.encodeComponent(sessionId)}/permission',
      directory: directory,
    );
    return _asList(await _request('GET', path))
        .whereType<Map>()
        .map(AgentPermission.fromJson)
        .where(
          (permission) =>
              permission.id.isNotEmpty && permission.sessionId == sessionId,
        )
        .toList(growable: false);
  }

  Future<void> createForm(
    String sessionId, {
    required String title,
    required List<Map<String, Object?>> fields,
  }) async {
    await _request(
      'POST',
      _withDirectory('/api/session/${Uri.encodeComponent(sessionId)}/form'),
      body: {'title': title, 'fields': fields},
    );
  }

  Future<void> updateSessionPermissions(
    String sessionId,
    List<Map<String, Object?>> permissions,
  ) async {
    await _request(
      'PATCH',
      _withDirectory('/api/session/${Uri.encodeComponent(sessionId)}'),
      body: {'permissions': permissions},
    );
  }

  Future<void> createPermissionRequest(
    String sessionId, {
    required String action,
    required List<String> resources,
    required String toolId,
  }) async {
    await _request(
      'POST',
      _withDirectory(
        '/api/session/${Uri.encodeComponent(sessionId)}/permission',
      ),
      body: {
        'action': action,
        'resources': resources,
        'source': {
          'type': 'tool',
          'messageID': 'msg_remoteaisync_test',
          'id': toolId,
        },
      },
    );
  }

  Future<void> replyToPermission(
    String sessionId,
    String requestId, {
    required String decision,
    String? directory,
  }) async {
    if (decision != 'once' && decision != 'always' && decision != 'reject') {
      throw const OpenCodeApiException('不支持的工具审批决定。');
    }
    await _request(
      'POST',
      _withDirectory(
        '/api/session/${Uri.encodeComponent(sessionId)}/permission/${Uri.encodeComponent(requestId)}/reply',
        directory: directory,
      ),
      body: {'decision': decision},
    );
  }

  Stream<Map<String, dynamic>> events() async* {
    final request = await _httpClient.getUrl(baseUri.resolve('/api/event'));
    request.headers
      ..set(HttpHeaders.authorizationHeader, _authorization)
      ..set(HttpHeaders.acceptHeader, 'text/event-stream');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw OpenCodeApiException(
        'OpenCode event stream returned HTTP ${response.statusCode}.',
      );
    }

    final data = <String>[];
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          final decoded = jsonDecode(data.join('\n'));
          if (decoded is Map) yield decoded.cast<String, dynamic>();
          data.clear();
        }
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
  }

  Future<void> close() async {
    _httpClient.close(force: true);
  }

  String _withDirectory(String path, {String? directory}) {
    final query = Uri(
      queryParameters: {'directory': directory ?? projectDirectory},
    ).query;
    return '$path?$query';
  }

  Future<Object?> _request(String method, String path, {Object? body}) async {
    final request = await _httpClient.openUrl(method, baseUri.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, _authorization);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final content = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OpenCodeApiException(
        'OpenCode API returned HTTP ${response.statusCode}.',
      );
    }
    final payload = content.replaceFirst('\uFEFF', '').trim();
    if (payload.isEmpty) return null;
    try {
      return jsonDecode(payload);
    } on FormatException {
      final contentType = response.headers.contentType?.mimeType ?? 'unknown';
      throw OpenCodeApiException(
        'OpenCode $method $path returned a non-JSON response '
        '(HTTP ${response.statusCode}, $contentType, ${payload.length} characters). '
        'Check that the local OpenCode server API is compatible and running.',
      );
    }
  }

  static List<Object?> _asList(Object? body) {
    if (body is List) return body.cast<Object?>();
    if (body is Map && body['data'] is List) {
      return (body['data'] as List).cast<Object?>();
    }
    throw const OpenCodeApiException(
      'OpenCode returned an unexpected list response.',
    );
  }

  static Map<String, dynamic> _asMap(Object? body) {
    if (body is Map && body['data'] is Map) {
      return (body['data'] as Map).cast<String, dynamic>();
    }
    if (body is Map) return body.cast<String, dynamic>();
    return const {};
  }
}

bool _isLoopback(String host) {
  if (host.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}

class OpenCodeApiException implements Exception {
  const OpenCodeApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OpenCodeSession {
  const OpenCodeSession({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.directory,
  });

  final String id;
  final String title;
  final String updatedAt;
  final String? directory;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt,
    if (directory != null) 'directory': directory,
  };

  factory OpenCodeSession.fromJson(Map<String, dynamic> json) {
    final time = json['time'];
    final updated = time is Map ? time['updated'] : null;
    final location = json['location'];
    return OpenCodeSession(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString().trim().isNotEmpty == true
          ? json['title'].toString()
          : '未命名会话',
      updatedAt: _formatTime(updated),
      directory:
          json['directory']?.toString() ??
          (location is Map ? location['directory']?.toString() : null),
    );
  }

  static List<AgentMessage> parseMessages(Map<String, dynamic> item) {
    final message = item['info'] is Map
        ? (item['info'] as Map).cast<String, dynamic>()
        : item['message'] is Map
        ? (item['message'] as Map).cast<String, dynamic>()
        : item;
    final role = message['type']?.toString() ?? message['role']?.toString();
    final author = switch (role) {
      'user' => MessageAuthor.user,
      'system' || 'synthetic' || 'compaction' => MessageAuthor.system,
      'shell' => MessageAuthor.tool,
      _ => MessageAuthor.assistant,
    };
    final messageId = message['id']?.toString() ?? 'message';
    final time = _formatTime(_messageTime(message['time']));
    final parts = message['content'] is List
        ? message['content'] as List
        : item['parts'] is List
        ? item['parts'] as List
        : const [];
    final output = <AgentMessage>[];

    final userText = message['text']?.toString() ?? '';
    if (author == MessageAuthor.user && userText.isNotEmpty) {
      output.add(
        AgentMessage(id: messageId, author: author, text: userText, time: time),
      );
    }

    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (part is! Map) continue;
      final type = part['type']?.toString();
      final partId = part['id']?.toString() ?? '$index';
      if (type == 'text') {
        final text = part['text']?.toString() ?? '';
        if (text.isNotEmpty) {
          output.add(
            AgentMessage(
              id: '$messageId:$partId',
              author: author,
              text: text,
              time: time,
              groupId: messageId,
            ),
          );
        }
      } else if (type == 'tool') {
        output.add(
          AgentMessage(
            id: '$messageId:$partId',
            author: MessageAuthor.tool,
            text: _toolSummary(part),
            time: time,
            groupId: messageId,
          ),
        );
      }
    }

    if (output.isEmpty && message['text'] is String) {
      final text = message['text'] as String;
      if (text.isNotEmpty) {
        output.add(
          AgentMessage(id: messageId, author: author, text: text, time: time),
        );
      }
    }
    return output;
  }

  static String _toolSummary(Map part) {
    final name = part['name']?.toString() ?? part['tool']?.toString() ?? 'Tool';
    final state = part['state'] is Map ? part['state'] as Map : const {};
    final status = state['status']?.toString();
    final input = state['input'];
    final lines = <String>['工具调用 · $name${status == null ? '' : ' · $status'}'];
    if (input != null) lines.add('输入：${_compactJson(input)}');
    final result = _toolResultText(state['content']);
    if (result.isNotEmpty) lines.add('输出：${_truncate(result, 1200)}');
    final error = state['error'];
    if (error != null) {
      lines.add('错误：${_compactJson(error)}');
    }
    return lines.join('\n');
  }

  static String _toolResultText(Object? content) {
    if (content is! List) return '';
    return content
        .whereType<Map>()
        .where((item) => item['type'] == 'text' && item['text'] is String)
        .map((item) => item['text'] as String)
        .where((text) => text.isNotEmpty)
        .join('\n');
  }
}

Object? _messageTime(Object? value) {
  if (value is Map) return value['created'];
  return value;
}

String _formatTime(Object? value) {
  DateTime? date;
  if (value is num) {
    date = DateTime.fromMillisecondsSinceEpoch(value.toInt());
  } else if (value is String) {
    date = DateTime.tryParse(value)?.toLocal();
  }
  date ??= DateTime.now();
  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String _compactJson(Object value) {
  final text = value is String ? value : jsonEncode(value);
  return _truncate(text, 1200);
}

String _truncate(String text, int maxLength) =>
    text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';

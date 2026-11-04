import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:remote_ai_sync/src/domain/models.dart';

class OpenCodeApi {
  OpenCodeApi({
    required this.baseUri,
    required String password,
    required this.projectDirectory,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient() {
    _authorization = 'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
  }

  final Uri baseUri;
  final String projectDirectory;
  final HttpClient _httpClient;
  late final String _authorization;

  Future<String> version() async {
    final body = _asMap(await _request('GET', '/api/info'));
    final version = body['version'];
    if (version is! String || version.isEmpty) {
      throw const OpenCodeApiException('OpenCode returned no version.');
    }
    return version;
  }

  Future<List<OpenCodeSession>> listSessions({int limit = 50}) async {
    final query = <String, String>{
      'limit': '$limit',
      'order': 'desc',
      'directory': projectDirectory,
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

  Future<List<AgentMessage>> listMessages(String sessionId) async {
    final path = '/api/session/${Uri.encodeComponent(sessionId)}/message';
    final query = Uri(
      queryParameters: {
        'limit': '100',
        'order': 'desc',
        'directory': projectDirectory,
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

  Future<void> sendReply(String sessionId, String text) async {
    await _request(
      'POST',
      '/api/session/${Uri.encodeComponent(sessionId)}/prompt',
      body: {'text': text},
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
    if (content.isEmpty) return null;
    try {
      return jsonDecode(content);
    } on FormatException {
      throw const OpenCodeApiException('OpenCode returned invalid JSON.');
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
  });

  final String id;
  final String title;
  final String updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt,
  };

  factory OpenCodeSession.fromJson(Map<String, dynamic> json) {
    final time = json['time'];
    final updated = time is Map ? time['updated'] : null;
    return OpenCodeSession(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString().trim().isNotEmpty == true
          ? json['title'].toString()
          : '未命名会话',
      updatedAt: _formatTime(updated),
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

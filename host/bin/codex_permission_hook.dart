import 'dart:convert';
import 'dart:io';

/// Optional Codex PermissionRequest hook. Stdout must contain hook JSON only.
Future<void> main(List<String> arguments) async {
  try {
    final port = _port(arguments);
    if (port == null) return _fallback();
    final bytes = <int>[];
    await for (final chunk in stdin.timeout(const Duration(seconds: 5))) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) return _fallback();
    }
    final input = jsonDecode(utf8.decode(bytes));
    if (input is! Map || input['hook_event_name'] != 'PermissionRequest') {
      return _fallback();
    }
    final config = jsonDecode(await File(_runtimePath(port)).readAsString());
    if (config is! Map ||
        config['port'] != port ||
        config['token'] is! String ||
        config['projectDirectory'] is! String ||
        !_sameDirectory(
          input['cwd']?.toString() ?? '',
          config['projectDirectory'] as String,
        )) {
      return _fallback();
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/codex-hook/approval'))
          .timeout(const Duration(seconds: 5));
      request.headers.set(
        'x-remoteaisync-hook-token',
        config['token'] as String,
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'hook_event_name': 'PermissionRequest',
          'session_id': input['session_id'],
          'cwd': input['cwd'],
          'tool_name': input['tool_name'],
          'tool_input': input['tool_input'],
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 310),
      );
      if (response.statusCode != HttpStatus.ok) return _fallback();
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      final decision = body is Map ? body['decision'] : null;
      if (decision != 'allow' && decision != 'deny') return _fallback();
      stdout.writeln(
        jsonEncode({
          'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': {'behavior': decision},
          },
        }),
      );
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    _fallback();
  }
}

void _fallback() => stdout.writeln('{}');

int? _port(List<String> arguments) {
  if (arguments.length != 2 || arguments.first != '--port') return null;
  final value = int.tryParse(arguments.last);
  return value != null && value >= 1 && value <= 65535 ? value : null;
}

String _runtimePath(int port) {
  final home = Platform.isWindows
      ? Platform.environment['LOCALAPPDATA']
      : Platform.environment['XDG_RUNTIME_DIR'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw const FormatException('No runtime dir');
  }
  return [
    home,
    'RemoteAISync',
    'codex-hook-$port.json',
  ].join(Platform.pathSeparator);
}

bool _sameDirectory(String left, String right) {
  if (left.isEmpty) return false;
  final a = Directory(left).absolute.path.replaceAll('\\', '/');
  final b = Directory(right).absolute.path.replaceAll('\\', '/');
  return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
}

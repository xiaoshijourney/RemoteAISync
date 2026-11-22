import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class UpdateService {
  UpdateService._(this._server, this._dataDirectory, this._adminFile);

  static const _maxArtifactBytes = 2 * 1024 * 1024 * 1024;
  static const _sessionLifetime = Duration(hours: 8);
  static const _iterations = 180000;
  static const _cookieName = 'ras_update_session';

  final HttpServer _server;
  final Directory _dataDirectory;
  final File _adminFile;
  final Map<String, DateTime> _sessions = {};
  final Map<String, List<DateTime>> _loginFailures = {};
  Future<void> _writeQueue = Future<void>.value();

  int get port => _server.port;

  static Future<UpdateService> bind({
    required int port,
    required String bindAddress,
    required String dataDirectory,
  }) async {
    final directory = Directory(dataDirectory).absolute;
    await directory.create(recursive: true);
    final artifacts = Directory(
      '${directory.path}${Platform.pathSeparator}artifacts',
    );
    await artifacts.create(recursive: true);
    final adminFile = File(
      '${directory.path}${Platform.pathSeparator}admin.json',
    );
    if (!await adminFile.exists()) {
      throw StateError(
        'Update admin is not initialized. Run with --init-admin --data-dir <path>.',
      );
    }
    final server = await HttpServer.bind(
      InternetAddress(bindAddress),
      port,
      shared: false,
    );
    final service = UpdateService._(server, directory, adminFile);
    unawaited(service._serve());
    return service;
  }

  static Future<void> initializeAdmin({
    required String dataDirectory,
    required String password,
  }) async {
    if (password.trim().length < 12) {
      throw ArgumentError('Admin password must be at least 12 characters.');
    }
    final directory = Directory(dataDirectory).absolute;
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}admin.json');
    if (await file.exists()) {
      throw StateError('Update admin already exists; refusing to replace it.');
    }
    final salt = _randomBytes(24);
    final hash = _pbkdf2(password, salt, _iterations);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'algorithm': 'pbkdf2-sha256',
        'iterations': _iterations,
        'salt': base64Url.encode(salt),
        'hash': base64Url.encode(hash),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  static List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }

  static List<int> _pbkdf2(String password, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final block = <int>[...salt, 0, 0, 0, 1];
    var value = hmac.convert(block).bytes;
    final result = List<int>.from(value);
    for (var i = 1; i < iterations; i++) {
      value = hmac.convert(value).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= value[j];
      }
    }
    return result;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      request.response.headers
        ..set('x-content-type-options', 'nosniff')
        ..set('referrer-policy', 'no-referrer')
        ..set('cache-control', 'no-store');
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _json(request.response, 200, {'status': 'ok'});
        return;
      }
      if (path == '/api/admin/login' && request.method == 'POST') {
        await _login(request);
        return;
      }
      if (path.startsWith('/api/admin/')) {
        if (!_isAuthorized(request)) {
          await _json(request.response, 401, {'error': 'login_required'});
          return;
        }
        if (request.method != 'GET' && !_validCsrf(request)) {
          await _json(request.response, 403, {'error': 'csrf_rejected'});
          return;
        }
        if (request.method == 'GET' && path == '/api/admin/session') {
          await _json(request.response, 200, {'csrfToken': _session(request)});
          return;
        }
        await _handleAdmin(request);
        return;
      }
      if (request.method == 'GET' && path.startsWith('/api/v1/updates/')) {
        await _latest(request);
        return;
      }
      if (request.method == 'GET' && path.startsWith('/api/v1/artifacts/')) {
        await _download(request);
        return;
      }
      await _json(request.response, 404, {'error': 'not_found'});
    } on FormatException {
      await _json(request.response, 400, {'error': 'invalid_request'});
    } on _UpdateException catch (error) {
      await _json(request.response, error.status, {'error': error.code});
    } on Object catch (error) {
      stderr.writeln('Update service request failed: $error');
      try {
        await _json(request.response, 500, {'error': 'internal_error'});
      } on Object {
        await request.response.close();
      }
    }
  }

  Future<void> _login(HttpRequest request) async {
    final address = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final now = DateTime.now();
    final failures = _loginFailures[address]
      ?..removeWhere(
        (time) => now.difference(time) >= const Duration(minutes: 1),
      );
    if (failures != null && failures.length >= 5) {
      await request.drain<void>();
      await _json(request.response, 429, {'error': 'try_again_later'});
      return;
    }
    final body = await _readJson(request);
    final password = body['password'];
    if (password is! String || !await _verifyPassword(password)) {
      _loginFailures.putIfAbsent(address, () => []).add(now);
      await _json(request.response, 401, {'error': 'invalid_credentials'});
      return;
    }
    _loginFailures.remove(address);
    final token = base64Url.encode(_randomBytes(32));
    _sessions[token] = DateTime.now().add(_sessionLifetime);
    request.response.headers.add(
      HttpHeaders.setCookieHeader,
      Cookie(_cookieName, token)
        ..httpOnly = true
        ..secure = true
        ..sameSite = SameSite.strict
        ..path = '/'
        ..maxAge = _sessionLifetime.inSeconds,
    );
    await _json(request.response, 200, {'csrfToken': token});
  }

  Future<bool> _verifyPassword(String password) async {
    final saved = jsonDecode(await _adminFile.readAsString());
    if (saved is! Map<String, dynamic> ||
        saved['algorithm'] != 'pbkdf2-sha256') {
      return false;
    }
    final salt = base64Url.decode(saved['salt'] as String);
    final expected = base64Url.decode(saved['hash'] as String);
    final actual = _pbkdf2(password, salt, saved['iterations'] as int);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  String? _session(HttpRequest request) {
    for (final cookie in request.cookies) {
      if (cookie.name == _cookieName) return cookie.value;
    }
    return null;
  }

  bool _isAuthorized(HttpRequest request) {
    final token = _session(request);
    final expires = token == null ? null : _sessions[token];
    if (expires == null) return false;
    if (DateTime.now().isAfter(expires)) {
      _sessions.remove(token);
      return false;
    }
    return true;
  }

  bool _validCsrf(HttpRequest request) {
    final token = _session(request);
    return token != null && request.headers.value('x-csrf-token') == token;
  }

  Future<void> _handleAdmin(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/api/admin/logout') {
      final token = _session(request);
      if (token != null) _sessions.remove(token);
      request.response.headers.add(
        HttpHeaders.setCookieHeader,
        Cookie(_cookieName, '')
          ..httpOnly = true
          ..secure = true
          ..sameSite = SameSite.strict
          ..path = '/'
          ..maxAge = 0,
      );
      await _json(request.response, 200, {'ok': true});
      return;
    }
    if (request.method == 'GET' && request.uri.path == '/api/admin/releases') {
      final state = await _readState();
      await _json(request.response, 200, {
        'releases': state['releases'],
        'disk': await _diskSummary(),
      });
      return;
    }
    if (request.method == 'GET' && request.uri.path == '/api/admin/audit') {
      final state = await _readState();
      await _json(request.response, 200, {'events': state['audit'] ?? []});
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/api/admin/releases') {
      await _createUpload(request);
      return;
    }
    final action = RegExp(
      r'^/api/admin/releases/([A-Za-z0-9_-]+)/(publish|withdraw)$',
    ).firstMatch(request.uri.path);
    if (action != null && request.method == 'POST') {
      await _setReleaseState(action.group(1)!, action.group(2)!);
      await _json(request.response, 200, {'ok': true});
      return;
    }
    await _json(request.response, 404, {'error': 'not_found'});
  }

  Future<void> _createUpload(HttpRequest request) async {
    final encodedMetadata = request.headers.value('x-release-metadata');
    if (encodedMetadata == null || encodedMetadata.length > 24000) {
      await request.drain<void>();
      await _json(request.response, 400, {'error': 'invalid_release_metadata'});
      return;
    }
    final decodedMetadata = jsonDecode(
      utf8.decode(base64Url.decode(encodedMetadata)),
    );
    if (decodedMetadata is! Map<String, dynamic>) {
      await request.drain<void>();
      await _json(request.response, 400, {'error': 'invalid_release_metadata'});
      return;
    }
    final metadata = decodedMetadata;
    final product = _choice(metadata['product'], {'client', 'host', 'relay'});
    final target = _choice(metadata['target'], {
      'android',
      'web',
      'windows',
      'ubuntu',
    });
    final version = metadata['version'];
    final build = metadata['build'];
    final notes = metadata['notes'];
    final filename = metadata['filename'];
    if (product == null ||
        target == null ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(version) ||
        build is! String ||
        build.trim().isEmpty ||
        build.length > 64 ||
        notes is! String ||
        notes.length > 12000 ||
        filename is! String ||
        filename.trim().isEmpty ||
        filename.length > 200 ||
        filename.contains('/') ||
        filename.contains(r'\')) {
      await _json(request.response, 400, {'error': 'invalid_release_metadata'});
      return;
    }
    if ((product == 'client' && !{'android', 'web'}.contains(target)) ||
        (product != 'client' && !{'windows', 'ubuntu'}.contains(target))) {
      await _json(request.response, 400, {'error': 'target_product_mismatch'});
      return;
    }
    final length = request.contentLength;
    if (length <= 0 || length > _maxArtifactBytes) {
      await request.drain<void>();
      await _json(request.response, 413, {'error': 'artifact_size_invalid'});
      return;
    }
    final id = base64Url.encode(_randomBytes(18)).replaceAll('=', '');
    final artifacts = Directory(
      '${_dataDirectory.path}${Platform.pathSeparator}artifacts',
    );
    final temporary = File(
      '${artifacts.path}${Platform.pathSeparator}.$id.upload',
    );
    final output = temporary.openWrite();
    final digestSink = _SingleDigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var written = 0;
    try {
      await for (final chunk in request) {
        written += chunk.length;
        if (written > _maxArtifactBytes) {
          throw const _UpdateException(413, 'artifact_size_invalid');
        }
        output.add(chunk);
        hashSink.add(chunk);
      }
      await output.flush();
      await output.close();
      hashSink.close();
    } on Object {
      await output.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    if (written != length) {
      await temporary.delete();
      await _json(request.response, 400, {'error': 'content_length_mismatch'});
      return;
    }
    final digest = digestSink.value!.toString();
    final artifact = File('${artifacts.path}${Platform.pathSeparator}$id');
    await temporary.rename(artifact.path);
    final now = DateTime.now().toUtc();
    final release = <String, Object?>{
      'id': id,
      'product': product,
      'target': target,
      'version': version,
      'build': build,
      'notes': notes,
      'mandatory': metadata['mandatory'] == true,
      'filename': filename,
      'size': written,
      'sha256': digest,
      'state': 'draft',
      'createdAt': now.toIso8601String(),
      'publishedAt': null,
    };
    await _mutateState((state) {
      (state['releases'] as List).add(release);
      _audit(state, 'artifact_uploaded', release);
    });
    await _json(request.response, 201, {'release': release});
  }

  String? _choice(Object? value, Set<String> choices) =>
      value is String && choices.contains(value) ? value : null;

  Future<void> _setReleaseState(String id, String action) async {
    await _mutateState((state) {
      final releases = state['releases'] as List;
      final matches = releases.cast<Map<String, dynamic>>().where(
        (value) => value['id'] == id,
      );
      if (matches.isEmpty) {
        throw const _UpdateException(404, 'release_not_found');
      }
      final release = matches.first;
      if (action == 'publish') {
        release['state'] = 'published';
        release['publishedAt'] = DateTime.now().toUtc().toIso8601String();
      } else {
        release['state'] = 'withdrawn';
      }
      _audit(
        state,
        action == 'publish' ? 'release_published' : 'release_withdrawn',
        release,
      );
    });
  }

  void _audit(
    Map<String, Object?> state,
    String action,
    Map<String, dynamic> release,
  ) {
    final audit = state.putIfAbsent('audit', () => <Object>[]) as List;
    audit.add({
      'action': action,
      'releaseId': release['id'],
      'product': release['product'],
      'target': release['target'],
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    if (audit.length > 5000) audit.removeRange(0, audit.length - 5000);
  }

  Future<void> _latest(HttpRequest request) async {
    final match = RegExp(
      r'^/api/v1/updates/(client|host|relay)/(android|web|windows|ubuntu)/latest$',
    ).firstMatch(request.uri.path);
    if (match == null) {
      await _json(request.response, 404, {'error': 'not_found'});
      return;
    }
    final state = await _readState();
    final candidates =
        (state['releases'] as List)
            .cast<Map<String, dynamic>>()
            .where(
              (release) =>
                  release['product'] == match.group(1) &&
                  release['target'] == match.group(2) &&
                  release['state'] == 'published',
            )
            .toList()
          ..sort(
            (a, b) => (b['publishedAt'] as String).compareTo(
              a['publishedAt'] as String,
            ),
          );
    if (candidates.isEmpty) {
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    final release = candidates.first;
    await _json(request.response, 200, {
      ...release,
      'downloadUrl': '/api/v1/artifacts/${release['id']}',
    });
  }

  Future<void> _download(HttpRequest request) async {
    final id = request.uri.pathSegments.isEmpty
        ? ''
        : request.uri.pathSegments.last;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      await _json(request.response, 404, {'error': 'not_found'});
      return;
    }
    final state = await _readState();
    final matches = (state['releases'] as List)
        .cast<Map<String, dynamic>>()
        .where(
          (release) => release['id'] == id && release['state'] == 'published',
        );
    if (matches.isEmpty) {
      await _json(request.response, 404, {'error': 'not_found'});
      return;
    }
    final release = matches.first;
    final file = File(
      '${_dataDirectory.path}${Platform.pathSeparator}artifacts${Platform.pathSeparator}$id',
    );
    if (!await file.exists()) {
      await _json(request.response, 410, {'error': 'artifact_missing'});
      return;
    }
    request.response
      ..headers.contentType = ContentType.binary
      ..headers.contentLength = release['size'] as int
      ..headers.set(
        'content-disposition',
        'attachment; filename="${(release['filename'] as String).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}"',
      );
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  Future<Map<String, Object?>> _readState() async {
    final file = File(
      '${_dataDirectory.path}${Platform.pathSeparator}releases.json',
    );
    if (!await file.exists()) return {'schema': 1, 'releases': <Object>[]};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, Object?> && decoded['releases'] is List) {
      return decoded;
    }
    throw const FormatException('Release database is invalid.');
  }

  Future<void> _mutateState(void Function(Map<String, Object?>) mutate) {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        final state = await _readState();
        mutate(state);
        final file = File(
          '${_dataDirectory.path}${Platform.pathSeparator}releases.json',
        );
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(jsonEncode(state), flush: true);
        await temporary.rename(file.path);
        completer.complete();
      } on Object catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<Map<String, Object?>> _diskSummary() async {
    final artifacts = Directory(
      '${_dataDirectory.path}${Platform.pathSeparator}artifacts',
    );
    var bytes = 0;
    await for (final entity in artifacts.list()) {
      if (entity is File) bytes += await entity.length();
    }
    return {'artifactBytes': bytes, 'maxArtifactBytes': _maxArtifactBytes};
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    if (request.contentLength > 65536) {
      await request.drain<void>();
      throw const FormatException('Request body is too large.');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (builder.length + chunk.length > 65536) {
        throw const FormatException('Request body is too large.');
      }
      builder.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected JSON object.');
    }
    return decoded;
  }

  Future<void> _json(HttpResponse response, int status, Object body) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _UpdateException implements Exception {
  const _UpdateException(this.status, this.code);

  final int status;
  final String code;
}

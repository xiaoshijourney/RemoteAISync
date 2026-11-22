import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

// ignore_for_file: avoid_relative_lib_imports

import '../host/lib/src/update_service.dart';

void main() {
  group('UpdateService', () {
    late Directory temp;
    late UpdateService service;
    late HttpClient client;
    String? cookie;
    String? csrf;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('ras-updates-');
      await UpdateService.initializeAdmin(
        dataDirectory: temp.path,
        password: 'correct horse battery staple 2026',
      );
      service = await UpdateService.bind(
        port: 0,
        bindAddress: '127.0.0.1',
        dataDirectory: temp.path,
      );
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await service.close();
      await temp.delete(recursive: true);
    });

    Uri uri(String path) => Uri.parse('http://127.0.0.1:${service.port}$path');

    Future<Map<String, dynamic>> sendJson(
      String method,
      String path, {
      Map<String, Object?> body = const {},
      bool admin = false,
    }) async {
      final request = await client.openUrl(method, uri(path));
      request.headers.contentType = ContentType.json;
      final encodedBody = utf8.encode(jsonEncode(body));
      request.contentLength = encodedBody.length;
      if (admin && cookie != null) {
        request.headers.add(HttpHeaders.cookieHeader, cookie!);
      }
      if (admin && csrf != null) {
        request.headers.set('x-csrf-token', csrf!);
      }
      request.add(encodedBody);
      final response = await request.close();
      final result =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      result['_status'] = response.statusCode;
      return result;
    }

    test(
      'requires setup and password authentication before managing releases',
      () async {
        final unauthorized = await sendJson('GET', '/api/admin/releases');
        expect(unauthorized['_status'], 401);

        final badLogin = await sendJson(
          'POST',
          '/api/admin/login',
          body: {'password': 'wrong password'},
        );
        expect(badLogin['_status'], 401);

        final login = await sendJson(
          'POST',
          '/api/admin/login',
          body: {'password': 'correct horse battery staple 2026'},
        );
        expect(login['_status'], 200);
        csrf = login['csrfToken'] as String;
        cookie = 'ras_update_session=$csrf';

        final releases = await sendJson(
          'GET',
          '/api/admin/releases',
          admin: true,
        );
        expect(releases['_status'], 200);
        expect(releases['releases'], isEmpty);
      },
    );

    test(
      'uploads, publishes, lists, downloads and withdraws a release',
      () async {
        final login = await sendJson(
          'POST',
          '/api/admin/login',
          body: {'password': 'correct horse battery staple 2026'},
        );
        csrf = login['csrfToken'] as String;
        cookie = 'ras_update_session=$csrf';

        final bytes = utf8.encode('ras test apk bytes');
        final metadata = base64Url.encode(
          utf8.encode(
            jsonEncode({
              'product': 'client',
              'target': 'android',
              'version': '1.2.0',
              'build': '12',
              'notes': 'Test release',
              'filename': 'ras.apk',
            }),
          ),
        );
        final upload = await client.postUrl(uri('/api/admin/releases'));
        upload.headers
          ..set(HttpHeaders.cookieHeader, cookie!)
          ..set('x-csrf-token', csrf!)
          ..set('x-release-metadata', metadata)
          ..contentLength = bytes.length;
        upload.add(bytes);
        final uploadResponse = await upload.close();
        final uploaded =
            jsonDecode(await utf8.decoder.bind(uploadResponse).join())
                as Map<String, dynamic>;
        expect(uploadResponse.statusCode, 201);
        final id = uploaded['release']['id'] as String;
        expect(uploaded['release']['sha256'], sha256.convert(bytes).toString());
        expect(uploaded['release']['state'], 'draft');

        final beforePublish = await client.getUrl(
          uri('/api/v1/updates/client/android/latest'),
        );
        final beforeResponse = await beforePublish.close();
        expect(beforeResponse.statusCode, 204);
        await beforeResponse.drain<void>();

        final published = await sendJson(
          'POST',
          '/api/admin/releases/$id/publish',
          admin: true,
        );
        expect(published['_status'], 200);

        final latestRequest = await client.getUrl(
          uri('/api/v1/updates/client/android/latest'),
        );
        final latestResponse = await latestRequest.close();
        expect(latestResponse.statusCode, 200);
        final latest =
            jsonDecode(await utf8.decoder.bind(latestResponse).join())
                as Map<String, dynamic>;
        expect(latest['version'], '1.2.0');
        expect(latest['downloadUrl'], '/api/v1/artifacts/$id');

        final downloadRequest = await client.getUrl(
          uri('/api/v1/artifacts/$id'),
        );
        final downloadResponse = await downloadRequest.close();
        expect(downloadResponse.statusCode, 200);
        expect(
          await downloadResponse.fold<List<int>>(
            <int>[],
            (all, chunk) => all..addAll(chunk),
          ),
          bytes,
        );

        final withdrawn = await sendJson(
          'POST',
          '/api/admin/releases/$id/withdraw',
          admin: true,
        );
        expect(withdrawn['_status'], 200);
        final afterWithdrawRequest = await client.getUrl(
          uri('/api/v1/updates/client/android/latest'),
        );
        final afterWithdrawResponse = await afterWithdrawRequest.close();
        expect(afterWithdrawResponse.statusCode, 204);
        await afterWithdrawResponse.drain<void>();
      },
    );

    test('rejects a product and target mismatch', () async {
      final login = await sendJson(
        'POST',
        '/api/admin/login',
        body: {'password': 'correct horse battery staple 2026'},
      );
      csrf = login['csrfToken'] as String;
      cookie = 'ras_update_session=$csrf';
      final metadata = base64Url.encode(
        utf8.encode(
          jsonEncode({
            'product': 'client',
            'target': 'ubuntu',
            'version': '1.2.0',
            'build': '12',
            'notes': '',
            'filename': 'remotaisync',
          }),
        ),
      );
      final request = await client.postUrl(uri('/api/admin/releases'));
      request.headers
        ..set(HttpHeaders.cookieHeader, cookie!)
        ..set('x-csrf-token', csrf!)
        ..set('x-release-metadata', metadata)
        ..contentLength = 3;
      request.add([1, 2, 3]);
      final response = await request.close();
      expect(response.statusCode, 400);
      await response.drain<void>();
    });
  });
}

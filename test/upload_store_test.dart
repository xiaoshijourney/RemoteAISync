import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// ignore: avoid_relative_lib_imports
import '../host/lib/src/upload_store.dart';

void main() {
  test('streams any file type into the project inbox', () async {
    final project = await Directory.systemTemp.createTemp(
      'remoteaisync-upload-test-',
    );
    final store = UploadStore(project.path);
    try {
      final id = await store.begin(
        clientId: 'client-a',
        sessionId: 'codex:thread-a',
        name: r'..\..\payload.pdf',
        sizeBytes: 5,
        mimeType: 'application/pdf',
      );
      await expectLater(
        store.append(
          clientId: 'client-a',
          uploadId: id,
          offset: 1,
          data: base64Encode(utf8.encode('hello')),
        ),
        throwsA(isA<UploadException>()),
      );
      expect(
        await store.append(
          clientId: 'client-a',
          uploadId: id,
          offset: 0,
          data: base64Encode(utf8.encode('hello')),
        ),
        5,
      );
      final file = await store.finish(clientId: 'client-a', uploadId: id);
      expect(file.path, startsWith(p.join(project.path, '.remoteaisync')));
      expect(p.basename(file.path), 'payload.pdf');
      expect(await File(file.path).readAsString(), 'hello');
      expect(
        store
            .resolve(
              clientId: 'client-a',
              sessionId: 'codex:thread-a',
              attachmentIds: [id],
            )
            .single
            .path,
        file.path,
      );
      expect(
        () => store.resolve(
          clientId: 'client-b',
          sessionId: 'codex:thread-a',
          attachmentIds: [id],
        ),
        throwsA(isA<UploadException>()),
      );
    } finally {
      await store.close();
      await project.delete(recursive: true);
    }
  });

  test('accepts files above 20 MiB without a fixed file-size cap', () async {
    final project = await Directory.systemTemp.createTemp(
      'remoteaisync-large-upload-test-',
    );
    final store = UploadStore(project.path);
    try {
      final id = await store.begin(
        clientId: 'client-a',
        sessionId: 'codex:thread-a',
        name: 'archive.bin',
        sizeBytes: 21 * 1024 * 1024,
      );
      await store.cancel(clientId: 'client-a', uploadId: id);
    } finally {
      await store.close();
      await project.delete(recursive: true);
    }
  });

  test('marks only valid supported images for native Codex input', () async {
    final project = await Directory.systemTemp.createTemp(
      'remoteaisync-image-upload-test-',
    );
    final store = UploadStore(project.path);
    try {
      final valid = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0];
      final validId = await store.begin(
        clientId: 'client-a',
        sessionId: 'codex:thread-a',
        name: 'image.png',
        sizeBytes: valid.length,
      );
      await store.append(
        clientId: 'client-a',
        uploadId: validId,
        offset: 0,
        data: base64Encode(valid),
      );
      expect(
        (await store.finish(
          clientId: 'client-a',
          uploadId: validId,
        )).isCodexImage,
        isTrue,
      );

      final invalidId = await store.begin(
        clientId: 'client-a',
        sessionId: 'codex:thread-a',
        name: 'renamed.png',
        sizeBytes: 3,
      );
      await store.append(
        clientId: 'client-a',
        uploadId: invalidId,
        offset: 0,
        data: base64Encode([1, 2, 3]),
      );
      expect(
        (await store.finish(
          clientId: 'client-a',
          uploadId: invalidId,
        )).isCodexImage,
        isFalse,
      );
    } finally {
      await store.close();
      await project.delete(recursive: true);
    }
  });
}

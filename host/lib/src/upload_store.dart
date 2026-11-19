import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Stores browser uploads inside the selected Agent workspace. Completed files
/// remain there so an Agent can read them after the WebSocket disconnects.
class UploadStore {
  UploadStore(String projectDirectory)
    : inboxDirectory = Directory(
        p.join(projectDirectory, '.remoteaisync', 'inbox'),
      );

  static const maxChunkBytes = 512 * 1024;

  final Directory inboxDirectory;
  final Map<String, _PendingUpload> _pending = {};
  final Map<String, StagedAttachment> _completed = {};

  Future<String> begin({
    required String clientId,
    required String sessionId,
    required String name,
    required int sizeBytes,
    String? mimeType,
  }) async {
    if (sizeBytes < 0 || name.trim().isEmpty) {
      throw const UploadException('文件名或文件大小无效。');
    }
    if (_pending.values.where((upload) => upload.clientId == clientId).length >=
        4) {
      throw const UploadException('同时最多上传 4 个文件，请稍后重试。');
    }
    final id = _newUploadId();
    final directory = Directory(p.join(inboxDirectory.path, id));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, _safeFileName(name)));
    final handle = await file.open(mode: FileMode.write);
    _pending[id] = _PendingUpload(
      clientId: clientId,
      sessionId: sessionId,
      name: name,
      sizeBytes: sizeBytes,
      mimeType: mimeType,
      file: file,
      handle: handle,
    );
    return id;
  }

  Future<int> append({
    required String clientId,
    required String uploadId,
    required int offset,
    required String data,
  }) async {
    final upload = _ownedPending(clientId, uploadId);
    if (offset != upload.receivedBytes) {
      throw const UploadException('文件块顺序错误，请重新上传。');
    }
    late final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw const UploadException('文件块编码无效。');
    }
    if (bytes.isEmpty || bytes.length > maxChunkBytes) {
      throw const UploadException('文件块大小无效。');
    }
    if (upload.receivedBytes + bytes.length > upload.sizeBytes) {
      throw const UploadException('上传内容超过声明的文件大小。');
    }
    await upload.handle.writeFrom(bytes);
    upload.receivedBytes += bytes.length;
    return upload.receivedBytes;
  }

  Future<StagedAttachment> finish({
    required String clientId,
    required String uploadId,
  }) async {
    final upload = _ownedPending(clientId, uploadId);
    if (upload.receivedBytes != upload.sizeBytes) {
      throw UploadException(
        '文件尚未上传完整：${upload.receivedBytes}/${upload.sizeBytes} 字节。',
      );
    }
    await upload.handle.flush();
    await upload.handle.close();
    _pending.remove(uploadId);
    final header = await upload.file
        .openRead(0, 12)
        .expand((chunk) => chunk)
        .toList();
    final attachment = StagedAttachment(
      id: uploadId,
      clientId: clientId,
      sessionId: upload.sessionId,
      name: upload.name,
      sizeBytes: upload.sizeBytes,
      mimeType: upload.mimeType,
      path: upload.file.path,
      isCodexImage: _isSupportedImage(upload.file.path, header),
    );
    _completed[uploadId] = attachment;
    return attachment;
  }

  List<StagedAttachment> resolve({
    required String clientId,
    required String sessionId,
    required List<String> attachmentIds,
  }) {
    if (attachmentIds.length > 20 ||
        attachmentIds.toSet().length != attachmentIds.length) {
      throw const UploadException('附件数量或附件 ID 无效。');
    }
    return attachmentIds
        .map((id) {
          final attachment = _completed[id];
          if (attachment == null ||
              attachment.clientId != clientId ||
              attachment.sessionId != sessionId) {
            throw const UploadException('附件尚未上传完成，或不属于当前会话。');
          }
          return attachment;
        })
        .toList(growable: false);
  }

  Future<void> cancel({required String clientId, required String uploadId}) =>
      _discard(uploadId, _ownedPending(clientId, uploadId));

  Future<void> discardPendingForClient(String clientId) async {
    for (final entry in _pending.entries.toList()) {
      if (entry.value.clientId == clientId) {
        await _discard(entry.key, entry.value);
      }
    }
  }

  Future<void> close() async {
    for (final entry in _pending.entries.toList()) {
      await _discard(entry.key, entry.value);
    }
  }

  _PendingUpload _ownedPending(String clientId, String uploadId) {
    final upload = _pending[uploadId];
    if (upload == null || upload.clientId != clientId) {
      throw const UploadException('上传任务不存在或已过期。');
    }
    return upload;
  }

  Future<void> _discard(String id, _PendingUpload upload) async {
    _pending.remove(id);
    await upload.handle.close();
    if (await upload.file.exists()) await upload.file.delete();
    final directory = upload.file.parent;
    if (await directory.exists()) await directory.delete();
  }
}

class StagedAttachment {
  const StagedAttachment({
    required this.id,
    required this.clientId,
    required this.sessionId,
    required this.name,
    required this.sizeBytes,
    required this.mimeType,
    required this.path,
    required this.isCodexImage,
  });

  final String id;
  final String clientId;
  final String sessionId;
  final String name;
  final int sizeBytes;
  final String? mimeType;
  final String path;
  final bool isCodexImage;
}

class UploadException implements Exception {
  const UploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _PendingUpload {
  _PendingUpload({
    required this.clientId,
    required this.sessionId,
    required this.name,
    required this.sizeBytes,
    required this.mimeType,
    required this.file,
    required this.handle,
  });

  final String clientId;
  final String sessionId;
  final String name;
  final int sizeBytes;
  final String? mimeType;
  final File file;
  final RandomAccessFile handle;
  int receivedBytes = 0;
}

String _newUploadId() => base64UrlEncode(
  List<int>.generate(18, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

String _safeFileName(String value) {
  final name = p
      .basename(value.replaceAll('\\', '/'))
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') return 'attachment';
  final safe = name.length > 150 ? name.substring(name.length - 150) : name;
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
    caseSensitive: false,
  ).hasMatch(safe)) {
    return '_$safe';
  }
  return safe;
}

bool _isSupportedImage(String path, List<int> header) {
  final extension = p.extension(path).toLowerCase();
  if (extension == '.png') {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (header.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (header[index] != signature[index]) return false;
    }
    return true;
  }
  if (extension == '.jpg' || extension == '.jpeg') {
    return header.length >= 3 &&
        header[0] == 0xff &&
        header[1] == 0xd8 &&
        header[2] == 0xff;
  }
  if (extension == '.webp') {
    return header.length >= 12 &&
        header[0] == 82 &&
        header[1] == 73 &&
        header[2] == 70 &&
        header[3] == 70 &&
        header[8] == 87 &&
        header[9] == 69 &&
        header[10] == 66 &&
        header[11] == 80;
  }
  return false;
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _downloadsChannel = MethodChannel('com.remotaisync/downloads');

Future<String?> saveBytesToLocalFile({
  required String name,
  required Uint8List bytes,
}) async {
  final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (Platform.isAndroid) {
    try {
      return await _downloadsChannel.invokeMethod<String>('saveToDownloads', {
        'name': safeName,
        'mimeType': _mimeTypeFor(safeName),
        'bytes': bytes,
      });
    } catch (_) {
      // Fall back to app Documents if the platform Downloads provider fails.
    }
  }
  final directory = await getApplicationDocumentsDirectory();
  await directory.create(recursive: true);

  var file = File('${directory.path}${Platform.pathSeparator}$safeName');
  if (await file.exists()) {
    final dot = safeName.lastIndexOf('.');
    final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
    final extension = dot > 0 ? safeName.substring(dot) : '';
    file = File(
      '${directory.path}${Platform.pathSeparator}$stem-${DateTime.now().millisecondsSinceEpoch}$extension',
    );
  }
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

String _mimeTypeFor(String name) =>
    switch (name.toLowerCase().split('.').last) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'txt' || 'log' || 'md' => 'text/plain',
      'json' => 'application/json',
      'csv' => 'text/csv',
      'html' || 'htm' => 'text/html',
      'css' => 'text/css',
      'js' || 'mjs' => 'text/javascript',
      'xml' => 'application/xml',
      _ => 'application/octet-stream',
    };

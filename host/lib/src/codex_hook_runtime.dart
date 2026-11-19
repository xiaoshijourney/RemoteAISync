import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The hook token is separate from the phone pairing token and stays outside
/// the Agent workspace. Only the local hook may submit a pending request.
String codexHookRuntimePath(int port) {
  final home = Platform.isWindows
      ? Platform.environment['LOCALAPPDATA']
      : Platform.environment['XDG_RUNTIME_DIR'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('Cannot find a per-user runtime directory.');
  }
  return p.join(home, 'RemoteAISync', 'codex-hook-$port.json');
}

Future<void> writeCodexHookRuntime({
  required int port,
  required String projectDirectory,
  required String token,
}) async {
  final file = File(codexHookRuntimePath(port));
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'port': port,
      'projectDirectory': p.normalize(p.absolute(projectDirectory)),
      'token': token,
    }),
    flush: true,
  );
  if (!Platform.isWindows) {
    await Process.run('chmod', ['600', file.path]);
  }
}

Future<void> deleteCodexHookRuntimeIfOwned({
  required int port,
  required String token,
}) async {
  final file = File(codexHookRuntimePath(port));
  if (!await file.exists()) return;
  try {
    final data = jsonDecode(await file.readAsString());
    if (data is Map && data['token'] == token) await file.delete();
  } on FormatException {
    // Leave a file that another process may have replaced.
  }
}

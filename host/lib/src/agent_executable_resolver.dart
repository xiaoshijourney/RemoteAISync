import 'dart:io';

import 'package:path/path.dart' as p;

class AgentExecutableNotFoundException implements Exception {
  const AgentExecutableNotFoundException(this.executable);

  final String executable;

  @override
  String toString() => '未找到可执行文件：$executable';
}

Future<String?> resolveAgentExecutable(
  String executable, {
  Iterable<String>? searchDirectories,
}) async {
  final requested = File(executable);
  if (_isPathLike(executable)) {
    return await requested.exists()
        ? p.normalize(p.absolute(executable))
        : null;
  }

  final directories = searchDirectories ?? _environmentPathDirectories();
  for (final directory in directories) {
    for (final candidateName in _candidateNames(executable)) {
      final candidate = File(p.join(directory, candidateName));
      if (await candidate.exists()) {
        return p.normalize(p.absolute(candidate.path));
      }
    }
  }

  for (final candidate in await _knownInstallLocations(executable)) {
    if (await File(candidate).exists()) {
      return p.normalize(p.absolute(candidate));
    }
  }
  return null;
}

bool _isPathLike(String value) =>
    p.isAbsolute(value) || value.contains('/') || value.contains(r'\');

Iterable<String> _environmentPathDirectories() sync* {
  final path = Platform.environment['PATH'] ?? '';
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    final trimmed = directory.trim();
    if (trimmed.isNotEmpty) yield trimmed;
  }
}

Iterable<String> _candidateNames(String executable) sync* {
  yield executable;
  final lower = executable.toLowerCase();
  if (!lower.endsWith('.exe')) yield '$executable.exe';
  if (Platform.isWindows) {
    if (!lower.endsWith('.cmd')) yield '$executable.cmd';
    if (!lower.endsWith('.bat')) yield '$executable.bat';
  }
}

Future<List<String>> _knownInstallLocations(String executable) async {
  final candidates = <String>[];
  final normalized = p.basenameWithoutExtension(executable).toLowerCase();
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final userBin = p.join(home, '.local', 'bin');
    candidates.add(p.join(userBin, executable));
    if (!executable.toLowerCase().endsWith('.exe')) {
      candidates.add(p.join(userBin, '$executable.exe'));
    }
  }

  if (normalized != 'codex') return candidates;
  final localAppData =
      Platform.environment['LOCALAPPDATA'] ??
      (home == null ? null : p.join(home, 'AppData', 'Local'));
  if (localAppData == null || localAppData.isEmpty) return candidates;

  final versionedBin = Directory(
    p.join(localAppData, 'OpenAI', 'Codex', 'bin'),
  );
  try {
    if (!await versionedBin.exists()) return candidates;
    final children = await versionedBin
        .list(followLinks: false)
        .where((entity) => entity is Directory)
        .toList();
    children.sort((a, b) => b.path.compareTo(a.path));
    for (final child in children) {
      candidates.add(p.join(child.path, 'codex.exe'));
    }
  } on FileSystemException {
    return candidates;
  }
  return candidates;
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:remote_ai_sync/src/domain/models.dart';

/// Holds desktop Codex hook requests until a paired client decides.
/// A timeout or bridge shutdown returns no decision to the native Codex UI.
class CodexHookBroker {
  CodexHookBroker({this.waitTimeout = const Duration(minutes: 5)});

  final Duration waitTimeout;
  final _events = StreamController<void>.broadcast();
  final Map<String, _PendingHookApproval> _pending = {};
  bool _closed = false;

  Stream<void> get events => _events.stream;

  Future<bool?> request({
    required String sessionId,
    required String toolName,
    required Object? toolInput,
  }) async {
    if (_closed || _pending.length >= 20) return null;
    final id = 'codex-hook:${_randomId()}';
    final permission = AgentPermission(
      id: id,
      sessionId: sessionId,
      action: 'Codex 桌面审批',
      resources: [
        '工具：$toolName',
        '参数：${_preview(jsonEncode(toolInput ?? {}))}',
      ],
      message: 'Codex 桌面版正在等待决定。超时后将回到电脑端审批。',
      toolId: toolName,
    );
    final pending = _PendingHookApproval(permission);
    _pending[id] = pending;
    _events.add(null);
    try {
      return await pending.decision.future.timeout(
        waitTimeout,
        onTimeout: () => null,
      );
    } finally {
      _pending.remove(id);
      if (!_closed) _events.add(null);
    }
  }

  List<AgentPermission> listPermissions(String sessionId) => _pending.values
      .where((pending) => pending.permission.sessionId == sessionId)
      .map((pending) => pending.permission)
      .toList(growable: false);

  int pendingCountFor(String sessionId) => _pending.values
      .where((pending) => pending.permission.sessionId == sessionId)
      .length;

  bool hasRequest(String sessionId, String requestId) =>
      _pending[requestId]?.permission.sessionId == sessionId;

  bool resolve(String sessionId, String requestId, {required bool allow}) {
    final pending = _pending[requestId];
    if (pending == null ||
        pending.permission.sessionId != sessionId ||
        pending.decision.isCompleted) {
      return false;
    }
    pending.decision.complete(allow);
    return true;
  }

  void fallBackPending() {
    for (final pending in _pending.values) {
      if (!pending.decision.isCompleted) pending.decision.complete(null);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    fallBackPending();
    _pending.clear();
    await _events.close();
  }
}

class _PendingHookApproval {
  _PendingHookApproval(this.permission);

  final AgentPermission permission;
  final Completer<bool?> decision = Completer<bool?>();
}

String _preview(String text) =>
    text.length <= 10000 ? text : '${text.substring(0, 10000)}\n…参数过长，已截断。';

String _randomId() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

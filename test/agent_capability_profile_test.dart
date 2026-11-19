import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  group('AgentCapabilityProfile', () {
    HostSession session(String agentId, {bool remoteManaged = false}) =>
        HostSession(
          id: 'session',
          title: 'Session',
          updatedAt: '',
          agentId: agentId,
          remoteManaged: remoteManaged,
        );

    test('OpenCode exposes local server operations', () {
      final profile = AgentCapabilityProfile.forSession(session('opencode'));

      expect(profile.canCreate, isTrue);
      expect(profile.canReply, isTrue);
      expect(profile.canInterrupt, isTrue);
      expect(profile.canChangeSettings, isTrue);
      expect(profile.canApprove, isTrue);
      expect(profile.canAnswerForms, isTrue);
    });

    test('Codex desktop history is queue-only', () {
      final profile = AgentCapabilityProfile.forSession(session('codex'));

      expect(profile.canCreate, isFalse);
      expect(profile.canReply, isTrue);
      expect(profile.canInterrupt, isFalse);
      expect(profile.canChangeSettings, isFalse);
      expect(profile.canApprove, isFalse);
      expect(profile.delivery, '桌面会话队列');
    });

    test('RemoteAISync owned Codex session exposes controls', () {
      final profile = AgentCapabilityProfile.forSession(
        session('codex', remoteManaged: true),
      );

      expect(profile.canCreate, isTrue);
      expect(profile.canInterrupt, isTrue);
      expect(profile.canChangeSettings, isTrue);
      expect(profile.canApprove, isTrue);
    });

    test(
      'Claude history remains read-only while managed sessions can stop',
      () {
        final history = AgentCapabilityProfile.forSession(session('claude'));
        final managed = AgentCapabilityProfile.forSession(
          session('claude', remoteManaged: true),
        );

        expect(history.canReply, isFalse);
        expect(history.canInterrupt, isFalse);
        expect(history.canChangeSettings, isFalse);
        expect(history.note, isNotNull);
        expect(managed.canReply, isTrue);
        expect(managed.canInterrupt, isTrue);
        expect(managed.canChangeSettings, isTrue);
        expect(managed.canApprove, isFalse);
      },
    );
  });
}

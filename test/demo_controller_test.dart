import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/application/demo_controller.dart';
import 'package:remote_ai_sync/src/domain/models.dart';

void main() {
  group('DemoController', () {
    test('records a reply and a local-only response', () {
      final controller = DemoController();

      controller.sendReply('  Please use the default port.  ');

      expect(controller.messages[3].text, 'Please use the default port.');
      expect(controller.messages[3].author, MessageAuthor.user);
      expect(controller.messages[4].text, contains('本地演示'));
    });

    test('records attachment-only messages without claiming transfer', () {
      final controller = DemoController();
      const attachment = AgentAttachment(
        id: 'file-1',
        name: 'design.pdf',
        sizeBytes: 4096,
        mimeType: 'application/pdf',
      );

      controller.sendReply('', attachments: const [attachment]);

      expect(controller.messages[3].text, isEmpty);
      expect(controller.messages[3].attachments.single.name, 'design.pdf');
      expect(controller.messages[4].text, contains('尚未传至电脑 Agent'));
    });

    test('resolves a pending approval once', () {
      final controller = DemoController();

      controller.resolveApproval(allow: false);
      controller.resolveApproval(allow: true);

      expect(controller.approval.status, ApprovalStatus.rejected);
      expect(controller.messages.last.text, '已拒绝该操作（本地演示）');
    });

    test('stores the selected question option in the session timeline', () {
      final controller = DemoController();

      controller.choosePort('3000');

      expect(controller.selectedPort, '3000');
      expect(controller.messages.last.text, '预览端口使用 3000');
    });
  });
}

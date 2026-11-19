import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/src/domain/models.dart';
import 'package:remote_ai_sync/src/domain/text_question_parser.dart';

void main() {
  AgentMessage message(
    String text, {
    MessageAuthor author = MessageAuthor.assistant,
  }) => AgentMessage(id: 'm1', author: author, text: text, time: '12:00');

  test('parses the desktop text shown for an A/B/C question', () {
    final result = parseTextChoiceQuestion(
      message('网页版里，这道选择题显示成什么样？\n- A. 可点击的选择题卡片\n- B. 只看到普通文字\n- C. 完全看不到这道题'),
    );
    expect(result?.prompt, '网页版里，这道选择题显示成什么样？');
    expect(result?.options.map((option) => option.reply), [
      'A. 可点击的选择题卡片',
      'B. 只看到普通文字',
      'C. 完全看不到这道题',
    ]);
  });

  test('ignores code, narrative lists, and non-assistant messages', () {
    const text = '请选择选项？\n```text\nA. first\nB. second\n```';
    expect(parseTextChoiceQuestion(message(text)), isNull);
    expect(parseTextChoiceQuestion(message('操作步骤\n1. 安装\n2. 运行')), isNull);
    expect(
      parseTextChoiceQuestion(
        message('选哪个？\nA. 甲\nB. 乙', author: MessageAuthor.user),
      ),
      isNull,
    );
  });
}

import 'models.dart';

class TextChoiceQuestion {
  const TextChoiceQuestion({
    required this.messageId,
    required this.prompt,
    required this.options,
  });

  final String messageId;
  final String prompt;
  final List<TextChoiceOption> options;
}

class TextChoiceOption {
  const TextChoiceOption({required this.key, required this.label});

  final String key;
  final String label;

  String get reply => '$key. $label';
}

final _choiceLine = RegExp(r'^\s*(?:[-*]\s*)?([A-Da-d1-4])[.、．)]\s+(.+?)\s*$');
final _codeFence = RegExp(r'^\s*```');

/// Recognizes a short, explicit choice list in the latest assistant message.
/// It is a text fallback, not a Codex request_user_input protocol response.
TextChoiceQuestion? parseTextChoiceQuestion(AgentMessage message) {
  if (message.author != MessageAuthor.assistant) return null;
  if (message.text.length > 6000) return null;

  final lines = message.text.split(RegExp(r'\r?\n'));
  var inCode = false;
  final options = <TextChoiceOption>[];
  final prompt = <String>[];
  var started = false;
  for (final line in lines) {
    if (_codeFence.hasMatch(line)) {
      inCode = !inCode;
      if (started) break;
      continue;
    }
    if (inCode) continue;
    final match = _choiceLine.firstMatch(line);
    if (match != null) {
      started = true;
      options.add(
        TextChoiceOption(
          key: match.group(1)!.toUpperCase(),
          label: match.group(2)!.trim(),
        ),
      );
      if (options.length > 4) return null;
      continue;
    }
    if (started) {
      if (line.trim().isNotEmpty) break;
    } else if (line.trim().isNotEmpty) {
      prompt.add(line.trim());
    }
  }
  if (options.length < 2 || prompt.isEmpty) return null;
  final keys = options.map((option) => option.key).toList();
  if (keys.toSet().length != keys.length) return null;
  for (var index = 1; index < keys.length; index++) {
    if (keys[index].codeUnitAt(0) != keys[index - 1].codeUnitAt(0) + 1) {
      return null;
    }
  }
  final question = prompt.last;
  if (!RegExp(r'[?？]|请选择|选择|哪种|哪个|哪项|请确认').hasMatch(question)) {
    return null;
  }
  return TextChoiceQuestion(
    messageId: message.id,
    prompt: question,
    options: options,
  );
}

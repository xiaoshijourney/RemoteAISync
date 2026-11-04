enum MessageAuthor { assistant, user, tool, system }

class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.time,
    this.attachments = const [],
  });

  final String id;
  final MessageAuthor author;
  final String text;
  final String time;
  final List<AgentAttachment> attachments;
}

class AgentAttachment {
  const AgentAttachment({
    required this.id,
    required this.name,
    required this.sizeBytes,
    this.mimeType,
  });

  final String id;
  final String name;
  final int sizeBytes;
  final String? mimeType;
}

enum ApprovalStatus { pending, approved, rejected }

class ToolApproval {
  const ToolApproval({
    required this.id,
    required this.toolName,
    required this.summary,
    required this.command,
    required this.target,
    required this.status,
  });

  final String id;
  final String toolName;
  final String summary;
  final String command;
  final String target;
  final ApprovalStatus status;

  ToolApproval copyWith({ApprovalStatus? status}) {
    return ToolApproval(
      id: id,
      toolName: toolName,
      summary: summary,
      command: command,
      target: target,
      status: status ?? this.status,
    );
  }
}

class DemoFile {
  const DemoFile({
    required this.name,
    required this.path,
    required this.size,
    required this.kind,
    required this.content,
    this.launchable = false,
  });

  final String name;
  final String path;
  final String size;
  final String kind;
  final String content;
  final bool launchable;
}

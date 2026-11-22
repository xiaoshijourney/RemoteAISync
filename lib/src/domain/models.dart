import 'dart:convert';
import 'dart:typed_data';

enum MessageAuthor { assistant, user, tool, system }

enum HostConnectionStatus { disconnected, connecting, connected, error }

/// Describes the transport lifecycle independently from pairing and session state.
enum TransportState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

enum PairingState {
  none,
  invitationImported,
  waitingApproval,
  paired,
  revoked,
  expired,
}

enum SessionRunState {
  idle,
  loading,
  running,
  waitingInput,
  waitingApproval,
  queued,
  stopped,
  failed,
  stale,
}

enum AttachmentTransferState {
  selecting,
  uploading,
  uploaded,
  sending,
  delivered,
  failed,
  cancelled,
}

enum ServiceState { stopped, starting, running, stopping, failed }

/// The operations the UI is allowed to expose for a particular Agent session.
class AgentCapabilityProfile {
  const AgentCapabilityProfile({
    required this.agentId,
    required this.canCreate,
    required this.canReply,
    required this.canInterrupt,
    required this.canChangeSettings,
    required this.canApprove,
    required this.canAnswerForms,
    required this.delivery,
    this.note,
  });

  final String agentId;
  final bool canCreate;
  final bool canReply;
  final bool canInterrupt;
  final bool canChangeSettings;
  final bool canApprove;
  final bool canAnswerForms;
  final String delivery;
  final String? note;

  factory AgentCapabilityProfile.forSession(HostSession session) {
    if (session.agentId == 'opencode') {
      return const AgentCapabilityProfile(
        agentId: 'opencode',
        canCreate: true,
        canReply: true,
        canInterrupt: true,
        // OpenCode applies the selected model and variant to each next prompt.
        canChangeSettings: true,
        canApprove: true,
        canAnswerForms: true,
        delivery: 'Server API',
      );
    }
    if (session.agentId == 'claude') {
      return AgentCapabilityProfile(
        agentId: 'claude',
        canCreate: true,
        canReply: session.remoteManaged,
        canInterrupt: session.remoteManaged,
        canChangeSettings: session.remoteManaged,
        canApprove: false,
        canAnswerForms: false,
        delivery: session.remoteManaged ? 'RemoteAISync CLI' : '本地记录',
        note: session.remoteManaged ? null : '此会话只支持查看已落地记录。',
      );
    }
    if (session.agentId == 'codex' && session.remoteManaged) {
      return const AgentCapabilityProfile(
        agentId: 'codex',
        canCreate: true,
        canReply: true,
        canInterrupt: true,
        canChangeSettings: true,
        canApprove: true,
        canAnswerForms: true,
        delivery: 'Codex app-server',
      );
    }
    return const AgentCapabilityProfile(
      agentId: 'codex',
      canCreate: false,
      canReply: true,
      canInterrupt: true,
      canChangeSettings: false,
      canApprove: false,
      canAnswerForms: false,
      delivery: '桌面会话队列',
      note: '发送新消息会先尝试停止当前回复；桌面会话仍占用时再排队。',
    );
  }
}

enum AgentAvailability {
  available,
  degraded,

  /// The executable or local runtime for this adapter is not installed.
  notInstalled,
  unavailable,
  unsupported,
  unknown,
}

class AgentRuntimeStatus {
  const AgentRuntimeStatus({
    required this.id,
    required this.availability,
    this.name,
    this.version,
    this.detail,
  });

  final String id;
  final AgentAvailability availability;
  final String? name;
  final String? version;
  final String? detail;

  bool get isAvailable => availability == AgentAvailability.available;

  factory AgentRuntimeStatus.fromJson(Map json) {
    final rawAvailability = json['availability']?.toString();
    return AgentRuntimeStatus(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString(),
      availability: AgentAvailability.values.firstWhere(
        (value) => value.name == rawAvailability,
        orElse: () => AgentAvailability.unknown,
      ),
      version: json['version']?.toString(),
      detail: json['detail']?.toString(),
    );
  }
}

class HostSession {
  const HostSession({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.agentId = 'opencode',
    this.remoteManaged = false,
    this.pendingCount = 0,
    this.directory,
  });

  final String id;
  final String title;
  final String updatedAt;
  final String agentId;
  final bool remoteManaged;
  final int pendingCount;
  final String? directory;
}

class HostFileEntry {
  const HostFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.sizeBytes,
    this.modifiedAt,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? sizeBytes;
  final DateTime? modifiedAt;

  factory HostFileEntry.fromJson(Map json) => HostFileEntry(
    name: json['name']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    isDirectory: json['isDirectory'] == true,
    sizeBytes: _asInt(json['sizeBytes']),
    modifiedAt: DateTime.tryParse(json['modifiedAt']?.toString() ?? ''),
  );
}

class WorkspaceFileContent {
  const WorkspaceFileContent({
    this.text,
    this.bytes,
    this.mimeType,
    this.previewKind = 'unsupported',
  });

  final String? text;
  final Uint8List? bytes;
  final String? mimeType;
  final String previewKind;

  factory WorkspaceFileContent.fromJson(Map json) => WorkspaceFileContent(
    text: json['text']?.toString(),
    bytes: json['bytes'] is String
        ? Uint8List.fromList(base64Decode(json['bytes'] as String))
        : null,
    mimeType: json['mimeType']?.toString(),
    previewKind: json['previewKind']?.toString() ?? 'unsupported',
  );
}

class WorkspaceFileDownload {
  const WorkspaceFileDownload({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class CodexModelOption {
  const CodexModelOption({
    required this.id,
    required this.name,
    required this.efforts,
    this.defaultEffort,
  });

  final String id;
  final String name;
  final List<String> efforts;
  final String? defaultEffort;

  factory CodexModelOption.fromJson(Map json) => CodexModelOption(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    efforts: (json['efforts'] as List? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false),
    defaultEffort: json['defaultEffort']?.toString(),
  );
}

class CodexControls {
  const CodexControls({
    required this.models,
    required this.skills,
    this.model,
    this.effort,
    this.running = false,
  });

  final List<CodexModelOption> models;
  final List<String> skills;
  final String? model;
  final String? effort;
  final bool running;

  factory CodexControls.fromJson(Map json) {
    final settings = json['settings'] is Map
        ? json['settings'] as Map
        : const {};
    return CodexControls(
      models: (json['models'] as List? ?? const [])
          .whereType<Map>()
          .map(CodexModelOption.fromJson)
          .where((model) => model.id.isNotEmpty)
          .toList(growable: false),
      skills: (json['skills'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      model: settings['model']?.toString(),
      effort: settings['effort']?.toString(),
      running: settings['running'] == true,
    );
  }
}

class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.time,
    this.attachments = const [],
    this.groupId,
  });

  final String id;
  final MessageAuthor author;
  final String text;
  final String time;
  final List<AgentAttachment> attachments;
  final String? groupId;
}

class AgentQueuedMessage {
  const AgentQueuedMessage({
    required this.id,
    required this.text,
    this.imageCount = 0,
  });

  final String id;
  final String text;
  final int imageCount;

  factory AgentQueuedMessage.fromJson(Map json) => AgentQueuedMessage(
    id: json['id']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    imageCount: json['imageCount'] is num
        ? (json['imageCount'] as num).toInt()
        : 0,
  );
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

enum AgentFormFieldType {
  string,
  number,
  integer,
  boolean,
  multiselect,
  external,
  unsupported,
}

class AgentFormOption {
  const AgentFormOption({
    required this.value,
    required this.label,
    this.description,
  });

  final String value;
  final String label;
  final String? description;

  factory AgentFormOption.fromJson(Map json) => AgentFormOption(
    value: json['value']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    description: json['description']?.toString(),
  );
}

class AgentFormCondition {
  const AgentFormCondition({
    required this.key,
    required this.operator,
    required this.value,
  });

  final String key;
  final String operator;
  final String value;

  factory AgentFormCondition.fromJson(Map json) => AgentFormCondition(
    key: json['key']?.toString() ?? '',
    operator: json['op']?.toString() ?? 'eq',
    value: json['value']?.toString() ?? '',
  );
}

class AgentFormField {
  const AgentFormField({
    required this.key,
    required this.type,
    this.title,
    this.description,
    this.required = false,
    this.format,
    this.pattern,
    this.placeholder,
    this.url,
    this.minimum,
    this.maximum,
    this.minLength,
    this.maxLength,
    this.minItems,
    this.maxItems,
    this.defaultValue,
    this.options = const [],
    this.conditions = const [],
    this.custom = false,
  });

  final String key;
  final AgentFormFieldType type;
  final String? title;
  final String? description;
  final bool required;
  final String? format;
  final String? pattern;
  final String? placeholder;
  final String? url;
  final num? minimum;
  final num? maximum;
  final int? minLength;
  final int? maxLength;
  final int? minItems;
  final int? maxItems;
  final Object? defaultValue;
  final List<AgentFormOption> options;
  final List<AgentFormCondition> conditions;
  final bool custom;

  factory AgentFormField.fromJson(Map json) {
    final type = switch (json['type']?.toString()) {
      'string' => AgentFormFieldType.string,
      'number' => AgentFormFieldType.number,
      'integer' => AgentFormFieldType.integer,
      'boolean' => AgentFormFieldType.boolean,
      'multiselect' => AgentFormFieldType.multiselect,
      'external' => AgentFormFieldType.external,
      _ => AgentFormFieldType.unsupported,
    };
    return AgentFormField(
      key: json['key']?.toString() ?? '',
      type: type,
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      required: json['required'] == true,
      format: json['format']?.toString(),
      pattern: json['pattern']?.toString(),
      placeholder: json['placeholder']?.toString(),
      url: json['url']?.toString(),
      minimum: json['minimum'] is num ? json['minimum'] as num : null,
      maximum: json['maximum'] is num ? json['maximum'] as num : null,
      minLength: _asInt(json['minLength']),
      maxLength: _asInt(json['maxLength']),
      minItems: _asInt(json['minItems']),
      maxItems: _asInt(json['maxItems']),
      defaultValue: json['default'],
      options: (json['options'] as List? ?? const [])
          .whereType<Map>()
          .map(AgentFormOption.fromJson)
          .toList(growable: false),
      conditions: (json['when'] as List? ?? const [])
          .whereType<Map>()
          .map(AgentFormCondition.fromJson)
          .toList(growable: false),
      custom: json['custom'] == true,
    );
  }
}

class AgentForm {
  const AgentForm({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.fields,
  });

  final String id;
  final String sessionId;
  final String title;
  final List<AgentFormField> fields;

  factory AgentForm.fromJson(Map json) => AgentForm(
    id: json['id']?.toString() ?? '',
    sessionId: json['sessionID']?.toString() ?? '',
    title: json['title']?.toString() ?? '需要你的回复',
    fields: (json['fields'] as List? ?? const [])
        .whereType<Map>()
        .map(AgentFormField.fromJson)
        .toList(growable: false),
  );
}

class AgentPermission {
  const AgentPermission({
    required this.id,
    required this.sessionId,
    required this.action,
    required this.resources,
    this.message,
    this.toolId,
  });

  final String id;
  final String sessionId;
  final String action;
  final List<String> resources;
  final String? message;
  final String? toolId;

  factory AgentPermission.fromJson(Map json) {
    final source = json['source'] is Map ? json['source'] as Map : const {};
    return AgentPermission(
      id: json['id']?.toString() ?? '',
      sessionId: json['sessionID']?.toString() ?? '',
      action: json['action']?.toString() ?? 'tool',
      resources: (json['resources'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      message: json['message']?.toString(),
      toolId: source['id']?.toString(),
    );
  }
}

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

int? _asInt(Object? value) => value is num ? value.toInt() : null;

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

enum MessageRole { user, agent }

enum MessageStatus { pending, streaming, done, error, cancelled, interrupted }

enum PartKind { text, thinking, tool, error, notice, artifact }

enum ToolStatus { running, done, failed }

/// One renderable block inside an agent reply.
class MessagePart {
  MessagePart({
    required this.kind,
    this.text = '',
    this.toolId,
    this.toolName,
    this.toolInput,
    this.toolOutput,
    this.toolStatus = ToolStatus.running,
  });

  final PartKind kind;
  String text;

  // Tool-call fields (kind == tool). Artifacts (kind == artifact) use
  // [toolName] for the artifact name, [toolInput] for its path on the
  // server and [text] for its content when the agent sent it inline.
  String? toolId;
  String? toolName;
  String? toolInput;
  String? toolOutput;
  ToolStatus toolStatus;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'text': text,
        if (toolId != null) 'toolId': toolId,
        if (toolName != null) 'toolName': toolName,
        if (toolInput != null) 'toolInput': toolInput,
        if (toolOutput != null) 'toolOutput': toolOutput,
        'toolStatus': toolStatus.name,
      };

  factory MessagePart.fromJson(Map<String, dynamic> json) => MessagePart(
        kind: PartKind.values.firstWhere((k) => k.name == json['kind'],
            orElse: () => PartKind.text),
        text: json['text'] as String? ?? '',
        toolId: json['toolId'] as String?,
        toolName: json['toolName'] as String?,
        toolInput: json['toolInput'] as String?,
        toolOutput: json['toolOutput'] as String?,
        toolStatus: ToolStatus.values.firstWhere(
            (s) => s.name == json['toolStatus'],
            orElse: () => ToolStatus.done),
      );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.createdAt,
    List<MessagePart>? parts,
    this.status = MessageStatus.done,
    this.runId,
    this.runOffset = 0,
    this.usage,
    List<String>? rawLines,
  })  : parts = parts ?? [],
        rawLines = rawLines ?? [];

  final String id;
  final MessageRole role;
  final DateTime createdAt;
  final List<MessagePart> parts;
  MessageStatus status;

  /// Identifier of the remote run backing this reply, used to resume
  /// streaming after a dropped connection.
  String? runId;

  /// Bytes of the run's output already consumed.
  int runOffset;

  /// Token usage summary reported by agy, if any.
  String? usage;

  /// Raw output lines, kept for the "view raw output" debug sheet.
  final List<String> rawLines;

  static const maxRawLines = 400;

  void addRaw(String line) {
    rawLines.add(line);
    if (rawLines.length > maxRawLines) rawLines.removeAt(0);
  }

  String get plainText => parts
      .where((p) => p.kind == PartKind.text)
      .map((p) => p.text)
      .join('\n\n')
      .trim();

  bool get isActive =>
      status == MessageStatus.pending || status == MessageStatus.streaming;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'createdAt': createdAt.toIso8601String(),
        'parts': parts.map((p) => p.toJson()).toList(),
        'status': status.name,
        if (runId != null) 'runId': runId,
        'runOffset': runOffset,
        if (usage != null) 'usage': usage,
        'rawLines': rawLines.length > 100
            ? rawLines.sublist(rawLines.length - 100)
            : rawLines,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        role: MessageRole.values.firstWhere((r) => r.name == json['role'],
            orElse: () => MessageRole.agent),
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
                DateTime.now(),
        parts: (json['parts'] as List? ?? [])
            .map((p) => MessagePart.fromJson(Map<String, dynamic>.from(p)))
            .toList(),
        status: MessageStatus.values.firstWhere(
            (s) => s.name == json['status'],
            orElse: () => MessageStatus.done),
        runId: json['runId'] as String?,
        runOffset: json['runOffset'] as int? ?? 0,
        usage: json['usage'] as String?,
        rawLines: (json['rawLines'] as List?)?.cast<String>().toList(),
      );
}

/// A chat thread on one server, optionally inside a project folder
/// ([project] is null for chats that belong to no project; those run in a
/// private scratch folder). [agyConversationId] is the
/// id agy reports so follow-up prompts continue the same conversation.
class Conversation {
  Conversation({
    required this.id,
    required this.serverId,
    this.project,
    required this.title,
    required this.createdAt,
    DateTime? updatedAt,
    this.agyConversationId,
    List<ChatMessage>? messages,
  })  : updatedAt = updatedAt ?? createdAt,
        messages = messages ?? [];

  final String id;
  final String serverId;
  /// Absolute project folder, or null for "no project". Fixed once the
  /// first message is sent, since agy ties a conversation to its folder.
  String? project;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  String? agyConversationId;
  final List<ChatMessage> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        if (project != null) 'workspace': project,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (agyConversationId != null) 'agyConversationId': agyConversationId,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        serverId: json['serverId'] as String,
        project: _projectOf(json['workspace']),
        title: json['title'] as String? ?? 'Conversation',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        agyConversationId: json['agyConversationId'] as String?,
        messages: (json['messages'] as List? ?? [])
            .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

String? _projectOf(Object? v) => v is String && v.isNotEmpty ? v : null;

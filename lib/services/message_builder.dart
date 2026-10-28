import 'dart:convert';

import '../models/conversation.dart';
import 'agent_stream_parser.dart';

/// Applies [AgentEvent]s to an agent [ChatMessage], merging deltas into
/// blocks and pairing tool results with their calls.
class MessageBuilder {
  MessageBuilder(this.message);

  final ChatMessage message;

  /// Latest conversation id reported by agy, if any.
  String? conversationId;

  /// The final `result` status (SUCCESS, ERROR, CANCELED, …), if reported.
  String? resultStatus;
  bool resultCancelled = false;

  /// True while the last text/thinking part is being built from deltas, so a
  /// following full block of the same kind replaces it instead of repeating.
  bool _streamingDeltas = false;

  void apply(AgentEvent event) {
    switch (event) {
      case SessionEvent(:final conversationId):
        if (conversationId != null) this.conversationId = conversationId;
      case TextDelta(:final text, :final thinking):
        final kind = thinking ? PartKind.thinking : PartKind.text;
        final last = _last;
        if (last != null && last.kind == kind && _streamingDeltas) {
          last.text += text;
        } else {
          message.parts.add(MessagePart(kind: kind, text: text));
        }
        _streamingDeltas = true;
      case TextBlock(:final text, :final thinking):
        final kind = thinking ? PartKind.thinking : PartKind.text;
        final last = _last;
        if (last != null && last.kind == kind) {
          if (last.text == text) {
            // Duplicate of what was streamed.
          } else if (_streamingDeltas &&
              (text.startsWith(last.text) || last.text.trim() == text.trim())) {
            last.text = text;
          } else {
            message.parts.add(MessagePart(kind: kind, text: text));
          }
        } else {
          message.parts.add(MessagePart(kind: kind, text: text));
        }
        _streamingDeltas = false;
      case ToolCallEvent(:final id, :final name, :final input):
        _streamingDeltas = false;
        final existing = id == null ? null : _toolById(id);
        if (existing != null) {
          existing.toolInput = input ?? existing.toolInput;
        } else {
          message.parts.add(MessagePart(
            kind: PartKind.tool,
            toolId: id,
            toolName: name,
            toolInput: input,
          ));
        }
      case ToolResultEvent(:final id, :final name, :final output, :final isError):
        _streamingDeltas = false;
        final part = (id == null ? null : _toolById(id)) ??
            _lastRunningTool(name) ??
            _lastRunningTool(null);
        if (part == null) {
          message.parts.add(MessagePart(
            kind: PartKind.tool,
            toolId: id,
            toolName: name ?? 'tool',
            toolOutput: output,
            toolStatus: isError ? ToolStatus.failed : ToolStatus.done,
          ));
        } else {
          part.toolOutput = output ?? part.toolOutput;
          part.toolStatus = isError ? ToolStatus.failed : ToolStatus.done;
        }
      case ArtifactEvent(:final name, :final path, :final content):
        _streamingDeltas = false;
        final existing = message.parts.where((p) =>
            p.kind == PartKind.artifact && (path != null ? p.toolInput == path : p.toolName == name));
        if (existing.isNotEmpty) {
          final p = existing.last;
          if (content != null) p.text = content;
          p.toolInput = path ?? p.toolInput;
        } else {
          message.parts.add(MessagePart(
            kind: PartKind.artifact,
            toolName: name,
            toolInput: path,
            text: content ?? '',
            toolStatus: ToolStatus.done,
          ));
        }
      case SubagentEvent(:final subagents):
        _streamingDeltas = false;
        for (final sub in subagents) {
          final key = sub.conversationId ?? sub.role ?? sub.typeName ?? '';
          final existing = message.parts
              .where((p) => p.kind == PartKind.subagent && (p.toolId ?? p.toolName) == key)
              .toList();
          final json = jsonEncode(sub.toJson());
          if (existing.isNotEmpty) {
            existing.last.toolInput = json;
          } else {
            message.parts.add(MessagePart(
              kind: PartKind.subagent,
              toolId: sub.conversationId,
              toolName: sub.role ?? sub.typeName ?? 'Subagent',
              toolInput: json,
              toolStatus: ToolStatus.done,
            ));
          }
        }
      case ErrorEvent(:final message):
        _streamingDeltas = false;
        this.message.parts.add(MessagePart(kind: PartKind.error, text: message));
      case ResultEvent(:final response, :final usage, :final conversationId):
        _streamingDeltas = false;
        if (conversationId != null) this.conversationId = conversationId;
        resultStatus = event.status;
        resultCancelled = event.isCancelled;
        if (usage != null) message.usage = usage;
        if (response != null && response.trim().isNotEmpty) {
          final shown = message.parts
              .where((p) => p.kind == PartKind.text)
              .map((p) => p.text)
              .join('\n');
          String squash(String x) => x.replaceAll(RegExp(r'\s+'), '');
          // The final response often repeats the streamed text, possibly
          // joined differently.
          if (!shown.contains(response.trim()) && squash(shown) != squash(response)) {
            final last = _last;
            if (last != null &&
                last.kind == PartKind.text &&
                response.trim().startsWith(last.text.trim())) {
              last.text = response;
            } else {
              message.parts.add(MessagePart(kind: PartKind.text, text: response));
            }
          }
        }
        if (event.isError && !event.isCancelled && !message.parts.any((p) => p.kind == PartKind.error)) {
          message.parts.add(MessagePart(
              kind: PartKind.error,
              text: 'The agent finished with status "${event.status}".'));
        }
      case RawLine(:final line):
        _streamingDeltas = false;
        final last = _last;
        if (last != null && last.kind == PartKind.notice) {
          last.text += '\n$line';
        } else {
          message.parts.add(MessagePart(kind: PartKind.notice, text: line));
        }
    }
  }

  /// Marks running tools as finished and, if agy produced no structured text
  /// at all, promotes plain output to the reply body.
  void finish({required bool success}) {
    for (final p in message.parts) {
      if (p.kind == PartKind.tool && p.toolStatus == ToolStatus.running) {
        p.toolStatus = success ? ToolStatus.done : ToolStatus.failed;
      }
    }
    final hasText = message.parts.any((p) => p.kind == PartKind.text);
    if (!hasText) {
      final notices =
          message.parts.where((p) => p.kind == PartKind.notice).toList();
      if (notices.isNotEmpty && notices.length == message.parts.length) {
        final text = notices.map((p) => p.text).join('\n');
        message.parts
          ..clear()
          ..add(MessagePart(kind: PartKind.text, text: text));
      }
    }
  }

  MessagePart? get _last => message.parts.isEmpty ? null : message.parts.last;

  MessagePart? _toolById(String id) {
    for (final p in message.parts.reversed) {
      if (p.kind == PartKind.tool && p.toolId == id) return p;
    }
    return null;
  }

  MessagePart? _lastRunningTool(String? name) {
    for (final p in message.parts.reversed) {
      if (p.kind == PartKind.tool &&
          p.toolStatus == ToolStatus.running &&
          (name == null || p.toolName == name)) {
        return p;
      }
    }
    return null;
  }
}

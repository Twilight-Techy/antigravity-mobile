import 'dart:convert';

import '../models/conversation.dart';
import 'agent_stream_parser.dart';

/// Marks a notice holding one of agy's system messages (e.g. "subagent
/// finished"), shown collapsed.
const systemNotice = 'system';

/// One line of agy's `transcript_full.jsonl`
/// (`~/.gemini/<app>/brain/<conversation>/.system_generated/logs/`), the
/// conversation's full record: prompts, replies with their thinking, tool
/// calls with their arguments and output, system messages.
class TranscriptStep {
  const TranscriptStep({
    required this.index,
    required this.type,
    this.status = 'DONE',
    this.content,
    this.thinking,
    this.error,
    this.toolCalls = const [],
    this.createdAt,
    this.inputTokens,
    this.outputTokens,
    this.cachedTokens,
  });

  final int index;

  /// `USER_INPUT`, `PLANNER_RESPONSE`, `GENERIC` (a tool's result),
  /// `SYSTEM_MESSAGE`, …
  final String type;
  final String status;
  final String? content;
  final String? thinking;
  final String? error;
  final List<({String name, Map<String, dynamic> args})> toolCalls;
  final DateTime? createdAt;
  final int? inputTokens;
  final int? outputTokens;
  final int? cachedTokens;

  static TranscriptStep? parse(String line) {
    final t = line.trim();
    if (!t.startsWith('{')) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(t);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['step_index'] is! num) return null;
    final m = Map<String, dynamic>.from(decoded);
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    int? n(Object? v) => v is num ? v.toInt() : null;
    return TranscriptStep(
      index: (m['step_index'] as num).toInt(),
      type: str(m['type']) ?? '',
      status: str(m['status']) ?? 'DONE',
      content: str(m['content']),
      thinking: str(m['thinking']),
      error: str(m['error']),
      toolCalls: [
        if (m['tool_calls'] is List)
          for (final c in (m['tool_calls'] as List).whereType<Map>())
            (name: str(c['name']) ?? 'tool', args: _args(c['args'])),
      ],
      createdAt: DateTime.tryParse(str(m['created_at']) ?? ''),
      inputTokens: n(m['input_tokens']),
      outputTokens: n(m['output_tokens']),
      cachedTokens: n(m['cache_read_tokens']),
    );
  }

  /// `transcript.jsonl` stores each argument JSON-encoded;
  /// `transcript_full.jsonl` stores them as values. Accept both.
  static Map<String, dynamic> _args(Object? v) {
    if (v is! Map) return const {};
    return v.map((k, value) {
      if (value is String) {
        final s = value.trim();
        if (s.startsWith('"') || s.startsWith('{') || s.startsWith('[')) {
          try {
            return MapEntry('$k', jsonDecode(s));
          } catch (_) {}
        }
      }
      return MapEntry('$k', value);
    });
  }

  static List<TranscriptStep> parseAll(String text) =>
      const LineSplitter().convert(text).map(parse).whereType<TranscriptStep>().toList();
}

/// Turns transcript steps into chat parts and messages.
class Transcript {
  /// Chat parts for each step, keyed by step index. Tool calls are made in
  /// a `PLANNER_RESPONSE` step and their results arrive as the following
  /// steps; each result is keyed by its own step, as in the live stream
  /// (`tool` steps carry the result's index).
  static Map<int, List<MessagePart>> partsByStep(Iterable<TranscriptStep> steps) {
    final out = <int, List<MessagePart>>{};
    final pending = <({String name, Map<String, dynamic> args})>[];
    for (final s in steps) {
      final parts = out.putIfAbsent(s.index, () => []);
      switch (s.type) {
        case 'USER_INPUT':
          pending.clear();
        case 'PLANNER_RESPONSE':
          if (s.thinking != null) parts.add(MessagePart(kind: PartKind.thinking, text: s.thinking!, step: s.index));
          if (s.content != null) parts.add(MessagePart(kind: PartKind.text, text: s.content!, step: s.index));
          pending
            ..clear()
            ..addAll(s.toolCalls);
        case 'SYSTEM_MESSAGE':
          final text = _systemText(s.content);
          if (text.isNotEmpty) {
            parts.add(MessagePart(kind: PartKind.notice, toolName: systemNotice, text: text, step: s.index));
          }
        case 'ERROR_MESSAGE':
          parts.add(MessagePart(kind: PartKind.error, text: s.error ?? s.content ?? 'Error', step: s.index));
        default:
          if (pending.isNotEmpty) {
            parts.addAll(_toolParts(pending.removeAt(0), s));
          } else if (s.error != null) {
            parts.add(MessagePart(kind: PartKind.error, text: s.error!, step: s.index));
          } else if (s.content != null) {
            parts.add(MessagePart(kind: PartKind.notice, text: _withoutTimes(s.content!), step: s.index));
          }
      }
      if (parts.isEmpty) out.remove(s.index);
    }
    return out;
  }

  static List<MessagePart> _toolParts(({String name, Map<String, dynamic> args}) call, TranscriptStep s) {
    final failed = s.status == 'ERROR' || s.error != null;
    final output = failed ? (s.error ?? s.content) : (s.content == null ? null : _withoutTimes(s.content!));
    if (call.name == 'invoke_subagent' && !failed) {
      final sub = _createdSubagent(output ?? '', call.args);
      if (sub != null) {
        return [
          MessagePart(
            kind: PartKind.subagent,
            toolId: sub.conversationId,
            toolName: sub.role ?? sub.typeName ?? 'Subagent',
            toolInput: jsonEncode(sub.toJson()),
            toolStatus: ToolStatus.done,
            step: s.index,
          ),
        ];
      }
    }
    final parts = [
      MessagePart(
        kind: PartKind.tool,
        toolId: 'step-${s.index}',
        toolName: call.name,
        toolInput: const JsonEncoder.withIndent('  ').convert(call.args),
        toolOutput: output,
        toolStatus: failed ? ToolStatus.failed : ToolStatus.done,
        step: s.index,
      ),
    ];
    if (!failed) {
      final artifact = AgentStreamParser.artifactFromTool(call.name, call.args, s.index);
      if (artifact != null) {
        parts.add(MessagePart(
          kind: PartKind.artifact,
          toolName: artifact.name,
          toolInput: artifact.path,
          toolStatus: ToolStatus.done,
          step: s.index,
        ));
      }
    }
    return parts;
  }

  /// invoke_subagent's result: "Created the following subagent:\n{json}".
  static SubagentInfo? _createdSubagent(String output, Map<String, dynamic> args) {
    final start = output.indexOf('{');
    final end = output.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final j = jsonDecode(output.substring(start, end + 1));
      if (j is! Map || j['conversationId'] is! String) return null;
      return SubagentInfo(
        typeName: args['TypeName'] as String?,
        role: args['Role'] as String?,
        conversationId: j['conversationId'] as String,
        logUri: j['logAbsoluteUri'] as String?,
        workspaceUris: (j['workspaceUris'] as List?)?.whereType<String>().toList() ?? const [],
      );
    } catch (_) {
      return null;
    }
  }

  /// Tool results start with "Created At: …\nCompleted At: …".
  static String _withoutTimes(String s) =>
      s.replaceFirst(RegExp(r'^Created At: [^\n]*\n(Completed At: [^\n]*\n?)?'), '').trim();

  static String _systemText(String? s) {
    if (s == null) return '';
    final m = RegExp(r'<SYSTEM_MESSAGE>[ \t]*\n([\s\S]*?)\s*</SYSTEM_MESSAGE>').firstMatch(s);
    var text = (m?.group(1) ?? s).trim();
    // "[Message] timestamp=… sender=system priority=… content=<text>"
    final content = RegExp(r'content=([\s\S]*)$').firstMatch(text);
    if (text.startsWith('[Message]') && content != null) text = content.group(1)!.trim();
    return text;
  }

  /// The user's own words from a `USER_INPUT` step, without the metadata
  /// agy wraps around them.
  static String userText(String? content) {
    if (content == null) return '';
    final m = RegExp(r'<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>').firstMatch(content);
    if (m != null) return m.group(1)!;
    return content.replaceAll(RegExp(r'<([A-Z_]+)>[\s\S]*?</\1>'), '').trim();
  }

  /// A reply's parts with agy's transcript folded in: steps the transcript
  /// has (after the reply's prompt at [firstStep]) come from it, adding
  /// thinking, full tool arguments and output; steps it doesn't have yet
  /// stay as streamed. Parts without a step (errors, notices) stay last.
  static List<MessagePart> merge(List<MessagePart> live, Map<int, List<MessagePart>> transcript, {required int firstStep}) {
    final covered = transcript.keys.where((k) => k > firstStep).toSet();
    final steps = <int>{...covered, ...live.map((p) => p.step).whereType<int>()}.toList()..sort();
    final out = <MessagePart>[];
    for (final step in steps) {
      final streamed = live.where((p) => p.step == step).toList();
      if (!covered.contains(step)) {
        out.addAll(streamed);
        continue;
      }
      for (final p in transcript[step]!) {
        // Keep output the stream had if the transcript left it out.
        if (p.kind == PartKind.tool && p.toolOutput == null) {
          final s = streamed.where((x) => x.kind == PartKind.tool).firstOrNull;
          p.toolOutput = s?.toolOutput;
        }
        out.add(p);
      }
    }
    out.addAll(live.where((p) => p.step == null));
    return out;
  }

  /// Chat messages for the steps after [afterStep]: each `USER_INPUT`
  /// starts a user message, and the steps until the next one form the
  /// agent's reply.
  static List<ChatMessage> messages(List<TranscriptStep> steps, {int afterStep = -1, required String Function() newId}) {
    final out = <ChatMessage>[];
    final parts = partsByStep(steps);
    ChatMessage? reply;
    var input = 0, output = 0, cached = 0;
    void closeReply() {
      if (reply != null && reply!.parts.isNotEmpty) {
        if (input + output > 0) {
          reply!.usage = [
            '${_fmt(input)} in',
            '${_fmt(output)} out',
            if (cached > 0) '${_fmt(cached)} cached',
          ].join(' · ');
        }
        out.add(reply!);
      }
      reply = null;
      input = output = cached = 0;
    }

    for (final s in steps) {
      if (s.index <= afterStep) continue;
      final at = s.createdAt?.toLocal() ?? DateTime.now();
      if (s.type == 'USER_INPUT') {
        closeReply();
        final text = userText(s.content);
        if (text.isNotEmpty) {
          out.add(ChatMessage(
            id: newId(),
            role: MessageRole.user,
            createdAt: at,
            parts: [MessagePart(kind: PartKind.text, text: text, step: s.index)],
          ));
        }
        continue;
      }
      reply ??= ChatMessage(id: newId(), role: MessageRole.agent, createdAt: at, firstStep: s.index - 1);
      reply!.parts.addAll(parts[s.index] ?? const []);
      input += s.inputTokens ?? 0;
      output += s.outputTokens ?? 0;
      cached += s.cachedTokens ?? 0;
    }
    closeReply();
    return out;
  }

  static String _fmt(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
}

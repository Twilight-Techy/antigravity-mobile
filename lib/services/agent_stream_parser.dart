import 'dart:convert';

/// Events understood by the chat UI, normalised from agy's
/// `--output-format stream-json` lines (or plain text output).
sealed class AgentEvent {
  const AgentEvent();
}

class SessionEvent extends AgentEvent {
  const SessionEvent({this.conversationId, this.model});
  final String? conversationId;
  final String? model;
}

/// Incremental text appended to the current block.
class TextDelta extends AgentEvent {
  const TextDelta(this.text, {this.thinking = false});
  final String text;
  final bool thinking;
}

/// A complete text block (a whole message rather than a delta).
class TextBlock extends AgentEvent {
  const TextBlock(this.text, {this.thinking = false});
  final String text;
  final bool thinking;
}

class ToolCallEvent extends AgentEvent {
  const ToolCallEvent({this.id, required this.name, this.input});
  final String? id;
  final String name;
  final String? input;
}

class ToolResultEvent extends AgentEvent {
  const ToolResultEvent({this.id, this.name, this.output, this.isError = false});
  final String? id;
  final String? name;
  final String? output;
  final bool isError;
}

class ErrorEvent extends AgentEvent {
  const ErrorEvent(this.message);
  final String message;
}

/// The final envelope: `{conversation_id, status, response, usage}`.
class ResultEvent extends AgentEvent {
  const ResultEvent({this.response, this.status, this.usage, this.conversationId});
  final String? response;
  final String? status;
  final String? usage;
  final String? conversationId;

  bool get isError {
    final s = status?.toLowerCase();
    return s != null && (s.contains('error') || s.contains('fail'));
  }
}

/// A line that was not JSON; shown as plain text output.
class RawLine extends AgentEvent {
  const RawLine(this.line);
  final String line;
}

/// Converts agy output lines into [AgentEvent]s.
///
/// The stream-json schema is not formally published, so this parser is
/// deliberately tolerant: it recognises the common shapes used by agent CLIs
/// (`type`/`event` discriminators, delta/chunk events, tool call/result
/// events, Anthropic-style content blocks, OpenAI-style function calls) and
/// falls back to any `text`/`content`/`response` field it can find.
class AgentStreamParser {
  static const _conversationKeys = [
    'conversation_id',
    'conversationId',
    'session_id',
    'sessionId',
    'thread_id',
    'threadId',
  ];

  List<AgentEvent> parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const [];
    if (!(trimmed.startsWith('{') && trimmed.endsWith('}'))) {
      return [RawLine(line)];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return [RawLine(line)];
    }
    if (decoded is! Map) return [RawLine(line)];
    return parseObject(Map<String, dynamic>.from(decoded));
  }

  List<AgentEvent> parseObject(Map<String, dynamic> m) {
    final events = <AgentEvent>[];
    final type = _str(m['type'] ?? m['event'] ?? m['kind'] ?? m['object'])
            ?.toLowerCase() ??
        '';
    final subtype = _str(m['subtype'])?.toLowerCase() ?? '';
    final t = '$type $subtype';

    final convId = _findConversationId(m);

    // Final result envelope (also the whole output of --output-format json).
    final isResult = type == 'result' ||
        type == 'final' ||
        type == 'done' ||
        type == 'complete' ||
        type == 'completed' ||
        type.endsWith('.completed') && !type.contains('tool') ||
        (type.isEmpty && m.containsKey('response') && m.containsKey('status'));
    if (isResult) {
      final response = _textOf(m['response'] ?? m['result'] ?? m['output']);
      events.add(ResultEvent(
        response: response,
        status: _str(m['status'] ?? m['subtype']),
        usage: _usageSummary(m['usage'] ?? m['stats']),
        conversationId: convId,
      ));
      if (m['error'] != null) events.add(ErrorEvent(_errorText(m['error'])));
      return events;
    }

    if (t.contains('error') || (type.isEmpty && m['error'] != null)) {
      events.add(ErrorEvent(_errorText(m['error'] ?? m['message'] ?? m)));
      return events;
    }

    final isTool = t.contains('tool') || t.contains('function');
    if (isTool) {
      final isResultish = t.contains('result') ||
          t.contains('output') ||
          t.contains('response') ||
          t.contains('end') ||
          t.contains('complete') ||
          t.contains('finish') ||
          t.contains('done');
      final id = _str(m['id'] ??
          m['tool_use_id'] ??
          m['tool_call_id'] ??
          m['toolCallId'] ??
          m['call_id'] ??
          m['callId']);
      final name = _toolName(m);
      if (isResultish) {
        events.add(ToolResultEvent(
          id: id,
          name: name,
          output: _textOf(m['output'] ??
              m['result'] ??
              m['content'] ??
              m['response'] ??
              m['text']),
          isError: m['is_error'] == true ||
              m['isError'] == true ||
              _str(m['status'])?.toLowerCase().contains('error') == true ||
              _str(m['status'])?.toLowerCase().contains('fail') == true,
        ));
      } else {
        events.add(ToolCallEvent(
          id: id,
          name: name ?? 'tool',
          input: _pretty(m['input'] ??
              m['args'] ??
              m['arguments'] ??
              m['parameters'] ??
              m['params'] ??
              (m['function'] is Map ? (m['function'] as Map)['arguments'] : null)),
        ));
      }
      return events;
    }

    final thinking = t.contains('thought') ||
        t.contains('thinking') ||
        t.contains('reasoning');
    final isDelta = t.contains('delta') ||
        t.contains('chunk') ||
        t.contains('token') ||
        t.contains('partial') ||
        t.contains('stream');

    // Anthropic-style wrapper: {"type":"assistant","message":{"content":[...]}}
    final message = m['message'];
    if (message is Map && message['content'] != null) {
      if (_str(message['role']) == 'user' || type == 'user') {
        return _toolResultsFromBlocks(message['content']);
      }
      events.addAll(_fromContent(message['content'], thinking: thinking));
      if (convId != null) events.insert(0, SessionEvent(conversationId: convId));
      return events;
    }

    if (type == 'user' || _str(m['role']) == 'user') {
      final blocks = _toolResultsFromBlocks(m['content']);
      if (convId != null) blocks.insert(0, SessionEvent(conversationId: convId));
      return blocks;
    }

    if (type == 'system' ||
        type == 'init' ||
        type.contains('start') ||
        type.contains('session') ||
        type.contains('conversation') ||
        subtype == 'init') {
      final text = _textOf(m['text'] ?? m['content']);
      events.add(SessionEvent(
        conversationId: convId,
        model: _str(m['model']),
      ));
      if (type == 'system' && text != null && text.isNotEmpty && subtype != 'init') {
        events.add(TextBlock(text, thinking: true));
      }
      return events;
    }

    if (convId != null) events.add(SessionEvent(conversationId: convId));

    if (isDelta) {
      final delta = m['delta'];
      String? text;
      var deltaThinking = thinking;
      if (delta is Map) {
        final dt = _str(delta['type'])?.toLowerCase() ?? '';
        if (dt.contains('thinking') || dt.contains('reasoning')) {
          deltaThinking = true;
        }
        text = _str(delta['text'] ??
            delta['thinking'] ??
            delta['content'] ??
            delta['partial_json']);
      } else {
        text = _str(delta ?? m['text'] ?? m['content'] ?? m['token'] ?? m['chunk']);
      }
      if (text != null && text.isNotEmpty) {
        events.add(TextDelta(text, thinking: deltaThinking));
      }
      return events;
    }

    final content = m['content'] ?? m['text'] ?? m['response'] ?? m['message'];
    if (content != null) {
      events.addAll(_fromContent(content, thinking: thinking));
    }
    return events;
  }

  List<AgentEvent> _fromContent(Object? content, {bool thinking = false}) {
    if (content is String) {
      return content.isEmpty ? const [] : [TextBlock(content, thinking: thinking)];
    }
    if (content is List) {
      final out = <AgentEvent>[];
      for (final block in content) {
        if (block is String) {
          out.add(TextBlock(block, thinking: thinking));
        } else if (block is Map) {
          final b = Map<String, dynamic>.from(block);
          final bt = _str(b['type'])?.toLowerCase() ?? 'text';
          if (bt.contains('tool') || bt.contains('function')) {
            out.addAll(parseObject(b));
          } else if (bt.contains('thinking') || bt.contains('reasoning')) {
            final text = _str(b['thinking'] ?? b['text'] ?? b['content']);
            if (text != null && text.isNotEmpty) {
              out.add(TextBlock(text, thinking: true));
            }
          } else {
            final text = _textOf(b['text'] ?? b['content']);
            if (text != null && text.isNotEmpty) {
              out.add(TextBlock(text, thinking: thinking));
            }
          }
        }
      }
      return out;
    }
    if (content is Map) {
      return _fromContent(
          content['text'] ?? content['content'] ?? content['parts'],
          thinking: thinking);
    }
    return const [];
  }

  List<AgentEvent> _toolResultsFromBlocks(Object? content) {
    if (content is! List) return [];
    final out = <AgentEvent>[];
    for (final block in content) {
      if (block is Map && _str(block['type'])?.contains('tool') == true) {
        out.addAll(parseObject(Map<String, dynamic>.from(block)));
      }
    }
    return out;
  }

  String? _findConversationId(Map<String, dynamic> m) {
    for (final key in _conversationKeys) {
      final v = _str(m[key]);
      if (v != null && v.isNotEmpty) return v;
    }
    for (final nested in [m['result'], m['session'], m['conversation'], m['data']]) {
      if (nested is Map) {
        for (final key in [..._conversationKeys, 'id']) {
          final v = _str(nested[key]);
          if (v != null && v.isNotEmpty) return v;
        }
      }
    }
    return null;
  }

  String? _toolName(Map<String, dynamic> m) {
    final direct = _str(m['name'] ??
        m['tool_name'] ??
        m['toolName'] ??
        m['tool'] ??
        m['function_name']);
    if (direct != null) return direct;
    for (final k in ['tool', 'function', 'call', 'tool_call']) {
      final v = m[k];
      if (v is Map) {
        final n = _str(v['name'] ?? v['tool_name']);
        if (n != null) return n;
      }
    }
    return null;
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  /// Best-effort extraction of displayable text from an arbitrary value.
  static String? _textOf(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    if (v is List) {
      final parts = v.map(_textOf).whereType<String>().where((s) => s.isNotEmpty);
      return parts.isEmpty ? null : parts.join('\n');
    }
    if (v is Map) {
      final inner = v['text'] ?? v['content'] ?? v['output'] ?? v['response'];
      if (inner != null) return _textOf(inner);
      return _pretty(v);
    }
    return v.toString();
  }

  static String? _pretty(Object? v) {
    if (v == null) return null;
    if (v is String) {
      final s = v.trim();
      if (s.startsWith('{') || s.startsWith('[')) {
        try {
          return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
        } catch (_) {}
      }
      return v;
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(v);
    } catch (_) {
      return v.toString();
    }
  }

  static String _errorText(Object? v) {
    if (v is Map) {
      return _str(v['message'] ?? v['error'] ?? v['detail']) ?? _pretty(v)!;
    }
    return _textOf(v) ?? 'Unknown error';
  }

  static String? _usageSummary(Object? usage) {
    if (usage is! Map) return _str(usage);
    int? pick(List<String> keys) {
      for (final k in keys) {
        final v = usage[k];
        if (v is num) return v.toInt();
      }
      return null;
    }

    final input = pick(['input_tokens', 'inputTokens', 'prompt_tokens', 'promptTokens']);
    final output = pick(['output_tokens', 'outputTokens', 'completion_tokens', 'candidates_tokens', 'candidatesTokens']);
    final total = pick(['total_tokens', 'totalTokens']);
    final parts = <String>[
      if (input != null) '${_fmt(input)} in',
      if (output != null) '${_fmt(output)} out',
      if (input == null && output == null && total != null) '${_fmt(total)} tokens',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _fmt(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
}

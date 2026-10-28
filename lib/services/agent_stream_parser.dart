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
  const TextDelta(this.text, {this.thinking = false, this.step});
  final String text;
  final bool thinking;

  /// agy step the text belongs to (`step_update.step_index`).
  final int? step;
}

/// The run's own prompt, at agy step [step]; later steps are its reply.
class UserInputEvent extends AgentEvent {
  const UserInputEvent(this.step);
  final int step;
}

/// A complete text block (a whole message rather than a delta).
class TextBlock extends AgentEvent {
  const TextBlock(this.text, {this.thinking = false});
  final String text;
  final bool thinking;
}

class ToolCallEvent extends AgentEvent {
  const ToolCallEvent({this.id, required this.name, this.input, this.step});
  final String? id;
  final String name;
  final String? input;
  final int? step;
}

class ToolResultEvent extends AgentEvent {
  const ToolResultEvent({this.id, this.name, this.output, this.isError = false});
  final String? id;
  final String? name;
  final String? output;
  final bool isError;
}

/// An artifact (plan, task list, walkthrough…) the agent created or updated.
class ArtifactEvent extends AgentEvent {
  const ArtifactEvent({required this.name, this.path, this.content, this.step});
  final String name;
  final String? path;
  final String? content;
  final int? step;
}

class ErrorEvent extends AgentEvent {
  const ErrorEvent(this.message);
  final String message;
}

/// The final envelope: `{conversation_id, status, response, usage}`.
class ResultEvent extends AgentEvent {
  const ResultEvent({
    this.response,
    this.status,
    this.usage,
    this.conversationId,
    this.deniedActions = const [],
    this.command,
    this.error,
  });
  final String? response;
  final String? status;
  final String? usage;
  final String? conversationId;

  /// Tools headless mode auto-denied (`result.denied_actions`), e.g.
  /// `RunCommand (command)`.
  final List<String> deniedActions;

  /// Set when the run was a slash command answered by agy itself (`/usage`,
  /// `/credits`, `/model`…): its name, and [response] is the report.
  final String? command;

  /// The `error`, when the result carried one.
  final String? error;

  bool get isError {
    final s = status?.toLowerCase();
    return s != null && (s.contains('error') || s.contains('fail') || s == 'invalid');
  }

  /// `CANCELED` / `INTERRUPTED`, or how agy 1.4.9 reports SIGINT: status
  /// `ERROR` with the error `interrupted`.
  bool get isCancelled {
    final s = status?.toLowerCase();
    return s == 'canceled' || s == 'cancelled' || s == 'interrupted' || error?.trim().toLowerCase() == 'interrupted';
  }
}

/// Subagents the agent started (from `step_update.subagent_info`).
class SubagentEvent extends AgentEvent {
  const SubagentEvent(this.subagents, {this.step});
  final List<SubagentInfo> subagents;
  final int? step;
}

class SubagentInfo {
  const SubagentInfo({this.typeName, this.role, this.conversationId, this.logUri, this.workspaceUris = const []});
  final String? typeName;
  final String? role;
  final String? conversationId;
  final String? logUri;
  final List<String> workspaceUris;

  Map<String, dynamic> toJson() => {
        if (typeName != null) 'type_name': typeName,
        if (role != null) 'role': role,
        if (conversationId != null) 'conversation_id': conversationId,
        if (logUri != null) 'log_uri': logUri,
        if (workspaceUris.isNotEmpty) 'workspace_uris': workspaceUris,
      };

  factory SubagentInfo.fromJson(Map<String, dynamic> j) => SubagentInfo(
        typeName: j['type_name'] as String?,
        role: j['role'] as String?,
        conversationId: j['conversation_id'] as String?,
        logUri: j['log_uri'] as String?,
        workspaceUris: (j['workspace_uris'] as List?)?.whereType<String>().toList() ?? const [],
      );
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
  /// [resumed]: the stream is being picked up mid-run (from a byte offset),
  /// so it won't start with the run's own `user_input` step.
  AgentStreamParser({bool resumed = false}) : _sawUserInput = resumed;

  /// Opening another agent's conversation (a subagent's) replays its first
  /// turn, which began with a system message, before our `user_input`
  /// step. Those steps are held back and dropped once our input shows up.
  bool _sawUserInput;
  bool _sawStep = false;
  final _heldBack = <AgentEvent>[];

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

    // agy's schema: `event` is init | step_update | command_result | result,
    // with the payload under a key of the same name (older builds put the
    // fields at the top level).
    final event = m['event'];
    if (event is String) {
      final payload = m[event] is Map ? Map<String, dynamic>.from(m[event] as Map) : m;
      switch (event) {
        case 'init':
          return [SessionEvent(conversationId: convId, model: _str(payload['model']))];
        case 'step_update':
          return _stepUpdate(payload, _str(payload['conversation_id']) ?? convId);
        case 'command_result':
          // The `result` line that follows carries the same report as text.
          return const [];
        case 'result':
          if (m[event] is Map) return _agyResult(payload);
      }
    }

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
      // The specific error first, so the result adds no generic one.
      if (m['error'] != null) events.add(ErrorEvent(_errorText(m['error'])));
      events.add(ResultEvent(
        response: response,
        status: _str(m['status'] ?? m['subtype']),
        usage: _usageSummary(m['usage'] ?? m['stats']),
        conversationId: convId,
      ));
      return events;
    }

    if (t.contains('error') || (type.isEmpty && m['error'] != null)) {
      events.add(ErrorEvent(_errorText(m['error'] ?? m['message'] ?? m)));
      return events;
    }

    if (t.contains('artifact')) {
      final a = m['artifact'] is Map ? Map<String, dynamic>.from(m['artifact'] as Map) : m;
      final path = _str(a['path'] ?? a['file_path'] ?? a['filePath'] ?? a['uri']);
      final name = _str(a['name'] ?? a['title'] ?? a['filename'] ?? a['file_name']) ??
          path?.split(RegExp(r'[\\/]')).last;
      if (name != null || path != null) {
        events.add(ArtifactEvent(
          name: name ?? 'Artifact',
          path: path,
          content: _textOf(a['content'] ?? a['markdown'] ?? a['text'] ?? a['body']),
        ));
        return events;
      }
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

  /// `step_update`: one step of the turn. `step_type` is `user_input`,
  /// `agent_response` (streamed via `text_delta`), `tool` (with `tool_info`),
  /// `subagent` (with `subagent_info`), `system_message`, `error_message`
  /// or `checkpoint`; `state` is `ACTIVE` until it ends as `DONE` or
  /// `ERROR`.
  List<AgentEvent> _stepUpdate(Map<String, dynamic> m, String? convId) {
    final session = <AgentEvent>[if (convId != null) SessionEvent(conversationId: convId)];
    final events = <AgentEvent>[];
    final stepType = _str(m['step_type'])?.toLowerCase() ?? '';
    final state = _str(m['state'])?.toUpperCase() ?? '';
    final ended = state == 'DONE' || state == 'ERROR';
    final index = m['step_index'] is num ? (m['step_index'] as num).toInt() : null;
    final id = 'step-${index ?? ''}';
    final firstStep = !_sawStep;
    _sawStep = true;
    if (stepType == 'user_input') {
      _sawUserInput = true;
      _heldBack.clear();
      return [...session, if (index != null) UserInputEvent(index)];
    }
    if (firstStep && !_sawUserInput && stepType != 'system_message') {
      // A normal run starts with its user_input; anything else first is a
      // replay we don't hold back for (e.g. a plain stream).
      _sawUserInput = true;
    }
    switch (stepType) {
      case 'agent_response':
        final delta = _str(m['text_delta']);
        if (delta != null && delta.isNotEmpty) events.add(TextDelta(delta, step: index));
      case 'tool':
        final info = m['tool_info'] is Map ? Map<String, dynamic>.from(m['tool_info'] as Map) : const <String, dynamic>{};
        final name = _str(info['name'] ?? m['tool_name']) ?? 'tool';
        final params = info['parameters'];
        events.add(ToolCallEvent(id: id, name: name, input: _pretty(params), step: index));
        if (ended) {
          final error = info['error'];
          events.add(ToolResultEvent(
            id: id,
            name: name,
            output: error != null ? _errorText(error) : _textOf(info['output']),
            isError: error != null || state == 'ERROR',
          ));
          if (state == 'DONE') {
            final artifact = artifactFromTool(name, params, index);
            if (artifact != null) events.add(artifact);
          }
        }
      case 'error_message':
        final text = _str(m['text_delta'] ?? m['error'] ?? m['message']);
        if (text != null && text.isNotEmpty) events.add(ErrorEvent(text));
    }
    final sub = m['subagent_info'];
    if (sub is Map && sub['subagents'] is List) {
      final list = (sub['subagents'] as List)
          .whereType<Map>()
          .map((e) => SubagentInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (list.isNotEmpty) events.add(SubagentEvent(list, step: index));
    }
    if (!_sawUserInput) {
      _heldBack.addAll(events);
      return session;
    }
    return [...session, ...events];
  }

  static const _fileWriteTools = {
    'write_file',
    'edit_file',
    'write_to_file',
    'replace_file_content',
    'multi_replace_file_content',
  };

  /// Files written to agy's artifact directory
  /// (`<appDataDir>/brain/<conversation-id>/`) are artifacts.
  static ArtifactEvent? artifactFromTool(String name, Object? params, [int? step]) {
    if (!_fileWriteTools.contains(name) || params is! Map) return null;
    final path = _str(params['Path'] ?? params['TargetFile'] ?? params['path'] ?? params['file_path']);
    if (path == null || !isArtifactPath(path)) return null;
    return ArtifactEvent(name: path.split(RegExp(r'[\\/]')).last, path: path, step: step);
  }

  /// Whether [path] is a user-facing file in an agy artifact directory, not
  /// its scratch files, uploads or generated logs.
  static bool isArtifactPath(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    final brain = parts.lastIndexOf('brain');
    if (brain < 0 || parts.length < brain + 3) return false;
    final inner = parts.sublist(brain + 2);
    if (inner.any((p) => p.startsWith('.') || p == 'scratch')) return false;
    return !inner.last.endsWith('.metadata.json');
  }

  /// agy's final `result` payload.
  List<AgentEvent> _agyResult(Map<String, dynamic> r) {
    final events = <AgentEvent>[];
    if (!_sawUserInput) {
      // Never saw our input, so nothing was a replay after all.
      events.addAll(_heldBack);
      _heldBack.clear();
    }
    final convId = _str(r['conversation_id']);
    final error = r['error'];
    final errorText = error != null && _textOf(error)?.isNotEmpty == true ? _errorText(error) : null;
    final cancelled = errorText?.trim().toLowerCase() == 'interrupted';
    if (errorText != null && !cancelled) events.add(ErrorEvent(errorText));
    final denied = <String>[];
    if (r['denied_actions'] is List) {
      for (final d in (r['denied_actions'] as List).whereType<Map>()) {
        final action = _str(d['action']);
        final display = _str(d['display_name']);
        final label = [
          if (display != null) display,
          if (action != null && action != display) '($action)',
        ].join(' ');
        if (label.isNotEmpty && !denied.contains(label)) denied.add(label);
      }
    }
    final command = r['command'] is Map ? _str((r['command'] as Map)['name']) : null;
    events.add(ResultEvent(
      response: _str(r['response']),
      status: _str(r['status']),
      usage: _usageSummary(r['usage']),
      conversationId: convId == null || convId.isEmpty ? null : convId,
      deniedActions: denied,
      command: command,
      error: errorText,
    ));
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
    final thinking = pick(['thinking_tokens', 'thinkingTokens']);
    final cached = pick(['cache_read_tokens', 'cacheReadTokens']);
    final output = pick(['output_tokens', 'outputTokens', 'completion_tokens', 'candidates_tokens', 'candidatesTokens']);
    final total = pick(['total_tokens', 'totalTokens']);
    final parts = <String>[
      if (input != null) '${_fmt(input)} in',
      if (output != null) '${_fmt(output)} out',
      if (thinking != null && thinking > 0) '${_fmt(thinking)} thinking',
      if (cached != null && cached > 0) '${_fmt(cached)} cached',
      if (input == null && output == null && total != null) '${_fmt(total)} tokens',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _fmt(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
}

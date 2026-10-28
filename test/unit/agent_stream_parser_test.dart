import 'dart:convert';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/services/agent_stream_parser.dart';
import 'package:antigravity_mobile/services/message_builder.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _build(List<Object> lines, {bool success = true}) {
  final m = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime(2026));
  final b = MessageBuilder(m);
  final p = AgentStreamParser();
  for (final l in lines) {
    p.parseLine(l is String ? l : jsonEncode(l)).forEach(b.apply);
  }
  b.finish(success: success);
  return m;
}

void main() {
  test('merges text deltas and ignores a duplicate final response', () {
    final m = _build([
      {'type': 'system', 'subtype': 'init', 'conversation_id': 'c1'},
      {'type': 'text_delta', 'delta': 'Hel'},
      {'type': 'text_delta', 'delta': 'lo'},
      {'type': 'result', 'status': 'SUCCESS', 'response': 'Hello', 'usage': {'input_tokens': 10, 'output_tokens': 2}},
    ]);
    expect(m.parts.length, 1);
    expect(m.plainText, 'Hello');
    expect(m.usage, '10 in · 2 out');
  });

  test('uses the final response when nothing streamed', () {
    final m = _build([
      {'conversation_id': 'c', 'status': 'SUCCESS', 'response': '# Done\nAll good.'},
    ]);
    expect(m.plainText, '# Done\nAll good.');
  });

  test('pairs tool calls with results by id and by order', () {
    final m = _build([
      {'type': 'tool_call', 'id': 'a', 'name': 'run_command', 'input': {'command': 'ls -la'}},
      {'type': 'tool_call', 'name': 'read_file', 'args': '{"path":"x.dart"}'},
      {'type': 'tool_result', 'id': 'a', 'output': 'total 0'},
      {'type': 'tool_result', 'output': 'void main() {}'},
    ]);
    final tools = m.parts.where((p) => p.kind == PartKind.tool).toList();
    expect(tools.length, 2);
    expect(tools[0].toolOutput, 'total 0');
    expect(tools[0].toolStatus, ToolStatus.done);
    expect(tools[0].toolInput, contains('"command": "ls -la"'));
    expect(tools[1].toolName, 'read_file');
    expect(tools[1].toolOutput, 'void main() {}');
  });

  test('understands Anthropic-style content blocks', () {
    final m = _build([
      {
        'type': 'assistant',
        'session_id': 's9',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'Let me look.'},
            {'type': 'text', 'text': 'Checking files.'},
            {'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'pwd'}},
          ],
        },
      },
      {
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 't1', 'content': '/root', 'is_error': false},
          ],
        },
      },
    ]);
    expect(m.parts.map((p) => p.kind), [PartKind.thinking, PartKind.text, PartKind.tool]);
    expect(m.parts[2].toolOutput, '/root');
  });

  test('marks failed tools and surfaces errors', () {
    final m = _build([
      {'type': 'tool_call', 'id': 'x', 'name': 'write_file'},
      {'type': 'tool_result', 'id': 'x', 'status': 'error', 'output': 'denied'},
      {'type': 'error', 'error': {'message': 'quota exceeded'}},
    ], success: false);
    expect(m.parts[0].toolStatus, ToolStatus.failed);
    expect(m.parts.last.kind, PartKind.error);
    expect(m.parts.last.text, 'quota exceeded');
  });

  test('plain text output becomes the reply', () {
    final m = _build(['Notice: update available', 'The answer is 42.']);
    expect(m.parts.single.kind, PartKind.text);
    expect(m.plainText, 'Notice: update available\nThe answer is 42.');
  });

  test('reports the conversation id from several shapes', () {
    final p = AgentStreamParser();
    String? idOf(Map<String, dynamic> m) {
      for (final e in p.parseObject(m)) {
        if (e is SessionEvent) return e.conversationId;
        if (e is ResultEvent) return e.conversationId;
      }
      return null;
    }

    expect(idOf({'type': 'init', 'conversationId': 'a'}), 'a');
    expect(idOf({'type': 'result', 'result': {'conversation_id': 'b'}}), 'b');
    expect(idOf({'type': 'session.started', 'session': {'id': 'c'}}), 'c');
  });

  test('error status on the result adds an error part', () {
    final m = _build([
      {'type': 'result', 'status': 'ERROR_TIMEOUT', 'response': ''},
    ], success: false);
    expect(m.parts.single.kind, PartKind.error);
  });

  test('artifact events become artifact parts, updated in place', () {
    final m = _build([
      {'type': 'artifact', 'name': 'implementation_plan.md', 'path': '/home/u/.gemini/x/implementation_plan.md'},
      {'type': 'text_delta', 'delta': 'Plan ready.'},
      {
        'type': 'artifact_updated',
        'artifact': {'path': '/home/u/.gemini/x/implementation_plan.md', 'content': '# Plan'}
      },
      {'type': 'artifact', 'title': 'Walkthrough', 'markdown': 'Steps'},
    ]);
    final arts = m.parts.where((p) => p.kind == PartKind.artifact).toList();
    expect(arts, hasLength(2));
    expect(arts[0].toolName, 'implementation_plan.md');
    expect(arts[0].text, '# Plan');
    expect(arts[1].toolName, 'Walkthrough');
    expect(arts[1].text, 'Steps');
    expect(m.plainText, 'Plan ready.');
  });

  test('parses the documented agy stream-json events', () {
    final m = _build([
      {'event': 'init', 'cwd': '/w', 'tools': ['read_file'], 'permission_mode': 'request-review', 'model': 'gemini-3.1-pro'},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 0, 'state': 'DONE', 'step_type': 'user_input'},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 1, 'state': 'ACTIVE', 'step_type': 'agent_response', 'text_delta': 'Let me '},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 1, 'state': 'ACTIVE', 'step_type': 'agent_response', 'text_delta': 'check.'},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 1, 'state': 'DONE', 'step_type': 'agent_response'},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 2, 'state': 'ACTIVE', 'step_type': 'tool', 'tool_name': 'run_command',
        'tool_info': {'name': 'run_command', 'parameters': {'command': 'npm test'}}},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 2, 'state': 'DONE', 'step_type': 'tool', 'tool_name': 'run_command',
        'tool_info': {'name': 'run_command', 'parameters': {'command': 'npm test'}, 'output': '12 passing'}, 'duration_seconds': 3.2},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 3, 'state': 'DONE', 'step_type': 'tool',
        'tool_info': {'name': 'write_file', 'parameters': {'path': 'x'}, 'error': {'type': 'PERMISSION', 'message': 'denied by rule'}}},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 4, 'state': 'ACTIVE', 'step_type': 'tool', 'tool_name': 'invoke_subagent',
        'subagent_info': {'subagents': [
          {'type_name': 'research', 'role': 'Docs researcher', 'conversation_id': 'sub-1', 'log_uri': 'file:///home/u/.gemini/logs/sub-1.jsonl', 'workspace_uris': ['file:///w']}
        ]}},
      {'event': 'step_update', 'conversation_id': 'c9', 'step_index': 5, 'state': 'DONE', 'step_type': 'checkpoint'},
      {'event': 'result', 'conversation_id': 'c9', 'status': 'SUCCESS', 'response': 'Let me check.', 'duration_seconds': 9.1, 'num_turns': 1,
        'usage': {'input_tokens': 2048, 'output_tokens': 300, 'thinking_tokens': 120, 'cache_read_tokens': 1000, 'total_tokens': 3468}},
    ]);
    expect(m.plainText, 'Let me check.');
    final tools = m.parts.where((p) => p.kind == PartKind.tool).toList();
    expect(tools.map((t) => t.toolName), ['run_command', 'write_file', 'invoke_subagent']);
    expect(tools[0].toolInput, contains('npm test'));
    expect(tools[0].toolOutput, '12 passing');
    expect(tools[0].toolStatus, ToolStatus.done);
    expect(tools[1].toolStatus, ToolStatus.failed);
    expect(tools[1].toolOutput, 'denied by rule');
    final sub = m.parts.singleWhere((p) => p.kind == PartKind.subagent);
    expect(sub.toolName, 'Docs researcher');
    expect(sub.toolId, 'sub-1');
    expect(m.usage, '2.0k in · 300 out · 120 thinking · 1.0k cached');
  });

  test('cancelled and interrupted results are not errors', () {
    final m = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime(2026));
    final b = MessageBuilder(m);
    AgentStreamParser().parseLine(jsonEncode({'event': 'result', 'status': 'INTERRUPTED', 'response': ''})).forEach(b.apply);
    expect(b.resultCancelled, isTrue);
    expect(m.parts.where((p) => p.kind == PartKind.error), isEmpty);
    final m2 = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime(2026));
    final b2 = MessageBuilder(m2);
    AgentStreamParser()
        .parseLine(jsonEncode({'event': 'result', 'status': 'ERROR', 'error': 'authentication required'}))
        .forEach(b2.apply);
    expect(m2.parts.single.text, 'authentication required');
  });
}

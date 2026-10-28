import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/services/agent_stream_parser.dart';
import 'package:antigravity_mobile/services/agy_service.dart';
import 'package:antigravity_mobile/services/message_builder.dart';
import 'package:antigravity_mobile/state/chat_controller.dart';
import 'package:antigravity_mobile/ui/widgets/message_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Output recorded from the real agy 1.4.9 (`agy -p … --output-format
/// stream-json`), with its model requests answered by a local stand-in for
/// the Gemini API (`GOOGLE_GEMINI_BASE_URL`). See test/fixtures/README.md.
const _dir = 'test/fixtures/agy_1_4_9';

String _fixture(String name) => File('$_dir/$name').readAsStringSync();

({ChatMessage message, MessageBuilder builder}) _replay(String name) {
  final m = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime(2026));
  final b = MessageBuilder(m);
  final p = AgentStreamParser();
  for (final line in _fixture('$name.jsonl').split('\n')) {
    p.parseLine(line).forEach(b.apply);
  }
  b.finish(success: true);
  return (message: m, builder: b);
}

List<MessagePart> _kind(ChatMessage m, PartKind k) => m.parts.where((p) => p.kind == k).toList();

void main() {
  test('plain reply: text, conversation id and usage', () {
    final r = _replay('hello');
    expect(r.message.plainText, 'Hello! How can I help?');
    expect(_kind(r.message, PartKind.text), hasLength(1));
    expect(r.builder.conversationId, isNotNull);
    expect(r.builder.resultStatus, 'SUCCESS');
    expect(r.message.usage, contains('90 in'));
  });

  test('file written to the brain directory becomes an artifact', () {
    final r = _replay('artifact');
    final artifacts = _kind(r.message, PartKind.artifact);
    expect(artifacts, hasLength(1));
    expect(artifacts.single.toolName, 'implementation_plan.md');
    expect(artifacts.single.toolInput, contains('/.gemini/antigravity-cli/brain/'));
    final tools = _kind(r.message, PartKind.tool);
    expect(tools.single.toolName, 'write_file');
    expect(tools.single.toolStatus, ToolStatus.done);
    expect(r.message.plainText, contains('I wrote the plan artifact.'));
  });

  test('workspace edit is a tool card, not an artifact', () {
    final r = _replay('edit');
    expect(_kind(r.message, PartKind.artifact), isEmpty);
    final tool = _kind(r.message, PartKind.tool).single;
    expect(tool.toolInput, contains('/home/dev/proj/hello.txt'));
    expect(tool.toolStatus, ToolStatus.done);
    expect(madeChanges(r.message), isTrue);
  });

  test('headless soft-deny is reported through denied_actions', () {
    final r = _replay('denied');
    expect(r.builder.deniedActions, ['RunCommand (command)']);
    expect(_kind(r.message, PartKind.tool).single.toolName, 'run_command');
  });

  test('a tool step ending in ERROR is a failed tool with its message', () {
    final r = _replay('tool_error');
    final tool = _kind(r.message, PartKind.tool).single;
    expect(tool.toolStatus, ToolStatus.failed);
    expect(tool.toolOutput, contains('permission check failed'));
    expect(r.builder.deniedActions, ['ReadFile (read_file)']);
  });

  test('subagent step carries a conversation to open', () {
    final r = _replay('subagent');
    final subs = _kind(r.message, PartKind.subagent);
    expect(subs, hasLength(1));
    final info = SubagentInfo.fromJson(Map<String, dynamic>.from(
        jsonDecode(subs.single.toolInput!) as Map));
    expect(info.role, 'Codebase Researcher');
    expect(info.typeName, 'researcher');
    expect(info.conversationId, isNotNull);
    expect(info.logUri, startsWith('file:///home/dev/.gemini/antigravity-cli/brain/'));
    expect(r.message.plainText, contains('All done with subagent.'));
    // The final response repeats the streamed text; it isn't added twice.
    expect('All done with subagent.'.allMatches(r.message.plainText), hasLength(1));
  });

  test("continuing a subagent's conversation drops the replayed first turn", () {
    final r = _replay('subagent_chat');
    final texts = _kind(r.message, PartKind.text);
    expect(texts, hasLength(1));
    expect('Subagent finished'.allMatches(r.message.plainText), hasLength(1));
  });

  test('resumed stream is not mistaken for a replay', () {
    final lines = _fixture('hello.jsonl').split('\n').where((l) => !l.contains('"user_input"'));
    final m = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime(2026));
    final b = MessageBuilder(m);
    final p = AgentStreamParser(resumed: true);
    for (final l in lines) {
      p.parseLine(l).forEach(b.apply);
    }
    expect(m.plainText, 'Hello! How can I help?');
  });

  test('slash-command reports render as a table', () {
    final r = _replay('help');
    final text = r.message.plainText;
    expect(text, contains('| /usage (quota) | View model quota usage |'));
    expect(text, contains('| --- |'));
    expect(r.builder.conversationId, isNull);
  });

  test('model report parses into data and text', () {
    final report = AgyReport.parse('/model', _fixture('model.jsonl'));
    expect(report.error, isNull);
    expect(report.data?['id'], 'gemini-3.1-pro-low');
    expect(report.text, contains('Gemini 3.1 Pro (Low)'));
    final usage = AgyReport.parse('/usage', _fixture('usage.jsonl'));
    expect(usage.error, isNull);
    expect(usage.data?['groups'], isEmpty);
  });

  test('interactive-only commands fail with agy\'s explanation', () {
    final r = _replay('diff_rejected');
    expect(r.builder.resultStatus, 'ERROR');
    expect(_kind(r.message, PartKind.error).single.text, contains('not available in print mode'));
  });

  test('Stop (SIGINT) reads as cancelled, not as an error', () {
    final r = _replay('interrupted');
    expect(r.builder.resultCancelled, isTrue);
    expect(_kind(r.message, PartKind.error), isEmpty);
  });

  test('signed-out server is recognised', () {
    final r = _replay('signed_out');
    final error = _kind(r.message, PartKind.error).single.text;
    expect(needsSignIn(error), isTrue);
    expect(agyStderr('error: x\nAGY_ERROR: {"a":1}'), 'error: x');
  });

  test('agy models output lists ids', () {
    expect(
      AgyService.parseModels('Fetching available models...\n'
          'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n'
          'gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\n'),
      ['gemini-3.1-pro-high', 'gemini-3.1-pro-low'],
    );
  });

  test('artifact paths exclude agy internals', () {
    const base = '/home/dev/.gemini/antigravity-cli/brain/abc';
    expect(AgentStreamParser.isArtifactPath('$base/task.md'), isTrue);
    expect(AgentStreamParser.isArtifactPath('$base/task.md.metadata.json'), isFalse);
    expect(AgentStreamParser.isArtifactPath('$base/scratch/x.py'), isFalse);
    expect(AgentStreamParser.isArtifactPath('$base/.system_generated/logs/transcript.jsonl'), isFalse);
    expect(AgentStreamParser.isArtifactPath('/home/dev/proj/task.md'), isFalse);
    expect(AgentStreamParser.isArtifactPath(r'C:\Users\d\.gemini\antigravity-cli\brain\abc\walkthrough.md'), isTrue);
  });
}

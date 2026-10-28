import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/services/agent_stream_parser.dart';
import 'package:antigravity_mobile/services/message_builder.dart';
import 'package:antigravity_mobile/services/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// Transcripts recorded from agy 1.4.9, each a conversation's
/// `transcript_full.jsonl`; see test/fixtures/README.md.
List<TranscriptStep> _steps(String name) =>
    TranscriptStep.parseAll(File('test/fixtures/agy_1_4_9/$name.jsonl').readAsStringSync());

var _n = 0;
String _id() => 'm${_n++}';

void main() {
  test('history from a conversation continued several times', () {
    final msgs = Transcript.messages(_steps('transcript_followups'), newId: _id);
    expect(msgs.map((m) => m.role), [
      MessageRole.user, MessageRole.agent, MessageRole.user, MessageRole.agent, MessageRole.user, MessageRole.agent,
    ]);
    expect(msgs.first.plainText, 'say hi', reason: "agy's metadata around the prompt is dropped");
    expect(msgs[1].plainText, 'Hello! How can I help?');
    expect(msgs[1].usage, '90 in · 25 out · 10 cached');
    // The system note about a restart is kept, collapsed.
    final notice = msgs[3].parts.firstWhere((p) => p.kind == PartKind.notice);
    expect(notice.toolName, systemNotice);
    expect(notice.text, startsWith('[Notice] All your subagents'));
  });

  test("thinking comes from the transcript", () {
    final msgs = Transcript.messages(_steps('transcript_goal'), newId: _id);
    final thinking = msgs[1].parts.where((p) => p.kind == PartKind.thinking);
    expect(thinking, isNotEmpty);
    expect(thinking.first.text, 'The user greets me.');
    expect(msgs.first.plainText, '/goal');
  });

  test('tool calls get their full arguments and output; artifacts are found', () {
    final reply = Transcript.messages(_steps('transcript_artifact'), newId: _id)[1];
    final tool = reply.parts.firstWhere((p) => p.kind == PartKind.tool);
    expect(tool.toolName, 'write_file');
    expect(tool.toolId, 'step-2', reason: 'keyed like the live stream');
    expect(jsonDecode(tool.toolInput!)['Content'], '# Plan\n\n- step one\n');
    expect(tool.toolOutput, startsWith('Created file.'));
    expect(tool.toolStatus, ToolStatus.done);
    expect(reply.parts.where((p) => p.kind == PartKind.artifact).single.toolName, 'implementation_plan.md');
    expect(reply.plainText, 'I wrote the plan artifact.');
  });

  test('failed tool step', () {
    final tool = Transcript.messages(_steps('transcript_tool_error'), newId: _id)[1]
        .parts
        .firstWhere((p) => p.kind == PartKind.tool);
    expect(tool.toolStatus, ToolStatus.failed);
    expect(tool.toolOutput, contains('permission check failed'));
  });

  test('subagent from the transcript can be opened', () {
    final reply = Transcript.messages(_steps('transcript_subagent'), newId: _id)[1];
    final sub = reply.parts.firstWhere((p) => p.kind == PartKind.subagent);
    final info = SubagentInfo.fromJson(Map<String, dynamic>.from(jsonDecode(sub.toolInput!) as Map));
    expect(info.role, 'Codebase Researcher');
    expect(info.conversationId, '6f8026d9-a366-42f2-b82c-9df99e569e14');
    expect(info.logUri, contains('/brain/6f8026d9-a366-42f2-b82c-9df99e569e14/'));
    expect(reply.parts.where((p) => p.kind == PartKind.notice && p.toolName == systemNotice), hasLength(1));
    expect(reply.plainText, contains('All done with subagent.'));
  });

  test('a streamed reply gains thinking and tool output from the transcript', () {
    // The live stream of the same run (fixture `artifact`): no thinking, no
    // tool output.
    final m = ChatMessage(id: 'r', role: MessageRole.agent, createdAt: DateTime(2026));
    final b = MessageBuilder(m);
    final p = AgentStreamParser();
    for (final l in File('test/fixtures/agy_1_4_9/artifact.jsonl').readAsLinesSync()) {
      p.parseLine(l).forEach(b.apply);
    }
    expect(m.firstStep, 0);
    expect(m.parts.firstWhere((x) => x.kind == PartKind.tool).toolOutput, isNull);
    m.parts.add(MessagePart(kind: PartKind.notice, text: 'kept'));

    final merged = Transcript.merge(m.parts, Transcript.partsByStep(_steps('transcript_artifact')), firstStep: m.firstStep!);
    final tool = merged.firstWhere((x) => x.kind == PartKind.tool);
    expect(tool.toolOutput, startsWith('Created file.'));
    expect(merged.where((x) => x.kind == PartKind.artifact), hasLength(1));
    expect(merged.where((x) => x.kind == PartKind.text).single.text, 'I wrote the plan artifact.');
    expect(merged.last.text, 'kept');
  });

  test('steps the transcript lacks yet stay as streamed', () {
    final live = [
      MessagePart(kind: PartKind.text, text: 'one', step: 1),
      MessagePart(kind: PartKind.text, text: 'still typing', step: 3),
    ];
    final merged = Transcript.merge(live, {
      1: [
        MessagePart(kind: PartKind.thinking, text: 'hmm', step: 1),
        MessagePart(kind: PartKind.text, text: 'one', step: 1),
      ],
    }, firstStep: 0);
    expect(merged.map((p) => p.text), ['hmm', 'one', 'still typing']);
  });
}

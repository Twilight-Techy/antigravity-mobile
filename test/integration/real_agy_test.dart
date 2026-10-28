// The app's own SSH pipeline against the real agy binary.
//
// Skipped unless AGM_REAL_AGY=1 and the AGM_SSH_TEST_* variables are set
// (see ssh_integration_test.dart), with the real agy installed in the test
// user's ~/.local/bin, `modelProvider: "gemini"` in its settings.json, and
// ~/.antigravity-mobile/env exporting GEMINI_API_KEY and
// GOOGLE_GEMINI_BASE_URL. Without a Google account to spare, the base URL
// can point at a local stand-in for the Gemini API that answers prompts
// containing ARTIFACT or SUB with the matching tool calls
// (tool/mock_gemini.py, see test/fixtures/README.md). Run it on its own:
// ssh_integration_test.dart replaces ~/.antigravity-mobile/env while it
// checks the API-key setup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/models/server_profile.dart';
import 'package:antigravity_mobile/services/agent_stream_parser.dart';
import 'package:antigravity_mobile/services/agy_service.dart';
import 'package:antigravity_mobile/services/message_builder.dart';
import 'package:antigravity_mobile/services/ssh_host.dart';
import 'package:antigravity_mobile/services/transcript.dart';
import 'package:antigravity_mobile/state/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final keyPath = Platform.environment['AGM_SSH_TEST_KEY'];
  final skip = keyPath == null || Platform.environment['AGM_REAL_AGY'] != '1'
      ? 'AGM_REAL_AGY=1 and AGM_SSH_TEST_KEY not set'
      : null;

  late SshHost host;
  late AgyService agy;

  setUpAll(() async {
    if (skip != null) return;
    final profile = ServerProfile(
      id: 'it',
      name: 'it',
      host: Platform.environment['AGM_SSH_TEST_HOST'] ?? '127.0.0.1',
      port: int.parse(Platform.environment['AGM_SSH_TEST_PORT'] ?? '2222'),
      username: Platform.environment['AGM_SSH_TEST_USER'] ?? 'agmtest',
      authMethod: AuthMethod.privateKey,
    );
    host = await SshHost.connect(
      profile: profile,
      secrets: ServerSecrets(privateKey: File(keyPath!).readAsStringSync()),
      verifyHostKey: (type, fp) => fp.startsWith('SHA256:'),
    );
    agy = await AgyService.detect(host);
  });

  tearDownAll(() {
    if (skip == null) host.close();
  });

  Future<({ChatMessage message, MessageBuilder builder, RunExit exit})> send(String prompt,
      {String? conversation, List<String> extraArgs = const []}) async {
    final run = agy.createRun(
      runId: 'real-${DateTime.now().microsecondsSinceEpoch}',
      cwd: '~/project',
      prompt: prompt,
      agyArgs: [...extraArgs, if (conversation != null) ...['--conversation', conversation], '--print-timeout', '0s'],
    );
    final message = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime.now());
    final builder = MessageBuilder(message);
    final parser = AgentStreamParser();
    RunEvent? last;
    final done = run.events.forEach((e) {
      last = e;
      if (e is RunLine) parser.parseLine(e.line).forEach(builder.apply);
    });
    await run.start();
    await done.timeout(const Duration(minutes: 3));
    builder.finish(success: true);
    return (message: message, builder: builder, exit: last as RunExit);
  }

  test('detects agy and lists model ids', () async {
    expect(agy.info.agyVersion, isNotEmpty);
    final auth = await agy.checkAuth();
    expect(auth.state, AuthState.signedIn);
    expect(auth.models, isNotEmpty);
    expect(auth.models.every((m) => !m.contains('\t') && !m.contains(' ')), isTrue, reason: '${auth.models}');
  }, skip: skip);

  test('chat reply, then a follow-up in the same conversation', () async {
    final first = await send('say hi');
    expect(first.exit.code, 0);
    expect(first.message.plainText, isNotEmpty);
    final id = first.builder.conversationId;
    expect(id, isNotNull);
    final second = await send('and again', conversation: id);
    expect(second.builder.conversationId, id);
    expect(second.message.parts.where((p) => p.kind == PartKind.text), hasLength(1));
  }, skip: skip);

  test('artifact is reported and found on disk', () async {
    final r = await send('ARTIFACT please');
    final artifact = r.message.parts.singleWhere((p) => p.kind == PartKind.artifact);
    final found = await agy.findArtifacts(r.builder.conversationId!);
    expect(found.map((f) => f.path), [artifact.toolInput]);
    expect((await agy.readFile(found.single.path)).text, startsWith('# Plan'));
  }, skip: skip);

  test("subagent's conversation can be messaged", () async {
    final r = await send('SUB please');
    final sub = r.message.parts.singleWhere((p) => p.kind == PartKind.subagent);
    final info = SubagentInfo.fromJson(Map<String, dynamic>.from(jsonDecode(sub.toolInput!) as Map));
    expect(info.conversationId, isNotNull);
    final reply = await send('anything new?', conversation: info.conversationId);
    expect(reply.exit.code, 0);
    expect(reply.builder.conversationId, info.conversationId);
    expect(reply.message.parts.where((p) => p.kind == PartKind.text), hasLength(1));
  }, skip: skip);

  test('Stop cancels a running reply', () async {
    final run = agy.createRun(
      runId: 'real-cancel-${DateTime.now().microsecondsSinceEpoch}',
      cwd: '~/project',
      prompt: 'SLOW please',
      agyArgs: const ['--print-timeout', '0s'],
    );
    final message = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime.now());
    final builder = MessageBuilder(message);
    final parser = AgentStreamParser();
    RunEvent? last;
    var sawUserInput = false;
    final done = run.events.forEach((e) {
      last = e;
      if (e is RunLine) {
        if (e.line.contains('"user_input"')) sawUserInput = true;
        parser.parseLine(e.line).forEach(builder.apply);
      }
    });
    // start() completes when the run does, like in the app.
    unawaited(run.start());
    for (var i = 0; i < 100 && !sawUserInput; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(sawUserInput, isTrue);
    final started = DateTime.now();
    await run.cancel();
    await done.timeout(const Duration(seconds: 30));
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 15)));
    final exit = last as RunExit;
    // agy reports SIGINT as status ERROR with the error "interrupted".
    expect(builder.resultCancelled, isTrue, reason: 'status ${builder.resultStatus}, code ${exit.code}');
    expect(message.plainText, isNot(contains('Finally done.')));
  }, skip: skip);

  test('one history: CLI and desktop-app conversations are listed, read and continued', () async {
    // A conversation started in the CLI, and one in the desktop app's store
    // (what the Antigravity desktop app on that machine writes to).
    Future<String> startIn(List<String> store, String prompt) async {
      final r = await agy.runAgy([...store, '-p', prompt, '--output-format', 'stream-json'],
          timeout: const Duration(minutes: 2));
      final result = r.stdout.split('\n').lastWhere((l) => l.contains('"event":"result"'));
      return (jsonDecode(result)['result'] as Map)['conversation_id'] as String;
    }

    final cliId = await startIn(const [], 'hello from the cli');
    final deskId = await startIn(ChatController.storeArgs(ServerConversation.desktopStore), 'hello from the desktop');

    final listed = await agy.listConversations();
    final cli = listed.singleWhere((c) => c.id == cliId);
    final desk = listed.singleWhere((c) => c.id == deskId);
    expect(cli.store, ServerConversation.cliStore);
    expect(desk.isDesktop, isTrue);
    expect(desk.workspace, isNotNull);

    // History, thinking included, from the transcript.
    final chunk = await agy.readTranscript(desk.store, deskId, 0);
    final history = Transcript.messages(TranscriptStep.parseAll(chunk.text), newId: () => 'x');
    expect(history.first.plainText, 'hello from the desktop');
    expect(history[1].parts.where((p) => p.kind == PartKind.thinking), isNotEmpty);

    // Continue it from the phone, in its own store.
    final reply = await send('and from the phone',
        conversation: deskId, extraArgs: ChatController.storeArgs(desk.store));
    expect(reply.exit.code, 0);
    expect(reply.builder.conversationId, deskId);
    final after = await agy.readTranscript(desk.store, deskId, chunk.nextOffset);
    final added = TranscriptStep.parseAll(after.text);
    expect(added.where((s) => s.type == 'USER_INPUT').map((s) => Transcript.userText(s.content)), ['and from the phone']);

    // A streamed reply gains its thinking from the transcript.
    final firstStep = reply.message.firstStep!;
    final merged = Transcript.merge(reply.message.parts, Transcript.partsByStep(added), firstStep: firstStep);
    expect(merged.where((p) => p.kind == PartKind.thinking), isNotEmpty);
  }, skip: skip);

  test('headless reports: usage, effort, model', () async {
    final usage = await agy.report('/usage');
    expect(usage.error, isNull);
    expect(usage.data, contains('groups'));
    final effort = await agy.report('/effort');
    expect(effort.data?['available'], isA<List>());
    final model = await agy.report('/model');
    expect(model.data?['id'], isNotNull);
    final diff = await agy.report('/diff');
    expect(diff.error, contains('print mode'));
  }, skip: skip);
}

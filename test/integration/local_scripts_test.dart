// The app's server scripts, run on this machine: POSIX sh on Linux and
// macOS, PowerShell on Windows (CI runs this on a Windows runner).
//
// Skipped unless AGM_FAKE_AGY points at tool/fake_agy.dart compiled with
// `dart compile exe`. A temporary home folder (with a space in its name)
// gets that fake agy in ~/.local/bin and a copy of an agy 1.4.9 store
// (test/fixtures/agy_1_4_9/store).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/services/agent_stream_parser.dart';
import 'package:antigravity_mobile/services/agy_service.dart';
import 'package:antigravity_mobile/services/message_builder.dart';
import 'package:antigravity_mobile/services/remote_host.dart';
import 'package:antigravity_mobile/services/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/local_host.dart';

void main() {
  final fake = Platform.environment['AGM_FAKE_AGY'];
  final skip = fake == null ? 'AGM_FAKE_AGY not set' : null;
  final windows = Platform.isWindows;
  final sep = Platform.pathSeparator;

  late Directory home;
  late Directory project;
  late Map<String, String> env;
  late File sleepFile;

  void copyTree(Directory from, Directory to) {
    for (final e in from.listSync(recursive: true)) {
      final rel = e.path.substring(from.path.length + 1);
      if (e is File) {
        File('${to.path}$sep$rel')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(e.readAsBytesSync());
      }
    }
  }

  setUpAll(() {
    if (fake == null) return;
    home = Directory.systemTemp.createTempSync('agm home ');
    final bin = Directory('${home.path}$sep.local${sep}bin')..createSync(recursive: true);
    File(fake).copySync('${bin.path}${sep}agy${windows ? '.exe' : ''}');
    if (!windows) Process.runSync('chmod', ['+x', '${bin.path}/agy']);
    sleepFile = File('${bin.path}${sep}fake_sleep');
    project = Directory('${home.path}${sep}my project')..createSync();
    copyTree(Directory('test${sep}fixtures${sep}agy_1_4_9${sep}store'), Directory('${home.path}$sep.gemini'));
    env = windows ? {'USERPROFILE': home.path} : {'HOME': home.path, 'PATH': '/usr/bin:/bin'};
  });

  tearDownAll(() {
    if (fake != null) home.deleteSync(recursive: true);
  });

  Future<AgyService> service({String Function(String)? rewrite}) =>
      AgyService.detect(LocalHost(environment: env, rewrite: rewrite));

  ({ChatMessage message, MessageBuilder builder, Stream<RunEvent> events}) watch(AgentRun run) {
    final m = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime.now());
    final b = MessageBuilder(m);
    final p = AgentStreamParser();
    final events = run.events.map((e) {
      if (e is RunLine) p.parseLine(e.line).forEach(b.apply);
      return e;
    }).asBroadcastStream();
    return (message: m, builder: b, events: events);
  }

  test('detects the server and agy', () async {
    final agy = await service();
    expect(agy.scripts.isWindows, windows);
    expect(agy.info.agyInstalled, isTrue);
    expect((await agy.checkAuth()).models, ['gemini-3-pro']);
  }, skip: skip);

  test('a reply streams, with the prompt passed exactly', () async {
    sleepFile.writeAsStringSync('0.2');
    final agy = await service();
    const prompt = 'Fix "quotes" & \$vars `ticks` \'single\' \\back\\slash %PATH% ^caret\nsecond line ✓';
    final run = agy.createRun(runId: 'local-${DateTime.now().microsecondsSinceEpoch}', cwd: project.path, prompt: prompt, agyArgs: const ['--print-timeout', '0s']);
    final w = watch(run);
    final last = w.events.last;
    await run.start();
    final exit = await last.timeout(const Duration(minutes: 1));
    expect(exit, isA<RunExit>());
    expect((exit as RunExit).code, 0);
    expect(w.message.plainText, 'You said: $prompt');
    expect(w.builder.conversationId, 'conv-123');
  }, skip: skip);

  test('a run outlives its follower and is resumed from where it stopped', () async {
    sleepFile.writeAsStringSync('4');
    final agy = await service();
    final runId = 'local-resume-${DateTime.now().microsecondsSinceEpoch}';
    final run = agy.createRun(runId: runId, cwd: project.path, prompt: 'keep going', agyArgs: const []);
    final w = watch(run);
    final firstLines = Completer<int>();
    var offset = 0;
    unawaited(w.events.forEach((e) {
      if (e is RunLine) {
        offset = e.offset;
        if (e.line.contains('You said: ') && !firstLines.isCompleted) firstLines.complete(offset);
      }
    }));
    unawaited(run.start());
    await firstLines.future.timeout(const Duration(seconds: 30));
    run.detach();

    // The connection is gone; agy keeps working on the server.
    await Future<void>.delayed(const Duration(seconds: 1));
    final again = agy.createRun(runId: runId, cwd: project.path, prompt: '', agyArgs: const []);
    expect(again.resumable, isTrue);
    final rest = <String>[];
    final last = again.events.map((e) {
      if (e is RunLine) rest.add(e.line);
      return e;
    }).last;
    unawaited(again.resume(offset));
    final exit = await last.timeout(const Duration(seconds: 40));
    expect(exit, isA<RunExit>());
    expect((exit as RunExit).code, 0);
    expect(rest.first, contains('keep going'), reason: 'resumed right after what was already read');
    expect(rest.last, contains('"event":"result"'));
  }, skip: skip);

  test('Stop ends the run', () async {
    sleepFile.writeAsStringSync('30');
    final agy = await service();
    final run = agy.createRun(runId: 'local-stop-${DateTime.now().microsecondsSinceEpoch}', cwd: project.path, prompt: 'slow', agyArgs: const []);
    final w = watch(run);
    final started = Completer<void>();
    final last = w.events.map((e) {
      if (e is RunLine && !started.isCompleted) started.complete();
      return e;
    }).last;
    unawaited(run.start());
    await started.future.timeout(const Duration(seconds: 30));
    final t = DateTime.now();
    await run.cancel();
    final exit = await last.timeout(const Duration(seconds: 30));
    expect(DateTime.now().difference(t), lessThan(const Duration(seconds: 20)));
    expect((exit as RunExit).code, 130);
    expect(w.message.plainText, isNot(contains('slow')));
  }, skip: skip);

  group('conversation list', () {
    late Map<String, String> expected;
    setUpAll(() {
      if (fake == null) return;
      expected = Map<String, String>.from(
          jsonDecode(File('test${sep}fixtures${sep}agy_1_4_9${sep}store_expected.json').readAsStringSync()) as Map);
    });

    Future<void> check(String Function(String)? rewrite, {required bool titles}) async {
      final agy = await service(rewrite: rewrite);
      final list = await agy.listConversations();
      expect(list, isNotEmpty);
      var withFolder = 0;
      for (final c in list) {
        final uri = expected['${c.store}/${c.id}'];
        expect(uri, isNotNull, reason: '${c.store}/${c.id} is in the fixture');
        if (c.workspace != null) {
          withFolder++;
          expect(c.workspace, Uri.parse(uri!).toFilePath(windows: windows));
        }
      }
      expect(withFolder, list.length, reason: 'every conversation is placed in its folder');
      expect(list.where((c) => c.isDesktop), isNotEmpty);
      if (titles) expect(list.where((c) => c.title.isNotEmpty), isNotEmpty);
    }

    test('read with the default tools', () => check(null, titles: !windows), skip: skip);

    test('without python3', () => check((c) => c.replaceFirst('command -v python3', 'false'), titles: true),
        skip: skip ?? (windows ? 'POSIX only' : null) ??
            (Process.runSync('sh', ['-c', 'command -v sqlite3']).exitCode == 0 ? null : 'sqlite3 not installed'));

    test('without python3 or sqlite3', () async {
      await check(
          (c) => c.replaceFirst('command -v python3', 'false').replaceFirst('command -v sqlite3', 'false'),
          titles: false);
    }, skip: skip ?? (windows ? 'POSIX only' : null));
  });

  test('a terminal session outlives its connection', () async {
    final agy = await service();
    // The first time, the ConPTY helper is compiled on the server.
    expect(await agy.ensurePtyHelper(), isTrue);
    final command = agy.scripts.terminal(
        cwd: project.path, runAgy: true, agyArgs: const [], tmuxSession: 'agm-test-${DateTime.now().millisecondsSinceEpoch}');
    final ansi = RegExp(r'\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[()=>][0-9A-Za-z]?)');
    Future<(RemoteProcess, StringBuffer)> attach() async {
      final p = await agy.host.start(command);
      final out = StringBuffer();
      p.stdout.listen((d) => out.write(utf8.decode(d, allowMalformed: true)));
      p.stderr.listen((d) => out.write(utf8.decode(d, allowMalformed: true)));
      return (p, out);
    }

    Future<void> waitFor(StringBuffer out, String text, {int seconds = 30}) async {
      for (var i = 0; i < seconds * 10; i++) {
        if (out.toString().replaceAll(ansi, '').contains(text)) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final log = File('${home.path}$sep.antigravity-mobile${sep}agmpty.log');
      fail('"$text" not in: ${out.toString().replaceAll(ansi, '')}'
          '${log.existsSync() ? '\nhost log: ${log.readAsStringSync()}' : ''}');
    }

    final (first, out1) = await attach();
    await waitFor(out1, 'interactive fake agy', seconds: 60);
    first.write(utf8.encode('hello\r'));
    await waitFor(out1, 'got hello');

    // The connection drops; the session keeps running on the server.
    first.close();
    await Future<void>.delayed(const Duration(seconds: 2));
    final (second, out2) = await attach();
    await waitFor(out2, 'got hello', seconds: 60);
    second.write(utf8.encode('again\r'));
    await waitFor(out2, 'got again');

    // When the program ends, the attached session ends too.
    second.write(utf8.encode('exit\r'));
    expect(await second.exitCode.timeout(const Duration(seconds: 30)), isNotNull);
  }, timeout: const Timeout(Duration(minutes: 5)), skip: skip ?? (windows ? null : 'Windows only (tmux is covered over SSH)'));

  test('reads a transcript in chunks', () async {
    final agy = await service();
    const id = 'c08d4fc2-2939-4dcc-aa07-a1a80d5ce702';
    final first = await agy.readTranscript('antigravity-cli', id, 0, maxBytes: 1000);
    expect(first.size, greaterThan(1000));
    var steps = TranscriptStep.parseAll(first.text);
    var offset = first.nextOffset;
    while (offset < first.size) {
      final next = await agy.readTranscript('antigravity-cli', id, offset);
      steps = [...steps, ...TranscriptStep.parseAll(next.text)];
      if (next.nextOffset == offset) break;
      offset = next.nextOffset;
    }
    expect(steps.map((s) => s.index), List.generate(8, (i) => i));
    expect(Transcript.messages(steps, newId: () => 'x').first.plainText, 'say hi');
  }, skip: skip);
}

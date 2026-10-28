// End-to-end checks of the remote scripts against a real SSH server.
//
// Skipped unless AGM_SSH_TEST_KEY points at a private key that can log in to
// AGM_SSH_TEST_USER@AGM_SSH_TEST_HOST:AGM_SSH_TEST_PORT, where a (fake or
// real) `agy` lives in ~/.local/bin and ~/project is a git repo with a
// modified readme.md and an untracked new.txt. See tool/fake_agy.sh.
import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/models/conversation.dart';
import 'package:antigravity_mobile/models/server_profile.dart';
import 'package:antigravity_mobile/services/agent_stream_parser.dart';
import 'package:antigravity_mobile/services/agy_service.dart';
import 'package:antigravity_mobile/services/message_builder.dart';
import 'package:antigravity_mobile/services/remote_scripts.dart';
import 'package:antigravity_mobile/services/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final keyPath = Platform.environment['AGM_SSH_TEST_KEY'];
  final skip = keyPath == null ? 'AGM_SSH_TEST_KEY not set' : null;

  late SshHost host;
  late AgyService agy;

  setUpAll(() async {
    if (keyPath == null) return;
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
      secrets: ServerSecrets(privateKey: File(keyPath).readAsStringSync()),
      verifyHostKey: (type, fp) => fp.startsWith('SHA256:'),
    );
    agy = await AgyService.detect(host);
  });

  tearDownAll(() {
    if (keyPath != null) host.close();
  });

  test('detects a POSIX host with agy installed', () {
    expect(agy.scripts.isWindows, isFalse);
    expect(agy.info.os.name, 'linux');
    expect(agy.info.agyInstalled, isTrue);
    expect(agy.info.agyVersion, contains('1.2.4'));
    expect(agy.info.hasGit, isTrue);
  }, skip: skip);

  test('auth check lists models', () async {
    final auth = await agy.checkAuth();
    expect(auth.state, AuthState.signedIn);
    expect(auth.models, ['gemini-3-pro', 'gemini-3-flash']);
  }, skip: skip);

  test('lists directories and reads files', () async {
    final listing = await agy.listDir('~/project');
    expect(listing.path, endsWith('/project'));
    final names = listing.entries.map((e) => e.name).toList();
    expect(names, containsAll(['.git', 'readme.md', 'new.txt']));
    expect(listing.entries.first.isDir, isTrue);

    final file = await agy.readFile('${listing.path}/readme.md');
    expect(file.text, startsWith('hello'));
    expect(file.isBinary, isFalse);

    final made = await agy.makeDir("~/scratch dir/it's here");
    expect(made, endsWith("/scratch dir/it's here"));
  }, skip: skip);

  test('reads git status and diffs', () async {
    final status = await agy.gitStatus('~/project');
    expect(status, isNotNull);
    final byPath = {for (final f in status!.files) f.path: f};
    expect(byPath['readme.md']!.change, GitChange.modified);
    expect(byPath['new.txt']!.change, GitChange.untracked);
    expect(await agy.gitDiff('~/project', byPath['readme.md']!), contains('+change'));
    expect(await agy.gitDiff('~/project', byPath['new.txt']!), contains('+new'));
    expect(await agy.gitStatus('/tmp'), isNull);
  }, skip: skip);

  test('runs a prompt and streams structured events', () async {
    final prompt = r'''Fix "quotes" & $vars `ticks` 'single' \back\slash
and a second line ✓''';
    final run = agy.createRun(
      runId: 'it-${DateTime.now().microsecondsSinceEpoch}',
      cwd: '~/project',
      prompt: prompt,
      agyArgs: const ['--mode', 'accept-edits'],
    );
    final message = ChatMessage(id: 'm', role: MessageRole.agent, createdAt: DateTime.now());
    final builder = MessageBuilder(message);
    final parser = AgentStreamParser();
    RunEvent? last;
    var offset = 0;
    final done = run.events.forEach((e) {
      last = e;
      if (e is RunLine) {
        offset = e.offset;
        parser.parseLine(e.line).forEach(builder.apply);
      }
    });
    await run.start();
    await done;
    expect(last, isA<RunExit>());
    expect((last as RunExit).code, 0);
    expect(builder.conversationId, 'conv-123');
    expect(message.plainText, contains('You said: $prompt'));
    final tool = message.parts.firstWhere((p) => p.kind == PartKind.tool);
    expect(tool.toolName, 'run_command');
    expect(tool.toolOutput, contains('readme.md'));
    expect(message.usage, '1.2k in · 34 out');
    expect(offset, greaterThan(100));
  }, skip: skip);

  test('resumes a detached run from an offset after detaching', () async {
    await host.run("sh -c 'echo 3 > \$HOME/.fake_sleep'");
    addTearDown(() => host.run("sh -c 'rm -f \$HOME/.fake_sleep'"));
    final runId = 'it-resume-${DateTime.now().microsecondsSinceEpoch}';
    final run = agy.createRun(runId: runId, cwd: '~/project', prompt: 'hi', agyArgs: const []);
    final lines = <String>[];
    var offset = 0;
    RunEvent? last;
    final done = run.events.forEach((e) {
      last = e;
      if (e is RunLine) {
        lines.add(e.line);
        offset = e.offset;
        if (e.line.contains('tool_call')) run.detach();
      }
    });
    await run.start();
    await done;
    expect(last, isA<RunLost>());
    expect((last as RunLost).resumable, isTrue);
    expect(lines.last, contains('tool_call'));

    final resumed = agy.createRun(runId: runId, cwd: '~/project', prompt: 'hi', agyArgs: const []);
    final more = <String>[];
    RunEvent? end;
    final done2 = resumed.events.forEach((e) {
      end = e;
      if (e is RunLine) more.add(e.line);
    });
    await resumed.resume(offset);
    await done2;
    expect(end, isA<RunExit>());
    expect(more.first, contains('tool_result'));
    expect(more.last, contains('"result"'));
  }, skip: skip);

  test('cancels a running prompt', () async {
    await host.run("sh -c 'echo 20 > \$HOME/.fake_sleep'");
    addTearDown(() => host.run("sh -c 'rm -f \$HOME/.fake_sleep'"));
    final run = agy.createRun(
        runId: 'it-cancel-${DateTime.now().microsecondsSinceEpoch}',
        cwd: '~/project',
        prompt: 'slow',
        agyArgs: const []);
    RunEvent? last;
    final sw = Stopwatch()..start();
    final done = run.events.forEach((e) {
      last = e;
      if (e is RunLine && e.line.contains('tool_call')) run.cancel();
    });
    await run.start();
    await done;
    expect(last, isA<RunExit>());
    expect((last as RunExit).code, isNot(0));
    expect(sw.elapsed.inSeconds, lessThan(15));
  }, skip: skip);

  test('the server pings ntfy and the push relay when a run ends', () async {
    // Stand-in curl that records its arguments and any piped body.
    const fakeCurl = '#!/bin/sh\n'
        '{ printf "ARGS:"; printf " %s" "\$@"; printf "\\n";\n'
        '  case "\$*" in *@-*) printf "STDIN:"; cat; printf "\\n";; esac; } >> "\$HOME/curl.log"\n';
    await host.runWithInput("sh -c 'cat > \$HOME/.local/bin/curl; chmod +x \$HOME/.local/bin/curl; rm -f \$HOME/curl.log'", fakeCurl);
    addTearDown(() => host.run("sh -c 'rm -f \$HOME/.local/bin/curl \$HOME/curl.log \$HOME/.antigravity-mobile/push'"));

    await agy.registerPush('https://relay.example.dev', 'key-ONE_1');
    await agy.registerPush('https://relay.example.dev', 'key-two');
    await agy.registerPush('https://relay.example.dev', 'key-two', remove: true);
    final push = await host.run("sh -c 'stat -c %a \$HOME/.antigravity-mobile/push; cat \$HOME/.antigravity-mobile/push'");
    expect(push.stdout.trim().split('\n'), ['600', 'https://relay.example.dev\tkey-ONE_1']);

    const link = 'antigravity://open?server=s1&conversation=c%22q';
    final run = agy.createRun(
      runId: 'it-notify-${DateTime.now().microsecondsSinceEpoch}',
      cwd: '~/project',
      prompt: 'hi',
      agyArgs: const [],
      notify: const RunNotify(workspaceName: 'my "proj"', link: link, ntfyUrl: 'https://ntfy.sh/agm-test'),
    );
    RunEvent? last;
    final done = run.events.forEach((e) => last = e);
    await run.start();
    await done;
    expect((last as RunExit).code, 0);
    String log = '';
    for (var i = 0; i < 25 && !log.contains('STDIN:'); i++) {
      log = (await host.run("sh -c 'cat \$HOME/curl.log 2>/dev/null'")).stdout;
      if (!log.contains('STDIN:')) await Future.delayed(const Duration(milliseconds: 200));
    }
    // ntfy: message plus a click link that opens the conversation.
    expect(log, contains('https://ntfy.sh/agm-test'));
    expect(log, contains('Click: $link'));
    expect(log, contains('Agent finished in my "proj"'));
    // Relay: valid JSON with this phone's key.
    expect(log, contains('https://relay.example.dev/send'));
    final body = log.split('\n').firstWhere((l) => l.startsWith('STDIN:')).substring(6);
    final json = jsonDecode(body) as Map;
    expect(json['key'], 'key-ONE_1');
    expect(json['title'], 'Agent finished in my "proj"');
    expect(json['link'], link);
    expect(log, isNot(contains(' hi ')), reason: 'the prompt is never sent');
  }, skip: skip);

  test('stores the API key via stdin in a private file', () async {
    await agy.setApiKey('AIza-test_key.123');
    final r = await host.run(
        "sh -c 'stat -c %a \$HOME/.antigravity-mobile/env; . \$HOME/.antigravity-mobile/env; echo key=\$GEMINI_API_KEY'");
    expect(r.stdout, contains('600'));
    expect(r.stdout, contains('key=AIza-test_key.123'));
    expect((await agy.readSettings())['modelProvider'], 'gemini');
    // The key never appears in a command line.
    expect(agy.scripts.saveApiKey(), isNot(contains('AIza')));

    await agy.setApiKey(null);
    final gone = await host.run("sh -c 'test -f \$HOME/.antigravity-mobile/env && echo yes || echo no'");
    expect(gone.stdout.trim(), 'no');
    expect((await agy.readSettings()).containsKey('modelProvider'), isFalse);
    expect(() => agy.setApiKey("bad'key"), throwsArgumentError);
  }, skip: skip);

  test('opens an interactive PTY running agy', () async {
    final pty = await host.startPty(
      agy.scripts.terminal(cwd: '~/project', runAgy: true, agyArgs: const [], tmuxSession: null),
      columns: 100,
      rows: 30,
    );
    final out = StringBuffer();
    final sub = pty.stdout.listen((d) => out.write(String.fromCharCodes(d)));
    await Future.delayed(const Duration(seconds: 1));
    pty.write('ping\r'.codeUnits);
    await pty.exitCode.timeout(const Duration(seconds: 10));
    await sub.cancel();
    expect(out.toString(), contains('interactive fake agy'));
    expect(out.toString(), contains('got ping'));
  }, skip: skip);
}

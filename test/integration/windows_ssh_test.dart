// The Windows server scripts over a real SSH connection to Windows OpenSSH.
//
// Skipped unless AGM_WIN_SSH_KEY points at a private key that can log in to
// AGM_WIN_SSH_USER@127.0.0.1:22 on a Windows machine whose
// %USERPROFILE%\.local\bin\agy.exe is tool/fake_agy.dart, compiled. CI sets
// this up on a Windows runner (see .github/workflows/build.yml).
//
// This is what the local script tests can't show: that work survives the SSH
// session ending (Windows OpenSSH ends a session's processes with it), and
// that the terminal session works through a real pseudoconsole.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antigravity_mobile/models/server_profile.dart';
import 'package:antigravity_mobile/services/agy_service.dart';
import 'package:antigravity_mobile/services/remote_host.dart';
import 'package:antigravity_mobile/services/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final keyPath = Platform.environment['AGM_WIN_SSH_KEY'];
  final skip = keyPath == null ? 'AGM_WIN_SSH_KEY not set' : null;

  Future<AgyService> connect() async {
    final host = await SshHost.connect(
      profile: ServerProfile(
        id: 'win',
        name: 'win',
        host: '127.0.0.1',
        username: Platform.environment['AGM_WIN_SSH_USER'] ?? 'runneradmin',
        authMethod: AuthMethod.privateKey,
      ),
      secrets: ServerSecrets(privateKey: File(keyPath!).readAsStringSync()),
      verifyHostKey: (type, fp) => fp.startsWith('SHA256:'),
    );
    return AgyService.detect(host);
  }

  final ansi = RegExp(r'\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[()=>][0-9A-Za-z]?)');

  Future<void> waitFor(StringBuffer out, String text, {int seconds = 30, String Function()? extra}) async {
    for (var i = 0; i < seconds * 10; i++) {
      if (out.toString().replaceAll(ansi, '').contains(text)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('"$text" not in: ${out.toString().replaceAll(ansi, '')}${extra?.call() ?? ''}');
  }

  String hostLog() {
    final log = File('${Platform.environment['USERPROFILE']}\\.antigravity-mobile\\agmpty.log');
    return log.existsSync() ? '\nhost log: ${log.readAsStringSync()}' : '';
  }

  test('a reply keeps running when the SSH session ends, and is resumed', () async {
    final sleep = File('${Platform.environment['USERPROFILE']}\\.local\\bin\\fake_sleep')..writeAsStringSync('6');
    addTearDown(() => sleep.writeAsStringSync('0.3'));

    final agy = await connect();
    expect(agy.scripts.isWindows, isTrue);
    final runId = 'win-ssh-${DateTime.now().microsecondsSinceEpoch}';
    final run = agy.createRun(runId: runId, cwd: '~', prompt: 'survive', agyArgs: const []);
    var offset = 0;
    final firstLine = Completer<void>();
    unawaited(run.events.forEach((e) {
      if (e is RunLine) {
        offset = e.offset;
        if (e.line.contains('You said: ') && !firstLine.isCompleted) firstLine.complete();
      }
    }));
    unawaited(run.start());
    await firstLine.future.timeout(const Duration(seconds: 60));
    // The whole SSH connection goes away, as when the phone loses signal.
    agy.host.close();
    await Future<void>.delayed(const Duration(seconds: 2));

    final again = await connect();
    final resumed = again.createRun(runId: runId, cwd: '~', prompt: '', agyArgs: const []);
    final lines = <String>[];
    final last = resumed.events.map((e) {
      if (e is RunLine) lines.add(e.line);
      return e;
    }).last;
    unawaited(resumed.resume(offset));
    final exit = await last.timeout(const Duration(seconds: 60));
    again.host.close();
    expect(exit, isA<RunExit>());
    expect((exit as RunExit).code, 0, reason: exit.stderr);
    expect(lines.join('\n'), contains('survive'));
    expect(lines.last, contains('"event":"result"'));
  }, timeout: const Timeout(Duration(minutes: 4)), skip: skip);

  test('the terminal session survives the SSH session ending', () async {
    var agy = await connect();
    expect(await agy.ensurePtyHelper(), isTrue, reason: agy.ptyHelperError);
    File('${Platform.environment['USERPROFILE']}\\.antigravity-mobile\\agmpty.trace').writeAsStringSync('');
    final command = agy.scripts.terminal(
        cwd: '~', runAgy: true, agyArgs: const [], tmuxSession: 'agm-ssh-${DateTime.now().millisecondsSinceEpoch}');

    Future<(RemotePty, StringBuffer)> attach(AgyService agy) async {
      final pty = await agy.host.startPty(command, columns: 100, rows: 30);
      final out = StringBuffer();
      pty.stdout.listen((d) => out.write(utf8.decode(d, allowMalformed: true)));
      pty.stderr.listen((d) => out.write(utf8.decode(d, allowMalformed: true)));
      return (pty, out);
    }

    final (first, out1) = await attach(agy);
    await waitFor(out1, 'interactive fake agy', seconds: 60, extra: hostLog);
    first.write(utf8.encode('hello\r'));
    await waitFor(out1, 'got hello', extra: hostLog);

    // The connection drops entirely; the session stays on the server.
    agy.host.close();
    await Future<void>.delayed(const Duration(seconds: 3));
    agy = await connect();
    expect(await agy.ensurePtyHelper(), isTrue);
    final (second, out2) = await attach(agy);
    await waitFor(out2, 'got hello', seconds: 60, extra: hostLog);
    second.write(utf8.encode('again\r'));
    await waitFor(out2, 'got again', extra: hostLog);

    second.write(utf8.encode('exit\r'));
    await second.exitCode.timeout(const Duration(seconds: 30));
    agy.host.close();
  }, timeout: const Timeout(Duration(minutes: 5)), skip: skip);
}

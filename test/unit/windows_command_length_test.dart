import 'dart:convert';

import 'package:antigravity_mobile/services/remote_scripts.dart';
import 'package:antigravity_mobile/services/windows_pty.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows OpenSSH runs commands through cmd.exe, which takes at most 8191
/// characters; the scripts are compressed to fit.
void main() {
  const s = PowerShellScripts();
  const limit = 8191;
  final longPrompt = List.filled(400, 'Refactor the parser and keep the tests green. ').join();

  final commands = {
    'probe': s.probe(),
    'startRun': s.startRun(
      runId: '1793197475244907-abcdef12',
      cwd: r'C:\Users\dev\Projects\a rather long project folder name',
      prompt: longPrompt,
      agyArgs: const ['--mode', 'plan', '--conversation', '0c0c117b-090a-499b-821e-6894bc56b013', '--print-timeout', '0s'],
      notify: const RunNotify(
        workspaceName: 'project',
        link: 'antigravity://open?server=abc&conversation=def',
        ntfyUrl: 'https://ntfy.sh/agm-topic',
      ),
    ),
    'followRun': s.followRun('1793197475244907-abcdef12', 123456),
    'cancelRun': s.cancelRun('1793197475244907-abcdef12'),
    'listConversations': s.listConversations(),
    'readTranscript': s.readTranscript('antigravity-cli', '0c0c117b-090a-499b-821e-6894bc56b013', 0, 2 << 20),
    'installPtyHelper': s.installPtyHelper(),
    'writePtyChunk': s.writePtyChunk(1, base64.encode(utf8.encode(windowsPtySource)).substring(0, 6000)),
    'terminal (persistent)': s.terminal(cwd: '~/project', runAgy: true, agyArgs: const ['--conversation', 'x'], tmuxSession: 'agm-project-1x2y'),
    'terminal': s.terminal(cwd: '~/project', runAgy: false, agyArgs: const []),
    'saveApiKey': s.saveApiKey(),
  };

  for (final e in commands.entries) {
    test('${e.key} fits on a cmd.exe command line', () {
      expect(e.value.length, lessThan(limit), reason: '${e.key}: ${e.value.length} characters');
    });
  }

  test('the prompt goes on stdin, not the command line', () {
    expect(s.startRunInput(prompt: longPrompt, agyArgs: const []), contains('Refactor the parser'));
    expect(commands['startRun'], isNot(contains('Refactor')));
  });
}

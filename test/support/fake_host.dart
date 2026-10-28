import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antigravity_mobile/services/remote_host.dart';
import 'package:antigravity_mobile/services/remote_scripts.dart';

/// An in-memory POSIX "server" that recognises the scripts the app sends and
/// answers like a VPS with agy installed would.
class FakeHost implements RemoteHost {
  FakeHost({this.agyInstalled = true, this.signedIn = true});

  bool agyInstalled;
  bool signedIn;
  final List<String> commands = [];
  final _done = Completer<void>();
  bool _closed = false;

  /// Lines the fake agent streams for each prompt.
  List<String> Function(String prompt) agentOutput = (prompt) => [
        jsonEncode({'type': 'system', 'subtype': 'init', 'conversation_id': 'conv-1'}),
        jsonEncode({'type': 'text_delta', 'delta': 'Sure! Looking at the project.'}),
        jsonEncode({'type': 'tool_call', 'id': 't1', 'name': 'run_command', 'input': {'command': 'ls -la'}}),
        jsonEncode({'type': 'tool_result', 'id': 't1', 'output': 'lib\npubspec.yaml'}),
        jsonEncode({'type': 'text_delta', 'delta': 'It is a **Flutter** app.'}),
        jsonEncode({'type': 'result', 'status': 'SUCCESS', 'conversation_id': 'conv-1', 'response': 'It is a **Flutter** app.'}),
      ];

  String _script(String command) {
    const prefix = "sh -c '";
    if (!command.startsWith(prefix)) return command;
    return command.substring(prefix.length, command.length - 1).replaceAll(r"'\''", "'");
  }

  CommandResult _answer(String script) {
    if (script.contains('-type d -name')) {
      return const CommandResult(0, '120\t/home/dev/.gemini/antigravity/brain/conv-1/task.md\n', '');
    }
    if (script.contains('echo "os=')) {
      return CommandResult(0, [
        'os=Linux',
        'arch=x86_64',
        'home=/home/dev',
        'shell=/bin/bash',
        'agy=${agyInstalled ? '/home/dev/.local/bin/agy' : ''}',
        'version=${agyInstalled ? 'agy 1.2.4' : ''}',
        'tmux=/usr/bin/tmux',
        'git=/usr/bin/git',
        'curl=/usr/bin/curl',
        'sudo=0',
      ].join('\n'), '');
    }
    if (script.contains('agy models')) {
      return signedIn
          ? const CommandResult(0, 'Available models:\n  gemini-3-pro\n  gemini-3-flash\n', '')
          : const CommandResult(1, 'You are currently not signed in.', '');
    }
    if (script.contains('started=')) {
      final id = RegExp(r'echo "started=([^"]+)"').firstMatch(script)!.group(1);
      return CommandResult(0, 'started=$id\n', '');
    }
    if (script.contains('-printf')) {
      if (script.contains('project')) {
        return const CommandResult(0, '/home/dev/project\nd\t4096\tlib\nf\t120\tpubspec.yaml\nf\t30\tREADME.md\n', '');
      }
      return const CommandResult(0, '/home/dev\nd\t4096\tproject\nd\t4096\t.cache\nf\t10\tnotes.txt\n', '');
    }
    if (script.contains('head -c')) {
      return CommandResult(0, '18\n${base64.encode(utf8.encode('void main() {}\n//'))}\n', '');
    }
    if (script.contains('--porcelain')) {
      return const CommandResult(0, '## main\n M lib/main.dart\n?? notes.md\n', '');
    }
    if (script.contains("'diff'")) {
      return const CommandResult(0, 'diff --git a/lib/main.dart b/lib/main.dart\n@@ -1 +1 @@\n-old\n+new\n', '');
    }
    if (script.contains('settings.json')) return const CommandResult(0, '', '');
    if (script.contains('kill -INT')) return const CommandResult(0, '', '');
    if (script.contains('echo ok')) return const CommandResult(0, 'ok', '');
    return const CommandResult(0, '', '');
  }

  String? _lastPrompt;

  @override
  Future<CommandResult> run(String command, {Duration? timeout}) async {
    commands.add(command);
    final script = _script(command);
    if (script.contains('started=')) {
      final b64 = RegExp(r"printf %s '([^']+)' \| b64d").firstMatch(script)?.group(1);
      _lastPrompt = b64 == null ? '' : utf8.decode(base64.decode(b64));
    }
    return _answer(script);
  }

  final Map<String, String> stdinFor = {};

  @override
  Future<CommandResult> runWithInput(String command, String input, {Duration? timeout}) async {
    commands.add(command);
    stdinFor[command] = input;
    return const CommandResult(0, '', '');
  }

  @override
  Future<RemoteProcess> start(String command) async {
    commands.add(command);
    final script = _script(command);
    if (script.contains('tail -c')) {
      final lines = agentOutput(_lastPrompt ?? '');
      return FakeProcess.scripted(
        stdout: lines.map((l) => '$l\n').toList(),
        stderr: ['${exitMarker}0\n'],
      );
    }
    if (script.contains('install.sh')) {
      agyInstalled = true;
      return FakeProcess.scripted(stdout: ['Downloading agy…\n', 'Installed: agy 1.2.4\n'], stderr: const []);
    }
    final r = _answer(script);
    return FakeProcess.scripted(stdout: [r.stdout], stderr: [r.stderr], exitCode: r.exitCode);
  }

  FakePty? lastPty;

  @override
  Future<RemotePty> startPty(String command, {int columns = 80, int rows = 24}) async {
    commands.add(command);
    return lastPty = FakePty();
  }

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _done.complete();
  }
}

class FakeProcess implements RemoteProcess {
  FakeProcess.scripted({required List<String> stdout, required List<String> stderr, int exitCode = 0}) {
    scheduleMicrotask(() async {
      for (final s in stdout) {
        if (s.isNotEmpty) _out.add(Uint8List.fromList(utf8.encode(s)));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final s in stderr) {
        if (s.isNotEmpty) _err.add(Uint8List.fromList(utf8.encode(s)));
      }
      await _out.close();
      await _err.close();
      _exit.complete(exitCode);
    });
  }

  final _out = StreamController<Uint8List>();
  final _err = StreamController<Uint8List>();
  final _exit = Completer<int?>();

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => _err.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(List<int> data) {}

  @override
  void close() {}
}

class FakePty implements RemotePty {
  final _out = StreamController<Uint8List>();
  final _err = StreamController<Uint8List>();
  final _exit = Completer<int?>();
  final written = <String>[];

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => _err.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(List<int> data) {
    final s = utf8.decode(data);
    written.add(s);
    _out.add(Uint8List.fromList(utf8.encode(s)));
  }

  @override
  void resize(int columns, int rows) {}

  @override
  void close() {
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

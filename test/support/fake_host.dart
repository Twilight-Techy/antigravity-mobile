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
  /// Lines the fake agent streams for each prompt, in agy's documented
  /// headless stream-json format.
  List<String> Function(String prompt) agentOutput = (prompt) => [
        jsonEncode({'event': 'init', 'init': {'cwd': '/home/dev/project', 'permission_mode': 'request-review'}}),
        jsonEncode({'event': 'step_update', 'step_update': {'conversation_id': 'conv-1', 'step_index': 0, 'state': 'DONE', 'step_type': 'user_input'}}),
        jsonEncode({'event': 'step_update', 'step_update': {'conversation_id': 'conv-1', 'step_index': 1, 'state': 'ACTIVE', 'step_type': 'agent_response', 'text_delta': 'Sure! Looking at the project.'}}),
        jsonEncode({'event': 'step_update', 'step_update': {'conversation_id': 'conv-1', 'step_index': 1, 'state': 'DONE', 'step_type': 'agent_response'}}),
        jsonEncode({'event': 'step_update', 'step_update': {'conversation_id': 'conv-1', 'step_index': 2, 'state': 'ACTIVE', 'step_type': 'tool', 'tool_name': 'run_command', 'tool_info': {'name': 'run_command', 'parameters': {'command': 'ls -la'}}}}),
        jsonEncode({'event': 'step_update', 'step_update': {'conversation_id': 'conv-1', 'step_index': 2, 'state': 'DONE', 'step_type': 'tool', 'tool_name': 'run_command', 'tool_info': {'name': 'run_command', 'parameters': {'command': 'ls -la'}, 'output': 'lib\npubspec.yaml'}}}),
        jsonEncode({'event': 'step_update', 'step_update': {'conversation_id': 'conv-1', 'step_index': 3, 'state': 'ACTIVE', 'step_type': 'agent_response', 'text_delta': 'It is a **Flutter** app.'}}),
        jsonEncode({'event': 'result', 'result': {'conversation_id': 'conv-1', 'status': 'SUCCESS', 'response': 'Sure! Looking at the project.It is a **Flutter** app.', 'usage': {'input_tokens': 900, 'output_tokens': 40}}}),
      ];

  /// Extra stderr the agent prints (e.g. soft-denied tool notices).
  List<String> agentStderr = const [];

  /// Last settings.json written by the app.
  String? writtenSettings;

  String _script(String command) {
    const prefix = "sh -c '";
    if (!command.startsWith(prefix)) return command;
    return command.substring(prefix.length, command.length - 1).replaceAll(r"'\''", "'");
  }

  CommandResult _answer(String script) {
    if (script.contains('metadata.json')) {
      return const CommandResult(0, '120\t/home/dev/.gemini/antigravity-cli/brain/conv-1/task.md\n', '');
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
    if (script.contains("agy 'agents'")) return const CommandResult(0, 'reviewer\ndocs-writer\n', '');
    if (script.contains('settings.json') && script.contains('b64d')) {
      final b64 = RegExp(r"printf %s '([^']+)' \| b64d").firstMatch(script)?.group(1);
      if (b64 != null) writtenSettings = utf8.decode(base64.decode(b64));
      return const CommandResult(0, '', '');
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
        stderr: [for (final l in agentStderr) '$l\n', '${exitMarker}0\n'],
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

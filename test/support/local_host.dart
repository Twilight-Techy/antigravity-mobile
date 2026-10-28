import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antigravity_mobile/services/remote_host.dart';

/// Runs the app's scripts on this machine instead of over SSH: `sh -c …`
/// on Linux and macOS, `powershell … -EncodedCommand …` on Windows.
/// [rewrite] lets a test alter a script first (e.g. hide python3).
class LocalHost implements RemoteHost {
  LocalHost({this.environment = const {}, this.rewrite});

  final Map<String, String> environment;
  final String Function(String command)? rewrite;
  final _done = Completer<void>();

  @override
  Future<RemoteProcess> start(String command) async {
    command = rewrite?.call(command) ?? command;
    final Process p;
    if (command.startsWith('powershell ')) {
      // `powershell <flags> -Command "<script>"`; the script has no double
      // quotes, so Dart's own quoting passes it through unchanged.
      final i = command.indexOf(' -Command "');
      final flags = command.substring(11, i).split(' ').where((f) => f.isNotEmpty);
      final script = command.substring(i + 11, command.length - 1);
      p = await Process.start('powershell', [...flags, '-Command', script], environment: environment);
    } else {
      p = await Process.start('/bin/sh', ['-c', command], environment: environment);
    }
    return _LocalProcess(p);
  }

  @override
  Future<CommandResult> run(String command, {Duration? timeout}) async =>
      collect(await start(command), timeout: timeout);

  @override
  Future<CommandResult> runWithInput(String command, String input, {Duration? timeout}) async {
    final p = await start(command);
    p.write(utf8.encode(input));
    (p as _LocalProcess).closeStdin();
    return collect(p, timeout: timeout);
  }

  @override
  Future<RemotePty> startPty(String command, {int columns = 80, int rows = 24}) =>
      throw UnsupportedError('No PTY in local script tests');

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _done.isCompleted;

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}

class _LocalProcess implements RemoteProcess {
  _LocalProcess(this._p);
  final Process _p;

  @override
  Stream<Uint8List> get stdout => _p.stdout.map(Uint8List.fromList);

  @override
  Stream<Uint8List> get stderr => _p.stderr.map(Uint8List.fromList);

  @override
  Future<int?> get exitCode => _p.exitCode;

  @override
  void write(List<int> data) => _p.stdin.add(data);

  void closeStdin() => unawaited(_p.stdin.close());

  @override
  void close() => _p.kill();
}

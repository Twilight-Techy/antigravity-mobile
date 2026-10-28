import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class CommandResult {
  const CommandResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  String get combined =>
      [stdout.trim(), stderr.trim()].where((s) => s.isNotEmpty).join('\n');
}

class RemoteCommandException implements Exception {
  RemoteCommandException(this.message, [this.result]);

  final String message;
  final CommandResult? result;

  @override
  String toString() {
    final detail = result?.combined;
    return detail == null || detail.isEmpty ? message : '$message\n$detail';
  }
}

/// A long-running remote process whose output is streamed.
abstract class RemoteProcess {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;

  /// Completes with the exit code, or null if the channel closed without one.
  Future<int?> get exitCode;

  void write(List<int> data);

  /// Closes the channel. The remote process may keep running unless it was
  /// started with a PTY.
  void close();
}

/// An interactive process attached to a pseudo-terminal.
abstract class RemotePty extends RemoteProcess {
  void resize(int columns, int rows);
}

/// The thin transport the rest of the app talks to. The real implementation
/// is backed by dartssh2; tests use an in-memory fake.
abstract class RemoteHost {
  /// Runs [command] (already wrapped for the remote shell) to completion.
  Future<CommandResult> run(String command, {Duration? timeout});

  /// Runs [command] with [input] written to its stdin (then EOF). Used for
  /// secrets so they never appear in a process list.
  Future<CommandResult> runWithInput(String command, String input, {Duration? timeout});

  /// Starts [command] and streams its output.
  Future<RemoteProcess> start(String command);

  /// Starts [command] attached to a PTY of the given size.
  Future<RemotePty> startPty(String command, {int columns = 80, int rows = 24});

  /// Completes when the underlying connection closes.
  Future<void> get done;

  bool get isClosed;

  void close();
}

/// Decodes a byte stream into lines, tolerating UTF-8 sequences that are
/// split across chunks.
Stream<String> decodeLines(Stream<List<int>> bytes) => bytes
    .cast<List<int>>()
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter());

/// Collects a process' output into a [CommandResult].
Future<CommandResult> collect(RemoteProcess process, {Duration? timeout}) async {
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  final outDone = process.stdout.forEach(out.add);
  final errDone = process.stderr.forEach(err.add);
  Future<int?> exit = process.exitCode;
  if (timeout != null) {
    exit = exit.timeout(timeout, onTimeout: () {
      process.close();
      return 124;
    });
  }
  final code = await exit;
  await Future.wait([outDone, errDone])
      .timeout(const Duration(seconds: 2), onTimeout: () => const []);
  return CommandResult(
    code ?? -1,
    utf8.decode(out.takeBytes(), allowMalformed: true),
    utf8.decode(err.takeBytes(), allowMalformed: true),
  );
}

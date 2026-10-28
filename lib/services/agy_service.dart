import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'remote_host.dart';
import 'remote_scripts.dart';

class HostInfo {
  const HostInfo({
    required this.os,
    required this.osName,
    required this.arch,
    required this.home,
    this.shell,
    this.agyPath,
    this.agyVersion,
    this.hasTmux = false,
    this.hasGit = false,
    this.canSudo = false,
    this.hasDownloader = true,
  });

  final RemoteOs os;
  final String osName;
  final String arch;
  final String home;
  final String? shell;
  final String? agyPath;
  final String? agyVersion;
  final bool hasTmux;
  final bool hasGit;
  final bool canSudo;
  final bool hasDownloader;

  bool get agyInstalled => agyPath != null && agyPath!.isNotEmpty;

  factory HostInfo.fromProbe(Map<String, String> p) {
    final osName = p['os'] ?? '';
    final lower = osName.toLowerCase();
    final os = lower.contains('linux')
        ? RemoteOs.linux
        : lower.contains('darwin')
            ? RemoteOs.macos
            : lower.contains('windows')
                ? RemoteOs.windows
                : RemoteOs.other;
    String? nonEmpty(String? v) => v == null || v.isEmpty ? null : v;
    return HostInfo(
      os: os,
      osName: osName,
      arch: p['arch'] ?? '',
      home: p['home'] ?? '~',
      shell: nonEmpty(p['shell']),
      agyPath: nonEmpty(p['agy']),
      agyVersion: nonEmpty(p['version']),
      hasTmux: nonEmpty(p['tmux']) != null,
      hasGit: nonEmpty(p['git']) != null,
      canSudo: p['sudo'] == '1',
      hasDownloader:
          nonEmpty(p['curl']) != null || nonEmpty(p['wget']) != null,
    );
  }
}

enum AuthState { signedIn, signedOut, unknown }

class AuthCheck {
  const AuthCheck(this.state, {this.models = const [], this.detail = ''});
  final AuthState state;
  final List<String> models;
  final String detail;
}

class DirEntry {
  const DirEntry({required this.name, required this.path, required this.isDir, this.size = 0, this.isLink = false});
  final String name;
  final String path;
  final bool isDir;
  final bool isLink;
  final int size;
}

class DirListing {
  const DirListing(this.path, this.entries);
  final String path;
  final List<DirEntry> entries;
}

class FileContent {
  const FileContent({required this.path, required this.size, required this.bytes});
  final String path;
  final int size;
  final Uint8List bytes;

  bool get truncated => bytes.length < size;

  bool get isBinary {
    final n = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  String get text => utf8.decode(bytes, allowMalformed: true);
}

enum GitChange { modified, added, deleted, renamed, untracked, conflicted, other }

class GitFile {
  const GitFile(this.path, this.change, {this.staged = false, this.code = ''});
  final String path;
  final GitChange change;
  final bool staged;
  final String code;
}

class GitStatus {
  const GitStatus({this.branch, this.ahead = 0, this.behind = 0, this.files = const []});
  final String? branch;
  final int ahead;
  final int behind;
  final List<GitFile> files;

  static GitStatus parse(String porcelain) {
    String? branch;
    var ahead = 0;
    var behind = 0;
    final files = <GitFile>[];
    for (final line in const LineSplitter().convert(porcelain)) {
      if (line.startsWith('## ')) {
        final head = line.substring(3);
        final dots = head.indexOf('...');
        final space = head.indexOf(' ');
        if (head.startsWith('No commits yet on ')) {
          branch = head.substring('No commits yet on '.length);
        } else {
          branch = head.substring(
              0, dots >= 0 ? dots : (space >= 0 ? space : head.length));
        }
        final a = RegExp(r'ahead (\d+)').firstMatch(head);
        final b = RegExp(r'behind (\d+)').firstMatch(head);
        if (a != null) ahead = int.parse(a.group(1)!);
        if (b != null) behind = int.parse(b.group(1)!);
        continue;
      }
      if (line.length < 4) continue;
      final x = line[0];
      final y = line[1];
      var path = line.substring(3);
      final arrow = path.indexOf(' -> ');
      if (arrow >= 0) path = path.substring(arrow + 4);
      if (path.startsWith('"') && path.endsWith('"')) {
        path = path.substring(1, path.length - 1);
      }
      final code = '$x$y';
      GitChange change;
      if (code == '??') {
        change = GitChange.untracked;
      } else if (x == 'U' || y == 'U' || code == 'AA' || code == 'DD') {
        change = GitChange.conflicted;
      } else if (x == 'R' || y == 'R') {
        change = GitChange.renamed;
      } else if (x == 'A' || y == 'A') {
        change = GitChange.added;
      } else if (x == 'D' || y == 'D') {
        change = GitChange.deleted;
      } else if (x == 'M' || y == 'M') {
        change = GitChange.modified;
      } else {
        change = GitChange.other;
      }
      files.add(GitFile(path, change, staged: x != ' ' && x != '?', code: code));
    }
    return GitStatus(branch: branch, ahead: ahead, behind: behind, files: files);
  }
}

/// High-level operations against the VPS: setup checks, the file browser,
/// git, and headless agent runs.
class AgyService {
  AgyService(this.host, this.scripts, this.info);

  final RemoteHost host;
  final RemoteScripts scripts;
  HostInfo info;

  /// Detects the remote shell dialect and gathers [HostInfo].
  static Future<AgyService> detect(RemoteHost host) async {
    const posix = PosixScripts();
    try {
      final r = await host.run(posix.probe(), timeout: const Duration(seconds: 20));
      final p = parseProbe(r.stdout);
      final os = (p['os'] ?? '').toLowerCase();
      if (r.ok && os.isNotEmpty && !os.startsWith('mingw') && !os.startsWith('msys') && !os.startsWith('cygwin')) {
        return AgyService(host, posix, HostInfo.fromProbe(p));
      }
    } catch (_) {}
    const ps = PowerShellScripts();
    final r = await host.run(ps.probe(), timeout: const Duration(seconds: 30));
    final p = parseProbe(r.stdout);
    if (!r.ok || p['os'] == null) {
      throw RemoteCommandException(
          'Could not detect the remote operating system. A POSIX shell (Linux/macOS) or PowerShell (Windows) is required.',
          r);
    }
    return AgyService(host, ps, HostInfo.fromProbe(p));
  }

  Future<HostInfo> refreshInfo() async {
    final r = await host.run(scripts.probe(), timeout: const Duration(seconds: 30));
    info = HostInfo.fromProbe(parseProbe(r.stdout));
    return info;
  }

  /// Runs [command], forwarding output lines to [onLine] as they arrive.
  Future<int> stream(String command, void Function(String line) onLine) async {
    final process = await host.start(command);
    final subs = [
      decodeLines(process.stdout).listen(onLine),
      decodeLines(process.stderr).listen(onLine),
    ];
    final code = await process.exitCode;
    await Future.delayed(const Duration(milliseconds: 200));
    for (final s in subs) {
      await s.cancel();
    }
    return code ?? -1;
  }

  Future<int> installAgy(void Function(String line) onLine) =>
      stream(scripts.installAgy(), onLine);

  Future<int> installTmux(void Function(String line) onLine) =>
      stream(scripts.installTmux(), onLine);

  Future<AuthCheck> checkAuth() async {
    final CommandResult r;
    try {
      r = await host.run(scripts.listModels(),
          timeout: const Duration(seconds: 45));
    } catch (e) {
      return AuthCheck(AuthState.unknown, detail: e.toString());
    }
    final out = r.combined;
    final lower = out.toLowerCase();
    final looksSignedOut = lower.contains('not signed in') ||
        lower.contains('sign in') ||
        lower.contains('signin') ||
        lower.contains('log in') ||
        lower.contains('login') ||
        lower.contains('unauthenticated') ||
        lower.contains('authenticate') ||
        lower.contains('oauth') ||
        lower.contains('credentials');
    if (r.exitCode == 124) {
      return AuthCheck(AuthState.signedOut,
          detail: 'agy did not answer in time; it is probably waiting for an interactive sign-in.');
    }
    if (r.ok && !looksSignedOut) {
      return AuthCheck(AuthState.signedIn, models: parseModels(out), detail: out);
    }
    if (looksSignedOut) return AuthCheck(AuthState.signedOut, detail: out);
    return AuthCheck(AuthState.unknown, detail: out);
  }

  /// Extracts model names from `agy models` output, ignoring headers, table
  /// borders and bullets.
  static List<String> parseModels(String output) {
    final models = <String>[];
    for (var line in const LineSplitter().convert(output)) {
      line = line.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trim();
      if (line.isEmpty) continue;
      // Table borders and rules (ASCII or box-drawing characters).
      if (RegExp(r'^[-=+|:\u2500-\u257F]+$').hasMatch(line.replaceAll(' ', ''))) continue;
      line = line.replaceFirst(RegExp(r'^([*•\-–>]|\d+[.)])\s+'), '');
      line = line.replaceAll('│', '|');
      if (line.contains('|')) {
        final cells = line.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
        if (cells.isEmpty) continue;
        line = cells.first;
      }
      line = line.replaceAll(RegExp(r'\s*\((default|current|active)\)\s*$', caseSensitive: false), '');
      final lower = line.toLowerCase();
      if (lower.endsWith(':') ||
          lower.startsWith('available models') ||
          lower == 'models' ||
          lower == 'model' ||
          lower == 'name' ||
          lower.startsWith('notice') ||
          lower.startsWith('warning') ||
          lower.startsWith('usage')) {
        continue;
      }
      if (line.length > 80) continue;
      if (!models.contains(line)) models.add(line);
    }
    return models;
  }

  Future<Map<String, dynamic>> readSettings() async {
    final r = await host.run(scripts.readAgySettings());
    final text = r.stdout.trim();
    if (text.isEmpty) return {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> writeSettings(Map<String, dynamic> settings) async {
    final r = await host.run(scripts.writeAgySettings(
        const JsonEncoder.withIndent('  ').convert(settings)));
    if (!r.ok) throw RemoteCommandException('Could not write agy settings.', r);
  }

  /// Switches agy between Google sign-in and a Gemini API key. The key is
  /// sent over stdin and stored in a file only the user can read.
  Future<void> setApiKey(String? key) async {
    if (key != null && !RegExp(r'^[A-Za-z0-9_\-.]+$').hasMatch(key)) {
      throw ArgumentError('That does not look like an API key.');
    }
    final settings = await readSettings();
    if (key != null) {
      final r = await host.runWithInput(scripts.saveApiKey(), key);
      if (!r.ok) throw RemoteCommandException('Could not save the API key.', r);
      if (settings['modelProvider'] == 'gemini') return;
      settings['modelProvider'] = 'gemini';
    } else {
      await host.run(scripts.clearApiKey());
      if (settings.remove('modelProvider') == null) return;
    }
    await writeSettings(settings);
  }

  Future<DirListing> listDir(String path) async {
    final r = await host.run(scripts.listDir(path), timeout: const Duration(seconds: 30));
    if (!r.ok) throw RemoteCommandException('Could not open $path', r);
    final lines = const LineSplitter().convert(r.stdout);
    if (lines.isEmpty) throw RemoteCommandException('Empty listing for $path', r);
    final resolved = lines.first.trim();
    final entries = <DirEntry>[];
    for (final line in lines.skip(1)) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      final name = parts.sublist(2).join('\t');
      if (name.isEmpty || name == '.' || name == '..') continue;
      entries.add(DirEntry(
        name: name,
        path: scripts.joinPath(resolved, name),
        isDir: parts[0] == 'd',
        isLink: parts[0] == 'l',
        size: int.tryParse(parts[1]) ?? 0,
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return DirListing(resolved, entries);
  }

  Future<FileContent> readFile(String path, {int maxBytes = 512 * 1024}) async {
    final r = await host.run(scripts.readFile(path, maxBytes), timeout: const Duration(seconds: 60));
    if (!r.ok) throw RemoteCommandException('Could not read $path', r);
    final lines = const LineSplitter().convert(r.stdout);
    if (lines.isEmpty) throw RemoteCommandException('Empty response for $path', r);
    final size = int.tryParse(lines.first.trim()) ?? 0;
    final b64 = lines.skip(1).join().replaceAll(RegExp(r'\s'), '');
    return FileContent(path: path, size: size, bytes: base64.decode(b64));
  }

  Future<String> makeDir(String path) async {
    final r = await host.run(scripts.makeDir(path));
    if (!r.ok) throw RemoteCommandException('Could not create $path', r);
    final lines = const LineSplitter().convert(r.stdout.trim());
    return lines.isEmpty ? path : lines.last.trim();
  }

  /// Returns null when [cwd] is not inside a git repository.
  Future<GitStatus?> gitStatus(String cwd) async {
    final r = await host.run(scripts.git(cwd, ['status', '--porcelain=v1', '-b', '-uall']),
        timeout: const Duration(seconds: 30));
    if (!r.ok) {
      if (r.combined.toLowerCase().contains('not a git repository')) return null;
      throw RemoteCommandException('git status failed', r);
    }
    return GitStatus.parse(r.stdout);
  }

  Future<String> gitDiff(String cwd, GitFile file) async {
    if (file.change == GitChange.untracked) {
      final r = await host.run(scripts.gitDiffUntracked(cwd, file.path));
      return r.stdout;
    }
    var r = await host.run(scripts.git(cwd, ['diff', '--no-color', 'HEAD', '--', file.path]));
    if (!r.ok) {
      // No commits yet: show what is staged.
      r = await host.run(scripts.git(cwd, ['diff', '--no-color', '--cached', '--', file.path]));
    }
    return r.stdout;
  }

  Future<CommandResult> git(String cwd, List<String> args) =>
      host.run(scripts.git(cwd, args), timeout: const Duration(seconds: 60));

  AgentRun createRun({
    required String runId,
    required String cwd,
    required String prompt,
    required List<String> agyArgs,
    NtfyPing? notify,
  }) =>
      AgentRun(
        service: this,
        runId: runId,
        cwd: cwd,
        prompt: prompt,
        agyArgs: agyArgs,
        notify: notify,
      );
}

sealed class RunEvent {
  const RunEvent();
}

/// One complete output line; [offset] is the byte offset just after it.
class RunLine extends RunEvent {
  const RunLine(this.line, this.offset);
  final String line;
  final int offset;
}

class RunExit extends RunEvent {
  const RunExit(this.code, this.stderr);
  final int code;
  final String stderr;
}

/// The stream ended without an exit code (connection dropped). For POSIX
/// hosts the run keeps going on the server and can be resumed.
class RunLost extends RunEvent {
  const RunLost(this.reason, {required this.resumable});
  final String reason;
  final bool resumable;
}

/// A headless `agy -p` run. On POSIX hosts the agent runs detached under
/// nohup, so [resume] can pick the output back up after a reconnect.
class AgentRun {
  AgentRun({
    required this.service,
    required this.runId,
    required this.cwd,
    required this.prompt,
    required this.agyArgs,
    this.notify,
  });

  final AgyService service;
  final NtfyPing? notify;
  final String runId;
  final String cwd;
  final String prompt;
  final List<String> agyArgs;

  final _events = StreamController<RunEvent>.broadcast();
  Stream<RunEvent> get events => _events.stream;

  RemoteProcess? _process;
  bool _cancelled = false;
  bool _finished = false;

  bool get resumable => !service.scripts.isWindows;

  Future<void> start() async {
    final scripts = service.scripts;
    final command = scripts.startRun(
      runId: runId,
      cwd: cwd,
      prompt: prompt,
      agyArgs: agyArgs,
      notify: notify,
    );
    if (scripts.isWindows) {
      await _follow(command, 0);
      return;
    }
    final r = await service.host.run(command, timeout: const Duration(seconds: 30));
    if (!r.ok || !r.stdout.contains('started=')) {
      _finish(RunExit(r.exitCode == 0 ? 1 : r.exitCode, r.combined));
      return;
    }
    await _follow(scripts.followRun(runId, 0), 0);
  }

  /// Re-attaches to a detached run from byte [offset].
  Future<void> resume(int offset) async {
    if (!resumable) {
      _finish(const RunLost('This run cannot be resumed on Windows.', resumable: false));
      return;
    }
    await _follow(service.scripts.followRun(runId, offset), offset);
  }

  Future<void> _follow(String command, int startOffset) async {
    final RemoteProcess process;
    try {
      process = await service.host.start(command);
    } catch (e) {
      _finish(RunLost(e.toString(), resumable: resumable));
      return;
    }
    _process = process;
    var offset = startOffset;
    final pending = <int>[];
    final stderr = StringBuffer();
    int? exitCode;

    final outDone = process.stdout.forEach((chunk) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] == 10) {
          pending.addAll(chunk.sublist(start, i));
          offset += pending.length + 1;
          var line = utf8.decode(pending, allowMalformed: true);
          if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
          pending.clear();
          if (!_finished) _events.add(RunLine(line, offset));
          start = i + 1;
        }
      }
      pending.addAll(chunk.sublist(start));
    });
    final errDone = decodeLines(process.stderr).forEach((line) {
      if (line.startsWith(exitMarker)) {
        exitCode = int.tryParse(line.substring(exitMarker.length).trim()) ?? 1;
      } else {
        stderr.writeln(line);
      }
    });

    final channelCode = await process.exitCode;
    await Future.wait([outDone, errDone])
        .timeout(const Duration(seconds: 3), onTimeout: () => const []);
    _process = null;

    if (pending.isNotEmpty && exitCode != null) {
      final line = utf8.decode(pending, allowMalformed: true);
      offset += pending.length;
      if (!_finished) _events.add(RunLine(line, offset));
    }

    if (_cancelled) {
      _finish(RunExit(exitCode ?? 130, stderr.toString()));
    } else if (exitCode != null) {
      _finish(RunExit(exitCode!, stderr.toString()));
    } else if (service.scripts.isWindows && channelCode != null) {
      _finish(RunExit(channelCode, stderr.toString()));
    } else {
      _finish(RunLost(
          stderr.isEmpty ? 'Connection to the server was lost.' : stderr.toString(),
          resumable: resumable));
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    try {
      await service.host.run(service.scripts.cancelRun(runId),
          timeout: const Duration(seconds: 15));
    } catch (_) {}
    if (service.scripts.isWindows) _process?.close();
  }

  /// Stops streaming locally without touching the remote run. The run can be
  /// picked up again with [resume] on a new [AgentRun].
  void detach() {
    _process?.close();
    _finish(RunLost('Detached from the run.', resumable: resumable));
  }

  void _finish(RunEvent event) {
    if (_finished) return;
    _finished = true;
    if (!_events.isClosed) {
      _events.add(event);
      _events.close();
    }
  }
}

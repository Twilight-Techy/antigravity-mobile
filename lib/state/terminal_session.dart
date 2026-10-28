import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../services/remote_host.dart';
import 'session_state.dart';

enum TerminalMode { agy, shell }

/// The interactive terminal tab: a real VT emulator wired to a PTY running
/// `agy` (or a shell), inside tmux when available so it survives reconnects.
class TerminalSession extends ChangeNotifier {
  TerminalSession(this.session) {
    terminal = Terminal(
      maxLines: 5000,
      onOutput: _onTerminalInput,
      onResize: (w, h, pw, ph) {
        _columns = w;
        _rows = h;
        _pty?.resize(w, h);
      },
      onTitleChange: (t) {
        title = t;
        _notify();
      },
    );
    _lastGeneration = session.generation;
    session.addListener(_onSessionChanged);
  }

  final SessionState session;
  late final Terminal terminal;

  RemotePty? _pty;
  StreamSubscription<String>? _out;
  int _columns = 80;
  int _rows = 24;
  int _lastGeneration = 0;
  bool _disposed = false;

  TerminalMode? _mode;
  TerminalMode? get mode => _mode;
  List<String> _extraArgs = const [];

  /// Folder the running terminal was started in.
  String? _dir;
  bool _persist = true;

  bool get running => _pty != null;
  bool _starting = false;
  bool get starting => _starting;
  String? title;
  String? error;

  /// Recently seen URLs, e.g. the Google sign-in link, newest first.
  final List<String> urls = [];
  final _ansi = RegExp(r'\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[()][0-9A-Za-z]|[=>78])');
  final _url = RegExp(r'https?://[^\s"<>\x00-\x1F]+');
  String _urlTail = '';

  /// Name of the tmux session for this server + workspace.
  String? get tmuxSessionName {
    if (!session.profile.useTmux || session.agy?.scripts.isWindows == true) return null;
    final ws = session.workspace ?? 'home';
    final base = ws.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? 'home';
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final hash = ws.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0xfffff).toRadixString(36);
    return 'agm-${safe.length > 20 ? safe.substring(0, 20) : safe}-$hash';
  }

  /// Starts the terminal. [persist] keeps agy in tmux across disconnects;
  /// one-off sessions such as sign-in pass false.
  Future<void> start({
    TerminalMode mode = TerminalMode.agy,
    List<String> extraArgs = const [],
    bool persist = true,
  }) async {
    final agy = session.agy;
    if (agy == null || !session.isConnected || _starting) return;
    _starting = true;
    error = null;
    _notify();
    await _closePty();
    _mode = mode;
    _dir = session.workspace;
    _extraArgs = extraArgs;
    _persist = persist;
    final command = agy.scripts.terminal(
      cwd: session.workspace ?? '~',
      runAgy: mode == TerminalMode.agy,
      agyArgs: [...session.profile.agentOptions.toInteractiveArgs(), ...extraArgs],
      tmuxSession: mode == TerminalMode.agy && persist ? tmuxSessionName : null,
    );
    try {
      final pty = await agy.host.startPty(command, columns: _columns, rows: _rows);
      _pty = pty;
      final decoder = const Utf8Decoder(allowMalformed: true);
      _out = pty.stdout.cast<List<int>>().transform(decoder).listen((data) {
        terminal.write(data);
        _scanUrls(data);
      });
      pty.stderr.cast<List<int>>().transform(decoder).listen(terminal.write);
      unawaited(pty.exitCode.then((_) => _onExit(pty)));
    } catch (e) {
      error = e.toString();
    } finally {
      _starting = false;
      _notify();
    }
  }

  /// Starts agy with an interactive slash command, e.g. `/config`.
  Future<void> runSlashCommand(String command) async {
    if (!running || _mode != TerminalMode.agy) {
      await start();
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    sendText('$command\r');
  }

  void sendText(String text) => _pty?.write(utf8.encode(text));

  void _onTerminalInput(String data) => _pty?.write(utf8.encode(data));

  void _scanUrls(String data) {
    final clean = (_urlTail + data).replaceAll(_ansi, '');
    _urlTail = clean.length > 300 ? clean.substring(clean.length - 300) : clean;
    var changed = false;
    for (final m in _url.allMatches(clean)) {
      var url = m.group(0)!;
      url = url.replaceAll(RegExp(r'[.,;:)\]]+$'), '');
      if (url.length < 12) continue;
      // A longer version of a URL we saw truncated at a chunk boundary.
      urls.removeWhere((u) => url.startsWith(u) || u == url);
      urls.insert(0, url);
      changed = true;
    }
    if (urls.length > 5) urls.removeRange(5, urls.length);
    if (changed) _notify();
  }

  void dismissUrls() {
    urls.clear();
    _notify();
  }

  void _onExit(RemotePty pty) {
    if (_pty != pty) return;
    _pty = null;
    _out?.cancel();
    _out = null;
    terminal.write('\r\n\x1b[2m[session ended]\x1b[0m\r\n');
    _notify();
  }

  void _onSessionChanged() {
    // Switched to a chat in another folder: leave the old session (tmux
    // keeps it on the server) and offer to start one here.
    if (_dir != null && session.workspace != null && session.workspace != _dir) {
      _dir = null;
      _mode = null;
      terminal.write('\x1b[2J\x1b[H');
      unawaited(stop());
      return;
    }
    if (session.generation != _lastGeneration) {
      _lastGeneration = session.generation;
      // Reconnected: re-attach (tmux keeps agy alive on the server).
      if (_mode != null) {
        terminal.write('\r\n\x1b[2m[reconnecting…]\x1b[0m\r\n');
        unawaited(start(mode: _mode!, extraArgs: _extraArgs, persist: _persist));
      }
    }
  }

  Future<void> stop() async {
    await _closePty();
    _notify();
  }

  Future<void> _closePty() async {
    final pty = _pty;
    _pty = null;
    await _out?.cancel();
    _out = null;
    pty?.close();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSessionChanged);
    _pty?.close();
    _out?.cancel();
    super.dispose();
  }
}

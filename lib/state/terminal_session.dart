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
  String _urlTail = '';

  /// agy conversation the terminal was opened on, if any, and the agy
  /// store it lives in (null for the CLI's own).
  String? _conversationId;
  String? get conversationId => _conversationId;
  String? _appDataDir;

  /// Name of the tmux session for this server + workspace (and agy
  /// conversation, when the terminal continues a chat).
  String? get tmuxSessionName {
    // On Windows servers a ConPTY host stands in for tmux.
    if (!session.profile.useTmux) return null;
    final ws = '${session.workspace ?? 'home'}${_conversationId == null ? '' : '#$_conversationId'}';
    final base = ws.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? 'home';
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final hash = ws.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0xfffff).toRadixString(36);
    return 'agm-${safe.length > 20 ? safe.substring(0, 20) : safe}-$hash';
  }

  /// Starts the terminal. [persist] keeps agy in tmux across disconnects;
  /// one-off sessions such as sign-in pass false.
  ///
  /// With [conversationId] agy resumes that conversation, so its subagents,
  /// background tasks and artifacts are the chat's own.
  Future<void> start({
    TerminalMode mode = TerminalMode.agy,
    List<String> extraArgs = const [],
    bool persist = true,
    String? conversationId,
    String? appDataDir,
  }) async {
    final agy = session.agy;
    if (agy == null || !session.isConnected || _starting) return;
    _starting = true;
    error = null;
    _notify();
    await _closePty();
    _mode = mode;
    _conversationId = mode == TerminalMode.agy ? conversationId : null;
    _appDataDir = mode == TerminalMode.agy ? appDataDir : null;
    _dir = session.workspace;
    _extraArgs = extraArgs;
    _persist = persist;
    var tmuxSession = mode == TerminalMode.agy && persist ? tmuxSessionName : null;
    if (tmuxSession != null && !await agy.ensurePtyHelper()) tmuxSession = null;
    final command = agy.scripts.terminal(
      cwd: session.workspace ?? '~',
      runAgy: mode == TerminalMode.agy,
      agyArgs: [
        if (_appDataDir != null && _appDataDir != 'antigravity-cli') '--app_data_dir=$_appDataDir',
        ...session.profile.agentOptions.toInteractiveArgs(),
        if (_conversationId != null) ...['--conversation', _conversationId!],
        ...extraArgs,
      ],
      tmuxSession: tmuxSession,
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

  /// Runs an interactive slash command, e.g. `/agents`, in agy — on the
  /// chat's own conversation when [conversationId] is given.
  Future<void> runSlashCommand(String command, {String? conversationId, String? appDataDir}) async {
    final reuse = running && _mode == TerminalMode.agy && _conversationId == conversationId && _appDataDir == appDataDir;
    if (!reuse) {
      await start(conversationId: conversationId, appDataDir: appDataDir);
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    // A trailing space means "type the rest": don't submit yet.
    if (command.isNotEmpty) sendText(command.endsWith(' ') ? command : '$command\r');
  }

  void sendText(String text) => _pty?.write(utf8.encode(text));

  void _onTerminalInput(String data) => _pty?.write(utf8.encode(data));

  void _scanUrls(String data) {
    // Kept raw: an OSC 8 hyperlink can span chunks, and it is the only
    // place a long URL (agy's sign-in link) arrives unbroken when the TUI
    // wraps the visible text at the terminal's width.
    final raw = _urlTail + data;
    _urlTail = raw.length > 4096 ? raw.substring(raw.length - 4096) : raw;
    var changed = false;
    for (final url in findUrls(raw)) {
      // A cut-off copy of a link we already have (wrapped or split text).
      if (urls.any((u) => u.length > url.length && u.startsWith(url))) continue;
      urls.removeWhere((u) => url.startsWith(u));
      urls.insert(0, url);
      changed = true;
    }
    if (urls.length > 5) urls.removeRange(5, urls.length);
    if (changed) _notify();
  }

  static final _osc8 = RegExp(r'\x1B\]8;[^;\x07\x1B]*;([^\x07\x1B]+)(?:\x07|\x1B\\)');
  static final _ansi = RegExp(r'\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[()][0-9A-Za-z]|[=>78])');
  static final _url = RegExp(r'https?://[^\s"<>\x00-\x1F]+');

  /// Links in raw terminal output: OSC 8 hyperlink targets first (complete
  /// even when the visible text is wrapped), then URLs in the visible text.
  static List<String> findUrls(String raw) {
    final found = <String>[];
    void add(String url) {
      url = url.replaceAll(RegExp(r'[.,;:)\]]+$'), '');
      if (url.length < 12 || !url.startsWith(RegExp('https?://'))) return;
      if (found.any((u) => u.startsWith(url))) return;
      found
        ..removeWhere((u) => url.startsWith(u))
        ..add(url);
    }

    for (final m in _osc8.allMatches(raw)) {
      add(m.group(1)!);
    }
    for (final m in _url.allMatches(raw.replaceAll(_ansi, ''))) {
      add(m.group(0)!);
    }
    return found;
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
        unawaited(start(mode: _mode!, extraArgs: _extraArgs, persist: _persist, conversationId: _conversationId));
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

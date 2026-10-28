import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

import '../../state/terminal_session.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Full-screen terminal, used for the sign-in flow during setup.
class TerminalScreen extends StatelessWidget {
  const TerminalScreen({super.key, required this.title, this.hint});
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(top: false, child: TerminalPane(hint: hint)),
    );
  }
}

/// The interactive agy TUI: VT emulator, detected-link banner, a row of keys
/// that phone keyboards lack, and a line editor for comfortable typing.
class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key, this.hint, this.showStartButtons = true});

  final String? hint;
  final bool showStartButtons;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final _controller = TerminalController();
  final _focus = FocusNode();
  final _input = TextEditingController();
  double _fontSize = 12.5;
  bool _ctrl = false;
  bool _showHint = true;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  void _key(TerminalSession t, TerminalKey key, {bool shift = false, bool ctrl = false}) {
    t.terminal.keyInput(key, shift: shift, ctrl: ctrl || _ctrl);
    if (_ctrl) setState(() => _ctrl = false);
  }

  void _text(TerminalSession t, String s) {
    if (_ctrl && s.length == 1) {
      t.terminal.charInput(s.toLowerCase().codeUnitAt(0), ctrl: true);
      setState(() => _ctrl = false);
    } else {
      t.terminal.textInput(s);
    }
  }

  Future<void> _paste(TerminalSession t) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) t.terminal.paste(text);
  }

  void _sendLine(TerminalSession t) {
    final text = _input.text;
    if (text.isEmpty) {
      t.terminal.keyInput(TerminalKey.enter);
      return;
    }
    t.terminal.paste(text);
    t.terminal.keyInput(TerminalKey.enter);
    _input.clear();
  }

  void _copySelection(TerminalSession t) {
    final sel = _controller.selection;
    final text = sel == null
        ? t.terminal.buffer.getText()
        : t.terminal.buffer.getText(sel);
    copyText(context, text.trimRight(), label: sel == null ? 'Copied screen text' : 'Copied');
    _controller.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TerminalSession>();
    return Column(
      children: [
        if (widget.hint != null && _showHint)
          _Banner(
            icon: Icons.info_outline,
            color: AppColors.accent,
            text: widget.hint!,
            onClose: () => setState(() => _showHint = false),
          ),
        if (t.urls.isNotEmpty) _UrlBanner(url: t.urls.first, onClose: t.dismissUrls),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onScaleUpdate: (d) {
                    if (d.pointerCount < 2) return;
                    setState(() => _fontSize = (_fontSize * (1 + (d.scale - 1) * 0.05)).clamp(8, 22));
                  },
                  child: TerminalView(
                    t.terminal,
                    controller: _controller,
                    focusNode: _focus,
                    theme: terminalTheme,
                    textStyle: TerminalStyle(
                      fontSize: _fontSize,
                      fontFamily: 'monospace',
                      fontFamilyFallback: monoFallback,
                    ),
                    padding: const EdgeInsets.all(6),
                    keyboardAppearance: Brightness.dark,
                    deleteDetection: true,
                  ),
                ),
              ),
              if (!t.running && widget.showStartButtons)
                Positioned.fill(
                  child: Container(
                    color: AppColors.background.withValues(alpha: 0.86),
                    child: t.starting
                        ? const Center(child: CircularProgressIndicator())
                        : _StartPanel(session: t),
                  ),
                ),
            ],
          ),
        ),
        _KeyBar(
          ctrl: _ctrl,
          onCtrl: () => setState(() => _ctrl = !_ctrl),
          onKey: (k, {shift = false, ctrl = false}) => _key(t, k, shift: shift, ctrl: ctrl),
          onText: (s) => _text(t, s),
          onPaste: () => _paste(t),
          onCopy: () => _copySelection(t),
          onKeyboard: () {
            if (_focus.hasFocus) {
              _focus.unfocus();
            } else {
              _focus.requestFocus();
            }
          },
          onZoom: (delta) => setState(() => _fontSize = (_fontSize + delta).clamp(8, 22)),
        ),
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  style: monoStyle(size: 13.5),
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendLine(t),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Type a line and send ⏎',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Send line',
                onPressed: () => _sendLine(t),
                icon: const Icon(Icons.keyboard_return, color: AppColors.accent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StartPanel extends StatelessWidget {
  const _StartPanel({required this.session});
  final TerminalSession session;

  @override
  Widget build(BuildContext context) {
    final tmux = session.tmuxSessionName;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal_rounded, size: 40, color: AppColors.textFaint),
            const SizedBox(height: 12),
            Text(session.mode == null ? 'Interactive terminal' : 'Session ended',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              tmux == null
                  ? 'Run the full agy TUI for /config, /mcp, approvals and anything the chat view does not cover.'
                  : 'Runs the full agy TUI in tmux session "$tmux", so it keeps going if you disconnect.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted, height: 1.4),
            ),
            if (session.error != null) ...[
              const SizedBox(height: 12),
              ErrorPanel(message: session.error!),
            ],
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => session.start(),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Start agy'),
                ),
                OutlinedButton.icon(
                  onPressed: () => session.start(mode: TerminalMode.shell),
                  icon: const Icon(Icons.code),
                  label: const Text('Shell'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

typedef _KeyCallback = void Function(TerminalKey key, {bool shift, bool ctrl});

class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.ctrl,
    required this.onCtrl,
    required this.onKey,
    required this.onText,
    required this.onPaste,
    required this.onCopy,
    required this.onKeyboard,
    required this.onZoom,
  });

  final bool ctrl;
  final VoidCallback onCtrl;
  final _KeyCallback onKey;
  final void Function(String) onText;
  final VoidCallback onPaste;
  final VoidCallback onCopy;
  final VoidCallback onKeyboard;
  final void Function(double) onZoom;

  @override
  Widget build(BuildContext context) {
    final keys = <Widget>[
      _k('esc', () => onKey(TerminalKey.escape)),
      _k('tab', () => onKey(TerminalKey.tab)),
      _k('⇧tab', () => onKey(TerminalKey.tab, shift: true)),
      _k('ctrl', onCtrl, active: ctrl),
      _k('^C', () => onKey(TerminalKey.keyC, ctrl: true), tooltip: 'Interrupt'),
      _k('↑', () => onKey(TerminalKey.arrowUp)),
      _k('↓', () => onKey(TerminalKey.arrowDown)),
      _k('←', () => onKey(TerminalKey.arrowLeft)),
      _k('→', () => onKey(TerminalKey.arrowRight)),
      _k('⏎', () => onKey(TerminalKey.enter)),
      _k('y', () => onText('y'), tooltip: 'Approve'),
      _k('n', () => onText('n'), tooltip: 'Reject'),
      _k('/', () => onText('/')),
      _k('@', () => onText('@')),
      _k('!', () => onText('!')),
      _k('^O', () => onKey(TerminalKey.keyO, ctrl: true), tooltip: 'Toggle tool output'),
      _k('^R', () => onKey(TerminalKey.keyR, ctrl: true), tooltip: 'Artifact review'),
      _k('^K', () => onKey(TerminalKey.keyK, ctrl: true), tooltip: 'Fast-approve subagent'),
      _k('^L', () => onKey(TerminalKey.keyL, ctrl: true), tooltip: 'Redraw'),
      _k('^D', () => onKey(TerminalKey.keyD, ctrl: true)),
      _k('PgUp', () => onKey(TerminalKey.pageUp)),
      _k('PgDn', () => onKey(TerminalKey.pageDown)),
      _icon(Icons.content_paste, onPaste, 'Paste'),
      _icon(Icons.copy_all, onCopy, 'Copy selection or screen'),
      _icon(Icons.text_decrease, () => onZoom(-1), 'Smaller'),
      _icon(Icons.text_increase, () => onZoom(1), 'Larger'),
    ];
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Keyboard',
            onPressed: onKeyboard,
            icon: const Icon(Icons.keyboard_alt_outlined, size: 20),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              children: keys,
            ),
          ),
        ],
      ),
    );
  }

  Widget _k(String label, VoidCallback onTap, {bool active = false, String? tooltip}) {
    final chip = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: active ? AppColors.accent : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            constraints: const BoxConstraints(minWidth: 38),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(label, style: monoStyle(size: 13, weight: FontWeight.w600)),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  Widget _icon(IconData icon, VoidCallback onTap, String tooltip) => IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
        icon: Icon(icon, size: 19, color: AppColors.textMuted),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text, this.onClose, this.actions = const []});
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.35))),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.35)),
          ),
          ...actions,
          if (onClose != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

class _UrlBanner extends StatelessWidget {
  const _UrlBanner({required this.url, required this.onClose});
  final String url;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return _Banner(
      icon: Icons.link,
      color: AppColors.accentAlt,
      text: url,
      onClose: onClose,
      actions: [
        TextButton(
          onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: const Text('Open'),
        ),
        IconButton(
          tooltip: 'Copy link',
          visualDensity: VisualDensity.compact,
          onPressed: () => copyText(context, url, label: 'Link copied'),
          icon: const Icon(Icons.copy, size: 18),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/agy_service.dart';
import '../../state/session_state.dart';
import '../../state/terminal_session.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'terminal_view.dart';

/// Checklist that gets a fresh VPS ready: install agy, sign in, and
/// optionally install tmux.
class SetupView extends StatefulWidget {
  const SetupView({super.key});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  final List<String> _log = [];
  String? _busy;
  String? _error;
  final _logScroll = ScrollController();

  Future<void> _install(String what, Future<int> Function(void Function(String)) action) async {
    final session = context.read<SessionState>();
    setState(() {
      _busy = what;
      _error = null;
      _log
        ..clear()
        ..add('\$ installing $what…');
    });
    try {
      final code = await action((line) {
        if (!mounted) return;
        setState(() => _log.add(line));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        });
      });
      await session.refreshInfo();
      if (code != 0) {
        setState(() => _error = 'Installing $what failed (exit code $code). See the log above.');
      } else if (what == 'Antigravity CLI') {
        await session.checkAuth();
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _signIn() async {
    final session = context.read<SessionState>();
    final terminal = context.read<TerminalSession>();
    await terminal.start(persist: false);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: terminal,
        child: const TerminalScreen(
          title: 'Sign in to Antigravity',
          hint:
              'Pick "Google OAuth", open the link on this phone, then paste the code back here with the Paste key. Close this screen when agy shows its prompt.',
        ),
      ),
    ));
    await terminal.stop();
    await session.checkAuth();
  }

  Future<void> _apiKey() async {
    final session = context.read<SessionState>();
    final controller = TextEditingController(text: session.secrets.geminiApiKey ?? '');
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use a Gemini API key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'agy will use the "gemini" model provider with this key instead of a Google sign-in. Get one from Google AI Studio.',
                style: TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'GEMINI_API_KEY'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (key == null) return;
    setState(() => _busy = 'API key');
    try {
      await session.useApiKey(key);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final info = session.info;
    final auth = session.auth;
    final agy = session.agy;
    if (info == null || agy == null) return const SizedBox.shrink();

    final signedIn = auth?.state == AuthState.signedIn;
    return Scaffold(
      appBar: AppBar(title: Text('Set up ${session.profile.name}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 16),
            child: Text(
              "Let's get the Antigravity CLI ready on this server.",
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
          _Step(
            done: true,
            title: 'Connected over SSH',
            subtitle: [
              info.osName,
              if (info.arch.isNotEmpty) info.arch,
              if (info.shell != null) baseName(info.shell!),
            ].join(' · '),
          ),
          _Step(
            done: info.agyInstalled,
            title: info.agyInstalled ? 'Antigravity CLI installed' : 'Install the Antigravity CLI',
            subtitle: info.agyInstalled
                ? (info.agyVersion ?? info.agyPath ?? '')
                : agy.scripts.isWindows
                    ? 'Runs the official installer (install.ps1) for your user.'
                    : 'Runs the official installer into ~/.local/bin. No root needed.',
            action: info.agyInstalled
                ? null
                : FilledButton(
                    onPressed: _busy != null
                        ? null
                        : () => _install('Antigravity CLI', agy.installAgy),
                    child: _busy == 'Antigravity CLI'
                        ? const _Spinner()
                        : const Text('Install'),
                  ),
          ),
          _Step(
            done: signedIn,
            enabled: info.agyInstalled,
            title: signedIn ? 'Signed in' : 'Sign in to Antigravity',
            subtitle: !info.agyInstalled
                ? 'Available after installing the CLI.'
                : session.checkingAuth
                    ? 'Checking…'
                    : signedIn
                        ? (auth!.models.isEmpty
                            ? 'Ready'
                            : '${auth.models.length} models available')
                        : 'Sign in with Google in the terminal, or use a Gemini API key.',
            action: !info.agyInstalled || signedIn
                ? null
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy != null ? null : _signIn,
                        icon: const Icon(Icons.login, size: 18),
                        label: const Text('Sign in'),
                      ),
                      OutlinedButton(
                        onPressed: _busy != null ? null : _apiKey,
                        child: _busy == 'API key' ? const _Spinner() : const Text('API key'),
                      ),
                      IconButton(
                        tooltip: 'Check again',
                        onPressed: session.checkingAuth ? null : session.checkAuth,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
          ),
          if (!agy.scripts.isWindows)
            _Step(
              done: info.hasTmux,
              optional: true,
              title: info.hasTmux ? 'tmux installed' : 'Install tmux (recommended)',
              subtitle: info.hasTmux
                  ? 'Terminal sessions survive disconnects.'
                  : info.canSudo
                      ? 'Keeps interactive agy sessions alive when your phone sleeps.'
                      : 'Needs root. Install it with your package manager, e.g. apt install tmux.',
              action: info.hasTmux || !info.canSudo
                  ? null
                  : OutlinedButton(
                      onPressed:
                          _busy != null ? null : () => _install('tmux', agy.installTmux),
                      child: _busy == 'tmux' ? const _Spinner() : const Text('Install'),
                    ),
            ),
          _Step(
            done: info.hasGit,
            optional: true,
            title: info.hasGit ? 'git found' : 'git not found',
            subtitle: info.hasGit
                ? 'The Changes tab shows diffs of what the agent edits.'
                : 'Install git to review the agent\'s changes in the Changes tab.',
          ),
          if (_log.length > 1 || _busy != null) ...[
            const SizedBox(height: 8),
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: AppColors.codeBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: ListView.builder(
                controller: _logScroll,
                padding: const EdgeInsets.all(12),
                itemCount: _log.length,
                itemBuilder: (_, i) => Text(
                  _log[i].replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), ''),
                  style: monoStyle(size: 11.5, color: AppColors.textMuted),
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorPanel(message: _error!),
          ],
          if (auth != null &&
              auth.state != AuthState.signedIn &&
              auth.detail.trim().isNotEmpty &&
              info.agyInstalled) ...[
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Sign-in check output',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
              children: [
                SelectableText(auth.detail.trim(),
                    style: monoStyle(size: 11.5, color: AppColors.textMuted)),
              ],
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: info.agyInstalled && _busy == null ? session.completeSetup : null,
            child: Text(signedIn ? 'Continue' : 'Continue anyway'),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.done,
    required this.title,
    required this.subtitle,
    this.action,
    this.optional = false,
    this.enabled = true,
  });

  final bool done;
  final bool optional;
  final bool enabled;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = done
        ? AppColors.success
        : optional
            ? AppColors.textFaint
            : AppColors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: color, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(subtitle,
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (action != null) ...[
                  const SizedBox(height: 12),
                  Padding(padding: const EdgeInsets.only(left: 34), child: action!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}

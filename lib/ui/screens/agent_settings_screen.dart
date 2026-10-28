import 'package:flutter/material.dart';

import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Edits agy's `~/.gemini/antigravity-cli/settings.json` on the server:
/// the documented settings and the allow / ask / deny permission rules that
/// decide which tools headless chats may use. Unknown keys are preserved.
class AgentSettingsScreen extends StatefulWidget {
  const AgentSettingsScreen({super.key, required this.session});

  /// Passed in because pushed routes sit outside the session's providers.
  final SessionState session;

  @override
  State<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _Choice {
  const _Choice(this.value, this.label, [this.help]);
  final String value;
  final String label;
  final String? help;
}

const _modes = [
  _Choice('', 'Default', 'Asks before edits and commands'),
  _Choice('accept-edits', 'Accept edits', 'Approves edits, asks before commands'),
  _Choice('auto', 'Auto (Preview)', 'Edits approved, commands sandboxed; risky ones ask'),
  _Choice('plan', 'Plan', 'Investigates and drafts a plan first'),
];

const _toolPermissions = [
  _Choice('request-review', 'Request review', 'Ask before tools (default)'),
  _Choice('proceed-in-sandbox', 'Proceed in sandbox', 'Run sandboxed commands without asking'),
  _Choice('always-proceed', 'Always proceed', 'Never ask (like Turbo)'),
  _Choice('strict', 'Strict', 'Ask for everything'),
];

const _artifactPolicies = [
  _Choice('asks-for-review', 'Ask for review', 'Pause for plan and artifact review'),
  _Choice('agent-decides', 'Agent decides'),
  _Choice('always-proceed', 'Always proceed'),
];

const _verbosity = [
  _Choice('high', 'High'),
  _Choice('medium', 'Medium'),
  _Choice('low', 'Low'),
];

/// Common rules offered as one-tap suggestions.
const _suggestions = [
  'command(git)',
  'command(regex:npm run (build|lint|test))',
  'command(npm install)',
  'command(flutter)',
  'command(python)',
  'command(ls)',
  'write_file(src/)',
  'read_url(github.com)',
  'mcp(*)',
];

class _AgentSettingsScreenState extends State<AgentSettingsScreen> {
  Map<String, dynamic>? _settings;
  String? _error;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final agy = widget.session.agy;
    if (agy == null) {
      setState(() => _error = 'Not connected.');
      return;
    }
    try {
      final s = await agy.readSettings();
      if (mounted) setState(() => _settings = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save() async {
    final agy = widget.session.agy;
    final s = _settings;
    if (agy == null || s == null) return;
    setState(() => _saving = true);
    try {
      await agy.writeSettings(s);
      if (!mounted) return;
      setState(() => _dirty = false);
      showSnack(context, 'Saved. New chats and terminal sessions use these settings.');
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _set(String key, Object? value) {
    setState(() {
      if (value == null) {
        _settings!.remove(key);
      } else {
        _settings![key] = value;
      }
      _dirty = true;
    });
  }

  List<String> _rules(String list) {
    final perms = _settings!['permissions'];
    if (perms is Map && perms[list] is List) return (perms[list] as List).whereType<String>().toList();
    return const [];
  }

  void _setRules(String list, List<String> rules) {
    final perms = Map<String, dynamic>.from((_settings!['permissions'] as Map?) ?? {});
    if (rules.isEmpty) {
      perms.remove(list);
    } else {
      perms[list] = rules;
    }
    _set('permissions', perms.isEmpty ? null : perms);
  }

  Future<void> _addRule(String list) async {
    final controller = TextEditingController();
    final rule = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add ${list == 'allow' ? 'an allow' : list == 'ask' ? 'an ask' : 'a deny'} rule'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: monoStyle(size: 13),
                decoration: const InputDecoration(hintText: 'command(git)'),
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
              const SizedBox(height: 10),
              const Text(
                  'action(target): command(prefix), command(regex:…), read_file(path), write_file(path), read_url(domain), execute_url(domain), mcp(server/tool). * matches everything.',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _suggestions)
                    ActionChip(
                      label: Text(s, style: monoStyle(size: 11)),
                      onPressed: () => controller.text = s,
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Add')),
        ],
      ),
    );
    final r = rule?.trim();
    if (r == null || r.isEmpty) return;
    if (!RegExp(r'^[a-z_]+\(.*\)$').hasMatch(r)) {
      if (mounted) showSnack(context, 'Rules look like action(target), e.g. command(git).');
      return;
    }
    _setRules(list, {..._rules(list), r}.toList());
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard changes?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
            ],
          ),
        );
        if (leave == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Permissions & settings'),
          actions: [
            TextButton(
              onPressed: _dirty && !_saving ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
        body: _error != null
            ? Padding(padding: const EdgeInsets.all(16), child: ErrorPanel(message: _error!, onRetry: _load))
            : s == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.only(bottom: 40),
                    children: [
                      const _Header('PERMISSION RULES',
                          'Deny beats ask beats allow. Chats run headless, so tools that would ask are skipped instead; allow what the agent may do.'),
                      for (final list in const ['allow', 'ask', 'deny']) _rulesSection(list),
                      const _Header('AGENT', null),
                      _choice('Tool permission', 'toolPermission', _toolPermissions, 'request-review'),
                      _choice('Mode in the terminal', 'agentMode', _modes, ''),
                      _choice('Artifact review', 'artifactReviewPolicy', _artifactPolicies, 'asks-for-review'),
                      _switch('Terminal sandbox', 'enableTerminalSandbox', false,
                          'Run agent commands in an isolated sandbox (workspace + temp, no network by default).'),
                      _switch('Access outside the workspace', 'allowNonWorkspaceAccess', false,
                          'Let the agent read and edit files outside the project folders.'),
                      _switch('Use AI credits after quota', 'useG1Credits', false,
                          'Keep working on credits once the free quota is used (not for business accounts).'),
                      const _Header('TERMINAL', null),
                      _choice('Verbosity', 'verbosity', _verbosity, 'medium'),
                      _switch(
                          'Notifications', 'notifications', false, 'Bell when agy needs approval or finishes a turn.'),
                      _switch('Show tips', 'showTips', true, null),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Other settings (color scheme, keybindings, status line…) are kept as they are. Use /config in the terminal for those.',
                          style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _rulesSection(String list) {
    final rules = _rules(list);
    final color = switch (list) {
      'allow' => AppColors.success,
      'ask' => AppColors.warning,
      _ => AppColors.danger,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(list[0].toUpperCase() + list.substring(1),
                  style: TextStyle(fontWeight: FontWeight.w600, color: color)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _addRule(list),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          if (rules.isEmpty)
            const Text('No rules', style: TextStyle(color: AppColors.textFaint, fontSize: 12.5))
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in rules)
                  InputChip(
                    label: Text(r, style: monoStyle(size: 11.5)),
                    onDeleted: () => _setRules(list, rules.where((x) => x != r).toList()),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _choice(String title, String key, List<_Choice> options, String fallback) {
    final current = (_settings![key] as String?) ?? fallback;
    final selected = options.where((o) => o.value == current).firstOrNull;
    return ListTile(
      title: Text(title),
      subtitle: Text(selected?.label ?? current, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final v = await showModalBottomSheet<String>(
          context: context,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final o in options)
                  ListTile(
                    leading: Icon(o.value == current ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: AppColors.accent),
                    title: Text(o.label),
                    subtitle: o.help == null
                        ? null
                        : Text(o.help!, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                    onTap: () => Navigator.pop(context, o.value),
                  ),
              ],
            ),
          ),
        );
        if (v != null) _set(key, v == fallback && v.isEmpty ? null : v);
      },
    );
  }

  Widget _switch(String title, String key, bool fallback, String? help) {
    final value = (_settings![key] as bool?) ?? fallback;
    return SwitchListTile(
      title: Text(title),
      subtitle: help == null ? null : Text(help, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
      value: value,
      onChanged: (v) => _set(key, v),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, this.help);
  final String title;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AppColors.textFaint, fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w600)),
            if (help != null) ...[
              const SizedBox(height: 4),
              Text(help!, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
            ],
          ],
        ),
      );
}

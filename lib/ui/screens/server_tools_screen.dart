import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/remote_host.dart';
import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// agy's own subcommands on the server: update and changelog, Remote
/// Control, MCP servers, plugins and custom agents.
class ServerToolsScreen extends StatefulWidget {
  const ServerToolsScreen({super.key, required this.session});

  /// Passed in because pushed routes sit outside the session's providers.
  final SessionState session;

  @override
  State<ServerToolsScreen> createState() => _ServerToolsScreenState();
}

class _ServerToolsScreenState extends State<ServerToolsScreen> {
  String? _running;

  Future<void> _run(String title, List<String> args, {Duration timeout = const Duration(seconds: 90)}) async {
    final agy = widget.session.agy;
    if (agy == null || _running != null) return;
    setState(() => _running = title);
    CommandResult r;
    try {
      r = await agy.runAgy(args, timeout: timeout);
    } catch (e) {
      r = CommandResult(1, '', e.toString());
    } finally {
      if (mounted) setState(() => _running = null);
    }
    if (!mounted) return;
    if (args.first == 'update') await widget.session.refreshInfo();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                Icon(r.ok ? Icons.check_circle : Icons.error_outline,
                    size: 18, color: r.ok ? AppColors.success : AppColors.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(onPressed: () => copyText(context, r.combined), icon: const Icon(Icons.copy, size: 18)),
              ],
            ),
            Text('agy ${args.join(' ')}', style: monoStyle(size: 11.5, color: AppColors.textFaint)),
            const SizedBox(height: 10),
            SelectableText(
              r.combined.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trim().isEmpty
                  ? '(no output)'
                  : r.combined.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trim(),
              style: monoStyle(size: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _ask(String title, String label, {String? hint, String? initial}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          style: monoStyle(size: 13),
          decoration: InputDecoration(labelText: label, hintText: hint),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Run')),
        ],
      ),
    );
  }

  Future<void> _named(String title, List<String> prefix, {String label = 'Name'}) async {
    final name = await _ask(title, label);
    if (name == null || name.isEmpty) return;
    await _run(title, [...prefix, name]);
  }

  Future<void> _addMcp() async {
    final name = await _ask('Add MCP server', 'Name', hint: 'fs');
    if (name == null || name.isEmpty || !mounted) return;
    final target = await _ask('Add MCP server', 'Command or URL',
        hint: 'npx -y @modelcontextprotocol/server-filesystem /work  or  https://…');
    if (target == null || target.isEmpty) return;
    final parts = target.split(RegExp(r'\s+'));
    await _run('Add MCP server', ['mcp', 'add', name, ...parts]);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.session.info;
    final busy = _running != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Antigravity CLI')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          _section('CLI', [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(info?.agyVersion ?? 'agy'),
              subtitle: Text(info?.agyPath ?? '', style: monoStyle(size: 11.5, color: AppColors.textFaint)),
            ),
            _action(Icons.system_update_alt, 'Update agy', 'agy update', busy,
                () => _run('Update agy', const ['update'], timeout: const Duration(minutes: 5))),
            _action(Icons.new_releases_outlined, 'Release notes', 'agy changelog', busy,
                () => _run('Release notes', const ['changelog'])),
            _action(Icons.memory, 'Models', 'agy models', busy, () => _run('Models', const ['models'])),
          ]),
          _section('REMOTE CONTROL', [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                "Google's own web dashboard for agy on this server (antigravity.google.com), with push notifications on phones. "
                'It runs as a background service on the server and needs the same Google account.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ),
            _action(Icons.wifi_tethering, 'Status', 'agy remote-control status', busy,
                () => _run('Remote Control status', const ['remote-control', 'status'])),
            _action(Icons.play_circle_outline, 'Start', 'agy remote-control start --name …', busy,
                () => _run('Start Remote Control', ['remote-control', 'start', '--name', widget.session.profile.name])),
            _action(Icons.stop_circle_outlined, 'Stop', 'agy remote-control stop', busy,
                () => _run('Stop Remote Control', const ['remote-control', 'stop'])),
            _action(Icons.open_in_new, 'Open dashboard', 'antigravity.google.com', false,
                () => launchUrl(Uri.parse('https://antigravity.google.com'), mode: LaunchMode.externalApplication)),
          ]),
          _section('MCP SERVERS', [
            _action(Icons.list, 'List', 'agy mcp list', busy, () => _run('MCP servers', const ['mcp', 'list'])),
            _action(Icons.add, 'Add', 'agy mcp add <name> <command|url>', busy, _addMcp),
            _action(Icons.toggle_on_outlined, 'Enable', 'agy mcp enable <name>', busy,
                () => _named('Enable MCP server', const ['mcp', 'enable'])),
            _action(Icons.toggle_off_outlined, 'Disable', 'agy mcp disable <name>', busy,
                () => _named('Disable MCP server', const ['mcp', 'disable'])),
            _action(Icons.delete_outline, 'Remove', 'agy mcp remove <name>', busy,
                () => _named('Remove MCP server', const ['mcp', 'remove'])),
          ]),
          _section('PLUGINS', [
            _action(Icons.list, 'List', 'agy plugin list', busy, () => _run('Plugins', const ['plugin', 'list'])),
            _action(Icons.download_outlined, 'Install', 'agy plugin install <name>', busy,
                () => _named('Install plugin', const ['plugin', 'install'], label: 'Plugin (name or name@version)')),
            _action(Icons.toggle_on_outlined, 'Enable', 'agy plugin enable <name>', busy,
                () => _named('Enable plugin', const ['plugin', 'enable'])),
            _action(Icons.toggle_off_outlined, 'Disable', 'agy plugin disable <name>', busy,
                () => _named('Disable plugin', const ['plugin', 'disable'])),
            _action(Icons.delete_outline, 'Uninstall', 'agy plugin uninstall <name>', busy,
                () => _named('Uninstall plugin', const ['plugin', 'uninstall'])),
            _action(Icons.input, 'Import from Gemini CLI', 'agy plugin import gemini', busy,
                () => _run('Import Gemini CLI extensions', const ['plugin', 'import', 'gemini'])),
            _action(Icons.input, 'Import from Claude', 'agy plugin import claude', busy,
                () => _run('Import Claude plugins', const ['plugin', 'import', 'claude'])),
          ]),
          _section('AGENTS', [
            _action(Icons.smart_toy_outlined, 'Custom agents', 'agy agents', busy,
                () => _run('Custom agents', const ['agents'])),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Define agents as Markdown in .agents/agents/ (project) or ~/.gemini/config/agents/ (global); pick one for a chat with the Agent chip.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
            child: Text(title,
                style: const TextStyle(
                    color: AppColors.textFaint, fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w600)),
          ),
          ...children,
        ],
      );

  Widget _action(IconData icon, String title, String command, bool disabled, VoidCallback onTap) => ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(command, style: monoStyle(size: 11, color: AppColors.textFaint)),
        enabled: !disabled,
        onTap: onTap,
      );
}

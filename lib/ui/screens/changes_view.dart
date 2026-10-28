import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/agy_service.dart';
import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'workspace_home.dart';

/// Git status of the workspace, so you can review what the agent changed.
class ChangesView extends StatefulWidget {
  const ChangesView({super.key});

  @override
  State<ChangesView> createState() => _ChangesViewState();
}

class _ChangesViewState extends State<ChangesView> {
  GitStatus? _status;
  bool _notRepo = false;
  bool _loading = false;
  String? _error;
  int _seenRuns = -1;
  int _seenGeneration = -1;

  Future<void> _load() async {
    final session = context.read<SessionState>();
    final agy = session.agy;
    if (agy == null || !session.isConnected) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await agy.gitStatus(session.workspace!);
      if (!mounted) return;
      setState(() {
        _status = status;
        _notRepo = status == null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _askAgent(String prompt) {
    final chat = context.read<ChatController>();
    chat.draft.text = prompt;
    WorkspaceHomeState.of(context)?.showTab(0);
  }

  @override
  Widget build(BuildContext context) {
    final runs = context.select<ChatController, int>((c) => c.completedRuns);
    final session = context.watch<SessionState>();
    if ((runs != _seenRuns || session.generation != _seenGeneration) && session.isConnected) {
      _seenRuns = runs;
      _seenGeneration = session.generation;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final status = _status;
    if (_error != null && status == null) {
      return ListView(padding: const EdgeInsets.all(16), children: [ErrorPanel(message: _error!, onRetry: _load)]);
    }
    if (_notRepo) {
      return EmptyState(
        icon: Icons.difference_outlined,
        title: 'Not a git repository',
        message: 'Initialise git in this workspace to review the agent\'s edits as diffs.',
        action: OutlinedButton(
          onPressed: () => _askAgent('Initialise a git repository here with a sensible .gitignore and make an initial commit.'),
          child: const Text('Ask the agent to set up git'),
        ),
      );
    }
    if (status == null) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.call_split, size: 18, color: AppColors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      status.branch ?? 'detached',
                      if (status.ahead > 0) '↑${status.ahead}',
                      if (status.behind > 0) '↓${status.behind}',
                    ].join('  '),
                    style: monoStyle(size: 13.5, weight: FontWeight.w600),
                  ),
                ),
                Text('${status.files.length} changed', style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 20)),
              ],
            ),
          ),
          if (status.files.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: EmptyState(icon: Icons.check_circle_outline, title: 'Working tree clean'),
            )
          else ...[
            for (final f in status.files)
              ListTile(
                dense: true,
                leading: _ChangeBadge(change: f.change),
                title: Text(baseName(f.path), style: const TextStyle(fontSize: 14.5)),
                subtitle: f.path.contains('/') || f.path.contains(r'\')
                    ? Text(f.path, style: monoStyle(size: 11, color: AppColors.textFaint), overflow: TextOverflow.ellipsis)
                    : null,
                trailing: f.staged ? const Text('staged', style: TextStyle(fontSize: 11, color: AppColors.success)) : null,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DiffScreen(agy: session.agy!, cwd: session.workspace!, file: f),
                )),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _askAgent('Review the uncommitted changes in this repository and point out any problems.'),
                    icon: const Icon(Icons.rate_review_outlined, size: 18),
                    label: const Text('Ask for a review'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _askAgent('Commit the current changes with a clear, descriptive commit message.'),
                    icon: const Icon(Icons.commit, size: 18),
                    label: const Text('Ask to commit'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge({required this.change});
  final GitChange change;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (change) {
      GitChange.modified => ('M', AppColors.warning),
      GitChange.added => ('A', AppColors.success),
      GitChange.untracked => ('U', AppColors.success),
      GitChange.deleted => ('D', AppColors.danger),
      GitChange.renamed => ('R', AppColors.accent),
      GitChange.conflicted => ('!', AppColors.danger),
      GitChange.other => ('•', AppColors.textMuted),
    };
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: monoStyle(size: 12.5, color: color, weight: FontWeight.w700)),
    );
  }
}

class DiffScreen extends StatefulWidget {
  const DiffScreen({super.key, required this.agy, required this.cwd, required this.file});
  final AgyService agy;
  final String cwd;
  final GitFile file;

  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  String? _diff;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.agy.gitDiff(widget.cwd, widget.file);
      if (mounted) setState(() => _diff = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final diff = _diff;
    return Scaffold(
      appBar: AppBar(
        title: Text(baseName(widget.file.path)),
        actions: [
          if (diff != null) IconButton(onPressed: () => copyText(context, diff), icon: const Icon(Icons.copy)),
        ],
      ),
      body: _error != null
          ? Padding(padding: const EdgeInsets.all(16), child: ErrorPanel(message: _error!))
          : diff == null
              ? const Center(child: CircularProgressIndicator())
              : diff.trim().isEmpty
                  ? const EmptyState(icon: Icons.difference_outlined, title: 'No textual changes')
                  : DiffView(diff: diff),
    );
  }
}

/// Unified diff with added/removed lines tinted.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.diff});
  final String diff;

  @override
  Widget build(BuildContext context) {
    var lines = diff.split('\n');
    final hidden = lines.length > 5000 ? lines.length - 5000 : 0;
    if (hidden > 0) lines = [...lines.take(5000), '… $hidden more lines'];
    return Container(
      color: AppColors.codeBackground,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: MediaQuery.sizeOf(context).width),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final l in lines) _line(l)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(String l) {
    Color? bg;
    var fg = const Color(0xFFD5D9E0);
    if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('diff ') || l.startsWith('index ')) {
      fg = AppColors.textFaint;
    } else if (l.startsWith('@@')) {
      fg = AppColors.accent;
      bg = AppColors.accent.withValues(alpha: 0.08);
    } else if (l.startsWith('+')) {
      fg = const Color(0xFF8FE3B4);
      bg = AppColors.success.withValues(alpha: 0.12);
    } else if (l.startsWith('-')) {
      fg = const Color(0xFFFFA8A6);
      bg = AppColors.danger.withValues(alpha: 0.12);
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Text(l.isEmpty ? ' ' : l, style: monoStyle(size: 12, color: fg)),
    );
  }
}

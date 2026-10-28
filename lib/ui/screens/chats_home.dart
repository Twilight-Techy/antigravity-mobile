import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../services/storage_service.dart';
import '../../state/chat_controller.dart';
import '../../state/chat_groups.dart';
import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'project_picker.dart';
import 'workspace_home.dart';

/// The list of chats on a server, grouped by project like the Antigravity
/// sidebar, with chats that belong to no project under "Other chats".
class ChatsHome extends StatefulWidget {
  const ChatsHome({super.key});

  @override
  State<ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<ChatsHome> {
  /// Projects showing all their chats instead of the latest few.
  final _expanded = <String>{};
  static const _collapsedCount = 4;

  @override
  void initState() {
    super.initState();
    final chat = context.read<ChatController>();
    chat.load().then((_) => chat.syncWithServer());
  }

  Future<void> _refresh() async {
    final chat = context.read<ChatController>();
    await chat.load();
    await chat.syncWithServer();
  }

  Future<void> _open(ConversationSummary c) async {
    final chat = context.read<ChatController>();
    if (!await chat.open(c.id) && mounted) {
      showSnack(context, 'Another chat is still running. Stop it or wait for it to finish.');
    }
  }

  void _newChat({String? project}) {
    final chat = context.read<ChatController>();
    if (chat.busy) {
      showSnack(context, 'Another chat is still running. Stop it or wait for it to finish.');
      return;
    }
    chat.newChat(project: project);
  }

  Future<void> _openFolder() async {
    final path = await browseForFolder(context);
    if (path == null || !mounted) return;
    context.read<SessionState>().touchProject(path);
    _newChat(project: path);
  }

  Future<void> _rename(ConversationSummary c) async {
    final chat = context.read<ChatController>();
    final controller = TextEditingController(text: c.title);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (value != null) await chat.rename(c.id, value);
  }

  Future<void> _delete(ConversationSummary c) async {
    final chat = context.read<ChatController>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove chat?'),
        content: Text(c.agyConversationId == null
            ? '"${c.title}" is removed from this phone. Files on the server are not changed.'
            : '"${c.title}" is removed from this list. agy keeps the conversation on the server, so it can still be resumed in the CLI (/resume) or the desktop app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await chat.delete(c.id);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final chat = context.watch<ChatController>();
    final groups = chat.groups;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Chats'),
            Row(
              children: [
                StatusDot(
                  color: session.isConnected ? AppColors.success : AppColors.danger,
                  pulse: session.status == ConnectionStatus.connecting,
                  size: 7,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(session.profile.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w400)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Open a folder',
            onPressed: session.isConnected ? _openFolder : null,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          ServerMenu(busy: chat.busy),
        ],
      ),
      body: Column(
        children: [
          if (!session.isConnected) const ConnectionBanner(),
          if (chat.syncing) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: groups.isEmpty
                ? EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'No chats yet',
                    message: 'Start a chat on its own, or open a project folder so the agent works in it.',
                    action: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: session.isConnected ? () => _newChat() : null,
                          icon: const Icon(Icons.add_comment_outlined),
                          label: const Text('New chat'),
                        ),
                        OutlinedButton.icon(
                          onPressed: session.isConnected ? _openFolder : null,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Open a folder'),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 96),
                      children: [
                        if (groups.projects.isNotEmpty) const _Label('PROJECTS'),
                        for (final g in groups.projects) ..._project(g, chat),
                        if (groups.others.isNotEmpty) ...[
                          _SectionHeader(
                            icon: Icons.chat_bubble_outline,
                            title: 'Other chats',
                            subtitle: 'Not in a project',
                            onNew: () => _newChat(),
                          ),
                          for (final c in groups.others) _tile(c, chat),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: groups.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: session.isConnected ? () => _newChat() : null,
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('New chat'),
            ),
    );
  }

  List<Widget> _project(ProjectGroup g, ChatController chat) {
    final expanded = _expanded.contains(g.path);
    final shown = expanded ? g.chats : g.chats.take(_collapsedCount).toList();
    return [
      _SectionHeader(
        icon: Icons.folder_rounded,
        title: baseName(g.path),
        subtitle: g.path,
        mono: true,
        onNew: () => _newChat(project: g.path),
        onForget: g.chats.isEmpty ? () => context.read<SessionState>().forgetProject(g.path) : null,
      ),
      if (g.chats.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(56, 0, 16, 8),
          child: Text('No chats yet', style: TextStyle(color: AppColors.textFaint, fontSize: 13)),
        ),
      for (final c in shown) _tile(c, chat),
      if (g.chats.length > _collapsedCount)
        Padding(
          padding: const EdgeInsets.only(left: 44),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => expanded ? _expanded.remove(g.path) : _expanded.add(g.path)),
              child: Text(expanded ? 'Show less' : 'Show all ${g.chats.length}'),
            ),
          ),
        ),
    ];
  }

  Widget _tile(ConversationSummary c, ChatController chat) {
    final running = chat.runningConversationId == c.id;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 56, right: 4),
      dense: true,
      title: Row(
        children: [
          Flexible(
            child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
          ),
          if (c.origin != ChatOrigin.app) ...[
            const SizedBox(width: 6),
            OriginBadge(c.origin),
          ],
        ],
      ),
      subtitle: Text(
        running ? 'Agent working…' : (c.preview.isEmpty ? timeAgo(c.updatedAt) : '${timeAgo(c.updatedAt)} · ${c.preview}'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: running ? AppColors.accent : AppColors.textMuted),
      ),
      leading: running ? const StatusDot(color: AppColors.accent, pulse: true) : null,
      onTap: () => _open(c),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, size: 20, color: AppColors.textFaint),
        onSelected: (v) {
          if (v == 'rename') {
            _rename(c);
          } else if (v == 'delete') {
            _delete(c);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', enabled: !running, child: const Text('Remove')),
        ],
      ),
    );
  }
}

/// Marks a chat started in the agy CLI or the Antigravity desktop app.
class OriginBadge extends StatelessWidget {
  const OriginBadge(this.origin, {super.key});
  final ChatOrigin origin;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          origin == ChatOrigin.desktop ? 'Desktop' : 'CLI',
          style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textFaint, fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w600)),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onNew,
    this.onForget,
    this.mono = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onNew;
  final VoidCallback? onForget;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 2),
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppColors.accent),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text(subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: mono
                        ? monoStyle(size: 11, color: AppColors.textFaint)
                        : const TextStyle(fontSize: 12, color: AppColors.textFaint)),
              ],
            ),
          ),
          if (onForget != null)
            IconButton(
              tooltip: 'Remove from list',
              visualDensity: VisualDensity.compact,
              onPressed: onForget,
              icon: const Icon(Icons.close, size: 18, color: AppColors.textFaint),
            ),
          IconButton(
            tooltip: 'New chat in $title',
            onPressed: onNew,
            icon: const Icon(Icons.add, size: 22),
          ),
        ],
      ),
    );
  }
}

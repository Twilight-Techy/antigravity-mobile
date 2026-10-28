import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../../state/terminal_session.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'changes_view.dart';
import 'chat_view.dart';
import 'files_view.dart';
import 'terminal_view.dart';

/// The main screen once a workspace is open: Chat, Files, Changes and
/// Terminal tabs, with conversations in the drawer.
class WorkspaceHome extends StatefulWidget {
  const WorkspaceHome({super.key});

  @override
  State<WorkspaceHome> createState() => WorkspaceHomeState();
}

class WorkspaceHomeState extends State<WorkspaceHome> {
  int _tab = 0;

  static WorkspaceHomeState? of(BuildContext context) =>
      context.findAncestorStateOfType<WorkspaceHomeState>();

  void showTab(int index) => setState(() => _tab = index);

  @override
  void initState() {
    super.initState();
    context.read<ChatController>().loadForWorkspace();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final chat = context.watch<ChatController>();
    final ws = session.workspace!;
    final connected = session.isConnected;
    final busy = chat.busy;

    return PopScope(
      // Back from a workspace returns to the workspace picker rather than
      // dropping the connection.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (busy) {
          showSnack(context, 'The agent is still working. Stop it or use Disconnect.');
          return;
        }
        await context.read<TerminalSession>().stop();
        session.closeWorkspace();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(baseName(ws), overflow: TextOverflow.ellipsis),
              Row(
                children: [
                  StatusDot(
                    color: !connected
                        ? AppColors.danger
                        : busy
                            ? AppColors.accent
                            : AppColors.success,
                    pulse:
                        busy || session.status == ConnectionStatus.connecting,
                    size: 7,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      !connected
                          ? (session.status == ConnectionStatus.connecting
                              ? 'Reconnecting…'
                              : 'Disconnected')
                          : busy
                              ? 'Agent working…'
                              : session.profile.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w400),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            if (_tab == 0)
              IconButton(
                tooltip: 'New conversation',
                onPressed: busy ? null : chat.newConversation,
                icon: const Icon(Icons.add_comment_outlined),
              ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'workspace':
                    await context.read<TerminalSession>().stop();
                    session.closeWorkspace();
                  case 'setup':
                    await session.reopenSetup();
                  case 'disconnect':
                    session.disconnect();
                    if (context.mounted) Navigator.of(context).pop();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'workspace',
                  enabled: !busy,
                  child: const ListTile(
                      leading: Icon(Icons.folder_open),
                      title: Text('Switch workspace'),
                      dense: true),
                ),
                const PopupMenuItem(
                  value: 'setup',
                  child: ListTile(
                      leading: Icon(Icons.build_circle_outlined),
                      title: Text('Server setup'),
                      dense: true),
                ),
                const PopupMenuItem(
                  value: 'disconnect',
                  child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text('Disconnect'),
                      dense: true),
                ),
              ],
            ),
          ],
        ),
        drawer: const _ConversationsDrawer(),
        body: Column(
          children: [
            if (!connected) const _ConnectionBanner(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [
                  ChatView(),
                  FilesView(),
                  ChangesView(),
                  TerminalPane(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: showTab,
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Agent'),
            NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: 'Files'),
            NavigationDestination(
                icon: Icon(Icons.difference_outlined),
                selectedIcon: Icon(Icons.difference),
                label: 'Changes'),
            NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: 'Terminal'),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final connecting = session.status == ConnectionStatus.connecting;
    return Material(
      color: AppColors.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 18, color: AppColors.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                connecting
                    ? 'Reconnecting…'
                    : session.error ??
                        'Connection lost. Running agent tasks continue on the server.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            TextButton(
              onPressed: connecting ? null : session.reconnect,
              child: const Text('Reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationsDrawer extends StatelessWidget {
  const _ConversationsDrawer();

  Future<void> _rename(BuildContext context, ChatController chat, String id,
      String title) async {
    final controller = TextEditingController(text: title);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename conversation'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (value != null) await chat.rename(id, value);
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final session = context.read<SessionState>();
    final currentId = chat.current?.id;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const AgLogo(size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(baseName(session.workspace ?? ''),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(session.workspace ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(
                                size: 11, color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: FilledButton.icon(
                onPressed: chat.busy
                    ? null
                    : () {
                        chat.newConversation();
                        Navigator.pop(context);
                      },
                icon: const Icon(Icons.add),
                label: const Text('New conversation'),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: chat.conversations.isEmpty
                  ? const EmptyState(
                      icon: Icons.forum_outlined, title: 'No conversations yet')
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: chat.conversations.length,
                      itemBuilder: (context, i) {
                        final c = chat.conversations[i];
                        final selected = c.id == currentId;
                        return ListTile(
                          selected: selected,
                          selectedTileColor:
                              AppColors.accent.withValues(alpha: 0.12),
                          selectedColor: AppColors.text,
                          title: Text(c.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            c.preview.isEmpty
                                ? timeAgo(c.updatedAt)
                                : '${timeAgo(c.updatedAt)} · ${c.preview}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textMuted),
                          ),
                          onTap: chat.busy && !selected
                              ? null
                              : () {
                                  chat.open(c.id);
                                  Navigator.pop(context);
                                },
                          trailing: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_horiz, size: 20),
                            onSelected: (v) {
                              if (v == 'rename') {
                                _rename(context, chat, c.id, c.title);
                              } else if (v == 'delete') {
                                chat.delete(c.id);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'rename', child: Text('Rename')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

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

/// One open chat: Agent, Files, Changes and Terminal tabs, all working in
/// the chat's project folder (or its scratch folder). Back returns to the
/// chat list.
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
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final chat = context.watch<ChatController>();
    final convo = chat.current;
    final ws = session.workspace;
    // Still on screen for a moment while switching back to the list.
    if (convo == null || ws == null) return const Scaffold();
    final connected = session.isConnected;
    final busy = chat.busy;
    final project = convo.project;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) chat.close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Chats',
            onPressed: chat.close,
            icon: const Icon(Icons.arrow_back),
          ),
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(convo.messages.isEmpty ? 'New chat' : convo.title, overflow: TextOverflow.ellipsis),
              Row(
                children: [
                  StatusDot(
                    color: !connected
                        ? AppColors.danger
                        : busy
                            ? AppColors.accent
                            : AppColors.success,
                    pulse: busy || session.status == ConnectionStatus.connecting,
                    size: 7,
                  ),
                  const SizedBox(width: 6),
                  Icon(project == null ? Icons.chat_bubble_outline : Icons.folder_rounded,
                      size: 12, color: AppColors.textMuted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      !connected
                          ? (session.status == ConnectionStatus.connecting ? 'Reconnecting…' : 'Disconnected')
                          : busy
                              ? 'Agent working…'
                              : project == null
                                  ? 'No project'
                                  : baseName(project),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w400),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            if (_tab == 0)
              IconButton(
                tooltip: 'New chat',
                onPressed: busy ? null : () => chat.newChat(project: project),
                icon: const Icon(Icons.add_comment_outlined),
              ),
            ServerMenu(busy: busy),
          ],
        ),
        body: Column(
          children: [
            if (!connected) const ConnectionBanner(),
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
                icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Agent'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Files'),
            NavigationDestination(
                icon: Icon(Icons.difference_outlined), selectedIcon: Icon(Icons.difference), label: 'Changes'),
            NavigationDestination(
                icon: Icon(Icons.terminal_outlined), selectedIcon: Icon(Icons.terminal), label: 'Terminal'),
          ],
        ),
      ),
    );
  }
}

/// Server setup and disconnect, shared by the chat list and chat screens.
class ServerMenu extends StatelessWidget {
  const ServerMenu({super.key, required this.busy});
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final session = context.read<SessionState>();
    return PopupMenuButton<String>(
      onSelected: (v) async {
        switch (v) {
          case 'setup':
            await context.read<TerminalSession>().stop();
            await session.reopenSetup();
          case 'disconnect':
            session.disconnect();
            if (context.mounted) Navigator.of(context).pop();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'setup',
          child: ListTile(leading: Icon(Icons.build_circle_outlined), title: Text('Server setup'), dense: true),
        ),
        PopupMenuItem(
          value: 'disconnect',
          child: ListTile(leading: Icon(Icons.logout), title: Text('Disconnect'), dense: true),
        ),
      ],
    );
  }
}

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

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
                    : session.error ?? 'Connection lost. Running agent tasks continue on the server.',
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

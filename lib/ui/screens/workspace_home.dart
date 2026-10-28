import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../../state/terminal_session.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'artifacts_screen.dart';
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
            IconButton(
              tooltip: 'Agent',
              onPressed: () => _agentMenu(context, convo),
              icon: const Icon(Icons.hub_outlined),
            ),
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

extension on WorkspaceHomeState {
  /// Artifacts, plus the agy panels that only exist in the interactive TUI,
  /// opened on this chat's own conversation so its subagents, background
  /// tasks and context are the ones shown.
  Future<void> _agentMenu(BuildContext context, Conversation convo) async {
    final terminal = context.read<TerminalSession>();
    final convoId = convo.agyConversationId;
    Future<void> inTerminal(String command) async {
      Navigator.pop(context);
      showTab(3);
      await terminal.runSlashCommand(command, conversationId: convoId);
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text('Agent', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  convoId == null
                      ? 'Send a message first to give this chat an agy conversation.'
                      : 'Panels below open this chat in the interactive terminal.',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                ),
              ),
              _item(sheet, Icons.description_outlined, 'Artifacts', 'Plans, task lists and walkthroughs', () {
                Navigator.pop(sheet);
                final session = context.read<SessionState>();
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => ArtifactsScreen(conversation: convo, session: session)));
              }),
              _item(sheet, Icons.account_tree_outlined, 'Subagents', 'See subagents and message them (/agents)',
                  () => inTerminal('/agents')),
              _item(sheet, Icons.pending_actions_outlined, 'Background tasks', 'Monitor and stop shell tasks (/tasks)',
                  () => inTerminal('/tasks')),
              _item(sheet, Icons.terminal, 'Continue in terminal', 'This chat in the full agy interface',
                  () => inTerminal('')),
              _item(sheet, Icons.data_usage, 'Usage & quota', 'Model quota usage (/usage)', () => inTerminal('/usage')),
              _item(sheet, Icons.donut_large, 'Context window', 'How full the context is (/context)',
                  () => inTerminal('/context')),
              _item(sheet, Icons.rule, 'Permissions', 'Allow rules for tools (/permissions)',
                  () => inTerminal('/permissions')),
              _item(sheet, Icons.extension_outlined, 'MCP servers', 'Manage MCP servers (/mcp)', () => inTerminal('/mcp')),
              _item(sheet, Icons.tune, 'agy settings', 'Settings editor (/config)', () => inTerminal('/config')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, IconData icon, String title, String subtitle, VoidCallback onTap) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
        onTap: onTap,
      );
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

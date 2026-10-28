import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/agent_options.dart';
import '../../models/conversation.dart';
import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../../state/terminal_session.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/message_widgets.dart';
import '../widgets/remote_browser.dart';
import 'agent_settings_screen.dart';
import 'artifacts_screen.dart';
import 'project_picker.dart';
import 'server_tools_screen.dart';
import 'workspace_home.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final convo = chat.current;
    final messages = convo?.messages ?? const <ChatMessage>[];
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? _Welcome(onPick: (s) {
                  chat.draft.text = s;
                  chat.draft.selection = TextSelection.collapsed(offset: s.length);
                })
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[messages.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: m.role == MessageRole.user
                          ? UserBubble(message: m)
                          : AgentMessageView(
                              message: m,
                              onCancel: chat.busy ? chat.cancel : null,
                              onResume: chat.resumePending,
                              onViewChanges: () => WorkspaceHomeState.of(context)?.showTab(2),
                            ),
                    );
                  },
                ),
        ),
        const _Composer(),
      ],
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onPick});
  final void Function(String) onPick;

  static const _projectSuggestions = [
    ('Explain this codebase', 'Give me an overview of this codebase: structure, main components and how to run it.'),
    ('Find bugs', 'Look for likely bugs or risky code in this project and suggest fixes.'),
    ('Write tests', 'Add tests for the most important untested code in this project.'),
    ('Review changes', 'Review my uncommitted changes and point out problems.'),
  ];

  static const _chatSuggestions = [
    ('Plan a project', 'Help me plan a new project: goals, architecture and first steps.'),
    ('Write a script', 'Write a small script that '),
    ('Explain a concept', 'Explain how '),
    ('Check the server', 'Check this server: disk space, memory, running services and anything that looks wrong.'),
  ];

  @override
  Widget build(BuildContext context) {
    final project = context.watch<ChatController>().current?.project;
    final suggestions = project == null ? _chatSuggestions : _projectSuggestions;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        const Center(child: AgLogo(size: 56)),
        const SizedBox(height: 20),
        Text(project == null ? 'What can I help with?' : 'What should we build in ${baseName(project)}?',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
            project == null
                ? 'This chat is not in a project. Pick one with the project chip below to let the agent work in a folder.'
                : 'The agent runs on your server with full access to this project.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMuted)),
        const SizedBox(height: 28),
        for (final (title, prompt) in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.auto_awesome, size: 18, color: AppColors.accentAlt),
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(prompt,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                onTap: () => onPick(prompt),
              ),
            ),
          ),
      ],
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer();

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send(ChatController chat) async {
    final session = context.read<SessionState>();
    if (!session.isConnected) {
      showSnack(context, 'Not connected. Reconnect to send.');
      return;
    }
    final text = chat.draft.text;
    if (text.trim().startsWith('/') && await _handleSlash(text.trim())) {
      chat.draft.clear();
      return;
    }
    final ok = await chat.send(text);
    if (ok) chat.draft.clear();
  }

  /// Handles slash commands that need the app or the interactive TUI.
  /// Returns true if handled; anything else is sent to agy as a prompt.
  Future<bool> _handleSlash(String text) async {
    final words = text.split(RegExp(r'\s+'));
    final cmd = _slashAliases[words.first.toLowerCase()] ?? words.first.toLowerCase();
    final arg = words.skip(1).join(' ').trim();
    final chat = context.read<ChatController>();
    final session = context.read<SessionState>();
    switch (cmd) {
      case '/new':
        chat.newChat(project: chat.current?.project);
        return true;
      case '/model':
        await showModelPicker(context);
        return true;
      case '/effort':
        await _effortPicker(chat);
        return true;
      case '/mode':
        await showModePicker(context);
        return true;
      case '/permissions':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AgentSettingsScreen(session: session)));
        return true;
      case '/artifact':
        final c = chat.current;
        if (c != null) {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => ArtifactsScreen(conversation: c, session: session)));
        }
        return true;
      case '/remote-control':
      case '/changelog':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerToolsScreen(session: session)));
        return true;
      case '/rename':
        final c = chat.current;
        if (c != null && arg.isNotEmpty && c.messages.isNotEmpty) await chat.rename(c.id, arg);
        return true;
      case '/copy':
        final last = chat.current?.messages.lastWhere((m) => m.role == MessageRole.agent,
            orElse: () => ChatMessage(id: '', role: MessageRole.agent, createdAt: DateTime.now()));
        if (last != null && last.plainText.isNotEmpty && mounted) await copyText(context, last.plainText);
        return true;
      case '/add-dir':
        await pickExtraFolders(context);
        return true;
      case '/voice':
        if (mounted) showSnack(context, "Use your keyboard's dictation (microphone) key to speak a prompt.");
        return true;
    }
    final command = slashCommands.where((c) => c.name == cmd).firstOrNull;
    if (command != null && command.terminal) {
      await _runInTerminal(arg.isEmpty ? cmd + (command.takesArgument ? ' ' : '') : '$cmd $arg');
      return true;
    }
    return false;
  }

  Future<void> _runInTerminal(String text) async {
    final terminal = context.read<TerminalSession>();
    WorkspaceHomeState.of(context)?.showTab(3);
    await terminal.runSlashCommand(text, conversationId: context.read<ChatController>().current?.agyConversationId);
  }

  Future<void> _slashSheet() async {
    final picked = await showModalBottomSheet<SlashCommand>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _SlashSheet(),
    );
    if (picked == null || !mounted) return;
    final chat = context.read<ChatController>();
    if (picked.takesArgument) {
      chat.draft.text = '${picked.name} ';
      chat.draft.selection = TextSelection.collapsed(offset: chat.draft.text.length);
      _focus.requestFocus();
      return;
    }
    if (!await _handleSlash(picked.name)) {
      chat.draft.text = picked.name;
      await _send(chat);
    }
  }

  Future<void> _mention() async {
    final session = context.read<SessionState>();
    final chat = context.read<ChatController>();
    final ws = session.workspace!;
    final path = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Mention a file', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: RemoteBrowser(
                agy: session.agy!,
                initialPath: ws,
                rootPath: ws,
                onFileTap: (f) => Navigator.pop(context, f.path),
                footerBuilder: (context, dir) => SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, dir),
                      child: const Text('Mention this folder'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (path == null) return;
    insertMention(chat, ws, path);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final session = context.watch<SessionState>();
    final opts = chat.options;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _ProjectChip(convo: chat.current),
                  const SizedBox(width: 6),
                  if (chat.current != null &&
                      (chat.current!.extraDirs.isNotEmpty ||
                          (chat.current!.project != null && chat.current!.messages.isEmpty))) ...[
                    _OptionChip(
                      key: const Key('folders-chip'),
                      icon: Icons.create_new_folder_outlined,
                      label: chat.current!.extraDirs.isEmpty ? 'Folders' : '+${chat.current!.extraDirs.length} folders',
                      locked: chat.current!.messages.isNotEmpty,
                      onTap: () => pickExtraFolders(context),
                    ),
                    const SizedBox(width: 6),
                  ],
                  _OptionChip(
                    icon: _modeIcon(opts.permissionMode),
                    label: opts.permissionMode.label,
                    highlight: opts.permissionMode == PermissionMode.fullAuto,
                    onTap: () => showModePicker(context),
                  ),
                  const SizedBox(width: 6),
                  _OptionChip(
                    key: const Key('agent-chip'),
                    icon: Icons.smart_toy_outlined,
                    label: opts.agent == null ? 'Default agent' : 'Agent: ${opts.agent}',
                    onTap: () => showAgentPicker(context),
                  ),
                  const SizedBox(width: 6),
                  _OptionChip(
                    icon: Icons.memory,
                    label: opts.model ?? 'Default model',
                    onTap: () => showModelPicker(context),
                  ),
                  const SizedBox(width: 6),
                  _OptionChip(
                    icon: Icons.speed,
                    label: opts.effort == Effort.auto ? 'Effort: auto' : 'Effort: ${opts.effort.name}',
                    onTap: () => _effortPicker(chat),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Commands',
                    onPressed: _slashSheet,
                    icon: const Text('/', style: TextStyle(fontSize: 20, color: AppColors.textMuted)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: chat.draft,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(
                        hintText: session.isConnected ? 'Ask Antigravity…' : 'Disconnected',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Mention a file',
                    onPressed: session.isConnected ? _mention : null,
                    icon: const Icon(Icons.alternate_email, color: AppColors.textMuted, size: 21),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
                    child: chat.busy
                        ? IconButton.filled(
                            tooltip: 'Stop',
                            style: IconButton.styleFrom(backgroundColor: AppColors.surfaceHighest),
                            onPressed: chat.cancel,
                            icon: const Icon(Icons.stop_rounded, color: AppColors.text),
                          )
                        : ValueListenableBuilder(
                            valueListenable: chat.draft,
                            builder: (context, value, _) => IconButton.filled(
                              tooltip: 'Send',
                              style: IconButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                disabledBackgroundColor: AppColors.surfaceHighest,
                              ),
                              onPressed: value.text.trim().isEmpty || !session.isConnected
                                  ? null
                                  : () => _send(chat),
                              icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _effortPicker(ChatController chat) async {
    final picked = await showModalBottomSheet<Effort>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Reasoning effort', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final e in Effort.values)
              ListTile(
                leading: Icon(e == chat.options.effort ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: AppColors.accent),
                title: Text(e == Effort.auto
                    ? 'Auto (agy default)'
                    : e == Effort.max
                        ? 'Max (only some models)'
                        : e.name[0].toUpperCase() + e.name.substring(1)),
                onTap: () => Navigator.pop(context, e),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await chat.setOptions(chat.options.copyWith(effort: picked));
  }
}

IconData _modeIcon(PermissionMode m) => switch (m) {
      PermissionMode.ask => Icons.shield_outlined,
      PermissionMode.plan => Icons.checklist_rounded,
      PermissionMode.acceptEdits => Icons.edit_outlined,
      PermissionMode.fullAuto => Icons.bolt_rounded,
    };

/// Inserts an `@path` mention (relative to the workspace when possible).
void insertMention(ChatController chat, String workspace, String path) {
  var rel = path;
  if (path.startsWith(workspace)) {
    rel = path.substring(workspace.length).replaceFirst(RegExp(r'^[\\/]+'), '');
    if (rel.isEmpty) rel = '.';
  }
  final mention = rel.contains(' ') ? '@"$rel"' : '@$rel';
  final text = chat.draft.text;
  final sel = chat.draft.selection;
  final at = sel.isValid ? sel.start : text.length;
  final before = text.substring(0, at);
  final after = text.substring(sel.isValid ? sel.end : text.length);
  final pad = before.isEmpty || before.endsWith(' ') ? '' : ' ';
  final inserted = '$pad$mention ';
  chat.draft.text = '$before$inserted$after';
  chat.draft.selection = TextSelection.collapsed(offset: before.length + inserted.length);
}

/// The chat's project. Changeable until the first message is sent, since
/// agy ties a conversation to its folder.
class _ProjectChip extends StatelessWidget {
  const _ProjectChip({required this.convo});
  final Conversation? convo;

  @override
  Widget build(BuildContext context) {
    final c = convo;
    if (c == null) return const SizedBox.shrink();
    final locked = c.messages.isNotEmpty;
    final label = c.project == null ? 'No project' : baseName(c.project!);
    return _OptionChip(
      key: const Key('project-chip'),
      icon: c.project == null ? Icons.chat_bubble_outline : Icons.folder_rounded,
      label: label,
      locked: locked,
      onTap: () async {
        if (locked) {
          showSnack(context, c.project == null
              ? 'This chat is not in a project. Start a new chat to use one.'
              : 'This chat belongs to ${c.project}.');
          return;
        }
        final choice = await pickProject(context, current: c.project);
        if (choice != null && context.mounted) context.read<ChatController>().setProject(choice.path);
      },
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight = false,
    this.locked = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final color = highlight ? AppColors.warning : AppColors.textMuted;
    return Material(
      color: AppColors.surface,
      shape: StadiumBorder(side: BorderSide(color: highlight ? AppColors.warning.withValues(alpha: 0.5) : AppColors.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: highlight ? AppColors.warning : AppColors.text)),
              ),
              if (!locked) const Icon(Icons.arrow_drop_down, size: 16, color: AppColors.textFaint),
              if (locked) const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showModePicker(BuildContext context) async {
  final chat = context.read<ChatController>();
  final picked = await showModalBottomSheet<PermissionMode>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('What may the agent do?', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final m in PermissionMode.values)
            ListTile(
              leading: Icon(_modeIcon(m),
                  color: m == chat.options.permissionMode ? AppColors.accent : AppColors.textMuted),
              title: Text(m.label),
              subtitle: Text(m.description, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
              trailing: m == chat.options.permissionMode ? const Icon(Icons.check, color: AppColors.accent) : null,
              onTap: () => Navigator.pop(context, m),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Chat replies run headless, so agy cannot stop to ask: tools that need approval are skipped and listed in the reply. '
              'Allow them with permission rules (Agent menu → Permissions & settings), or use the Terminal for step-by-step approvals '
              'and the Auto (Preview) mode.',
              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
          ),
        ],
      ),
    ),
  );
  if (picked != null) await chat.setOptions(chat.options.copyWith(permissionMode: picked));
}

/// Custom agents from `agy agents`, used with `--agent`.
Future<void> showAgentPicker(BuildContext context) async {
  final chat = context.read<ChatController>();
  final agy = context.read<SessionState>().agy;
  if (agy == null) return;
  final agents = await agy.listAgents();
  if (!context.mounted) return;
  final custom = TextEditingController();
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Center(child: Text('Agent', style: TextStyle(fontWeight: FontWeight.w600))),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Custom agents are Markdown files in .agents/agents/ (project) or ~/.gemini/config/agents/ (global).',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
            ListTile(
              leading: Icon(chat.options.agent == null ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: AppColors.accent),
              title: const Text('Default agent'),
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final a in agents)
              ListTile(
                leading: Icon(chat.options.agent == a ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: AppColors.accent),
                title: Text(a),
                onTap: () => Navigator.pop(context, a),
              ),
            if (agents.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('`agy agents` listed no custom agents.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: TextField(
                controller: custom,
                decoration: InputDecoration(
                  labelText: 'Agent name',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.check),
                    onPressed: () => Navigator.pop(context, custom.text.trim()),
                  ),
                ),
                onSubmitted: (v) => Navigator.pop(context, v.trim()),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null) return;
  await chat.setOptions(
      picked.isEmpty ? chat.options.copyWith(clearAgent: true) : chat.options.copyWith(agent: picked));
}

Future<void> showModelPicker(BuildContext context) async {
  final chat = context.read<ChatController>();
  final session = context.read<SessionState>();
  if ((session.auth?.models ?? const []).isEmpty && session.isConnected) {
    await session.checkAuth();
  }
  if (!context.mounted) return;
  final models = session.auth?.models ?? const <String>[];
  final custom = TextEditingController();
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Center(child: Text('Model', style: TextStyle(fontWeight: FontWeight.w600))),
              ),
              ListTile(
                leading: Icon(chat.options.model == null ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: AppColors.accent),
                title: const Text('Default'),
                subtitle: const Text('Whatever agy is configured to use'),
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final m in models)
                ListTile(
                  leading: Icon(chat.options.model == m ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: AppColors.accent),
                  title: Text(m),
                  onTap: () => Navigator.pop(context, m),
                ),
              if (models.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('Could not list models from `agy models`. Enter a model name below.',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: TextField(
                  controller: custom,
                  decoration: InputDecoration(
                    labelText: 'Other model',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.check),
                      onPressed: () => Navigator.pop(context, custom.text.trim()),
                    ),
                  ),
                  onSubmitted: (v) => Navigator.pop(context, v.trim()),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (picked == null) return;
  await chat.setOptions(
      picked.isEmpty ? chat.options.copyWith(clearModel: true) : chat.options.copyWith(model: picked));
}

class SlashCommand {
  const SlashCommand(this.name, this.description,
      {this.terminal = false, this.app = false, this.takesArgument = false});
  final String name;
  final String description;

  /// Interactive panels that only exist in the TUI.
  final bool terminal;

  /// Handled by the app itself.
  final bool app;
  final bool takesArgument;
}

/// Every slash command in the agy reference. `app` ones are handled here,
/// `terminal` ones are interactive panels opened on this chat's
/// conversation, and the rest are sent to the agent as prompts.
const slashCommands = [
  // In the app.
  SlashCommand('/new', 'New chat (also /clear)', app: true),
  SlashCommand('/model', 'Choose the model', app: true),
  SlashCommand('/effort', 'Reasoning effort, low to max', app: true),
  SlashCommand('/mode', 'Default, Plan, Accept edits or Full auto', app: true),
  SlashCommand('/permissions', 'Allow / ask / deny rules', app: true),
  SlashCommand('/artifact', 'Artifacts of this chat', app: true),
  SlashCommand('/rename', 'Rename this chat', app: true, takesArgument: true),
  SlashCommand('/copy', 'Copy the last reply', app: true),
  SlashCommand('/add-dir', 'Add another folder (before the first message)', app: true),
  SlashCommand('/remote-control', 'Remote Control, MCP, plugins, update', app: true),
  SlashCommand('/changelog', 'agy release notes', app: true),
  // Sent to the agent.
  SlashCommand('/plan', 'Investigate and draft an implementation plan', takesArgument: true),
  SlashCommand('/goal', 'Work autonomously until the goal is verified', takesArgument: true),
  SlashCommand('/grill-me', 'Agent interviews you before starting', takesArgument: true),
  SlashCommand('/boost', 'Multi-agent deep reasoning (paid plans)', takesArgument: true),
  SlashCommand('/teamwork-preview', 'Multi-agent teams (paid plans)', takesArgument: true),
  SlashCommand('/learn', 'Turn corrections into rules or skills', takesArgument: true),
  // Interactive panels, in the terminal.
  SlashCommand('/agents', 'Subagents: watch, approve, message', terminal: true),
  SlashCommand('/tasks', 'Background tasks: logs, stop', terminal: true),
  SlashCommand('/diff', 'Review per-turn changes, comment lines', terminal: true),
  SlashCommand('/rewind', 'Roll back to an earlier message', terminal: true),
  SlashCommand('/fork', 'Branch this conversation', terminal: true),
  SlashCommand('/btw', 'Side question without interrupting', terminal: true, takesArgument: true),
  SlashCommand('/schedule', 'Run a task later or on a cron', terminal: true, takesArgument: true),
  SlashCommand('/browser', 'Browser subagent driving Chrome', terminal: true, takesArgument: true),
  SlashCommand('/codesearch', 'Code search panel', terminal: true),
  SlashCommand('/usage', 'Model quota (also /quota)', terminal: true),
  SlashCommand('/credits', 'AI credits', terminal: true),
  SlashCommand('/context', 'Context-window usage', terminal: true),
  SlashCommand('/resume', 'Conversations started elsewhere', terminal: true),
  SlashCommand('/skills', 'Browse skills', terminal: true),
  SlashCommand('/hooks', 'Browse hooks', terminal: true),
  SlashCommand('/mcp', 'MCP server manager', terminal: true),
  SlashCommand('/plugin', 'Plugin manager and marketplace', terminal: true),
  SlashCommand('/config', 'All settings', terminal: true),
  SlashCommand('/keybindings', 'Keyboard shortcuts', terminal: true),
  SlashCommand('/statusline', 'Status bar', terminal: true),
  SlashCommand('/title', 'Terminal title', terminal: true),
  SlashCommand('/feedback', 'Send feedback', terminal: true),
  SlashCommand('/logout', 'Sign out of agy', terminal: true),
  SlashCommand('/help', 'Commands and shortcuts', terminal: true),
];

/// Aliases from the agy reference.
const _slashAliases = {
  '/clear': '/new',
  '/quota': '/usage',
  '/settings': '/config',
  '/switch': '/resume',
  '/conversation': '/resume',
  '/undo': '/rewind',
  '/branch': '/fork',
  '/cs': '/codesearch',
  '/search': '/codesearch',
  '/plugins': '/plugin',
  '/teamwork': '/teamwork-preview',
};

class _SlashSheet extends StatelessWidget {
  const _SlashSheet();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Commands', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final c in slashCommands)
            ListTile(
              dense: true,
              leading: Text(c.name, style: monoStyle(size: 13.5, color: AppColors.accent)),
              title: Text(c.description, style: const TextStyle(fontSize: 13.5)),
              trailing: c.terminal
                  ? const Tooltip(
                      message: 'Opens in the Terminal tab',
                      child: Icon(Icons.terminal, size: 16, color: AppColors.textFaint))
                  : c.app
                      ? const Tooltip(
                          message: 'Handled in the app',
                          child: Icon(Icons.phone_android, size: 16, color: AppColors.textFaint))
                      : const Tooltip(
                          message: 'Sent to the agent',
                          child: Icon(Icons.auto_awesome, size: 16, color: AppColors.textFaint)),
              onTap: () => Navigator.pop(context, c),
            ),
        ],
      ),
    );
  }
}

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

  static const _suggestions = [
    ('Explain this codebase', 'Give me an overview of this codebase: structure, main components and how to run it.'),
    ('Find bugs', 'Look for likely bugs or risky code in this project and suggest fixes.'),
    ('Write tests', 'Add tests for the most important untested code in this project.'),
    ('Review changes', 'Review my uncommitted changes and point out problems.'),
  ];

  @override
  Widget build(BuildContext context) {
    final ws = context.read<SessionState>().workspace ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        const Center(child: AgLogo(size: 56)),
        const SizedBox(height: 20),
        Text('What should we build in ${baseName(ws)}?',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('The agent runs on your server with full access to this workspace.',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted)),
        const SizedBox(height: 28),
        for (final (title, prompt) in _suggestions)
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
    final cmd = text.split(RegExp(r'\s+')).first.toLowerCase();
    final chat = context.read<ChatController>();
    switch (cmd) {
      case '/new':
      case '/clear':
        chat.newConversation();
        return true;
      case '/model':
        await showModelPicker(context);
        return true;
      case '/mode':
      case '/permissions-mode':
        await showModePicker(context);
        return true;
      case '/plan':
      case '/planning':
        await chat.setOptions(chat.options.copyWith(permissionMode: PermissionMode.plan));
        if (mounted) showSnack(context, 'Plan mode on');
        return true;
    }
    final command = slashCommands.where((c) => c.name == cmd).firstOrNull;
    if (command != null && command.terminal) {
      await _runInTerminal(text);
      return true;
    }
    return false;
  }

  Future<void> _runInTerminal(String text) async {
    final terminal = context.read<TerminalSession>();
    WorkspaceHomeState.of(context)?.showTab(3);
    await terminal.runSlashCommand(text);
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
                  _OptionChip(
                    icon: _modeIcon(opts.permissionMode),
                    label: opts.permissionMode.label,
                    highlight: opts.permissionMode == PermissionMode.fullAuto,
                    onTap: () => showModePicker(context),
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
                title: Text(e == Effort.auto ? 'Auto (agy default)' : e.name[0].toUpperCase() + e.name.substring(1)),
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

class _OptionChip extends StatelessWidget {
  const _OptionChip({required this.icon, required this.label, required this.onTap, this.highlight = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;

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
              const Icon(Icons.arrow_drop_down, size: 16, color: AppColors.textFaint),
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
              'Chat replies run headless, so agy cannot stop to ask for approval. For step-by-step approvals use the Terminal tab.',
              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
          ),
        ],
      ),
    ),
  );
  if (picked != null) await chat.setOptions(chat.options.copyWith(permissionMode: picked));
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
  const SlashCommand(this.name, this.description, {this.terminal = false, this.takesArgument = false});
  final String name;
  final String description;

  /// Interactive panels that only exist in the TUI.
  final bool terminal;
  final bool takesArgument;
}

const slashCommands = [
  SlashCommand('/new', 'Start a new conversation'),
  SlashCommand('/model', 'Choose the model'),
  SlashCommand('/mode', 'Choose what the agent may do'),
  SlashCommand('/plan', 'Plan before acting'),
  SlashCommand('/boost', 'Multi-agent deep reasoning on a task', takesArgument: true),
  SlashCommand('/fast', 'Skip planning for quick actions', takesArgument: true),
  SlashCommand('/btw', 'Ask a side question', takesArgument: true),
  SlashCommand('/config', 'Settings editor', terminal: true),
  SlashCommand('/permissions', 'Tool permission rules', terminal: true),
  SlashCommand('/mcp', 'MCP server manager', terminal: true),
  SlashCommand('/agents', 'Agent manager and background subagents', terminal: true),
  SlashCommand('/skills', 'Browse loaded skills', terminal: true),
  SlashCommand('/artifact', 'Artifact review panel', terminal: true),
  SlashCommand('/diff', 'Interactive diff viewer', terminal: true),
  SlashCommand('/resume', 'Resume an earlier agy conversation', terminal: true),
  SlashCommand('/rewind', 'Roll history back', terminal: true),
  SlashCommand('/tasks', 'Background shell tasks', terminal: true),
  SlashCommand('/context', 'Context-window usage', terminal: true),
  SlashCommand('/usage', 'Model quota usage', terminal: true),
  SlashCommand('/credits', 'Credits', terminal: true),
  SlashCommand('/hooks', 'Review hooks', terminal: true),
  SlashCommand('/logout', 'Sign out of agy', terminal: true),
  SlashCommand('/help', 'Commands and shortcuts', terminal: true),
];

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
                  : null,
              onTap: () => Navigator.pop(context, c),
            ),
        ],
      ),
    );
  }
}

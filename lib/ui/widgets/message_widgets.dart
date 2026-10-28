import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../services/agent_stream_parser.dart';
import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../screens/agent_settings_screen.dart';
import '../screens/artifacts_screen.dart';
import '../theme/app_theme.dart';
import 'common.dart';
import 'markdown_view.dart';

class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final text = message.parts.map((p) => p.text).join('\n');
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        child: GestureDetector(
          onLongPress: () => copyText(context, text),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.16),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
            ),
            child: Text(text, style: const TextStyle(fontSize: 15, height: 1.45)),
          ),
        ),
      ),
    );
  }
}

/// An agent reply laid out like the Antigravity agent panel: text flows
/// full-width, tool calls render as compact cards.
class AgentMessageView extends StatelessWidget {
  const AgentMessageView({
    super.key,
    required this.message,
    this.onCancel,
    this.onResume,
    this.onViewChanges,
  });

  final ChatMessage message;
  final VoidCallback? onCancel;
  final VoidCallback? onResume;

  /// Shown on replies where the agent edited files.
  final VoidCallback? onViewChanges;

  @override
  Widget build(BuildContext context) {
    final parts = message.parts;
    final active = message.isActive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const AgLogo(size: 20),
            const SizedBox(width: 8),
            const Text('Antigravity',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            const SizedBox(width: 8),
            _StatusLabel(message: message),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < parts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PartView(
              part: parts[i],
              live: active && i == parts.length - 1,
            ),
          ),
        if (active && parts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: _TypingDots(),
          ),
        if (message.status == MessageStatus.interrupted)
          _InlineNotice(
            icon: Icons.link_off,
            text: 'Lost connection while the agent was working. It keeps running on the server.',
            action: onResume == null ? null : TextButton(onPressed: onResume, child: const Text('Resume')),
          ),
        if (message.status == MessageStatus.cancelled)
          const _InlineNotice(icon: Icons.stop_circle_outlined, text: 'Stopped.'),
        if (!active) _Footer(message: message, onViewChanges: madeChanges(message) ? onViewChanges : null),
        if (active && onCancel != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: TextButton.icon(
              onPressed: onCancel,
              style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: const Text('Stop'),
            ),
          ),
      ],
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final (String text, Color color) = switch (message.status) {
      MessageStatus.pending => ('starting…', AppColors.textMuted),
      MessageStatus.streaming => (_activity(message), AppColors.accent),
      MessageStatus.error => ('error', AppColors.danger),
      MessageStatus.cancelled => ('stopped', AppColors.textMuted),
      MessageStatus.interrupted => ('disconnected', AppColors.warning),
      MessageStatus.done => ('', AppColors.textMuted),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isActive) ...[
          SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color)),
          const SizedBox(width: 6),
        ],
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }

  static String _activity(ChatMessage m) {
    if (m.parts.isEmpty) return 'thinking…';
    final last = m.parts.last;
    return switch (last.kind) {
      PartKind.thinking => 'thinking…',
      PartKind.tool when last.toolStatus == ToolStatus.running => 'running ${_humanTool(last.toolName)}…',
      _ => 'working…',
    };
  }
}

class _PartView extends StatelessWidget {
  const _PartView({required this.part, required this.live});
  final MessagePart part;
  final bool live;

  @override
  Widget build(BuildContext context) {
    switch (part.kind) {
      case PartKind.text:
        return MarkdownView(part.text, selectable: !live);
      case PartKind.thinking:
        return _Collapsible(
          icon: Icons.psychology_outlined,
          title: live ? 'Thinking' : 'Thought',
          initiallyExpanded: live,
          child: Text(part.text,
              style: const TextStyle(
                  color: AppColors.textMuted, fontStyle: FontStyle.italic, height: 1.45, fontSize: 13.5)),
        );
      case PartKind.tool:
        return ToolCard(part: part);
      case PartKind.error:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
              const SizedBox(width: 10),
              Expanded(child: SelectableText(part.text, style: monoStyle(size: 12.5))),
            ],
          ),
        );
      case PartKind.artifact:
        return _ArtifactCard(part: part);
      case PartKind.subagent:
        return _SubagentCard(part: part);
      case PartKind.notice when part.toolName == permissionsNotice:
        return _SkippedToolsCard(part: part);
      case PartKind.notice:
        return _Collapsible(
          icon: Icons.notes,
          title: 'Output',
          initiallyExpanded: false,
          child: SelectableText(part.text, style: monoStyle(size: 12, color: AppColors.textMuted)),
        );
    }
  }
}

String _humanTool(String? name) {
  if (name == null || name.isEmpty) return 'tool';
  final spaced = name
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .trim()
      .toLowerCase();
  return spaced;
}

/// A compact card for one tool call; tap to see its input and output.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.part});
  final MessagePart part;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;

  static IconData _icon(String name) {
    final n = name.toLowerCase();
    if (n.contains('command') || n.contains('shell') || n.contains('bash') || n.contains('terminal') || n.contains('exec')) {
      return Icons.terminal_rounded;
    }
    if (n.contains('write') || n.contains('edit') || n.contains('replace') || n.contains('patch') || n.contains('create')) {
      return Icons.edit_note_rounded;
    }
    if (n.contains('read') || n.contains('view') || n.contains('open') || n.contains('cat')) {
      return Icons.description_outlined;
    }
    if (n.contains('search') || n.contains('grep') || n.contains('find') || n.contains('glob') || n.contains('list')) {
      return Icons.search_rounded;
    }
    if (n.contains('web') || n.contains('fetch') || n.contains('browser') || n.contains('url')) {
      return Icons.public_rounded;
    }
    if (n.contains('agent') || n.contains('task')) return Icons.hub_outlined;
    return Icons.build_outlined;
  }

  /// Picks the most telling argument (command, path, query…) to show inline.
  static String? summary(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(input);
      if (decoded is Map) {
        for (final key in const [
          'command', 'CommandLine', 'cmd', 'file_path', 'filePath', 'path', 'AbsolutePath',
          'TargetFile', 'pattern', 'query', 'Query', 'url', 'Url', 'description', 'prompt',
        ]) {
          final v = decoded[key];
          if (v is String && v.trim().isNotEmpty) return v.trim().split('\n').first;
          if (v is List && v.isNotEmpty) return v.join(' ');
        }
        for (final v in decoded.values) {
          if (v is String && v.trim().isNotEmpty && v.length < 200) return v.trim().split('\n').first;
        }
        return null;
      }
    } catch (_) {}
    return input.trim().split('\n').first;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.part;
    final name = p.toolName ?? 'tool';
    final sub = summary(p.toolInput);
    final statusIcon = switch (p.toolStatus) {
      ToolStatus.running => const SizedBox(
          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
      ToolStatus.done => const Icon(Icons.check_rounded, size: 16, color: AppColors.success),
      ToolStatus.failed => const Icon(Icons.close_rounded, size: 16, color: AppColors.danger),
    };
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
              child: Row(
                children: [
                  Icon(_icon(name), size: 17, color: AppColors.textMuted),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: _humanTool(name),
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        if (sub != null)
                          TextSpan(text: '  $sub', style: monoStyle(size: 12, color: AppColors.textMuted)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  statusIcon,
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppColors.textFaint),
                ],
              ),
            ),
          ),
          if (_open) ...[
            const Divider(height: 1),
            if (p.toolInput != null && p.toolInput!.isNotEmpty) _section('Input', p.toolInput!),
            if (p.toolOutput != null && p.toolOutput!.isNotEmpty) _section('Output', p.toolOutput!),
            if ((p.toolInput ?? '').isEmpty && (p.toolOutput ?? '').isEmpty)
              const Padding(
                padding: EdgeInsets.all(10),
                child: Text('No details reported.', style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
              ),
          ],
        ],
      ),
    );
  }

  Widget _section(String label, String text) {
    final lines = text.split('\n');
    final shown = lines.length > 400 ? '${lines.take(400).join('\n')}\n… ${lines.length - 400} more lines' : text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textFaint, letterSpacing: 0.6)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(shown, style: monoStyle(size: 11.5, color: AppColors.textMuted)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Collapsible extends StatefulWidget {
  const _Collapsible({
    required this.icon,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });
  final IconData icon;
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 16, color: AppColors.textFaint),
                const SizedBox(width: 6),
                Text(widget.title, style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: AppColors.textFaint),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(top: 4, left: 7),
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: AppColors.border, width: 2)),
            ),
            child: widget.child,
          ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: AppColors.textMuted, fontSize: 13))),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Whether the agent edited, created or deleted files in this reply.
bool madeChanges(ChatMessage m) => m.parts.any((p) =>
    p.kind == PartKind.tool &&
    p.toolStatus != ToolStatus.failed &&
    RegExp(r'write|edit|replace|patch|create|delete|remove|move|rename|apply', caseSensitive: false)
        .hasMatch(p.toolName ?? ''));

/// A subagent the agent started: open its own chat, or read its log.
class _SubagentCard extends StatelessWidget {
  const _SubagentCard({required this.part});
  final MessagePart part;

  SubagentInfo? get _info {
    try {
      return SubagentInfo.fromJson(Map<String, dynamic>.from(jsonDecode(part.toolInput ?? '{}') as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> _openChat(BuildContext context, SubagentInfo info) async {
    final id = info.conversationId;
    if (id == null) return;
    final ok = await context
        .read<ChatController>()
        .openSubagent(agyConversationId: id, role: info.role ?? info.typeName ?? 'subagent');
    if (!ok && context.mounted) showSnack(context, 'Wait for the current reply to finish first.');
  }

  void _openLog(BuildContext context, SubagentInfo info) {
    final uri = Uri.tryParse(info.logUri ?? '');
    final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : info.logUri;
    if (path == null) return;
    openArtifact(context, ArtifactRef(name: '${info.role ?? 'subagent'} log.json', path: path));
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final role = info?.role ?? part.toolName ?? 'Subagent';
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 18, color: AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: role, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  if (info?.typeName != null)
                    TextSpan(text: '  ${info!.typeName}', style: monoStyle(size: 11.5, color: AppColors.textMuted)),
                ])),
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            children: [
              if (info?.conversationId != null)
                TextButton.icon(
                  onPressed: () => _openChat(context, info!),
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: const Text('Open chat'),
                ),
              if (info?.logUri != null)
                TextButton.icon(
                  onPressed: () => _openLog(context, info!),
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: const Text('View log'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tools headless permissions skipped, with a shortcut to allow them.
class _SkippedToolsCard extends StatelessWidget {
  const _SkippedToolsCard({required this.part});
  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.block, size: 18, color: AppColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text('Some tools were skipped (not allowed by your permissions)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(part.text, style: monoStyle(size: 11.5, color: AppColors.textMuted)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                final session = context.read<SessionState>();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => AgentSettingsScreen(session: session)));
              },
              child: const Text('Edit permissions'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.part});
  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    final name = part.toolName ?? 'Artifact';
    return Material(
      color: AppColors.accentAlt.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.accentAlt.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => openArtifact(
            context, ArtifactRef(name: name, path: part.toolInput, content: part.text.isEmpty ? null : part.text)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.description_outlined, size: 20, color: AppColors.accentAlt),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                    const Text('Artifact · tap to open', style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.message, this.onViewChanges});
  final ChatMessage message;
  final VoidCallback? onViewChanges;

  void _raw(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                const Expanded(
                    child: Text('Raw agy output', style: TextStyle(fontWeight: FontWeight.w600))),
                IconButton(
                  onPressed: () => copyText(context, message.rawLines.join('\n')),
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
            if (message.rawLines.isEmpty)
              const Text('Nothing recorded.', style: TextStyle(color: AppColors.textMuted)),
            SelectableText(message.rawLines.join('\n'), style: monoStyle(size: 11, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = message.plainText;
    return Row(
      children: [
        if (onViewChanges != null)
          TextButton.icon(
            onPressed: onViewChanges,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.difference_outlined, size: 16),
            label: const Text('View changes'),
          ),
        if (message.usage != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(message.usage!,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
            ),
          ),
        const Spacer(),
        if (text.isNotEmpty)
          IconButton(
            tooltip: 'Copy reply',
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            onPressed: () => copyText(context, text),
            icon: const Icon(Icons.copy_rounded, color: AppColors.textFaint),
          ),
        IconButton(
          tooltip: 'Raw output',
          visualDensity: VisualDensity.compact,
          iconSize: 17,
          onPressed: () => _raw(context),
          icon: const Icon(Icons.data_object, color: AppColors.textFaint),
        ),
      ],
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final t = ((_c.value * 3) - i).clamp(0.0, 1.0);
          final o = 0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2);
          return Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Opacity(
              opacity: o,
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
              ),
            ),
          );
        }),
      ),
    );
  }
}

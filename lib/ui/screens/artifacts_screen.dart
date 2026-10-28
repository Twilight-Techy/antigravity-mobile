import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../services/agy_service.dart';
import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/markdown_view.dart';

/// An artifact found for a chat: announced in the agent's output, or saved
/// by agy in a folder named after the conversation.
class ArtifactRef {
  const ArtifactRef({required this.name, this.path, this.content, this.size});
  final String name;
  final String? path;
  final String? content;
  final int? size;
}

/// Artifacts the agent reported in this chat's replies.
List<ArtifactRef> artifactsIn(Conversation c) {
  final seen = <String>{};
  final out = <ArtifactRef>[];
  for (final m in c.messages.reversed) {
    for (final p in m.parts.where((p) => p.kind == PartKind.artifact)) {
      final key = p.toolInput ?? p.toolName ?? '';
      if (!seen.add(key)) continue;
      out.add(ArtifactRef(
          name: p.toolName ?? 'Artifact', path: p.toolInput, content: p.text.isEmpty ? null : p.text));
    }
  }
  return out;
}

/// All artifacts for a chat: plans, task lists, walkthroughs and so on.
class ArtifactsScreen extends StatefulWidget {
  const ArtifactsScreen({super.key, required this.conversation, required this.session});
  final Conversation conversation;

  /// Passed in because pushed routes sit outside the session's providers.
  final SessionState session;

  @override
  State<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

class _ArtifactsScreenState extends State<ArtifactsScreen> {
  List<ArtifactRef>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reported = artifactsIn(widget.conversation);
    final id = widget.conversation.agyConversationId;
    final agy = widget.session.agy;
    var found = const <DirEntry>[];
    String? error;
    if (id != null && agy != null) {
      try {
        found = await agy.findArtifacts(id);
      } catch (e) {
        error = e.toString();
      }
    }
    final paths = reported.map((a) => a.path).whereType<String>().toSet();
    if (!mounted) return;
    setState(() {
      _error = error;
      _items = [
        ...reported,
        for (final f in found)
          if (!paths.contains(f.path)) ArtifactRef(name: f.name, path: f.path, size: f.size),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Artifacts'),
        actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? EmptyState(
                  icon: Icons.description_outlined,
                  title: 'No artifacts yet',
                  message: widget.conversation.agyConversationId == null
                      ? 'Artifacts appear once the agent has replied in this chat.'
                      : 'The agent has not saved plans, task lists or walkthroughs for this chat. '
                          'You can also open /artifact from the agent menu.',
                )
              : ListView(
                  children: [
                    if (_error != null)
                      Padding(padding: const EdgeInsets.all(16), child: ErrorPanel(message: _error!)),
                    for (final a in items)
                      ListTile(
                        leading: const Icon(Icons.description_outlined, color: AppColors.accentAlt),
                        title: Text(_title(a.name)),
                        subtitle: Text(
                          [if (a.path != null) a.path!, if (a.size != null) formatBytes(a.size!)].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(size: 11, color: AppColors.textFaint),
                        ),
                        onTap: () => openArtifact(context, a, session: widget.session),
                      ),
                  ],
                ),
    );
  }
}

/// `implementation_plan.md` → `Implementation plan`.
String _title(String name) {
  final base = name.replaceAll(RegExp(r'\.(md|markdown|txt|json|html)$', caseSensitive: false), '');
  final spaced = base.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  return spaced.isEmpty ? name : spaced[0].toUpperCase() + spaced.substring(1);
}

Future<void> openArtifact(BuildContext context, ArtifactRef a, {SessionState? session}) {
  final s = session ?? context.read<SessionState>();
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => ArtifactViewer(artifact: a, session: s)));
}

class ArtifactViewer extends StatefulWidget {
  const ArtifactViewer({super.key, required this.artifact, required this.session});
  final ArtifactRef artifact;
  final SessionState session;

  @override
  State<ArtifactViewer> createState() => _ArtifactViewerState();
}

class _ArtifactViewerState extends State<ArtifactViewer> {
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = widget.artifact;
    final agy = widget.session.agy;
    // Prefer the file on the server (it may have been updated since).
    if (a.path != null && agy != null) {
      try {
        final f = await agy.readFile(a.path!);
        if (mounted) setState(() => _text = f.text);
        return;
      } catch (e) {
        if (a.content == null) {
          if (mounted) setState(() => _error = e.toString());
          return;
        }
      }
    }
    if (mounted) setState(() => _text = a.content ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.artifact;
    final text = _text;
    final isMarkdown = !RegExp(r'\.(json|txt|html)$', caseSensitive: false).hasMatch(a.name);
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(a.name)),
        actions: [
          if (text != null) IconButton(tooltip: 'Copy', onPressed: () => copyText(context, text), icon: const Icon(Icons.copy)),
          IconButton(tooltip: 'Reload', onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _error != null
          ? Padding(padding: const EdgeInsets.all(16), child: ErrorPanel(message: _error!, onRetry: _load))
          : text == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (isMarkdown)
                      MarkdownView(text)
                    else
                      CodeBlock(code: text, language: languageForFile(a.name)),
                  ],
                ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/agy_service.dart';
import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/markdown_view.dart';
import '../widgets/remote_browser.dart';
import 'chat_view.dart';
import 'workspace_home.dart';

class FilesView extends StatelessWidget {
  const FilesView({super.key});

  void _mention(BuildContext context, String path) {
    final session = context.read<SessionState>();
    insertMention(context.read<ChatController>(), session.workspace!, path);
    WorkspaceHomeState.of(context)?.showTab(0);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final agy = session.agy;
    if (agy == null) return const SizedBox.shrink();
    return RemoteBrowser(
      key: ValueKey('files-${session.workspace}-${session.generation}'),
      agy: agy,
      initialPath: session.workspace!,
      onFileTap: (f) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FileViewerScreen(
          agy: agy,
          entry: f,
          onMention: () {
            Navigator.of(context).pop();
            _mention(context, f.path);
          },
        ),
      )),
      onFileLongPress: (e) => showModalBottomSheet(
        context: context,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('Mention in chat'),
                onTap: () {
                  Navigator.pop(sheet);
                  _mention(context, e.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy path'),
                onTap: () {
                  Navigator.pop(sheet);
                  copyText(context, e.path, label: 'Path copied');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({super.key, required this.agy, required this.entry, this.onMention});

  final AgyService agy;
  final DirEntry entry;
  final VoidCallback? onMention;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  FileContent? _file;
  String? _error;
  bool _wrap = false;
  bool _renderMarkdown = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final f = await widget.agy.readFile(widget.entry.path);
      if (mounted) setState(() => _file = f);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  bool get _isMarkdown => widget.entry.name.toLowerCase().endsWith('.md');

  @override
  Widget build(BuildContext context) {
    final f = _file;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.entry.name, overflow: TextOverflow.ellipsis),
            Text(formatBytes(widget.entry.size),
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          if (_isMarkdown)
            IconButton(
              tooltip: _renderMarkdown ? 'Show source' : 'Render',
              onPressed: () => setState(() => _renderMarkdown = !_renderMarkdown),
              icon: Icon(_renderMarkdown ? Icons.code : Icons.article_outlined),
            ),
          IconButton(
            tooltip: _wrap ? 'No wrap' : 'Wrap lines',
            onPressed: () => setState(() => _wrap = !_wrap),
            icon: Icon(_wrap ? Icons.wrap_text : Icons.notes),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'mention') widget.onMention?.call();
              if (v == 'copy' && f != null) copyText(context, f.text);
              if (v == 'path') copyText(context, widget.entry.path, label: 'Path copied');
              if (v == 'reload') _load();
            },
            itemBuilder: (_) => [
              if (widget.onMention != null) const PopupMenuItem(value: 'mention', child: Text('Mention in chat')),
              const PopupMenuItem(value: 'copy', child: Text('Copy contents')),
              const PopupMenuItem(value: 'path', child: Text('Copy path')),
              const PopupMenuItem(value: 'reload', child: Text('Reload')),
            ],
          ),
        ],
      ),
      body: _error != null
          ? Padding(padding: const EdgeInsets.all(16), child: ErrorPanel(message: _error!, onRetry: _load))
          : f == null
              ? const Center(child: CircularProgressIndicator())
              : f.isBinary
                  ? const EmptyState(
                      icon: Icons.insert_drive_file_outlined,
                      title: 'Binary file',
                      message: 'This file cannot be shown as text.')
                  : Column(
                      children: [
                        if (f.truncated)
                          Container(
                            width: double.infinity,
                            color: AppColors.warning.withValues(alpha: 0.12),
                            padding: const EdgeInsets.all(8),
                            child: Text(
                                'Showing the first ${formatBytes(f.bytes.length)} of ${formatBytes(f.size)}.',
                                style: const TextStyle(fontSize: 12.5)),
                          ),
                        Expanded(
                          child: _isMarkdown && _renderMarkdown
                              ? ListView(padding: const EdgeInsets.all(16), children: [MarkdownView(f.text)])
                              : _CodeView(text: f.text, language: languageForFile(widget.entry.name), wrap: _wrap),
                        ),
                      ],
                    ),
    );
  }
}

class _CodeView extends StatelessWidget {
  const _CodeView({required this.text, this.language, required this.wrap});
  final String text;
  final String? language;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final lines = '\n'.allMatches(text).length + 1;
    final gutter = List.generate(lines, (i) => '${i + 1}').join('\n');
    final style = monoStyle(size: 12.5, color: const Color(0xFFD5D9E0));
    final code = SelectableText.rich(
      TextSpan(style: style, children: highlightSpans(text, language)),
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppColors.border))),
          child: Text(gutter, textAlign: TextAlign.right, style: style.copyWith(color: AppColors.textFaint)),
        ),
        if (wrap)
          Expanded(child: Padding(padding: const EdgeInsets.all(12), child: code))
        else
          Padding(padding: const EdgeInsets.all(12), child: code),
      ],
    );
    return Container(
      color: AppColors.codeBackground,
      constraints: const BoxConstraints.expand(),
      child: SingleChildScrollView(
        child: wrap ? row : SingleChildScrollView(scrollDirection: Axis.horizontal, child: row),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../services/agy_service.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// Browses directories on the server. Used by the workspace picker
/// ([dirsOnly]) and the Files tab.
class RemoteBrowser extends StatefulWidget {
  const RemoteBrowser({
    super.key,
    required this.agy,
    required this.initialPath,
    this.dirsOnly = false,
    this.rootPath,
    this.onFileTap,
    this.onFileLongPress,
    this.onPathChanged,
    this.footerBuilder,
  });

  final AgyService agy;
  final String initialPath;
  final bool dirsOnly;

  /// When set, navigating above this path is not offered.
  final String? rootPath;
  final void Function(DirEntry file)? onFileTap;
  final void Function(DirEntry entry)? onFileLongPress;
  final void Function(String path)? onPathChanged;
  final Widget Function(BuildContext context, String path)? footerBuilder;

  @override
  State<RemoteBrowser> createState() => RemoteBrowserState();
}

class RemoteBrowserState extends State<RemoteBrowser> {
  late String _path = widget.initialPath;
  DirListing? _listing;
  bool _loading = true;
  String? _error;
  bool _showHidden = false;

  String get path => _listing?.path ?? _path;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> refresh() => _load(path);

  Future<void> _load(String target) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.agy.listDir(target);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _path = listing.path;
        _loading = false;
      });
      widget.onPathChanged?.call(listing.path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool get _atRoot {
    final scripts = widget.agy.scripts;
    if (scripts.isRoot(path)) return true;
    final root = widget.rootPath;
    return root != null && _norm(path) == _norm(root);
  }

  String _norm(String p) => p.replaceAll(RegExp(r'[\\/]+$'), '');

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      final created = await widget.agy.makeDir(widget.agy.scripts.joinPath(path, name.trim()));
      await _load(created);
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    }
  }

  List<(String, String)> _crumbs() {
    final scripts = widget.agy.scripts;
    final out = <(String, String)>[];
    var p = path;
    for (var i = 0; i < 30; i++) {
      out.insert(0, (baseName(p).isEmpty ? p : baseName(p), p));
      if (scripts.isRoot(p)) break;
      final parent = scripts.parentOf(p);
      if (parent == p) break;
      p = parent;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final entries = (_listing?.entries ?? const <DirEntry>[])
        .where((e) => _showHidden || !e.name.startsWith('.'))
        .where((e) => !widget.dirsOnly || e.isDir)
        .toList();
    final crumbs = _crumbs();
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Up',
                onPressed: _atRoot || _loading ? null : () => _load(widget.agy.scripts.parentOf(path)),
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      for (var i = 0; i < crumbs.length; i++) ...[
                        if (i > 0)
                          const Icon(Icons.chevron_right, size: 16, color: AppColors.textFaint),
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => _load(crumbs[i].$2),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                            child: Text(
                              crumbs[i].$1,
                              style: TextStyle(
                                fontSize: 13,
                                color: i == crumbs.length - 1 ? AppColors.text : AppColors.textMuted,
                                fontWeight: i == crumbs.length - 1 ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (v) {
                  if (v == 'hidden') setState(() => _showHidden = !_showHidden);
                  if (v == 'refresh') refresh();
                  if (v == 'mkdir') _newFolder();
                  if (v == 'copy') copyText(context, path, label: 'Path copied');
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                  const PopupMenuItem(value: 'mkdir', child: Text('New folder')),
                  CheckedPopupMenuItem(
                      value: 'hidden', checked: _showHidden, child: const Text('Show hidden')),
                  const PopupMenuItem(value: 'copy', child: Text('Copy path')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading && _listing == null
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? ListView(padding: const EdgeInsets.all(16), children: [
                      ErrorPanel(message: _error!, onRetry: refresh),
                    ])
                  : RefreshIndicator(
                      onRefresh: refresh,
                      child: entries.isEmpty
                          ? ListView(children: [
                              const SizedBox(height: 80),
                              EmptyState(
                                icon: Icons.folder_open,
                                title: widget.dirsOnly ? 'No sub-folders' : 'Empty folder',
                              ),
                            ])
                          : ListView.builder(
                              itemCount: entries.length,
                              itemBuilder: (context, i) {
                                final e = entries[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    e.isDir ? Icons.folder_rounded : _fileIcon(e.name),
                                    color: e.isDir ? AppColors.accent : AppColors.textMuted,
                                    size: 22,
                                  ),
                                  title: Text(e.name,
                                      style: const TextStyle(fontSize: 14.5),
                                      overflow: TextOverflow.ellipsis),
                                  trailing: e.isDir
                                      ? const Icon(Icons.chevron_right, color: AppColors.textFaint)
                                      : Text(formatBytes(e.size),
                                          style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
                                  onTap: () {
                                    if (e.isDir || e.isLink && widget.dirsOnly) {
                                      _load(e.path);
                                    } else if (e.isLink) {
                                      // Could be either; try as a directory first.
                                      _openLink(e);
                                    } else {
                                      widget.onFileTap?.call(e);
                                    }
                                  },
                                  onLongPress: widget.onFileLongPress == null
                                      ? null
                                      : () => widget.onFileLongPress!(e),
                                );
                              },
                            ),
                    ),
        ),
        if (_loading && _listing != null) const LinearProgressIndicator(minHeight: 2),
        if (widget.footerBuilder != null) widget.footerBuilder!(context, path),
      ],
    );
  }

  Future<void> _openLink(DirEntry e) async {
    try {
      final listing = await widget.agy.listDir(e.path);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _path = listing.path;
      });
    } catch (_) {
      widget.onFileTap?.call(e);
    }
  }

  static IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'md' || 'txt' || 'rst' => Icons.description_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' => Icons.image_outlined,
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' || 'ini' || 'env' => Icons.settings_outlined,
      'zip' || 'gz' || 'tar' || 'tgz' || 'xz' => Icons.archive_outlined,
      _ => Icons.code_rounded,
    };
  }
}

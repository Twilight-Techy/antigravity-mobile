import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/remote_browser.dart';

/// Pick the project folder agy should work in.
class WorkspacePicker extends StatefulWidget {
  const WorkspacePicker({super.key});

  @override
  State<WorkspacePicker> createState() => _WorkspacePickerState();
}

class _WorkspacePickerState extends State<WorkspacePicker> {
  bool _browsing = false;

  @override
  void initState() {
    super.initState();
    _browsing = context.read<SessionState>().profile.recentWorkspaces.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final agy = session.agy!;
    final recents = session.profile.recentWorkspaces;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Open a workspace'),
            Text(session.profile.displayAddress,
                style: monoStyle(size: 11.5, color: AppColors.textMuted)),
          ],
        ),
        actions: [
          if (recents.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _browsing = !_browsing),
              child: Text(_browsing ? 'Recent' : 'Browse'),
            ),
        ],
      ),
      body: _browsing
          ? RemoteBrowser(
              agy: agy,
              initialPath: agy.info.home,
              dirsOnly: true,
              footerBuilder: (context, path) => SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    border: Border(top: BorderSide(color: AppColors.border)),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => session.openWorkspace(path),
                      icon: const Icon(Icons.folder_open),
                      label: Text('Open ${baseName(path)}', overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 10),
                  child: Text('RECENT',
                      style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 12,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w600)),
                ),
                for (final ws in recents)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        leading: const Icon(Icons.folder_rounded, color: AppColors.accent),
                        title: Text(baseName(ws), style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(ws,
                            style: monoStyle(size: 11.5, color: AppColors.textMuted),
                            overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => session.openWorkspace(ws),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _browsing = true),
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('Browse the server'),
                ),
              ],
            ),
    );
  }
}

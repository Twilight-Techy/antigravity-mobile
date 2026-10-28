import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/remote_browser.dart';

/// The result of picking a project: a folder, or no project.
class ProjectChoice {
  const ProjectChoice(this.path);
  final String? path;
}

/// Bottom sheet: no project, a recent project, or browse for a folder.
Future<ProjectChoice?> pickProject(BuildContext context, {String? current}) async {
  final session = context.read<SessionState>();
  final recents = session.profile.recentWorkspaces;
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Project', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('No project'),
              subtitle: const Text('Runs in a private scratch folder on the server',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
              trailing: current == null ? const Icon(Icons.check, color: AppColors.accent) : null,
              onTap: () => Navigator.pop(context, const ProjectChoice(null)),
            ),
            if (recents.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text('RECENT',
                    style: TextStyle(
                        color: AppColors.textFaint, fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w600)),
              ),
            for (final p in recents)
              ListTile(
                leading: const Icon(Icons.folder_rounded, color: AppColors.accent),
                title: Text(baseName(p)),
                subtitle: Text(p,
                    overflow: TextOverflow.ellipsis, style: monoStyle(size: 11.5, color: AppColors.textMuted)),
                trailing: current == p ? const Icon(Icons.check, color: AppColors.accent) : null,
                onTap: () => Navigator.pop(context, ProjectChoice(p)),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('Open a folder…'),
              onTap: () => Navigator.pop(context, 'browse'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice is ProjectChoice) return choice;
  if (choice == 'browse' && context.mounted) {
    final path = await browseForFolder(context);
    if (path != null) return ProjectChoice(path);
  }
  return null;
}

/// Full-screen folder browser; returns the chosen folder.
Future<String?> browseForFolder(BuildContext context) {
  final session = context.read<SessionState>();
  final agy = session.agy;
  if (agy == null) return Future.value(null);
  return Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (context) => Scaffold(
      appBar: AppBar(title: const Text('Choose a project folder')),
      body: RemoteBrowser(
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
                onPressed: () => Navigator.pop(context, path),
                icon: const Icon(Icons.folder_open),
                label: Text('Use ${baseName(path)}', overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
}

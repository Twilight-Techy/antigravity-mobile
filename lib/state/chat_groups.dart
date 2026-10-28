import '../services/storage_service.dart';

class ProjectGroup {
  ProjectGroup(this.path, this.chats);

  /// Project folder.
  final String path;

  /// Most recent first.
  final List<ConversationSummary> chats;

  DateTime? get lastActivity => chats.isEmpty ? null : chats.first.updatedAt;
}

class ChatGroups {
  const ChatGroups(this.projects, this.others);

  /// Projects with recent activity first, then recently opened projects that
  /// have no chats yet.
  final List<ProjectGroup> projects;

  /// Chats that belong to no project, most recent first.
  final List<ConversationSummary> others;

  bool get isEmpty => projects.isEmpty && others.isEmpty;
}

/// Groups a server's chats by project, like the Antigravity sidebar.
/// [recentProjects] (most recent first) adds projects that have no chats yet.
ChatGroups groupChats(List<ConversationSummary> chats, List<String> recentProjects) {
  final byProject = <String, List<ConversationSummary>>{};
  final others = <ConversationSummary>[];
  for (final c in chats) {
    final p = c.project;
    if (p == null) {
      others.add(c);
    } else {
      byProject.putIfAbsent(p, () => []).add(c);
    }
  }
  int newestFirst(ConversationSummary a, ConversationSummary b) => b.updatedAt.compareTo(a.updatedAt);
  for (final list in byProject.values) {
    list.sort(newestFirst);
  }
  others.sort(newestFirst);

  final active = byProject.entries.map((e) => ProjectGroup(e.key, e.value)).toList()
    ..sort((a, b) => b.lastActivity!.compareTo(a.lastActivity!));
  final empty = recentProjects
      .where((p) => !byProject.containsKey(p))
      .toSet()
      .map((p) => ProjectGroup(p, const []));
  return ChatGroups([...active, ...empty], others);
}

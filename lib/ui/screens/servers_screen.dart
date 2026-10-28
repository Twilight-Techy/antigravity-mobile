import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_profile.dart';
import '../../state/servers_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'server_form_screen.dart';
import 'session_screen.dart';

class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final servers = context.read<ServersState>();
    final saved = await Navigator.of(context).push<ServerProfile>(MaterialPageRoute(
      builder: (_) => ServerFormScreen(profile: servers.createDraft(), isNew: true),
    ));
    if (saved != null && context.mounted) _open(context, saved);
  }

  void _open(BuildContext context, ServerProfile profile) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SessionScreen(profile: profile),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final servers = context.watch<ServersState>();
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
                child: Row(
                  children: [
                    const AgLogo(size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('Antigravity',
                              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                          SizedBox(height: 2),
                          Text('Your agent, on your server',
                              style: TextStyle(color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
                child: Text('SERVERS',
                    style: TextStyle(
                        color: AppColors.textFaint,
                        fontSize: 12,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            if (!servers.loaded)
              const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
            else if (servers.profiles.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.dns_outlined,
                  title: 'Connect your first VPS',
                  message:
                      'Add a server you can reach over SSH. The app checks for the Antigravity CLI and installs it if needed.',
                  action: FilledButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add server'),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                sliver: SliverList.separated(
                  itemCount: servers.profiles.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _ServerCard(
                    profile: servers.profiles[i],
                    onOpen: () => _open(context, servers.profiles[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: servers.profiles.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _add(context),
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.profile, required this.onOpen});
  final ServerProfile profile;
  final VoidCallback onOpen;

  Future<void> _edit(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ServerFormScreen(profile: profile, isNew: false),
    ));
  }

  Future<void> _delete(BuildContext context) async {
    final servers = context.read<ServersState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove server?'),
        content: Text(
            'This removes ${profile.name} and its saved credentials and chats from this phone. Nothing on the server is changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await servers.delete(profile);
  }

  @override
  Widget build(BuildContext context) {
    final last = profile.recentWorkspaces.isEmpty ? null : profile.recentWorkspaces.first;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(Icons.dns_rounded, color: AppColors.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.name.isEmpty ? profile.host : profile.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(profile.displayAddress,
                        style: monoStyle(size: 12, color: AppColors.textMuted)),
                    if (last != null || profile.lastConnectedAt != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (last != null) baseName(last),
                          if (profile.lastConnectedAt != null) timeAgo(profile.lastConnectedAt!),
                        ].join(' · '),
                        style: const TextStyle(color: AppColors.textFaint, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
                onSelected: (v) {
                  if (v == 'edit') _edit(context);
                  if (v == 'delete') _delete(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

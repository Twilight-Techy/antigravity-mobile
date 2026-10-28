import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../models/server_profile.dart';
import '../../services/agy_service.dart';
import '../../services/notifier.dart';
import '../../state/chat_controller.dart';
import '../../state/servers_state.dart';
import '../../state/session_state.dart';
import '../../state/terminal_session.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'server_form_screen.dart';
import 'setup_view.dart';
import 'workspace_home.dart';
import 'workspace_picker.dart';

/// Owns one connection to [profile] and everything built on top of it.
class SessionScreen extends StatelessWidget {
  const SessionScreen({super.key, required this.profile, this.connector});

  final ServerProfile profile;
  final HostConnector? connector;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) => SessionState(
            servers: context.read<ServersState>(),
            profile: profile,
            connector: connector ?? context.read<HostConnector>(),
          ),
        ),
        ChangeNotifierProvider(create: (context) => ChatController(context.read<SessionState>())),
        ChangeNotifierProvider(create: (context) => TerminalSession(context.read<SessionState>())),
      ],
      child: const _SessionBody(),
    );
  }
}

class _SessionBody extends StatefulWidget {
  const _SessionBody();

  @override
  State<_SessionBody> createState() => _SessionBodyState();
}

class _SessionBodyState extends State<_SessionBody> with WidgetsBindingObserver {
  bool _everConnected = false;

  /// Once the checklist is on screen it stays until the user continues, so
  /// background re-checks do not swap it out mid-install.
  bool _inSetup = false;

  late final ChatController _chat;
  late final Notifier _notifier;
  StreamSubscription<String>? _taps;
  bool _background = false;
  bool _askedPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final session = context.read<SessionState>();
    session.onHostKey = _confirmHostKey;
    _notifier = context.read<Notifier>();
    _chat = context.read<ChatController>()
      ..onPromptSent = _onPromptSent
      ..onReplyFinished = _onReplyFinished;
    _taps = _notifier.taps.listen(_onNotificationTap);
    WidgetsBinding.instance.addPostFrameCallback((_) => session.connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _taps?.cancel();
    _chat
      ..onPromptSent = null
      ..onReplyFinished = null;
    unawaited(_notifier.releaseKeepAlive());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = context.read<SessionState>();
    switch (state) {
      case AppLifecycleState.resumed:
        _background = false;
        unawaited(_notifier.releaseKeepAlive());
        unawaited(session.ensureConnected());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_background) return;
        _background = true;
        // Keep the connection up so the reply can finish and we can notify.
        if (_chat.busy && session.profile.notifyOnFinish) {
          unawaited(_notifier.keepAlive(workspaceName(session.workspace ?? '')));
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onPromptSent() {
    if (_askedPermission || !context.read<SessionState>().profile.notifyOnFinish) return;
    _askedPermission = true;
    unawaited(_notifier.requestPermission());
  }

  void _onReplyFinished(Conversation conversation, ChatMessage reply) {
    unawaited(_notifier.releaseKeepAlive());
    final profile = context.read<SessionState>().profile;
    // With ntfy the server sends the push itself; avoid a duplicate.
    final serverPushes = profile.ntfyUrl != null && profile.ntfyUrl!.isNotEmpty;
    if (!_background || !profile.notifyOnFinish || serverPushes) return;
    if (reply.status == MessageStatus.cancelled) return;
    final ws = workspaceName(conversation.workspace);
    final failed = reply.status == MessageStatus.error;
    var body = failed
        ? reply.parts.lastWhere((p) => p.kind == PartKind.error, orElse: () => MessagePart(kind: PartKind.error)).text
        : reply.plainText;
    body = body.replaceAll(RegExp(r'[#*`>_]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.length > 140) body = '${body.substring(0, 140)}…';
    unawaited(_notifier.agentFinished(
      conversationId: conversation.id,
      title: failed ? 'Agent hit an error in $ws' : 'Agent finished in $ws',
      body: body.isEmpty ? conversation.title : body,
    ));
  }

  Future<void> _onNotificationTap(String conversationId) async {
    final session = context.read<SessionState>();
    final convo = await session.storage.loadConversation(conversationId);
    if (convo == null || convo.serverId != session.profile.id) return;
    if (convo.workspace == session.workspace) {
      await _chat.open(conversationId);
      if (mounted) WorkspaceHomeState.of(context)?.showTab(0);
    }
  }

  Future<bool> _confirmHostKey(
      String hostPort, String type, String fingerprint, String? previous) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: Icon(previous == null ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
            color: previous == null ? AppColors.accent : AppColors.danger),
        title: Text(previous == null ? 'Trust this server?' : 'Host key changed!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(previous == null
                ? 'First connection to $hostPort. Check that the fingerprint matches your server before trusting it.'
                : 'The key for $hostPort is different from the one you trusted before. This can mean the server was reinstalled — or that someone is intercepting the connection.'),
            const SizedBox(height: 12),
            Text(type, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(fingerprint, style: monoStyle(size: 12)),
            if (previous != null) ...[
              const SizedBox(height: 10),
              const Text('Previously trusted', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(previous, style: monoStyle(size: 12, color: AppColors.textMuted)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: previous == null ? null : FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(previous == null ? 'Trust' : 'Trust new key'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    if (session.status == ConnectionStatus.connected) _everConnected = true;

    final Widget body;
    if (!_everConnected) {
      body = session.status == ConnectionStatus.failed
          ? _FailedView(session: session)
          : _ConnectingView(session: session);
    } else if (!session.setupDone) {
      final info = session.info;
      final auth = session.auth;
      if (session.setupRequested || _inSetup) {
        body = const SetupView();
      } else if (info != null &&
          info.agyInstalled &&
          (auth == null || session.checkingAuth) &&
          session.isConnected) {
        body = const _ConnectingView.checking();
      } else if (info != null && info.agyInstalled && auth?.state == AuthState.signedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !session.setupDone) session.completeSetup();
        });
        body = const _ConnectingView.checking();
      } else {
        _inSetup = true;
        body = const SetupView();
      }
    } else if (session.workspace == null) {
      _inSetup = false;
      body = const WorkspacePicker();
    } else {
      _inSetup = false;
      body = const WorkspaceHome();
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: body);
  }
}

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({this.session}) : checking = false;
  const _ConnectingView.checking()
      : session = null,
        checking = true;

  final SessionState? session;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final s = session ?? context.read<SessionState>();
    return Scaffold(
      appBar: AppBar(title: Text(s.profile.name)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AgLogo(size: 56),
            const SizedBox(height: 24),
            const SizedBox(width: 160, child: LinearProgressIndicator(minHeight: 2)),
            const SizedBox(height: 16),
            Text(
              checking
                  ? 'Checking Antigravity sign-in…'
                  : (s.progress.isEmpty ? 'Connecting…' : s.progress),
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailedView extends StatelessWidget {
  const _FailedView({required this.session});
  final SessionState session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(session.profile.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.cloud_off_rounded, size: 48, color: AppColors.textFaint),
          const SizedBox(height: 16),
          Text("Couldn't connect to ${session.profile.displayAddress}",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          ErrorPanel(message: session.error ?? 'Unknown error'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: session.connect,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ServerFormScreen(profile: session.profile, isNew: false),
              ));
              await session.connect();
            },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit server details'),
          ),
        ],
      ),
    );
  }
}

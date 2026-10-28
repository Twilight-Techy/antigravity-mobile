import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/links.dart';
import 'services/notifier.dart';
import 'services/push_service.dart';
import 'services/storage_service.dart';
import 'state/servers_state.dart';
import 'state/session_state.dart';
import 'ui/screens/servers_screen.dart';
import 'ui/screens/session_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifier = LocalNotifier();
  final push = FcmPushService();
  await Future.wait([notifier.init(), push.init()]);
  runApp(AntigravityMobileApp(
    storage: StorageService(),
    notifier: notifier,
    push: push,
    deepLinks: _deepLinks(),
  ));
}

/// `antigravity://` links opened from outside the app (e.g. tapping an ntfy
/// notification), including the one that launched it.
Stream<Uri> _deepLinks() async* {
  try {
    yield* AppLinks().uriLinkStream;
  } catch (e) {
    debugPrint('Deep links unavailable: $e');
  }
}

class AntigravityMobileApp extends StatelessWidget {
  const AntigravityMobileApp({
    super.key,
    required this.storage,
    this.connector = sshConnector,
    this.notifier,
    this.push,
    this.deepLinks,
  });

  final StorageService storage;

  /// How SSH connections are opened; replaced in tests.
  final HostConnector connector;

  /// Agent-finished notifications; silent when null (tests).
  final Notifier? notifier;

  /// FCM via the push relay; off when null.
  final PushService? push;

  final Stream<Uri>? deepLinks;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ServersState(storage)..load()),
        Provider<HostConnector>.value(value: connector),
        Provider<Notifier>.value(value: notifier ?? SilentNotifier()),
        Provider<PushService>.value(value: push ?? NoPushService()),
        Provider<OpenRequests>(create: (_) => OpenRequests()),
      ],
      child: _LinkRouter(
        deepLinks: deepLinks,
        child: (navigatorKey) => MaterialApp(
          title: 'Antigravity Mobile',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          darkTheme: buildTheme(),
          themeMode: ThemeMode.dark,
          home: const ServersScreen(),
        ),
      ),
    );
  }
}

/// Routes "open this conversation" requests from notification taps, FCM
/// pushes and deep links. The open session for that server handles it
/// directly; otherwise this opens the server's session.
class _LinkRouter extends StatefulWidget {
  const _LinkRouter({required this.child, this.deepLinks});

  final Widget Function(GlobalKey<NavigatorState> navigatorKey) child;
  final Stream<Uri>? deepLinks;

  @override
  State<_LinkRouter> createState() => _LinkRouterState();
}

class _LinkRouterState extends State<_LinkRouter> {
  final _navigator = GlobalKey<NavigatorState>();
  final _subs = <StreamSubscription<Object?>>[];
  late final OpenRequests _requests;

  @override
  void initState() {
    super.initState();
    _requests = context.read<OpenRequests>();
    _subs
      ..add(_requests.stream.listen(_open))
      ..add(context.read<Notifier>().taps.listen(_requests.addLink))
      ..add(context.read<PushService>().openedLinks.listen(_requests.addLink));
    if (widget.deepLinks != null) _subs.add(widget.deepLinks!.listen(_requests.addLink));
    final pending = _requests.takePending();
    if (pending != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(pending));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _open(OpenRequest request) async {
    final servers = context.read<ServersState>();
    if (!servers.loaded) await servers.load();
    final profile = servers.byId(request.serverId);
    final nav = _navigator.currentState;
    if (profile == null || nav == null) return;
    nav.popUntil((r) => r.isFirst);
    await nav.push(MaterialPageRoute(
      builder: (_) => SessionScreen(profile: profile, openConversationId: request.conversationId),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child(_navigator);
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/notifier.dart';
import 'services/storage_service.dart';
import 'state/servers_state.dart';
import 'state/session_state.dart';
import 'ui/screens/servers_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifier = LocalNotifier();
  await notifier.init();
  runApp(AntigravityMobileApp(storage: StorageService(), notifier: notifier));
}

class AntigravityMobileApp extends StatelessWidget {
  const AntigravityMobileApp({
    super.key,
    required this.storage,
    this.connector = sshConnector,
    this.notifier,
  });

  final StorageService storage;

  /// Agent-finished notifications; silent when null (tests).
  final Notifier? notifier;

  /// How SSH connections are opened; replaced in tests.
  final HostConnector connector;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ServersState(storage)..load()),
        Provider<HostConnector>.value(value: connector),
        Provider<Notifier>.value(value: notifier ?? SilentNotifier()),
      ],
      child: MaterialApp(
        title: 'Antigravity Mobile',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        darkTheme: buildTheme(),
        themeMode: ThemeMode.dark,
        home: const ServersScreen(),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/storage_service.dart';
import 'state/servers_state.dart';
import 'state/session_state.dart';
import 'ui/screens/servers_screen.dart';
import 'ui/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AntigravityMobileApp(storage: StorageService()));
}

class AntigravityMobileApp extends StatelessWidget {
  const AntigravityMobileApp({super.key, required this.storage, this.connector = sshConnector});

  final StorageService storage;

  /// How SSH connections are opened; replaced in tests.
  final HostConnector connector;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ServersState(storage)..load()),
        Provider<HostConnector>.value(value: connector),
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

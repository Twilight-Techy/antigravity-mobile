import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/chat_state.dart';
import 'ui/screens/connection_screen.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatState()),
      ],
      child: const AntigravityMobileApp(),
    ),
  );
}

class AntigravityMobileApp extends StatelessWidget {
  const AntigravityMobileApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Antigravity Mobile',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      ),
      home: const ConnectionScreen(),
    );
  }
}

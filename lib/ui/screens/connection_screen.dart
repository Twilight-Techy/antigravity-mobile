import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/chat_state.dart';
import 'chat_screen.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({Key? key}) : super(key: key);

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _hostController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  bool _isConnecting = false;

  Future<void> _connect() async {
    setState(() => _isConnecting = true);
    
    final chatState = context.read<ChatState>();
    final success = await chatState.connect(
      _hostController.text.trim(),
      _userController.text.trim(),
      _passController.text,
    );
    
    setState(() => _isConnecting = false);
    
    if (success && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = context.watch<ChatState>().connectionError;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Antigravity',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('Connect to your VPS'),
              const SizedBox(height: 32),
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(labelText: 'Host IP'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _userController,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 32),
              if (error.isNotEmpty) ...[
                Text(error, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 16),
              ],
              _isConnecting
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _connect,
                      child: const Text('Connect via SSH'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

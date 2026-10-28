import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../models/chat_state.dart';
import 'connection_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({Key? key}) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();

  void _send() {
    final text = _inputController.text;
    if (text.isNotEmpty) {
      context.read<ChatState>().sendMessage(text);
      _inputController.clear();
    }
  }

  void _disconnect() {
    context.read<ChatState>().disconnect();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ConnectionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatLog = context.watch<ChatState>().chatLog;
    final isConnected = context.watch<ChatState>().isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Antigravity CLI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: 'Interrupt Agent',
            onPressed: () => context.read<ChatState>().stopAgent(),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Disconnect',
            onPressed: _disconnect,
          ),
        ],
      ),
      body: Column(
        children: [
          if (!isConnected)
            Container(
              color: Colors.red,
              width: double.infinity,
              padding: const EdgeInsets.all(8.0),
              child: const Text('Disconnected', textAlign: TextAlign.center),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: MarkdownBody(
                data: chatLog,
                // In a real app, you would define custom syntax highlighters and styles here.
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            color: Theme.of(context).cardColor,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      hintText: 'Type a slash command or prompt...',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

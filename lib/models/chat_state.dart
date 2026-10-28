import 'package:flutter/foundation.dart';
import '../services/ssh_service.dart';

class ChatState extends ChangeNotifier {
  final SSHService _sshService = SSHService();
  
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  String _connectionError = '';
  String get connectionError => _connectionError;

  // For simplicity, we just keep a continuous log of text. 
  // In a robust implementation, you would parse this into distinct Message objects.
  final StringBuffer _chatLog = StringBuffer();
  String get chatLog => _chatLog.toString();

  ChatState() {
    _sshService.onMessageReceived = (msg) {
      _chatLog.write(msg);
      notifyListeners();
    };
    
    _sshService.onError = (err) {
      _chatLog.write('\n[Error]: $err\n');
      notifyListeners();
    };
    
    _sshService.onDisconnected = () {
      _isConnected = false;
      notifyListeners();
    };
  }

  Future<bool> connect(String host, String username, String password) async {
    _connectionError = '';
    notifyListeners();

    _isConnected = await _sshService.connect(host, username, password);
    if (!_isConnected) {
      _connectionError = 'Failed to connect to $host';
    }
    notifyListeners();
    return _isConnected;
  }

  void sendMessage(String message) {
    if (message.isNotEmpty) {
      _sshService.sendMessage(message);
      // We don't manually append to chatLog here, 
      // because agy will echo the command or generate output.
    }
  }

  void stopAgent() {
    _sshService.sendInterrupt();
  }

  void disconnect() {
    _sshService.disconnect();
    _isConnected = false;
    _chatLog.clear();
    notifyListeners();
  }
}

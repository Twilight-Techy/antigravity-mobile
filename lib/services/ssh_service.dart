import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'ansi_parser.dart';

class SSHService {
  SSHClient? _client;
  SSHSession? _session;

  // Stream controller to broadcast parsed text
  void Function(String)? onMessageReceived;
  void Function(String)? onError;
  void Function()? onDisconnected;

  Future<bool> connect(String host, String username, String password) async {
    try {
      _client = SSHClient(
        await SSHSocket.connect(host, 22),
        username: username,
        onPasswordRequest: () => password,
      );

      // Start the Antigravity CLI process.
      // We explicitly request a PTY so that it acts like a real terminal.
      _session = await _client!.execute('agy');
      
      // Listen to stdout
      _session!.stdout.listen((Uint8List data) {
        final rawString = utf8.decode(data);
        final parsedString = AnsiParser.stripAnsiCodes(rawString);
        if (parsedString.isNotEmpty && onMessageReceived != null) {
          onMessageReceived!(parsedString);
        }
      });

      // Listen to stderr
      _session!.stderr.listen((Uint8List data) {
        final rawString = utf8.decode(data);
        final parsedString = AnsiParser.stripAnsiCodes(rawString);
        if (parsedString.isNotEmpty && onError != null) {
          onError!(parsedString);
        }
      });

      // Handle disconnect
      _session!.done.then((_) {
        if (onDisconnected != null) onDisconnected!();
      });

      return true;
    } catch (e) {
      if (onError != null) onError!(e.toString());
      return false;
    }
  }

  void sendMessage(String message) {
    if (_session != null) {
      // Write the message to the session's standard input followed by a newline
      final data = utf8.encode('$message\n');
      _session!.write(data);
    }
  }

  void sendInterrupt() {
    if (_session != null) {
      // Send Ctrl+C (0x03)
      _session!.write(Uint8List.fromList([3]));
    }
  }

  void disconnect() {
    _session?.close();
    _client?.close();
  }
}

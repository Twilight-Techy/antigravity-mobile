import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/server_profile.dart';
import 'remote_host.dart';

/// Called with the server's host key fingerprint (`SHA256:...`). Return true
/// to trust it.
typedef HostKeyVerifier = FutureOr<bool> Function(String type, String fingerprint);

class SshConnectException implements Exception {
  SshConnectException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [RemoteHost] backed by a dartssh2 client.
class SshHost implements RemoteHost {
  SshHost._(this._client);

  final SSHClient _client;

  static Future<SshHost> connect({
    required ServerProfile profile,
    required ServerSecrets secrets,
    required HostKeyVerifier verifyHostKey,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(profile.host, profile.port,
          timeout: timeout);
    } catch (e) {
      throw SshConnectException(
          'Could not reach ${profile.host}:${profile.port} ($e)');
    }

    List<SSHKeyPair>? identities;
    if (profile.authMethod == AuthMethod.privateKey) {
      final pem = secrets.privateKey;
      if (pem == null || pem.trim().isEmpty) {
        socket.close();
        throw SshConnectException('No private key saved for this server.');
      }
      try {
        identities = SSHKeyPair.fromPem(pem.trim(), secrets.passphrase);
      } catch (e) {
        socket.close();
        throw SshConnectException(
            'Could not read the private key. Check the key and passphrase. ($e)');
      }
    }

    final password = secrets.password ?? '';
    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: profile.authMethod == AuthMethod.password
          ? () => password
          : null,
      onUserInfoRequest: profile.authMethod == AuthMethod.password
          ? (request) => request.prompts.map((_) => password).toList()
          : null,
      onVerifyHostKey: (type, fingerprint) =>
          verifyHostKey(type, String.fromCharCodes(fingerprint)),
      keepAliveInterval: const Duration(seconds: 15),
      authTimeout: timeout,
    );

    try {
      await client.authenticated.timeout(timeout);
    } on SSHAuthError catch (e) {
      client.close();
      throw SshConnectException('Authentication failed: ${e.message}');
    } on SSHHostkeyError catch (_) {
      client.close();
      throw SshConnectException('Host key was rejected.');
    } on TimeoutException {
      client.close();
      throw SshConnectException('Timed out while signing in.');
    } catch (e) {
      client.close();
      throw SshConnectException('SSH connection failed: $e');
    }
    return SshHost._(client);
  }

  @override
  Future<CommandResult> run(String command, {Duration? timeout}) async {
    final process = await start(command);
    return collect(process, timeout: timeout);
  }

  @override
  Future<RemoteProcess> start(String command) async {
    final session = await _client.execute(command);
    return _SshProcess(session);
  }

  @override
  Future<RemotePty> startPty(String command,
      {int columns = 80, int rows = 24}) async {
    final session = await _client.execute(
      command,
      pty: SSHPtyConfig(width: columns, height: rows),
    );
    return _SshPty(session);
  }

  @override
  Future<void> get done => _client.done;

  @override
  bool get isClosed => _client.isClosed;

  @override
  void close() => _client.close();
}

class _SshProcess implements RemoteProcess {
  _SshProcess(this.session);

  final SSHSession session;

  @override
  Stream<Uint8List> get stdout => session.stdout;

  @override
  Stream<Uint8List> get stderr => session.stderr;

  @override
  Future<int?> get exitCode async {
    await session.done;
    return session.exitCode;
  }

  @override
  void write(List<int> data) => session.write(Uint8List.fromList(data));

  @override
  void close() => session.close();
}

class _SshPty extends _SshProcess implements RemotePty {
  _SshPty(super.session);

  @override
  void resize(int columns, int rows) {
    if (columns > 0 && rows > 0) session.resizeTerminal(columns, rows);
  }
}

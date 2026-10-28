import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/server_profile.dart';
import '../services/agy_service.dart';
import '../services/push_service.dart';
import '../services/remote_host.dart';
import '../services/ssh_host.dart';
import '../services/storage_service.dart';
import 'servers_state.dart';

enum ConnectionStatus { idle, connecting, connected, lost, failed }

/// Asks the user whether to trust a host key. [previous] is set when the key
/// changed since the last connection.
typedef HostKeyDecider = Future<bool> Function(
    String hostPort, String type, String fingerprint, String? previous);

typedef HostConnector = Future<RemoteHost> Function(
    ServerProfile profile, ServerSecrets secrets, HostKeyVerifier verify);

Future<RemoteHost> sshConnector(
        ServerProfile profile, ServerSecrets secrets, HostKeyVerifier verify) =>
    SshHost.connect(profile: profile, secrets: secrets, verifyHostKey: verify);

/// One live connection to a server and the workspace chosen on it.
class SessionState extends ChangeNotifier {
  SessionState({
    required this.servers,
    required this.profile,
    HostConnector? connector,
    PushService? push,
  })  : _connector = connector ?? sshConnector,
        _push = push ?? NoPushService();

  final PushService _push;

  /// True once this phone is registered for relay pushes on this server, so
  /// local notifications can be skipped to avoid duplicates.
  bool pushRegistered = false;

  final ServersState servers;
  final ServerProfile profile;
  final HostConnector _connector;

  StorageService get storage => servers.storage;

  HostKeyDecider? onHostKey;

  ConnectionStatus _status = ConnectionStatus.idle;
  ConnectionStatus get status => _status;

  String? _error;
  String? get error => _error;

  String _progress = '';
  String get progress => _progress;

  ServerSecrets _secrets = const ServerSecrets();
  ServerSecrets get secrets => _secrets;

  AgyService? _agy;
  AgyService? get agy => _agy;
  HostInfo? get info => _agy?.info;

  AuthCheck? _auth;
  AuthCheck? get auth => _auth;
  bool _checkingAuth = false;
  bool get checkingAuth => _checkingAuth;

  /// Set once the user has finished (or skipped) the setup checklist.
  bool setupDone = false;

  /// True when the user reopened setup from the menu, so it is shown even if
  /// everything is already in place.
  bool setupRequested = false;

  String? _workspace;
  String? get workspace => _workspace;

  /// Bumped every time a (re)connection succeeds so dependants can resume.
  int _generation = 0;
  int get generation => _generation;

  bool _disposed = false;
  bool _manualDisconnect = false;

  bool get isConnected => _status == ConnectionStatus.connected;

  Future<bool> connect() async {
    if (_status == ConnectionStatus.connecting) return false;
    _manualDisconnect = false;
    _setStatus(ConnectionStatus.connecting, progress: 'Connecting to ${profile.displayAddress}…');
    try {
      _secrets = await storage.loadSecrets(profile.id);
      final host = await _connector(profile, _secrets, _verifyHostKey);
      _progress = 'Checking the server…';
      _notify();
      final agy = await AgyService.detect(host);
      final key = _secrets.geminiApiKey;
      if (key != null && agy.info.agyInstalled) {
        // Apply a key entered in the server form.
        try {
          await agy.setApiKey(key);
        } catch (_) {}
      }
      _agy?.host.close();
      _agy = agy;
      unawaited(host.done.then((_) => _onClosed(host), onError: (_) => _onClosed(host)));
      unawaited(_syncPush(agy));
      profile.lastConnectedAt = DateTime.now();
      unawaited(servers.update(profile));
      _generation++;
      _setStatus(ConnectionStatus.connected);
      if (agy.info.agyInstalled && _auth == null) unawaited(checkAuth());
      return true;
    } catch (e) {
      _error = e.toString();
      _setStatus(ConnectionStatus.failed);
      return false;
    }
  }

  /// Registers (or, if notifications are off, unregisters) this phone for
  /// pushes from this server.
  Future<void> _syncPush(AgyService agy) async {
    if (!_push.available) return;
    try {
      final reg = await _push.register();
      if (reg == null) return;
      await agy.registerPush(reg.relayUrl, reg.key, remove: !profile.notifyOnFinish);
      pushRegistered = profile.notifyOnFinish;
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  Future<bool> _verifyHostKey(String type, String fingerprint) async {
    final hostPort = '${profile.host}:${profile.port}';
    final known = (await storage.loadKnownHosts())[hostPort];
    if (known == fingerprint) return true;
    final decider = onHostKey;
    if (decider == null) return false;
    final ok = await decider(hostPort, type, fingerprint, known);
    if (ok) await storage.trustHostKey(hostPort, fingerprint);
    return ok;
  }

  void _onClosed(RemoteHost host) {
    if (_disposed || _agy?.host != host) return;
    if (_manualDisconnect) return;
    _setStatus(ConnectionStatus.lost, progress: 'Connection lost');
  }

  /// Reconnects after the connection dropped (e.g. the phone slept).
  Future<bool> reconnect() async {
    if (_status == ConnectionStatus.connected && !(_agy?.host.isClosed ?? true)) {
      return true;
    }
    return connect();
  }

  /// Called when the app returns to the foreground.
  Future<void> ensureConnected() async {
    if (_status == ConnectionStatus.connecting || _manualDisconnect) return;
    final host = _agy?.host;
    if (host == null) return;
    if (host.isClosed || _status == ConnectionStatus.lost) {
      await connect();
      return;
    }
    // The socket may be half-dead after a long sleep; probe it.
    try {
      await host.run('echo ok', timeout: const Duration(seconds: 6));
    } catch (_) {
      host.close();
      await connect();
    }
  }

  Future<AuthCheck?> checkAuth() async {
    final agy = _agy;
    if (agy == null) return null;
    _checkingAuth = true;
    _notify();
    try {
      _auth = await agy.checkAuth();
    } finally {
      _checkingAuth = false;
      _notify();
    }
    return _auth;
  }

  Future<HostInfo?> refreshInfo() async {
    final agy = _agy;
    if (agy == null) return null;
    await agy.refreshInfo();
    _notify();
    return agy.info;
  }

  /// Stores a Gemini API key and switches agy to the `gemini` provider.
  Future<void> useApiKey(String? key) async {
    final agy = _agy;
    final trimmed = key?.trim();
    final value = trimmed == null || trimmed.isEmpty ? null : trimmed;
    _secrets = ServerSecrets(
      password: _secrets.password,
      privateKey: _secrets.privateKey,
      passphrase: _secrets.passphrase,
      geminiApiKey: value,
    );
    await storage.saveSecrets(profile.id, _secrets);
    if (agy != null) await agy.setApiKey(value);
    await checkAuth();
  }

  void completeSetup() {
    setupDone = true;
    setupRequested = false;
    _notify();
  }

  Future<void> reopenSetup() async {
    setupDone = false;
    setupRequested = true;
    _notify();
    await refreshInfo();
    await checkAuth();
  }

  void openWorkspace(String path) {
    _workspace = path;
    profile.touchWorkspace(path);
    unawaited(servers.update(profile));
    _notify();
  }

  void closeWorkspace() {
    _workspace = null;
    _notify();
  }

  void disconnect() {
    _manualDisconnect = true;
    _agy?.host.close();
    _setStatus(ConnectionStatus.idle);
  }

  void _setStatus(ConnectionStatus status, {String progress = ''}) {
    _status = status;
    _progress = progress;
    if (status != ConnectionStatus.failed) _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _manualDisconnect = true;
    _agy?.host.close();
    super.dispose();
  }
}

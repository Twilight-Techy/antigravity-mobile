import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_options.dart';
import '../models/server_profile.dart';
import '../services/storage_service.dart';

/// The list of saved servers.
class ServersState extends ChangeNotifier {
  ServersState(this.storage);

  final StorageService storage;
  final List<ServerProfile> _profiles = [];
  bool _loaded = false;

  List<ServerProfile> get profiles => List.unmodifiable(_profiles);
  bool get loaded => _loaded;

  Future<void> load() async {
    _profiles
      ..clear()
      ..addAll(await storage.loadProfiles());
    _profiles.sort((a, b) => (b.lastConnectedAt ?? DateTime(0))
        .compareTo(a.lastConnectedAt ?? DateTime(0)));
    _loaded = true;
    notifyListeners();
  }

  ServerProfile? byId(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  ServerProfile createDraft() => ServerProfile(
        id: const Uuid().v4(),
        name: '',
        host: '',
        username: 'root',
      );

  Future<void> save(ServerProfile profile, ServerSecrets secrets) async {
    final i = _profiles.indexWhere((p) => p.id == profile.id);
    if (i >= 0) {
      _profiles[i] = profile;
    } else {
      _profiles.insert(0, profile);
    }
    await storage.saveSecrets(profile.id, secrets);
    await storage.saveProfiles(_profiles);
    notifyListeners();
  }

  /// Persists changes made to an existing profile object in place.
  Future<void> update(ServerProfile profile) async {
    if (!_profiles.any((p) => p.id == profile.id)) return;
    await storage.saveProfiles(_profiles);
    notifyListeners();
  }

  Future<void> setAgentOptions(ServerProfile profile, AgentOptions options) {
    profile.agentOptions = options;
    return update(profile);
  }

  Future<void> delete(ServerProfile profile) async {
    _profiles.removeWhere((p) => p.id == profile.id);
    await storage.saveProfiles(_profiles);
    await storage.deleteSecrets(profile.id);
    await storage.forgetHostKey('${profile.host}:${profile.port}');
    await storage.deleteConversationsFor(profile.id);
    notifyListeners();
  }
}

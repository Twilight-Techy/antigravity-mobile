import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../models/server_profile.dart';

/// Persists profiles, conversations and trusted host keys in shared
/// preferences, and credentials in the platform keystore.
class StorageService {
  StorageService({SharedPreferencesAsync? prefs, SecretStore? secrets})
      : _prefs = prefs ?? SharedPreferencesAsync(),
        _secrets = secrets ?? SecureSecretStore();

  final SharedPreferencesAsync _prefs;
  final SecretStore _secrets;

  static const _profilesKey = 'profiles.v1';
  static const _hostKeysKey = 'known_hosts.v1';
  static const _conversationIndexKey = 'conversations.index.v1';
  static String _conversationKey(String id) => 'conversation.$id.v1';
  static String _secretKey(String id) => 'secrets.$id';
  static String _hiddenKey(String serverId) => 'hidden_agy.$serverId.v1';
  static const _showThinkingKey = 'show_thinking.v1';
  static const _maxConversations = 400;

  Future<List<ServerProfile>> loadProfiles() async {
    final raw = await _prefs.getString(_profilesKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<ServerProfile> profiles) => _prefs.setString(
      _profilesKey, jsonEncode(profiles.map((p) => p.toJson()).toList()));

  Future<ServerSecrets> loadSecrets(String profileId) async {
    final raw = await _secrets.read(_secretKey(profileId));
    if (raw == null) return const ServerSecrets();
    try {
      return ServerSecrets.fromMap(Map<String, dynamic>.from(jsonDecode(raw)));
    } catch (_) {
      return const ServerSecrets();
    }
  }

  Future<void> saveSecrets(String profileId, ServerSecrets secrets) =>
      _secrets.write(_secretKey(profileId), jsonEncode(secrets.toMap()));

  Future<void> deleteSecrets(String profileId) =>
      _secrets.delete(_secretKey(profileId));

  /// Trusted host key fingerprints keyed by `host:port`.
  Future<Map<String, String>> loadKnownHosts() async {
    final raw = await _prefs.getString(_hostKeysKey);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw));
    } catch (_) {
      return {};
    }
  }

  Future<void> trustHostKey(String hostPort, String fingerprint) async {
    final hosts = await loadKnownHosts();
    hosts[hostPort] = fingerprint;
    await _prefs.setString(_hostKeysKey, jsonEncode(hosts));
  }

  Future<void> forgetHostKey(String hostPort) async {
    final hosts = await loadKnownHosts();
    hosts.remove(hostPort);
    await _prefs.setString(_hostKeysKey, jsonEncode(hosts));
  }

  /// Lightweight index entries (no messages) for the conversation drawer.
  Future<List<ConversationSummary>> loadConversationIndex() async {
    final raw = await _prefs.getString(_conversationIndexKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => ConversationSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Conversation?> loadConversation(String id) async {
    final raw = await _prefs.getString(_conversationKey(id));
    if (raw == null) return null;
    try {
      return Conversation.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveConversation(Conversation conversation) => saveConversations([conversation]);

  /// Saves several conversations, updating the index once.
  Future<void> saveConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    final index = await loadConversationIndex();
    for (final conversation in conversations) {
      await _prefs.setString(
          _conversationKey(conversation.id), jsonEncode(conversation.toJson()));
      index.removeWhere((c) => c.id == conversation.id);
      index.add(ConversationSummary.of(conversation));
    }
    index.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    // Keep storage bounded.
    while (index.length > _maxConversations) {
      final dropped = index.removeLast();
      await _prefs.remove(_conversationKey(dropped.id));
    }
    await _prefs.setString(
        _conversationIndexKey, jsonEncode(index.map((c) => c.toJson()).toList()));
  }

  /// agy conversations removed from this server's chat list, so syncing
  /// with the server doesn't bring them back.
  Future<Set<String>> loadHiddenConversations(String serverId) async =>
      (await _prefs.getStringList(_hiddenKey(serverId)))?.toSet() ?? {};

  Future<void> hideConversation(String serverId, String agyConversationId) async {
    final hidden = await loadHiddenConversations(serverId)..add(agyConversationId);
    await _prefs.setStringList(_hiddenKey(serverId), hidden.toList());
  }

  Future<bool> loadShowThinking() async => await _prefs.getBool(_showThinkingKey) ?? true;

  Future<void> saveShowThinking(bool value) => _prefs.setBool(_showThinkingKey, value);

  Future<void> deleteConversation(String id) async {
    await _prefs.remove(_conversationKey(id));
    final index = await loadConversationIndex();
    index.removeWhere((c) => c.id == id);
    await _prefs.setString(
        _conversationIndexKey, jsonEncode(index.map((c) => c.toJson()).toList()));
  }

  Future<void> deleteConversationsFor(String serverId) async {
    final index = await loadConversationIndex();
    for (final c in index.where((c) => c.serverId == serverId)) {
      await _prefs.remove(_conversationKey(c.id));
    }
    index.removeWhere((c) => c.serverId == serverId);
    await _prefs.setString(
        _conversationIndexKey, jsonEncode(index.map((c) => c.toJson()).toList()));
  }
}

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.serverId,
    this.project,
    required this.title,
    required this.updatedAt,
    this.preview = '',
    this.agyConversationId,
    this.origin = ChatOrigin.app,
  });

  final String id;
  final String serverId;
  /// Project folder, or null for chats that belong to no project.
  final String? project;
  final String title;
  final DateTime updatedAt;
  final String preview;
  final String? agyConversationId;

  /// Where the chat was started (this app, the CLI or the desktop app).
  final ChatOrigin origin;

  factory ConversationSummary.of(Conversation c) {
    final lastAgent = c.messages.lastWhere(
      (m) => m.role == MessageRole.agent,
      orElse: () => c.messages.isEmpty
          ? ChatMessage(id: '', role: MessageRole.agent, createdAt: DateTime.now())
          : c.messages.last,
    );
    final text = lastAgent.plainText;
    final preview = (text.isEmpty ? c.serverPreview ?? '' : text).replaceAll(RegExp(r'\s+'), ' ');
    return ConversationSummary(
      id: c.id,
      serverId: c.serverId,
      project: c.project,
      title: c.title,
      updatedAt: c.updatedAt,
      preview: preview.length > 120 ? '${preview.substring(0, 120)}…' : preview,
      agyConversationId: c.agyConversationId,
      origin: c.origin,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        if (project != null) 'workspace': project,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'preview': preview,
        if (agyConversationId != null) 'agyConversationId': agyConversationId,
        'origin': origin.name,
      };

  factory ConversationSummary.fromJson(Map<String, dynamic> json) =>
      ConversationSummary(
        id: json['id'] as String,
        serverId: json['serverId'] as String,
        project: (json['workspace'] as String?)?.isNotEmpty == true ? json['workspace'] as String : null,
        title: json['title'] as String? ?? 'Conversation',
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now(),
        preview: json['preview'] as String? ?? '',
        agyConversationId: json['agyConversationId'] as String?,
        origin: ChatOrigin.values.firstWhere((o) => o.name == json['origin'], orElse: () => ChatOrigin.app),
      );
}

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore() : _storage = const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory secret store for tests and platforms without a keystore.
class MemorySecretStore implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

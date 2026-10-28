import 'agent_options.dart';

enum AuthMethod { password, privateKey }

/// A saved VPS the app knows how to reach over SSH.
///
/// Secrets (password, private key, passphrase, API key) are never stored on
/// this object; they live in secure storage keyed by [id].
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = AuthMethod.password,
    this.useTmux = true,
    this.notifyOnFinish = true,
    this.ntfyUrl,
    this.newChatsInDesktopApp = false,
    List<String>? recentWorkspaces,
    AgentOptions? agentOptions,
    this.lastConnectedAt,
  })  : recentWorkspaces = recentWorkspaces ?? [],
        agentOptions = agentOptions ?? const AgentOptions();

  final String id;
  String name;
  String host;
  int port;
  String username;
  AuthMethod authMethod;

  /// Run the interactive terminal inside tmux so sessions survive the phone
  /// going to sleep or switching networks.
  bool useTmux;

  /// Show a notification when the agent finishes while the app is in the
  /// background.
  bool notifyOnFinish;

  /// Optional ntfy topic URL (e.g. https://ntfy.sh/agm-…) the server posts
  /// to when a run ends, so a push arrives even if the app was closed.
  String? ntfyUrl;

  /// Save new chats in the Antigravity desktop app's store on this machine
  /// (`~/.gemini/antigravity`) instead of the CLI's, so the desktop app
  /// lists them. Either way the CLI can resume them.
  bool newChatsInDesktopApp;

  /// Most recently used first.
  List<String> recentWorkspaces;

  AgentOptions agentOptions;
  DateTime? lastConnectedAt;

  String get displayAddress =>
      port == 22 ? '$username@$host' : '$username@$host:$port';

  void touchWorkspace(String path) {
    recentWorkspaces.remove(path);
    recentWorkspaces.insert(0, path);
    if (recentWorkspaces.length > 8) {
      recentWorkspaces = recentWorkspaces.sublist(0, 8);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'useTmux': useTmux,
        'notifyOnFinish': notifyOnFinish,
        if (ntfyUrl != null) 'ntfyUrl': ntfyUrl,
        'newChatsInDesktopApp': newChatsInDesktopApp,
        'recentWorkspaces': recentWorkspaces,
        'agentOptions': agentOptions.toJson(),
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 22,
        username: json['username'] as String? ?? '',
        authMethod: AuthMethod.values.firstWhere(
          (m) => m.name == json['authMethod'],
          orElse: () => AuthMethod.password,
        ),
        useTmux: json['useTmux'] as bool? ?? true,
        notifyOnFinish: json['notifyOnFinish'] as bool? ?? true,
        ntfyUrl: json['ntfyUrl'] as String?,
        newChatsInDesktopApp: json['newChatsInDesktopApp'] as bool? ?? false,
        recentWorkspaces:
            (json['recentWorkspaces'] as List?)?.cast<String>().toList(),
        agentOptions: json['agentOptions'] is Map
            ? AgentOptions.fromJson(
                Map<String, dynamic>.from(json['agentOptions'] as Map))
            : null,
        lastConnectedAt: json['lastConnectedAt'] == null
            ? null
            : DateTime.tryParse(json['lastConnectedAt'] as String),
      );
}

/// Credentials for a [ServerProfile], kept in secure storage.
class ServerSecrets {
  const ServerSecrets({
    this.password,
    this.privateKey,
    this.passphrase,
    this.geminiApiKey,
  });

  final String? password;
  final String? privateKey;
  final String? passphrase;

  /// Optional `GEMINI_API_KEY` exported for agy instead of Google sign-in.
  final String? geminiApiKey;

  Map<String, String> toMap() => {
        if (password != null) 'password': password!,
        if (privateKey != null) 'privateKey': privateKey!,
        if (passphrase != null) 'passphrase': passphrase!,
        if (geminiApiKey != null) 'geminiApiKey': geminiApiKey!,
      };

  factory ServerSecrets.fromMap(Map<String, dynamic> map) => ServerSecrets(
        password: map['password'] as String?,
        privateKey: map['privateKey'] as String?,
        passphrase: map['passphrase'] as String?,
        geminiApiKey: map['geminiApiKey'] as String?,
      );
}

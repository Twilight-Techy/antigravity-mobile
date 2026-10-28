/// How much the agent may do without asking, mapped onto agy's flags.
enum PermissionMode {
  /// Default agy behaviour. In headless runs shell and write tools are
  /// soft-denied unless allowed by rules in settings.json.
  ask,

  /// `--mode plan`: plan first, no edits.
  plan,

  /// `--mode accept-edits`: file edits are applied automatically.
  acceptEdits,

  /// `--dangerously-skip-permissions`: everything is auto-approved.
  fullAuto,
}

extension PermissionModeLabel on PermissionMode {
  String get label => switch (this) {
        PermissionMode.ask => 'Ask / read-only',
        PermissionMode.plan => 'Plan',
        PermissionMode.acceptEdits => 'Accept edits',
        PermissionMode.fullAuto => 'Full auto (Turbo)',
      };

  String get description => switch (this) {
        PermissionMode.ask =>
          'Uses your permission rules. Unapproved shell commands and writes are skipped.',
        PermissionMode.plan => 'Agent plans before acting and does not edit files.',
        PermissionMode.acceptEdits => 'File edits are applied automatically.',
        PermissionMode.fullAuto =>
          'Like Turbo in Antigravity: every command and edit runs without asking (--dangerously-skip-permissions).',
      };
}

enum Effort { auto, low, medium, high }

class AgentOptions {
  const AgentOptions({
    this.model,
    this.permissionMode = PermissionMode.acceptEdits,
    this.effort = Effort.auto,
    this.sandbox = false,
    this.fast = false,
  });

  /// Model slug passed with `--model`; null uses agy's default.
  final String? model;
  final PermissionMode permissionMode;
  final Effort effort;

  /// `--sandbox`: restrict terminal execution.
  final bool sandbox;

  /// Fast mode: skip planning for quick actions (agy's `/fast`).
  final bool fast;

  AgentOptions copyWith({
    String? model,
    bool clearModel = false,
    PermissionMode? permissionMode,
    Effort? effort,
    bool? sandbox,
    bool? fast,
  }) =>
      AgentOptions(
        model: clearModel ? null : (model ?? this.model),
        permissionMode: permissionMode ?? this.permissionMode,
        effort: effort ?? this.effort,
        sandbox: sandbox ?? this.sandbox,
        fast: fast ?? this.fast,
      );

  /// Applies Fast mode to a prompt: agy expands slash commands in headless
  /// runs, so `/fast <task>` skips planning just like in the TUI.
  String applyTo(String prompt) =>
      fast && !prompt.startsWith('/') ? '/fast $prompt' : prompt;

  /// Flags shared by the headless chat runs and the interactive terminal.
  List<String> toArgs() => [
        if (model != null && model!.isNotEmpty) ...['--model', model!],
        if (effort != Effort.auto) ...['--effort', effort.name],
        if (sandbox) '--sandbox',
        ...switch (permissionMode) {
          PermissionMode.ask => const <String>[],
          PermissionMode.plan => const ['--mode', 'plan'],
          PermissionMode.acceptEdits => const ['--mode', 'accept-edits'],
          PermissionMode.fullAuto => const ['--dangerously-skip-permissions'],
        },
      ];

  /// Flags for the interactive TUI, which can ask for approvals itself, so
  /// the permission mode is left to agy.
  List<String> toInteractiveArgs() => [
        if (model != null && model!.isNotEmpty) ...['--model', model!],
        if (effort != Effort.auto) ...['--effort', effort.name],
        if (sandbox) '--sandbox',
      ];

  Map<String, dynamic> toJson() => {
        'model': model,
        'permissionMode': permissionMode.name,
        'effort': effort.name,
        'sandbox': sandbox,
        'fast': fast,
      };

  factory AgentOptions.fromJson(Map<String, dynamic> json) => AgentOptions(
        model: json['model'] as String?,
        permissionMode: PermissionMode.values.firstWhere(
          (m) => m.name == json['permissionMode'],
          orElse: () => PermissionMode.acceptEdits,
        ),
        effort: Effort.values.firstWhere(
          (e) => e.name == json['effort'],
          orElse: () => Effort.auto,
        ),
        sandbox: json['sandbox'] as bool? ?? false,
        fast: json['fast'] as bool? ?? false,
      );
}

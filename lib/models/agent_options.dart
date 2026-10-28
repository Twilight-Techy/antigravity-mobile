/// How much the agent may do without asking, mapped onto agy's flags.
enum PermissionMode {
  /// agy's `default` mode. In headless runs workspace reads and writes are
  /// allowed; shell, web and MCP tools are soft-denied unless allowed by
  /// rules in settings.json. (`auto` mode falls back to this when headless,
  /// so it is only offered in the terminal.)
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
        PermissionMode.ask => 'Default',
        PermissionMode.plan => 'Plan',
        PermissionMode.acceptEdits => 'Accept edits',
        PermissionMode.fullAuto => 'Full auto (Turbo)',
      };

  String get description => switch (this) {
        PermissionMode.ask =>
          'Edits inside the project are allowed. Shell commands, web and MCP tools run only if your permission rules allow them; otherwise they are skipped.',
        PermissionMode.plan => 'Investigates read-only and drafts an implementation plan before writing code (--mode=plan).',
        PermissionMode.acceptEdits =>
          'Approves file edits and creations in the project; shell commands still follow your permission rules (--mode=accept-edits).',
        PermissionMode.fullAuto =>
          'Every tool call is approved, including shell commands, like Turbo in the Antigravity app (--dangerously-skip-permissions).',
      };
}

/// `--effort`. Which levels apply depends on the model (`agy -p /effort`).
enum Effort { auto, low, medium, high, xhigh, max }

class AgentOptions {
  const AgentOptions({
    this.model,
    this.permissionMode = PermissionMode.acceptEdits,
    this.effort = Effort.auto,
    this.sandbox = false,
    this.agent,
  });

  /// Model slug passed with `--model`; null uses agy's default.
  final String? model;
  final PermissionMode permissionMode;
  final Effort effort;

  /// `--sandbox`: restrict terminal execution.
  final bool sandbox;

  /// Custom agent passed with `--agent` (see `agy agents`); null = default.
  final String? agent;

  AgentOptions copyWith({
    String? model,
    bool clearModel = false,
    PermissionMode? permissionMode,
    Effort? effort,
    bool? sandbox,
    String? agent,
    bool clearAgent = false,
  }) =>
      AgentOptions(
        model: clearModel ? null : (model ?? this.model),
        permissionMode: permissionMode ?? this.permissionMode,
        effort: effort ?? this.effort,
        sandbox: sandbox ?? this.sandbox,
        agent: clearAgent ? null : (agent ?? this.agent),
      );

  /// Flags shared by the headless chat runs and the interactive terminal.
  List<String> toArgs() => [
        if (model != null && model!.isNotEmpty) ...['--model', model!],
        if (agent != null && agent!.isNotEmpty) ...['--agent', agent!],
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
        if (agent != null && agent!.isNotEmpty) ...['--agent', agent!],
        if (effort != Effort.auto) ...['--effort', effort.name],
        if (sandbox) '--sandbox',
      ];

  Map<String, dynamic> toJson() => {
        'model': model,
        'permissionMode': permissionMode.name,
        'effort': effort.name,
        'sandbox': sandbox,
        'agent': agent,
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
        agent: json['agent'] as String?,
      );
}

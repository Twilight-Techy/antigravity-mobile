# agy feature map

How every feature in the official Antigravity CLI documentation
(antigravity.google/docs: CLI reference, Headless mode, Execution modes,
Permissions, Subagents, Projects, Conversations, Artifacts, Remote Control,
Slash commands) maps to the app.

Rows marked ✓ were checked against the real agy 1.4.9 binary (see
`test/fixtures/README.md` and `test/integration/real_agy_test.dart`). Where
the binary differs from the docs, the binary wins and the difference is noted.

**Native** means built into the app's own screens. **Terminal** means it
opens in the Terminal tab, running the full agy interface on *the same
conversation* (`agy --conversation <id>`), from the Agent menu or the `/`
palette. **Prompt** means it's sent to the agent as a message.

## Launch & conversations

| agy | App |
| --- | --- |
| `agy` interactive TUI | Terminal tab (tmux-persistent) |
| `-p` headless, `--output-format stream-json` | ✓ Native: every chat reply. The binary nests each payload under its event name (`{"event":"step_update","step_update":{…}}`), unlike the flat examples in the docs; both are parsed |
| `--conversation <id>`, `-c` | ✓ Native: follow-ups continue the chat's agy conversation |
| `-i` seeded interactive | Terminal (Continue in terminal) |
| `--input-format stream-json` | Not used. Each turn is its own detached run, so it survives disconnects |
| `--print-timeout` | ✓ Native: `0s` (wait for the turn). 1.4.9's own default is `0s` too; it is passed explicitly in case an older agy defaults to 5m |
| Ctrl+C / SIGINT | ✓ Native: Stop. agy ends the turn with status `ERROR` and error `interrupted` (exit 1), which the app shows as cancelled |
| `--json-schema`, `--disable-slash-commands`, `--log-file` | Not exposed (scripting/CI options) |
| Conversation history (`~/.gemini/antigravity-cli/conversation_summaries.db`, transcripts in `brain/<id>/`) | ✓ Native: every agy conversation on the server is in the chat list, grouped by project and marked **CLI** or **Desktop**. Opening one loads its history from agy's transcript; turns taken in the CLI or the desktop app are added when the chat is opened again |
| Antigravity desktop app on the same machine (store `~/.gemini/antigravity`) | ✓ Native: its conversations are listed too and continued in place with `--app_data_dir=antigravity`, so the desktop app sees the new turns. Server setting **Save new chats to the desktop app** puts new chats there |
| `/resume`, `/switch`, `/conversation` | Chats made in the app are agy CLI conversations, so `/resume` in the CLI lists them; its "Other" tab imports desktop-app ones. In the app: Terminal (Agent menu → Other conversations) |
| `/clear`, `/new` | Native: New chat |
| `/rename` | Native: rename in the chat list, or `/rename <name>` |
| `/rewind` (`/undo`), `/fork` (`/branch`) | Terminal (Agent menu) |
| `/copy` | Native: copy button on replies, or `/copy` |
| `/exit`, `/quit` | n/a (leave the chat or Terminal) |

## Projects, folders, workspaces

| agy | App |
| --- | --- |
| Conversation history scoped to the working directory | Native: chats grouped by project folder, plus "Other chats" (scratch folder) |
| `--add-dir`, `/add-dir` (multi-folder projects) | Native: Folders chip / `/add-dir` before the first message |
| `--project`, `--new-project`, `default-cli-project` | Not exposed. agy keeps projects in `~/.gemini/config/projects/<id>.json`, but there's no command to list them; folders cover the same need |

## Modes, models, effort, agents

| agy | App |
| --- | --- |
| `--mode` default / accept-edits / plan | Native: mode picker (Default, Accept edits, Plan) |
| `auto` mode (Preview) | Terminal only (headless falls back to default). Set it as the terminal's mode in Permissions & settings |
| Shift+Tab mode cycling | Terminal key bar (⇧tab) |
| `--dangerously-skip-permissions` (always-proceed, like Turbo) | Native: "Full auto (Turbo)" |
| `--sandbox`, `enableTerminalSandbox` | Native: Permissions & settings |
| `--model`, `/model`, `agy models` | Native: model picker |
| `--effort`, `/effort` (low, medium, high, xhigh, max) | ✓ Native: effort picker, which asks `agy -p /effort --model <m>` for the levels the chosen model offers |
| `--agent`, `agy agents`, custom agents | Native: Agent chip, Antigravity CLI → Custom agents |
| `/plan`, `/goal`, `/grill-me`, `/boost`, `/teamwork-preview`, `/learn` | ✓ Prompt (from the `/` palette). agy expands them in `-p` mode too; `/goal` keeps working over several system-driven turns |
| `/fast`, `/planning` | Removed in agy 1.1.0; not offered |

## Tools, permissions, settings

| agy | App |
| --- | --- |
| `permissions.allow / ask / deny` rules | Native: Permissions & settings (add/remove rules, suggestions) |
| Headless soft-denied tools | ✓ Native: "Some tools were skipped" card on the reply → Edit permissions. Read from `result.denied_actions` (`RunCommand (command)`…), with the stderr notice as a fallback |
| `toolPermission`, `artifactReviewPolicy`, `allowNonWorkspaceAccess`, `useG1Credits`, `verbosity`, `notifications`, `showTips`, `agentMode` | Native: Permissions & settings |
| Other settings (colors, keybindings, status line, title, vim…) | Terminal: `/config`, `/keybindings`, `/statusline`, `/title` |
| `modelProvider: gemini` + `GEMINI_API_KEY` | Native: setup → API key (stored off the command line) |

## Tool calls, subagents, tasks

| agy | App |
| --- | --- |
| `step_update` tool steps (`tool_info` parameters/output/error) | ✓ Native: tool cards with input and output. Steps end in `DONE` or `ERROR`. The stream gives only some arguments and often no output, so the app fills both in from agy's transcript while the reply runs |
| Thinking | ✓ Native: not in the stream; read from the transcript (`thinking` on each model step) and shown as a collapsed **Thought** block. Agent menu → **Show thinking** hides them |
| System messages (`/goal` continuations, subagent reports, restart notices) | ✓ Native: collapsed **System** notes |
| `subagent_info` (role, type, conversation, log) | ✓ Native: subagent cards (`step_type: subagent`) → Open chat / View log. Messaging the subagent with `--conversation <its id>` works; agy replays the subagent's first turn first, which the app drops |
| `/agents`, Alt+J, Ctrl+K (approve subagent actions) | Terminal (Agent menu → Subagents; key bar ⌥J, ^K) |
| `/tasks` (background shell tasks) | Terminal (Agent menu → Background tasks) |
| `/btw`, `/schedule`, `/browser`, `/codesearch` | Terminal (Agent menu) |

## Artifacts & changes

| agy | App |
| --- | --- |
| Artifacts (plans, walkthroughs…) | ✓ Native: files the agent writes to `~/.gemini/antigravity-cli/brain/<conversation id>/` (each with a `<name>.metadata.json`) show as artifact cards, and Agent menu → Artifacts lists that folder, skipping `scratch/`, `.system_generated/` and the metadata files |
| Artifact review: approve/reject, comments (`/artifact`, Ctrl+R, `A`) | Terminal (Agent menu → Review artifacts; key bar ^R, A) |
| `/diff` per-turn diffs with line comments | Terminal (Agent menu → Review changes). Native: Changes tab (git status + diffs), "View changes" on replies that edited files |
| File browsing | Native: Files tab and viewer |

## Usage, account, extensions, CLI

| agy | App |
| --- | --- |
| `result.usage` (input/output/thinking/cached tokens) | ✓ Native: shown under each reply |
| `/usage` (`/quota`), `/credits` | ✓ Native: Agent menu → Usage & quota, from `agy -p /usage` and `agy -p /credits` (a `command_result` event plus a tab-separated report). With a Gemini API key agy has no quota to report |
| `/context` | Terminal (Agent menu) |
| `/help`, `/skills`, `/hooks`, `/model`, `/effort`, `/config`, `/permissions`, `/agents`, `/changelog` in `-p` mode | ✓ agy answers these itself without the model. The app shows `/help`, `/skills` and `/hooks` natively and uses `/effort` for the picker |
| `/diff`, `/rewind`, `/mcp` and other panels in `-p` mode | ✓ agy refuses them ("not available in print mode", exit 2), so the app opens them in the Terminal |
| Sign-in, `/logout` | Native setup (sign-in runs the TUI) / Terminal. ✓ A signed-out headless run prints a sign-in URL, waits 60s, then fails with "authentication failed or timed out"; the reply then offers **Sign in** |
| `agy mcp add/remove/list/enable/disable`, `/mcp` | Native: Antigravity CLI → MCP servers; Terminal `/mcp` |
| `agy plugin install/uninstall/list/enable/disable/import`, `/plugin` | Native: Antigravity CLI → Plugins; Terminal `/plugin` |
| `/skills`, `/hooks` | ✓ Native list (Agent menu → Skills & hooks); editing in the Terminal |
| `agy update`, `agy changelog`, `/changelog` | Native: Antigravity CLI |
| `agy remote-control start/status/stop`, `--remote-control` | Native: Antigravity CLI → Remote Control (+ link to antigravity.google.com) |
| `/voice`, F5, `agy mic-serve` | Use the phone keyboard's dictation instead (mic-serve is for desktop→SSH) |
| `/feedback`, `?` | Terminal |
| `!` shell, `@` file mention | Native: `@` mention button; `!` in Terminal; Shell in Terminal |
| Keyboard shortcuts (Esc, Ctrl+C/D/L/O/R/G/K, y/n/e, PgUp/PgDn…) | Terminal key bar |

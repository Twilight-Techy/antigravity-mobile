# agy feature map

How every feature in the official Antigravity CLI documentation
(antigravity.google/docs: CLI reference, Headless mode, Execution modes,
Permissions, Subagents, Projects, Conversations, Artifacts, Remote Control,
Slash commands) maps to the app.

**Native** means built into the app's own screens. **Terminal** means it
opens in the Terminal tab, running the full agy interface on *the same
conversation* (`agy --conversation <id>`), from the Agent menu or the `/`
palette. **Prompt** means it's sent to the agent as a message.

## Launch & conversations

| agy | App |
| --- | --- |
| `agy` interactive TUI | Terminal tab (tmux-persistent) |
| `-p` headless, `--output-format stream-json` | Native: every chat reply |
| `--conversation <id>`, `-c` | Native: follow-ups continue the chat's agy conversation |
| `-i` seeded interactive | Terminal (Continue in terminal) |
| `--input-format stream-json` | Not used. Each turn is its own detached run, so it survives disconnects |
| `--print-timeout` | Native: set to `0s` so long tasks aren't cut off |
| `--json-schema`, `--disable-slash-commands`, `--log-file` | Not exposed (scripting/CI options) |
| `/resume`, `/switch`, `/conversation` | Terminal (Agent menu → Other conversations). Chats made in the app are native |
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
| `--project`, `--new-project`, `default-cli-project` | Not exposed. agy doesn't document a way to list project IDs; folders cover the same need |

## Modes, models, effort, agents

| agy | App |
| --- | --- |
| `--mode` default / accept-edits / plan | Native: mode picker (Default, Accept edits, Plan) |
| `auto` mode (Preview) | Terminal only (headless falls back to default). Set it as the terminal's mode in Permissions & settings |
| Shift+Tab mode cycling | Terminal key bar (⇧tab) |
| `--dangerously-skip-permissions` (always-proceed, like Turbo) | Native: "Full auto (Turbo)" |
| `--sandbox`, `enableTerminalSandbox` | Native: Permissions & settings |
| `--model`, `/model`, `agy models` | Native: model picker |
| `--effort`, `/effort` (low…max) | Native: effort picker |
| `--agent`, `agy agents`, custom agents | Native: Agent chip, Antigravity CLI → Custom agents |
| `/plan`, `/goal`, `/grill-me`, `/boost`, `/teamwork-preview`, `/learn` | Prompt (from the `/` palette) |
| `/fast`, `/planning` | Removed in agy 1.1.0; not offered |

## Tools, permissions, settings

| agy | App |
| --- | --- |
| `permissions.allow / ask / deny` rules | Native: Permissions & settings (add/remove rules, suggestions) |
| Headless soft-denied tools (stderr notice) | Native: "Some tools were skipped" card on the reply → Edit permissions |
| `toolPermission`, `artifactReviewPolicy`, `allowNonWorkspaceAccess`, `useG1Credits`, `verbosity`, `notifications`, `showTips`, `agentMode` | Native: Permissions & settings |
| Other settings (colors, keybindings, status line, title, vim…) | Terminal: `/config`, `/keybindings`, `/statusline`, `/title` |
| `modelProvider: gemini` + `GEMINI_API_KEY` | Native: setup → API key (stored off the command line) |

## Tool calls, subagents, tasks

| agy | App |
| --- | --- |
| `step_update` tool steps (`tool_info` parameters/output/error) | Native: tool cards with input and output |
| `subagent_info` (role, type, conversation, log) | Native: subagent cards → Open chat (messages the subagent's conversation) / View log |
| `/agents`, Alt+J, Ctrl+K (approve subagent actions) | Terminal (Agent menu → Subagents; key bar ⌥J, ^K) |
| `/tasks` (background shell tasks) | Terminal (Agent menu → Background tasks) |
| `/btw`, `/schedule`, `/browser`, `/codesearch` | Terminal (Agent menu) |

## Artifacts & changes

| agy | App |
| --- | --- |
| Artifacts (plans, walkthroughs…) | Native: artifact cards in replies, Agent menu → Artifacts (also finds files saved under the conversation id in `~/.gemini`) |
| Artifact review: approve/reject, comments (`/artifact`, Ctrl+R, `A`) | Terminal (Agent menu → Review artifacts; key bar ^R, A) |
| `/diff` per-turn diffs with line comments | Terminal (Agent menu → Review changes). Native: Changes tab (git status + diffs), "View changes" on replies that edited files |
| File browsing | Native: Files tab and viewer |

## Usage, account, extensions, CLI

| agy | App |
| --- | --- |
| `result.usage` (input/output/thinking/cached tokens) | Native: shown under each reply |
| `/usage` (`/quota`), `/credits`, `/context` | Terminal (Agent menu) |
| Sign-in, `/logout` | Native setup (sign-in runs the TUI) / Terminal |
| `agy mcp add/remove/list/enable/disable`, `/mcp` | Native: Antigravity CLI → MCP servers; Terminal `/mcp` |
| `agy plugin install/uninstall/list/enable/disable/import`, `/plugin` | Native: Antigravity CLI → Plugins; Terminal `/plugin` |
| `/skills`, `/hooks` | Terminal |
| `agy update`, `agy changelog`, `/changelog` | Native: Antigravity CLI |
| `agy remote-control start/status/stop`, `--remote-control` | Native: Antigravity CLI → Remote Control (+ link to antigravity.google.com) |
| `/voice`, F5, `agy mic-serve` | Use the phone keyboard's dictation instead (mic-serve is for desktop→SSH) |
| `/feedback`, `/help`, `?` | Terminal |
| `!` shell, `@` file mention | Native: `@` mention button; `!` in Terminal; Shell in Terminal |
| Keyboard shortcuts (Esc, Ctrl+C/D/L/O/R/G/K, y/n/e, PgUp/PgDn…) | Terminal key bar |

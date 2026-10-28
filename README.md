# Antigravity Mobile

A Flutter app for driving the [Antigravity CLI](https://antigravity.google) (`agy`)
on your own VPS from your phone. It connects over SSH, gets the server ready
(installs `agy`, signs you in), and gives you an Antigravity-style agent chat
plus a file browser, a git diff reviewer and the full interactive TUI.

Nothing has to be deployed on the server beyond `agy` itself. Everything goes
over SSH.

## Features

- **Servers**: password or private-key auth. Credentials are kept in the
  device keystore. Host keys are trusted on first use and changes are flagged.
- **Setup checklist**: detects the OS, installs `agy` with the official
  installer (no root needed), optionally installs `tmux`, and signs in with
  Google (through the interactive TUI) or a Gemini API key.
- **Chats grouped by project**, like the Antigravity sidebar: each project
  folder lists its chats, newest first. Chats that belong to no project are
  under **Other chats**. Choose a new chat's project with the project chip
  (a recent folder, browse the server, or no project). The project is locked
  once you send the first message, because agy ties a conversation to its
  folder. No-project chats run in a private scratch folder
  (`~/.antigravity-mobile/scratch`), not your whole home directory.
- **One history with the CLI and the desktop app.** Every agy conversation
  on the server shows up in the chat list (marked **CLI** or **Desktop**),
  and any of them can be continued from the phone. Conversations of the
  Antigravity desktop app on that machine are continued in its own store
  (`--app_data_dir=antigravity`), so it sees the new turns; chats started
  here are agy CLI conversations that `/resume` lists.
- **Agent chat**
  - Each prompt runs `agy -p … --output-format stream-json`, so replies arrive
    as structured events instead of scraped terminal output.
  - Replies render as markdown with highlighted code, the model's thinking
    (collapsed, or hidden with **Show thinking**), tool-call cards with full
    input and output, subagents, artifacts and system notes. Thinking and
    tool output come from agy's transcript, which the app reads while the
    reply streams.
  - Follow-ups continue the same agy conversation (`--conversation <id>`).
  - Pickers for model (`agy models`), mode (Default, Plan, Accept edits,
    Full auto, the CLI's version of Turbo), reasoning effort (low to max)
    and custom agent (`agy agents` / `--agent`). Extra folders per chat
    (`--add-dir`).
  - Tool calls, subagents (open the subagent's own conversation as a chat,
    or read its log) and **artifacts** render natively. Tools that headless
    permissions skipped are listed with a shortcut to the **Permissions &
    settings** editor (allow/ask/deny rules and agy's settings).
  - **Agent menu**: Artifacts, Permissions & settings, the Antigravity CLI
    screen (update, release notes, Remote Control, MCP, plugins, agents), and
    every interactive-only panel (subagents, background tasks, per-turn diff
    review, artifact review, rewind, fork, /btw, /schedule, /browser, usage
    and credits, context, skills…), opened on *this chat's own conversation*
    in the terminal.
  - Replies where the agent edited files get a **View changes** button that
    jumps to the diff.
  - See [docs/FEATURE_MAP.md](docs/FEATURE_MAP.md) for how every documented
    agy feature maps to the app.
  - `/` command palette, `@` file mentions, Stop.
  - **Survives your phone sleeping.** The agent runs detached (`nohup` on
    Linux/macOS, a WMI-created process on Windows) and writes to
    `~/.antigravity-mobile/runs/`. If the connection
    drops, the app reconnects and resumes the stream from the last byte it
    received.
- **Files**: browse the workspace, syntax-highlighted viewer, rendered
  markdown, "mention in chat".
- **Changes**: `git status` with coloured diffs, so you can review what the
  agent edited, plus one-tap "ask for a review" and "ask to commit".
- **Terminal**: a real VT emulator ([xterm](https://pub.dev/packages/xterm))
  running the full `agy` TUI for `/config`, `/mcp`, `/permissions`, step-by-step
  approvals, etc. It runs inside tmux when available, so sessions survive
  disconnects. A key bar provides esc/tab/ctrl/arrows/`y`/`n`/^C/^O/^R/^K, and
  links such as the Google sign-in URL are detected and offered as Open/Copy.
- **Notifications** when the agent finishes while the app is in the
  background. Tapping one opens that conversation.
  - **Android, built in:** a foreground service ("Agent working in …") keeps
    the connection open until the agent is done.
  - **Android push (FCM):** if the app was built with Firebase and the push
    relay (see [`relay/`](relay/README.md)), the server itself pushes
    through the relay, so you're notified even if the app was killed. Users
    set nothing up; the app owner deploys the relay once.
  - **iOS:** the system only allows about 30 seconds of background time. For
    longer tasks, turn on **Push via ntfy** in the server settings. The server
    posts to your [ntfy](https://ntfy.sh) topic when a task ends, and tapping
    that notification opens this app on the conversation. Only the workspace
    name and outcome are sent.
  - All of these open the app through `antigravity://open?server=…&conversation=…`
    links.
- **Linux, macOS and Windows servers**: scripts are generated for POSIX `sh` or
  PowerShell (Windows OpenSSH) automatically.

## How it talks to agy

| Need | Mechanism |
| --- | --- |
| Chat replies | `agy -p "<prompt>" --output-format stream-json --print-timeout 0s [--conversation id] [--mode/--model/--effort/--agent/--add-dir …]` in the chat's folder. Detached (`nohup` on Linux/macOS, a WMI-created process on Windows), streamed from its output file, resumable by byte offset |
| Conversation list | agy's index (`conversation_summaries.db`) read with `python3` or `sqlite3`; without either, the transcripts plus a byte-level read of the index for each chat's folder |
| Sign-in, `/config`, approvals | Interactive `agy` in a PTY (`tmux new-session -A` when available) |
| Models | `agy models` (`id<TAB>name` lines) |
| Quota, credits, skills, effort levels | `agy -p /usage` (and `/credits`, `/skills`, `/hooks`, `/help`, `/effort`) with `--output-format stream-json`: agy answers these itself |
| Install | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` (or `install.ps1` on Windows) |
| API key | Sent over **stdin** into `~/.antigravity-mobile/env` (mode 600), never on a command line. `modelProvider: "gemini"` is set in `~/.gemini/antigravity-cli/settings.json` |
| Files / git | `find`/`head`/`base64`/`git` over SSH exec channels |

Replies are parsed from agy's headless `stream-json` events: `init`,
`step_update` (streamed `text_delta`, `tool` steps with `tool_info`,
`subagent` steps with `subagent_info`), `command_result` and the final
`result` (status, response, usage, `denied_actions`). agy 1.4.9 nests each
payload under its event name (`{"event":"result","result":{…}}`). The parser
was checked against output recorded from the real binary
(`test/fixtures/agy_1_4_9`); it also accepts the flat shape in the docs and
other common agent-CLI shapes as a fallback.

Artifacts are the files the agent writes to agy's artifact directory,
`~/.gemini/antigravity-cli/brain/<conversation id>/`.

Headless runs can't stop to ask for approval. Edits inside the project are
allowed, while shell, web and MCP tools are skipped unless your
`permissions.allow` rules allow them. The reply lists what was skipped,
with a shortcut to add rules. Use **Full auto** to allow everything, or the
Terminal tab for step-by-step approvals.

## Project layout

```
lib/
  models/      ServerProfile, AgentOptions, Conversation/ChatMessage
  services/    RemoteHost (SSH transport), RemoteScripts (sh + PowerShell),
               AgyService (setup, files, git, AgentRun), stream parser,
               MessageBuilder, StorageService
  state/       ServersState, SessionState, ChatController, TerminalSession
  ui/          screens (servers, setup, workspace picker, chat, files,
               changes, terminal), widgets, theme
test/
  unit/        parser, scripts, git status, options, JSON round-trips
  widget/      full app flow against an in-memory fake server
  integration/ real SSH against a server with a fake agy (opt-in)
tool/fake_agy.sh  stand-in agy used by the integration tests
relay/            Cloudflare Worker push relay for FCM (optional)
```

## Building

Requires Flutter 3.47+ (Dart 3.13).

```sh
flutter pub get
flutter run                      # on a connected device or emulator
flutter build apk --release      # Android
flutter build ipa                # iOS (on macOS with Xcode)
```

CI (`.github/workflows/build.yml`) runs analyze and tests, then builds the
Android APKs and an **unsigned iOS IPA** on a macOS runner. Download them from
the run's artifacts. The IPA can be sideloaded with AltStore or Sideloadly,
which re-sign it with your Apple ID. Distributing through TestFlight or the
App Store needs an Apple Developer account and signing secrets.

The release Android build is currently signed with the debug key. Add your
own signing config in `android/app/build.gradle.kts` before publishing.
Windows/macOS/Linux desktop builds also work for development. The web target
cannot open raw TCP sockets, so SSH does not work there.

## Tests

```sh
flutter analyze
flutter test                     # unit + widget tests
```

`test/unit/real_agy_output_test.dart` replays output recorded from the real
agy 1.4.9 binary. The integration tests need an SSH server you control with
the fake agy installed:

```sh
# on the test server, for a throwaway user:
install -D tool/fake_agy.sh ~/.local/bin/agy
mkdir ~/project && cd ~/project && git init && echo hello > readme.md \
  && git add . && git commit -m init && echo change >> readme.md && echo new > new.txt

# locally:
AGM_SSH_TEST_KEY=path/to/private_key AGM_SSH_TEST_HOST=host \
AGM_SSH_TEST_PORT=22 AGM_SSH_TEST_USER=user flutter test test/integration/ssh_integration_test.dart
```

`test/integration/local_scripts_test.dart` runs the server scripts on the
machine running the tests, without SSH: sh on Linux/macOS and PowerShell on
Windows (CI runs it on both). It needs the Dart fake agy:

```sh
dart compile exe tool/fake_agy.dart -o build/fake_agy/agy
AGM_FAKE_AGY=build/fake_agy/agy flutter test test/integration/local_scripts_test.dart
```

`test/integration/real_agy_test.dart` runs the same pipeline against the
**real** agy (`AGM_REAL_AGY=1`). Without a Google account to spare, point agy
at `tool/mock_gemini.py`, a scripted stand-in for the Gemini API:
`modelProvider: "gemini"` in `~/.gemini/antigravity-cli/settings.json`, and
`export GEMINI_API_KEY=dummy GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:8765` in
`~/.antigravity-mobile/env`.

## Limitations

- On Windows servers the Terminal tab has no tmux, so an interactive session
  ends when the connection drops. Chat replies are not affected: they run
  detached (started through WMI) and resume after a reconnect, as on Linux.
- Approval prompts are interactive only in the Terminal tab (see above).
- Settings such as `modelProvider` are kept per store, so a Gemini API key
  set up in the app applies to the CLI's store; desktop-app conversations
  use the desktop app's own sign-in.

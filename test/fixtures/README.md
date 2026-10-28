# Recorded agy output

`agy_1_4_9/` holds what the real Antigravity CLI 1.4.9 (linux x64) printed
for `agy -p "<prompt>" --output-format stream-json`: `<name>.jsonl` is
stdout and `<name>.stderr` is stderr. Home and project paths were rewritten
to `/home/dev` and `/home/dev/proj`.

The binary was the official release (sha512 checked against its manifest).
Its model calls were answered by `tool/mock_gemini.py`: agy was set to use
the Gemini API (`modelProvider: "gemini"`, `GEMINI_API_KEY=dummy`) with
`GOOGLE_GEMINI_BASE_URL` pointing at the mock. Everything else, including
the event format, tool execution, permissions, artifacts, subagents and slash
commands, is agy's own.

| Fixture | Prompt | Shows |
| --- | --- | --- |
| `hello` | `say hi` | `init`, `user_input`, `agent_response` with `text_delta`, `result` with `usage` |
| `artifact` | `ARTIFACT please` | `write_file` to `~/.gemini/antigravity-cli/brain/<conversation>/implementation_plan.md` |
| `edit` | `EDIT please` | a workspace write (allowed headlessly) |
| `denied` | `CMD please` | `run_command` soft-denied: `result.denied_actions` and the stderr notice |
| `tool_error` | `BADTOOL please` | a tool step ending in state `ERROR` with `tool_info.error` |
| `subagent` | `SUB please` | `define_subagent`, then a `subagent` step with `subagent_info` (conversation, log, workspaces) |
| `subagent_chat` | `--conversation <subagent id>` | continuing a subagent's conversation: agy replays its first turn before our `user_input` |
| `interrupted` | `SLOW please`, then SIGINT | Stop: status `ERROR`, error `interrupted`, exit code 1 |
| `usage`, `help`, `model` | `/usage`, `/help`, `/model` | `command_result` with structured `data`, then a `result` with a tab-separated `response` |
| `diff_rejected` | `/diff` | interactive-only commands are refused in print mode (exit 2) |
| `signed_out` | no credentials | headless runs print a sign-in URL, wait 60s for a code, then fail |

To re-run the app's SSH pipeline against the real binary, see
`test/integration/real_agy_test.dart`.

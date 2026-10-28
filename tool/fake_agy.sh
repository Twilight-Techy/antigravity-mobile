#!/bin/bash
# Fake agy for integration tests. Emits the documented headless
# stream-json events (init / step_update / result).
case "$1" in
  --version) echo "agy 1.4.4 (fake)"; exit 0;;
  models) echo "Available models:"; echo "  gemini-3-pro (default)"; echo "  gemini-3-flash"; exit 0;;
  agents) echo "reviewer"; echo "docs-writer"; exit 0;;
  mcp) echo "fs  stdio  enabled"; exit 0;;
  remote-control) echo "Remote control: stopped"; exit 0;;
esac
P=""; CONV=""; ARGS="$*"
while [ $# -gt 0 ]; do case "$1" in -p|--prompt|--print) P="$2"; shift;; --output-format|--print-timeout|--mode|--model|--effort|--agent|--add-dir) shift;; --conversation) CONV="$2"; shift;; esac; shift; done
if [ -n "$P" ]; then
  [ -z "$CONV" ] && CONV="conv-123"
  echo "{\"event\":\"init\",\"cwd\":\"$PWD\",\"tools\":[\"run_command\"],\"permission_mode\":\"request-review\",\"model\":\"gemini-3-pro\"}"
  echo "{\"event\":\"step_update\",\"conversation_id\":\"$CONV\",\"step_index\":0,\"state\":\"DONE\",\"step_type\":\"user_input\"}"
  echo "{\"event\":\"step_update\",\"conversation_id\":\"$CONV\",\"step_index\":1,\"state\":\"ACTIVE\",\"step_type\":\"agent_response\",\"text_delta\":\"You said: \"}"
  sleep 0.3
  python3 -c 'import json,sys; print(json.dumps({"event":"step_update","conversation_id":sys.argv[2],"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":sys.argv[1]}))' "$P" "$CONV"
  echo "{\"event\":\"step_update\",\"conversation_id\":\"$CONV\",\"step_index\":1,\"state\":\"DONE\",\"step_type\":\"agent_response\"}"
  echo "{\"event\":\"step_update\",\"conversation_id\":\"$CONV\",\"step_index\":2,\"state\":\"ACTIVE\",\"step_type\":\"tool\",\"tool_name\":\"run_command\",\"tool_info\":{\"name\":\"run_command\",\"parameters\":{\"command\":\"ls\"}}}"
  sleep "$(cat $HOME/.fake_sleep 2>/dev/null || echo 0.5)"
  echo "{\"event\":\"step_update\",\"conversation_id\":\"$CONV\",\"step_index\":2,\"state\":\"DONE\",\"step_type\":\"tool\",\"tool_name\":\"run_command\",\"tool_info\":{\"name\":\"run_command\",\"parameters\":{\"command\":\"ls\"},\"output\":\"$(ls | tr '\n' ' ')\"}}"
  case "$P" in *deny-me*) echo "Tool run_command was denied: requires approval (headless)" >&2;; esac
  echo "$ARGS" > "$HOME/.fake_last_args"
  echo "{\"event\":\"result\",\"conversation_id\":\"$CONV\",\"status\":\"SUCCESS\",\"response\":\"done\",\"duration_seconds\":1.2,\"num_turns\":1,\"usage\":{\"input_tokens\":1200,\"output_tokens\":34,\"total_tokens\":1234}}"
  exit 0
fi
echo "interactive fake agy. type something:"; read x; echo "got $x"

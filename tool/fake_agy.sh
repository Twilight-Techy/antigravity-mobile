#!/bin/bash
# Fake agy for integration tests. Emits headless stream-json in the shape
# agy 1.4.9 prints: {"event":"<name>","<name>":{...}} for init, step_update,
# command_result and result (see test/fixtures/agy_1_4_9 for real output).
case "$1" in
  --version) echo "1.4.9"; exit 0;;
  models) echo "Fetching available models..."; printf 'gemini-3-pro\tGemini 3 Pro\ngemini-3-flash\tGemini 3 Flash\n'; exit 0;;
  agents) echo "reviewer"; echo "docs-writer"; exit 0;;
  mcp) echo "fs  stdio  enabled"; exit 0;;
  remote-control) echo "Remote control: stopped"; exit 0;;
esac
P=""; CONV=""; ARGS="$*"
while [ $# -gt 0 ]; do case "$1" in -p|--prompt|--print) P="$2"; shift;; --output-format|--print-timeout|--mode|--model|--effort|--agent|--add-dir) shift;; --conversation) CONV="$2"; shift;; esac; shift; done
step() { echo "{\"event\":\"step_update\",\"step_update\":{\"conversation_id\":\"$CONV\",$1}}"; }
if [ -n "$P" ]; then
  echo "$ARGS" > "$HOME/.fake_last_args"
  case "$P" in
    /usage)
      echo '{"event":"command_result","command":{"name":"usage","data":{"groups":[]}}}'
      printf '{"event":"result","result":{"conversation_id":"","status":"SUCCESS","response":"Gemini 3 Pro\\t80%% left\\n","num_turns":0}}\n'
      exit 0;;
    /diff)
      echo '{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"/diff is not available in print mode"}}'
      exit 2;;
  esac
  [ -z "$CONV" ] && CONV="conv-123"
  echo "{\"event\":\"init\",\"conversation_id\":\"$CONV\",\"init\":{\"cwd\":\"$PWD\",\"tools\":[\"run_command\"],\"permission_mode\":\"request-review\"}}"
  step '"step_index":0,"state":"DONE","step_type":"user_input"'
  step '"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"You said: "'
  sleep 0.3
  python3 -c 'import json,sys; print(json.dumps({"event":"step_update","step_update":{"conversation_id":sys.argv[2],"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":sys.argv[1]}}))' "$P" "$CONV"
  step '"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls"}}'
  sleep "$(cat $HOME/.fake_sleep 2>/dev/null || echo 0.5)"
  step "\"step_index\":2,\"state\":\"DONE\",\"step_type\":\"tool\",\"tool_name\":\"run_command\",\"tool_info\":{\"name\":\"run_command\",\"parameters\":{\"CommandLine\":\"ls\"},\"output\":\"$(ls | tr '\n' ' ')\"}"
  DENIED=""
  case "$P" in *deny-me*)
    echo 'jetski: no output produced — a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied.' >&2
    DENIED=',"denied_actions":[{"action":"command","display_name":"RunCommand"}]';;
  esac
  echo "{\"event\":\"result\",\"result\":{\"conversation_id\":\"$CONV\",\"status\":\"SUCCESS\",\"response\":\"done\",\"duration_seconds\":1.2,\"num_turns\":1,\"usage\":{\"input_tokens\":1200,\"output_tokens\":34,\"thinking_tokens\":0,\"cache_read_tokens\":0,\"total_tokens\":1234}$DENIED}}"
  exit 0
fi
echo "interactive fake agy. type something:"; read x; echo "got $x"

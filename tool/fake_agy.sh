#!/bin/bash
# Fake agy for integration tests.
case "$1" in
  --version) echo "agy 1.2.4 (fake)"; exit 0;;
  models) echo "Available models:"; echo "  gemini-3-pro (default)"; echo "  gemini-3-flash"; exit 0;;
esac
P=""; CONV=""
while [ $# -gt 0 ]; do case "$1" in -p|--prompt) P="$2"; shift;; --output-format) shift;; --conversation) CONV="$2"; shift;; esac; shift; done
if [ -n "$P" ]; then
  [ -z "$CONV" ] && CONV="conv-123"
  echo "{\"type\":\"system\",\"subtype\":\"init\",\"conversation_id\":\"$CONV\",\"model\":\"gemini-3-pro\"}"
  printf '{"type":"text_delta","delta":"You said: "}\n'
  sleep 0.3
  python3 -c 'import json,sys; print(json.dumps({"type":"text_delta","delta":sys.argv[1]}))' "$P"
  echo '{"type":"tool_call","id":"t1","name":"run_command","input":{"command":"ls"}}'
  sleep "$(cat $HOME/.fake_sleep 2>/dev/null || echo 0.5)"
  echo "{\"type\":\"tool_result\",\"id\":\"t1\",\"output\":\"$(ls | tr '\n' ' ')\"}"
  echo "{\"type\":\"result\",\"status\":\"SUCCESS\",\"conversation_id\":\"$CONV\",\"response\":\"done\",\"usage\":{\"input_tokens\":1200,\"output_tokens\":34}}"
  exit 0
fi
echo "interactive fake agy. type something:"; read x; echo "got $x"

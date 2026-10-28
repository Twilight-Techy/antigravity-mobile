#!/usr/bin/env python3
"""A stand-in for the Gemini API, to run the real agy without a Google account.

agy talks to the Gemini API directly when `modelProvider: "gemini"` is set in
~/.gemini/antigravity-cli/settings.json and GEMINI_API_KEY is exported;
GOOGLE_GEMINI_BASE_URL points it here instead of Google. The replies are
scripted by keywords in the first prompt of the conversation:

  ARTIFACT  writes implementation_plan.md to the artifact directory
  EDIT      writes hello.txt in the workspace (MOCK_CWD)
  CMD       runs a shell command (denied in headless mode)
  BADTOOL   reads a file outside the workspace (denied, step ends in ERROR)
  SUB       defines and invokes a subagent; the subagent replies SUBDONE
  SLOW      answers after 25 seconds (to test Stop)
  anything else gets "Hello! How can I help?"

Usage: python3 tool/mock_gemini.py [port]  (default 8765), then
  GEMINI_API_KEY=dummy GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:8765 agy -p hi --output-format stream-json
"""
import http.server
import json
import os
import re
import sys
import time


def _usage():
    return {"promptTokenCount": 100, "candidatesTokenCount": 20, "thoughtsTokenCount": 5,
            "totalTokenCount": 125, "cachedContentTokenCount": 10}


def _candidate(parts, finish=None):
    c = {"content": {"role": "model", "parts": parts}}
    if finish:
        c["finishReason"] = finish
    return {"candidates": [c], "usageMetadata": _usage()}


def _call(name, args):
    return [_candidate([{"functionCall": {"name": name, "args": args}, "thoughtSignature": "c2ln"}], "STOP")]


def _text(t, thought=None):
    out = [_candidate([{"text": thought, "thought": True}])] if thought else []
    half = len(t) // 2
    return out + [_candidate([{"text": t[:half]}]), _candidate([{"text": t[half:]}], "STOP")]


def reply(body):
    if "tools" not in body:  # title generation and other side requests
        return _text("Chat title")
    system = json.dumps(body.get("systemInstruction", ""))
    contents = body.get("contents", [])
    first = "".join(p.get("text", "") for p in contents[0].get("parts", [])) if contents else ""
    answered = [p["functionResponse"]["name"] for c in contents for p in c.get("parts", []) if "functionResponse" in p]
    m = re.search(r'Artifact Directory Path: (\S+?)(?:\\n|\s|")', system)
    artifacts = m.group(1) if m else "/tmp"

    if "SLOW" in first:
        time.sleep(25)
        return _text("Finally done.")
    if "SUBTASK" in first:
        return _text("SUBDONE Subagent finished: found 3 files.", "Looking around")
    if "ARTIFACT" in first:
        if not answered:
            return _call("write_file", {"Path": artifacts + "/implementation_plan.md", "Content": "# Plan\n\n- step one\n",
                                        "ArtifactMetadata": {"Summary": "The plan", "UserFacing": True, "RequestFeedback": True}})
        return _text("I wrote the plan artifact.")
    if "EDIT" in first:
        if not answered:
            return _call("write_file", {"Path": os.environ.get("MOCK_CWD", os.getcwd()) + "/hello.txt", "Content": "hi\n"})
        return _text("Created hello.txt.")
    if "CMD" in first:
        if not answered:
            return _call("run_command", {"CommandLine": "echo hello", "toolSummary": "Echo test", "WaitMsBeforeAsync": 2000})
        return _text("Ran the command.")
    if "BADTOOL" in first:
        if not answered:
            return _call("read_file", {"Path": "/nonexistent/file.txt"})
        return _text("That file does not exist.")
    if "SUB" in first:
        if "define_subagent" not in answered:
            return _call("define_subagent", {"Name": "researcher", "Description": "Researches code",
                                             "SystemPrompt": "You research code."})
        if "invoke_subagent" not in answered:
            return _call("invoke_subagent", {"TypeName": "researcher", "Role": "Codebase Researcher",
                                             "Prompt": "SUBTASK: list files"})
        if "SUBDONE" not in json.dumps(contents):
            return _text("Subagent started, waiting.")
        return _text("All done with subagent.")
    return _text("Hello! How can I help?", "The user greets me.")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        data = "".join("data: " + json.dumps(c) + "\r\n\r\n" for c in reply(body)).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

"""A scripted OpenAI-compatible model for pi's simulator tests (pi's "network" provider), no real model needed.

The latest user message decides: "run exactly: CMD." calls bash with CMD; "TOOLTEST" calls bash with an echo and then
answers with the tool's result as the model got it (so a test sees that results reach the model); "MCP NAME {json}"
calls the tool NAME. Once the tools answered, or without one: the words after "exactly the word(s)" and "add the word",
a Python code block for "Python code block", else "ok". Every request's messages go to requests.jsonl beside it.

    tools/model-mock/server.py [PORT]     (default 8792; base URL http://127.0.0.1:PORT/v1, model "mock")

A simulator test points pi at it once, and the tests after it keep it (TEST_RUNNER_ variables reach the tests):

    TEST_RUNNER_PI_PROMPT=TOOLTEST TEST_RUNNER_PI_LAUNCH_ARGS="-setNetworkEndpoint|http://127.0.0.1:8792/v1|-setDefaultModel|network:mock" \
        xcodebuild test ... -only-testing:DemoTourUITests/TourTests/testPrompt
    (then testSendNow, testQueuedSteering, testCopyMessage, testFork, testMCPServer with
     TEST_RUNNER_PI_PROMPT="MCP mcp__mock__get_secret_number {}", ...)
"""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOG = Path(__file__).with_name("requests.jsonl")


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(part.get("text", "") for part in content or [] if isinstance(part, dict))


def decide(messages):
    last_user = max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1)
    prompt = text_of(messages[last_user]["content"]) if last_user >= 0 else ""
    after = messages[last_user + 1:]
    tools_answered = [m for m in after if m.get("role") == "tool"]
    if not tools_answered:
        if m := re.search(r"run exactly: (.+?)\.(\s|$)", prompt):
            return {"tool": "bash", "args": {"command": m.group(1)}}
        if "TOOLTEST" in prompt:
            return {"tool": "bash", "args": {"command": "echo tool-output-$((6*7))"}}
        if m := re.search(r"MCP (\S+) (\{.*\})", prompt):
            return {"tool": m.group(1), "args": json.loads(m.group(2))}
    if "TOOLTEST" in prompt or re.search(r"MCP \S+ \{", prompt):
        return {"text": "The tool said: " + " | ".join(text_of(m.get("content")).strip() for m in tools_answered)}
    # Words asked for, across the user's messages since the last answer.
    users = [text_of(m["content"]) for m in messages if m.get("role") == "user"]
    words = []
    # A message that says its words answers with just those; one that adds to them, with the earlier ones too.
    for text in users[-1:] if re.search(r"exactly the words? ", prompt) else users[-3:]:
        words += [w.strip() for w in re.findall(r"exactly the words? ([\w ]+?)[.,]", text)]
        words += re.findall(r"add the word (\w+)", text)
    if "Python code block" in prompt:
        return {"text": '```python\nprint("copy test")\n```'}
    if "reply with the word ok" in prompt:
        return {"text": "ok"}
    return {"text": " ".join(dict.fromkeys(words)) or "ok"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self.send(200, {"object": "list", "data": [{"id": "mock", "object": "model", "context_length": 128000, "max_output_tokens": 8192}]})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        messages = body.get("messages", [])
        reply = decide(messages)
        with LOG.open("a") as log:
            log.write(json.dumps({"at": time.time(), "messages": messages, "tools": [t["function"]["name"] for t in body.get("tools", [])], "reply": reply}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        base = {"id": f"mock-{time.time_ns()}", "object": "chat.completion.chunk", "created": int(time.time()), "model": "mock"}

        def chunk(delta, finish=None):
            event = dict(base, choices=[{"index": 0, "delta": delta, "finish_reason": finish}])
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()

        try:
            if "tool" in reply:
                chunk({"role": "assistant", "content": None, "tool_calls": [{"index": 0, "id": f"call_{time.time_ns()}", "type": "function",
                                                                          "function": {"name": reply["tool"], "arguments": json.dumps(reply["args"])}}]})
                chunk({}, "tool_calls")
            else:
                chunk({"role": "assistant", "content": ""})
                for piece in re.findall(r"\S+\s*|\s+", reply["text"]):
                    chunk({"content": piece})
                chunk({}, "stop")
            usage = dict(base, choices=[], usage={"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110})
            self.wfile.write(f"data: {json.dumps(usage)}\n\ndata: [DONE]\n\n".encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8792
    print(f"model mock on http://127.0.0.1:{port}/v1", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

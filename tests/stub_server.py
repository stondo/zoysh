#!/usr/bin/env python3
"""OpenAI-compatible stub server for zoysh tests.

Stdlib-only HTTP server used by the zoysh test suite so that streaming,
cancellation, and multi-step behavior can be tested without a real model
backend.

Usage:
    python3 tests/stub_server.py [port] [script] [request_log]

    port         port to listen on (default 9199, host 127.0.0.1)
    script       canned response script name (default "plain")
    request_log  optional file where each request is appended as one JSON
                 line {"path": ..., "body": ...} for test assertions

Endpoints:
    GET  /v1/models               -> {"data": [{"id": "stub-model"}]}
    POST /v1/chat/completions     -> OpenAI Chat Completions (SSE or JSON)
    POST /v1/messages             -> Anthropic Messages (SSE or JSON)
    POST /v1/responses            -> OpenAI Responses (SSE or JSON)

When the request body contains "stream": true the server answers with SSE
chunks built from the script; otherwise it answers with a full JSON body
whose content is byte-identical to the concatenation of the SSE chunks.
This lets tests assert that streaming and non-streaming paths agree.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"

# Each script maps to a list of SSE chunks. The full (non-streaming) response
# content is always "".join(chunks) so both transports agree by construction.
SCRIPTS = {
    "plain": [
        '{"type":"chat","response":"Hello from the stub."}',
    ],
    "chat-md": [
        "## Stub answer\n\n",
        "- item one\n",
        "- item two\n\n",
        "Use `ls -l` to list files.",
    ],
    "command": [
        '{"type":"command","command":"echo hello-zoysh","explanation":"prints a greeting"}',
    ],
    "widget": [
        '{"type":"command","command":"echo ZOYSH_WIDGET_OK","explanation":"prints the marker"}',
    ],
    "think": [
        '<think>let me think about this</think>'
        '{"type":"chat","response":"visible after thinking"}',
    ],
    # The think tags straddle chunk boundaries to exercise the incremental
    # suppression state machine in the zoysh streaming helper.
    "think-stream": [
        "<thi",
        'nk>the model muses quietly</thi',
        'nk>{"type"',
        ':"chat","response":"visible after thinking"}',
    ],
    "slow": [
        "counting ",
        "one, ",
        "two, ",
        "three.",
    ],
    "veryslow": [
        "this chunk arrives too late",
    ],
    "plan3": [
        "Build all the things\n",
        "```zoysh:plan\n",
        "echo step-one\necho step-two\necho step-three\n",
        "```",
    ],
    "plan2echo": [
        "Two-step plan\n",
        "```zoysh:plan\n",
        "echo known-output-marker\necho done\n",
        "```",
    ],
    "lastcmd": [
        '{"type":"chat","response":"the last command printed known-output-marker"}',
    ],
    "truncated": [
        '{"type":"command","command":"echo neve',
    ],
}

CHUNK_DELAY = {
    "slow": 0.4,
}

FIRST_CHUNK_DELAY = {
    "veryslow": 30.0,
}

FINISH_REASON_OVERRIDE = {
    "truncated": "length",
}


class StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "zoysh-stub/1.0"

    # Class attributes configured by main().
    script = "plain"
    request_log = None

    def log_message(self, fmt, *args):
        pass

    # ── helpers ────────────────────────────────────────────────────────────

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _log_request(self, path, body):
        if not self.request_log:
            return
        try:
            with open(self.request_log, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"path": path, "body": body}) + "\n")
        except OSError:
            pass

    def _writable(self):
        return True

    # ── routes ─────────────────────────────────────────────────────────────

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._log_request(self.path, "")
            payload = json.dumps({"data": [{"id": "stub-model"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404, "unknown path")

    def do_POST(self):
        body = self._read_body()
        try:
            request = json.loads(body.decode("utf-8", "replace"))
        except ValueError:
            request = {}
        streaming = request.get("stream") is True
        self._log_request(self.path, body.decode("utf-8", "replace"))

        if self.script == "error429":
            payload = json.dumps(
                {"error": {"message": "stub rate limited"}}
            ).encode()
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        path = self.path.rstrip("/")
        if path.endswith("/chat/completions"):
            self._serve_chat_completions(streaming)
        elif path.endswith("/messages"):
            self._serve_anthropic(streaming)
        elif path.endswith("/responses"):
            self._serve_responses(streaming)
        else:
            self.send_error(404, "unknown path")

    # ── provider shapes ────────────────────────────────────────────────────

    def _chunks(self):
        return SCRIPTS[self.script]

    def _delay(self):
        time.sleep(FIRST_CHUNK_DELAY.get(self.script, 0.0))

    def _chunk_delay(self):
        delay = CHUNK_DELAY.get(self.script, 0.0)
        if delay:
            time.sleep(delay)

    def _finish_reason(self):
        return FINISH_REASON_OVERRIDE.get(self.script, "stop")

    def _send_sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self._delay()
        for index, data in enumerate(events):
            self.wfile.write(b"data: " + data + b"\n\n")
            self.wfile.flush()
            if index + 1 < len(events):
                self._chunk_delay()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _send_json(self, payload):
        data = json.dumps(payload).encode()
        self._delay()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _serve_chat_completions(self, streaming):
        chunks = self._chunks()
        finish = self._finish_reason()
        if streaming:
            events = [
                json.dumps({"choices": [{"delta": {"content": chunk}}]}).encode()
                for chunk in chunks
            ]
            events.append(
                json.dumps({"choices": [{"delta": {}, "finish_reason": finish}]}).encode()
            )
            self._send_sse(events)
        else:
            content = "".join(chunks)
            self._send_json(
                {
                    "choices": [
                        {"message": {"content": content}, "finish_reason": finish}
                    ]
                }
            )

    def _serve_anthropic(self, streaming):
        chunks = self._chunks()
        stop = "max_tokens" if self.script == "truncated" else "end_turn"
        if streaming:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self._delay()
            self.wfile.write(
                b"data: " + json.dumps({"type": "message_start"}).encode() + b"\n\n"
            )
            self.wfile.write(
                b"data: "
                + json.dumps(
                    {"type": "content_block_start", "index": 0}
                ).encode()
                + b"\n\n"
            )
            for index, chunk in enumerate(chunks):
                self.wfile.write(
                    b"data: "
                    + json.dumps(
                        {
                            "type": "content_block_delta",
                            "index": 0,
                            "delta": {"type": "text_delta", "text": chunk},
                        }
                    ).encode()
                    + b"\n\n"
                )
                self.wfile.flush()
                if index + 1 < len(chunks):
                    self._chunk_delay()
            self.wfile.write(
                b"data: "
                + json.dumps(
                    {"type": "message_delta", "delta": {"stop_reason": stop}}
                ).encode()
                + b"\n\n"
            )
            self.wfile.write(
                b"data: " + json.dumps({"type": "message_stop"}).encode() + b"\n\n"
            )
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        else:
            content = "".join(chunks)
            self._send_json(
                {"content": [{"type": "text", "text": content}], "stop_reason": stop}
            )

    def _serve_responses(self, streaming):
        chunks = self._chunks()
        incomplete = self.script == "truncated"
        if streaming:
            events = []
            for chunk in chunks:
                events.append(
                    json.dumps(
                        {"type": "response.output_text.delta", "delta": chunk}
                    ).encode()
                )
            completed = (
                {"type": "response.completed"}
                if not incomplete
                else {"type": "response.incomplete"}
            )
            events.append(json.dumps(completed).encode())
            self._send_sse(events)
        else:
            content = "".join(chunks)
            self._send_json(
                {
                    "output": [
                        {
                            "type": "message",
                            "content": [{"type": "output_text", "text": content}],
                        }
                    ],
                    "status": "incomplete" if incomplete else "completed",
                }
            )


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9199
    StubHandler.script = sys.argv[2] if len(sys.argv) > 2 else "plain"
    StubHandler.request_log = sys.argv[3] if len(sys.argv) > 3 else None

    server = ThreadingHTTPServer((HOST, port), StubHandler)
    server.daemon_threads = True
    print(f"zoysh-stub listening on {HOST}:{port} script={StubHandler.script}",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

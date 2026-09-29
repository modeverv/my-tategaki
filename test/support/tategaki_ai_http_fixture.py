#!/usr/bin/env python3
"""Loopback-only synthetic OpenAI-shaped fixture for Emacs HTTP smoke tests.

No models or external network are used. Port 0 chooses an ephemeral port;
stdout's first JSON line reports it. Stop by terminating this process.
"""
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

requests = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def respond(self, status, body, headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def dispatch(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.respond(400, {"error": "request must be valid UTF-8 JSON"})
            return
        if self.path.endswith("/fixture/log"):
            with lock:
                log = list(requests)
            self.respond(200, {"requests": log})
            return
        with lock:
            requests.append({"method": self.command, "path": self.path, "payload": payload})
        if self.path.startswith("/slow/"):
            time.sleep(0.5)
        if self.path.startswith("/redirect/"):
            self.respond(302, {"error": "redirect"}, {"Location": f"http://127.0.0.1:{self.server.server_port}/redirect-target"})
            return
        if self.path == "/redirect-target":
            self.respond(200, {"error": "redirect was incorrectly followed"})
            return
        if self.path.startswith("/error/"):
            self.respond(503, {"error": "synthetic unavailable"})
            return
        if self.path.startswith("/invalid/"):
            self.respond(200, b'{"broken":')
            return
        if self.path.endswith("/models"):
            if self.path.startswith("/bad-models/"):
                self.respond(200, {"models": "invalid collection"})
            elif self.path.startswith("/empty-models/"):
                self.respond(200, {"data": []})
            else:
                self.respond(200, {"data": [{"id": "fixture-model"}, {"id": "試験モデル"}]})
        elif self.path.endswith("/embeddings"):
            texts = payload.get("input", [])
            items = []
            for index, text in enumerate(texts):
                vector = [1.0, 0.0, 0.0] if "鍵" in text else [0.0, 1.0, 0.0] if "海" in text else [0.0, 0.0, 1.0]
                if self.path.startswith("/bad-vector/"):
                    vector = ["not-numeric"]
                items.append({"index": index, "embedding": vector})
            self.respond(200, {"data": list(reversed(items))})
        elif self.path.endswith("/chat/completions"):
            if self.path.startswith("/missing-choice/"):
                self.respond(200, {"choices": []})
                return
            messages = payload.get("messages", [])
            content = "\n".join(message.get("content", "") for message in messages)
            citation = re.search(r"\[[^\]\n]+:[0-9]+\]", content)
            text = "原稿から確認できること\n花子は鍵を探しています。" + (" " + citation.group(0) if citation else "") + "\n推測\n不明です。\n不明\nその後の行動。"
            self.respond(200, {"choices": [{"message": {"role": "assistant", "content": text}}]})
        else:
            self.respond(404, {"error": "unknown fixture route"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(json.dumps({"port": server.server_port}), flush=True)
    server.serve_forever()

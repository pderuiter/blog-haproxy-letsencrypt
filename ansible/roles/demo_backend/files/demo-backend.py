#!/usr/bin/env python3
"""DEMO ONLY: a tiny backend that echoes the request headers it received.

Answers 200 on every path (including /health) and sends Server and
X-Powered-By headers, so you can see HAProxy add and remove headers.
"""
import http.server
import socketserver
import sys

BIND, PORT = sys.argv[1], int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self):
        lines = ["Request Headers:", "================"]
        lines += [f"{name}: {value}" for name, value in self.headers.items()]
        lines.append(f"served-by: demo-backend-{PORT}")
        body = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Server", "demo-backend")
        self.send_header("X-Powered-By", "python")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _reply

    def log_message(self, *args):
        pass


socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer((BIND, PORT), Handler).serve_forever()

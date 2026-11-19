# Chapter 13 reference: app.py after the rolling-update change (v2).
# If your own edit of app/app.py goes wrong, copy this file over it.
import http.server
import os
import socket

CODE_VERSION = "v2"
GREETING = os.environ.get("GREETING", "hello")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        body = f"{GREETING} from app-deployment-demo {CODE_VERSION}, served by {socket.gethostname()}\n"
        self.wfile.write(body.encode())


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()

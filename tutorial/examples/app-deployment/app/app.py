import http.server
import os

CODE_VERSION = "v1"
GREETING = os.environ.get("GREETING", "hello")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        body = f"{GREETING} from app-deployment-demo {CODE_VERSION}\n"
        self.wfile.write(body.encode())


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()

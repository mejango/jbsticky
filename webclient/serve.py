# ponytail: stdlib server with no-cache headers so edits show up on plain refresh
# Railway sets PORT; bind all interfaces there, localhost otherwise.
import http.server, os, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()
port = int(os.environ.get("PORT", sys.argv[1] if len(sys.argv) > 1 else 8788))
host = "0.0.0.0" if "PORT" in os.environ else "127.0.0.1"
http.server.ThreadingHTTPServer((host, port), Handler).serve_forever()

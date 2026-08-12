# ponytail: stdlib server with no-cache headers so edits show up on plain refresh
import http.server, functools, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

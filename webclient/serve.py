#!/usr/bin/env python3
"""Serve the public Sticky client with Waitress and WhiteNoise."""

import json
import os
from pathlib import Path
import re
import sys

from whitenoise import WhiteNoise

ROOT = Path(__file__).resolve().parent
PUBLIC_ASSETS = frozenset({
    "index.html", "config.js", "app.js", "runtime.js", "tx-engine.js", "tx-safe.js",
    "relayr.js", "launch-session.js", "bridge.js", "llms.txt",
    "Beatrice-Medium.woff2", "Beatrice-Regular.woff2", "PPAgrandir-WideBold.woff2",
    "artizen.jpg", "banny.png", "cone.png", "donut.png", "drip-corner.png", "drip-round.png",
    "drip-wide.png", "goo.png", "goo2.png", "hero-donut.png", "hero.png", "jar.png", "juicebox.png",
})
SECURITY_HEADERS = [
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
    ("Content-Security-Policy", "frame-ancestors 'none'; object-src 'none'; base-uri 'self'"),
]


def readiness(root):
    try:
        for name in ("config.js", "index.html"):
            candidate = root / name
            if candidate.is_symlink() or not candidate.is_file():
                raise ValueError("missing public build file")
        source = (root / "config.js").read_text(encoding="utf-8")
        assignment = re.search(r"window\.STICKY_CONFIG\s*=\s*(\{.*\})\s*;\s*\Z", source, re.S)
        config = json.loads(assignment[1]) if assignment else None
        if not isinstance(config, dict) or not isinstance(config.get("demoMode"), bool):
            raise ValueError("not generated configuration")
        if not config["demoMode"]:
            deployer = config.get("deployer", "")
            if not re.fullmatch(r"0x[0-9a-fA-F]{40}", deployer) or int(deployer, 16) == 0:
                raise ValueError("missing live deployer")
        document = (root / "index.html").read_text(encoding="utf-8")
        scripts = re.findall(r'<script\b[^>]*\bsrc=[\"\']([^\"\']+)', document)
        for script in scripts:
            name = script.split("?", 1)[0]
            candidate = root / name
            if name not in PUBLIC_ASSETS or candidate.is_symlink() or not candidate.is_file():
                raise ValueError("missing public script")
        return {"ok": True, "mode": "demo" if config["demoMode"] else "live"}
    except (OSError, ValueError, TypeError):
        return {"ok": False, "error": "Client build or generated deployment configuration is incomplete"}


class PublicFiles(WhiteNoise):
    def __init__(self, application, root):
        self.public_root = root
        super().__init__(application, root=root, max_age=86400, allow_all_origins=False,
                         add_headers_function=self.asset_headers)

    def add_file_to_dictionary(self, url, path, stat_cache=None):
        candidate = Path(path)
        if (url != "/" + candidate.name or candidate.name not in PUBLIC_ASSETS
                or candidate.is_symlink() or candidate.resolve().parent != self.public_root):
            return
        # WhiteNoise can discover adjacent compressed variants. Supply only this
        # allowlisted file's metadata so an unreviewed .gz/.br or symlink cannot
        # bypass the public-file boundary through Accept-Encoding.
        super().add_file_to_dictionary(url, path, stat_cache={str(candidate): candidate.stat()})

    @staticmethod
    def asset_headers(headers, path, url):
        if Path(path).suffix in (".html", ".js", ".txt"):
            headers["Cache-Control"] = "no-store" if url == "/config.js" else "no-cache"


def create_app(root=ROOT, revision=None):
    root = Path(root).resolve()
    state = readiness(root)
    if revision and re.fullmatch(r"[0-9a-fA-F]{7,40}", revision):
        state["revision"] = revision

    def respond(environ, start_response, status, body, content_type="text/plain; charset=utf-8", extra=()):
        headers = [("Content-Type", content_type), ("Content-Length", str(len(body))), ("Cache-Control", "no-store"), *extra]
        start_response(status, headers)
        return [] if environ.get("REQUEST_METHOD") == "HEAD" else [body]

    def not_found(environ, start_response):
        return respond(environ, start_response, "404 Not Found", b"Not found\n")

    assets = PublicFiles(not_found, root)

    def application(environ, start_response):
        def secure_response(status, headers, exc_info=None):
            return start_response(status, [*headers, *SECURITY_HEADERS], exc_info)

        if environ.get("REQUEST_METHOD") not in ("GET", "HEAD"):
            return respond(environ, secure_response, "405 Method Not Allowed", b"Method not allowed\n",
                           extra=[("Allow", "GET, HEAD")])
        path = environ.get("PATH_INFO", "")
        if path == "/healthz":
            body = (json.dumps(state, separators=(",", ":")) + "\n").encode()
            return respond(environ, secure_response, "200 OK" if state["ok"] else "503 Service Unavailable",
                           body, "application/json")
        if path == "/":
            environ = {**environ, "PATH_INFO": "/index.html"}
        return assets(environ, secure_response)

    application.ready = state["ok"]
    return application


def main():
    from waitress import serve

    app = create_app(revision=os.environ.get("RAILWAY_GIT_COMMIT_SHA"))
    if "PORT" in os.environ and not app.ready:
        raise SystemExit("Refusing to start: run build-config.py with valid deployment configuration or explicit STICKY_DEMO=true")
    port = int(os.environ.get("PORT", sys.argv[1] if len(sys.argv) > 1 else "8788"))
    host = "0.0.0.0" if "PORT" in os.environ else "127.0.0.1"
    serve(app, host=host, port=port, threads=4, connection_limit=100,
          channel_timeout=30, cleanup_interval=5, max_request_header_size=16384,
          max_request_body_size=1024, ident="Sticky")


if __name__ == "__main__":
    main()

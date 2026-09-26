#!/usr/bin/env python3
"""Serve the public Sticky client with Waitress and WhiteNoise."""

import json
import os
from pathlib import Path
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

from whitenoise import WhiteNoise

ROOT = Path(__file__).resolve().parent
PUBLIC_ASSETS = frozenset({
    "index.html", "config.js", "app.js", "runtime.js", "calldata.js", "tx-engine.js", "tx-safe.js",
    "relayr.js", "launch-session.js", "launch-plan.js", "center-intents.js", "bridge.js", "llms.txt",
    "wallet-chooser.js", "center-connect.js", "center-callback.js", "center-callback.html",
    "Beatrice-Medium.woff2", "Beatrice-Regular.woff2", "PPAgrandir-WideBold.woff2",
    "artizen.jpg", "banny.png", "cone.png", "donut.png", "drip-corner.png", "drip-round.png",
    "drip-wide.png", "goo.png", "goo2.png", "hero-donut.png", "hero.png", "jar.png", "juicebox.png",
})
CALLBACK_PATH = "/center/callback"
CALLBACK_FILE = "/center-callback.html"
WALLET_ORIGIN = re.compile(r"https://[a-z0-9.-]+|http://(?:localhost|127\.0\.0\.1|\[::1\])(?::[0-9]{1,5})?")


def security_headers(wallet_origin=None, callback=False):
    """Every page refuses framing and form posts, except for what the Signa sign-in needs.

    With Signa on, the page posts its launch form to Signa (form-action) and sends
    strict-origin so that post carries this site's origin; no-referrer would send Origin: null.
    Only the callback page may be framed, and only by this site: the sign-in frame lands on it.
    """
    if callback:
        return [
            ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "SAMEORIGIN"),
            ("Referrer-Policy", "strict-origin"),
            ("Content-Security-Policy", "script-src 'self'; frame-ancestors 'self'; object-src 'none'; base-uri 'self'; form-action 'none'"),
        ]
    form_action = wallet_origin or "'none'"
    return [
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "strict-origin" if wallet_origin else "no-referrer"),
        ("Content-Security-Policy", f"script-src 'self'; frame-ancestors 'none'; object-src 'none'; base-uri 'self'; form-action {form_action}"),
    ]


SECURITY_HEADERS = security_headers()


def read_config(root):
    source = (root / "config.js").read_text(encoding="utf-8")
    assignment = re.search(r"window\.STICKY_CONFIG\s*=\s*(\{.*\})\s*;\s*\Z", source, re.S)
    config = json.loads(assignment[1]) if assignment else None
    if not isinstance(config, dict) or not isinstance(config.get("demoMode"), bool):
        raise ValueError("not generated configuration")
    return config


def wallet_origin(root):
    """The configured Signa issuer, or None when sign-in is off or the config is unusable."""
    try:
        wallet = read_config(root).get("centerWallet")
    except (OSError, ValueError, TypeError):
        return None
    issuer = wallet.get("issuer") if isinstance(wallet, dict) else None
    return issuer if isinstance(issuer, str) and WALLET_ORIGIN.fullmatch(issuer) else None


def readiness(root):
    try:
        for name in ("config.js", "index.html"):
            candidate = root / name
            if candidate.is_symlink() or not candidate.is_file():
                raise ValueError("missing public build file")
        config = read_config(root)
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
        if config.get("centerWallet") is not None:
            if not wallet_origin(root):
                raise ValueError("invalid Signa issuer")
            for name in ("center-callback.html", "center-callback.js", "center-connect.js"):
                candidate = root / name
                if candidate.is_symlink() or not candidate.is_file():
                    raise ValueError("missing Signa callback file")
        return {"ok": True, "mode": "demo" if config["demoMode"] else "live"}
    except (OSError, ValueError, TypeError):
        return {"ok": False, "error": "Client build or generated deployment configuration is incomplete"}


BENDYSTRAW_PATH = re.compile(r"/bendystraw/(production|testnet)/graphql")
BENDYSTRAW_URL = re.compile(r"https://[a-z0-9.-]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~-]+)*/?")
BENDYSTRAW_MAX_BODY = 8192
BENDYSTRAW_MAX_RESPONSE = 8 * 1024 * 1024
BENDYSTRAW_TIMEOUT = 8
BENDYSTRAW_TTL = 15


def tls_context():
    """The default trust store, or the first system CA bundle when this Python ships without one."""
    context = ssl.create_default_context()
    if not context.cert_store_stats().get("x509_ca"):
        for bundle in ("/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem", "/etc/pki/tls/certs/ca-bundle.crt"):
            if os.path.isfile(bundle):
                context.load_verify_locations(bundle)
                break
    return context


def bendystraw_upstreams(root):
    """The configured Bendystraw GraphQL endpoints, by environment."""
    try:
        config = read_config(root)
    except (OSError, ValueError, TypeError):
        return {}
    upstreams = {}
    for environment, key in (("production", "bendystrawUrl"), ("testnet", "testnetBendystrawUrl")):
        url = config.get(key)
        if isinstance(url, str) and BENDYSTRAW_URL.fullmatch(url):
            url = url.rstrip("/")
            upstreams[environment] = url if url.endswith("/graphql") else url + "/graphql"
    return upstreams


class BendystrawRelay:
    """Relays the page's read-only GraphQL queries to Bendystraw, whose CORS list does not include this site.

    Only the two configured endpoints are reachable. Identical queries within a few seconds share one upstream
    answer, so many visitors cost Bendystraw one query. A failure is a 502 and the page falls back to chain reads.
    """

    def __init__(self, upstreams, fetch=None):
        self.upstreams = upstreams
        self.fetch = fetch or self.post
        self.tls = None if fetch else tls_context()
        self.cache = {}
        self.lock = threading.Lock()

    def post(self, url, body):
        request = urllib.request.Request(url, data=body, method="POST", headers={
            "Content-Type": "application/json", "Accept": "application/json", "User-Agent": "sticky.center"})
        with urllib.request.urlopen(request, timeout=BENDYSTRAW_TIMEOUT, context=self.tls) as response:
            payload = response.read(BENDYSTRAW_MAX_RESPONSE + 1)
            if len(payload) > BENDYSTRAW_MAX_RESPONSE:
                raise ValueError("response too large")
            return response.status, payload

    def __call__(self, environment, body):
        upstream = self.upstreams.get(environment)
        if not upstream:
            return 404, b'{"errors":[{"message":"Bendystraw is not configured."}]}'
        try:
            query = json.loads(body)
        except ValueError:
            query = None
        if not isinstance(query, dict) or not isinstance(query.get("query"), str) \
                or not isinstance(query.get("variables", {}), (dict, type(None))):
            return 400, b'{"errors":[{"message":"Expected a GraphQL query."}]}'
        key = (environment, body)
        now = time.monotonic()
        with self.lock:
            hit = self.cache.get(key)
            if hit and now - hit[0] < BENDYSTRAW_TTL:
                return 200, hit[1]
        try:
            status, payload = self.fetch(upstream, body)
            json.loads(payload)
        except urllib.error.HTTPError as error:
            return 502, json.dumps({"errors": [{"message": f"Bendystraw returned HTTP {error.code}."}]}).encode()
        except (OSError, ValueError):
            return 502, b'{"errors":[{"message":"Bendystraw is unavailable."}]}'
        if status != 200:
            return 502, json.dumps({"errors": [{"message": f"Bendystraw returned HTTP {status}."}]}).encode()
        with self.lock:
            if len(self.cache) >= 256:
                self.cache = {k: v for k, v in self.cache.items() if now - v[0] < BENDYSTRAW_TTL}
                if len(self.cache) >= 256:
                    self.cache.clear()
            self.cache[key] = (now, payload)
        return 200, payload


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
            headers["Cache-Control"] = "no-store" if url in ("/config.js", CALLBACK_FILE) else "no-cache"


def create_app(root=ROOT, revision=None, bendystraw_fetch=None):
    root = Path(root).resolve()
    state = readiness(root)
    issuer = wallet_origin(root) if state["ok"] else None
    page_headers = security_headers(issuer)
    callback_headers = security_headers(issuer, callback=True)
    if revision and re.fullmatch(r"[0-9a-fA-F]{7,40}", revision):
        state["revision"] = revision

    def respond(environ, start_response, status, body, content_type="text/plain; charset=utf-8", extra=()):
        headers = [("Content-Type", content_type), ("Content-Length", str(len(body))), ("Cache-Control", "no-store"), *extra]
        start_response(status, headers)
        return [] if environ.get("REQUEST_METHOD") == "HEAD" else [body]

    def not_found(environ, start_response):
        return respond(environ, start_response, "404 Not Found", b"Not found\n")

    assets = PublicFiles(not_found, root)
    relay = BendystrawRelay(bendystraw_upstreams(root) if state["ok"] else {}, bendystraw_fetch)

    def bendystraw(environ, start_response, environment):
        if environ.get("REQUEST_METHOD") != "POST":
            return respond(environ, start_response, "405 Method Not Allowed", b"Method not allowed\n", extra=[("Allow", "POST")])
        try:
            length = int(environ.get("CONTENT_LENGTH") or 0)
        except ValueError:
            length = -1
        if not 0 < length <= BENDYSTRAW_MAX_BODY:
            return respond(environ, start_response, "413 Content Too Large", b"Query too large\n")
        status, payload = relay(environment, environ["wsgi.input"].read(length))
        reason = {200: "OK", 400: "Bad Request", 404: "Not Found", 502: "Bad Gateway"}[status]
        return respond(environ, start_response, f"{status} {reason}", payload, "application/json")

    def application(environ, start_response):
        def secure_response(status, headers, exc_info=None):
            return start_response(status, [*headers, *page_headers], exc_info)

        def callback_response(status, headers, exc_info=None):
            return start_response(status, [*headers, *callback_headers], exc_info)

        relayed = BENDYSTRAW_PATH.fullmatch(environ.get("PATH_INFO", ""))
        if relayed:
            return bendystraw(environ, secure_response, relayed[1])
        if environ.get("REQUEST_METHOD") not in ("GET", "HEAD"):
            return respond(environ, secure_response, "405 Method Not Allowed", b"Method not allowed\n",
                           extra=[("Allow", "GET, HEAD")])
        path = environ.get("PATH_INFO", "")
        if path == "/healthz":
            body = (json.dumps(state, separators=(",", ":")) + "\n").encode()
            return respond(environ, secure_response, "200 OK" if state["ok"] else "503 Service Unavailable",
                           body, "application/json")
        if path == CALLBACK_PATH and issuer:
            return assets({**environ, "PATH_INFO": CALLBACK_FILE}, callback_response)
        if path in (CALLBACK_PATH, CALLBACK_FILE):
            return not_found(environ, secure_response)
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
    # Bendystraw queries are the only request bodies; each relay can hold a thread for its upstream timeout.
    serve(app, host=host, port=port, threads=8, connection_limit=100,
          channel_timeout=30, cleanup_interval=5, max_request_header_size=16384,
          max_request_body_size=BENDYSTRAW_MAX_BODY, ident="Sticky")


if __name__ == "__main__":
    main()

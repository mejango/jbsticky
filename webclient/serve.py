#!/usr/bin/env python3
"""Serve the public Sticky client with Waitress and WhiteNoise."""

import hashlib
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
        bendystraw_operations(root)
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


BENDYSTRAW_PATH = re.compile(r"/api/bendystraw/(mainnet|testnet)/query")
BENDYSTRAW_URL = re.compile(r"https://[a-z0-9.-]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~-]+)*/?")
BENDYSTRAW_OPERATIONS = "bendystraw-operations.json"
BENDYSTRAW_MAX_BODY = 8192
BENDYSTRAW_MAX_RESPONSE = 8 * 1024 * 1024
BENDYSTRAW_TIMEOUT = 8
BENDYSTRAW_TTL = 15
OPERATION_ID = re.compile(r"[a-f0-9]{64}")
DECLARATIONS = re.compile(r"\s*query\s+\w+\s*(?:\(([^)]*)\))?\s*\{")
DECLARATION = re.compile(r"\$(\w+)\s*:\s*((?:\[\s*\w+\s*!?\s*\]|\w+)\s*!?)\s*(?:,|$)")
FIELD = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}")
MAX_STRING = 1024
MAX_LIST = 100
MAX_FIELDS = 32
MAX_DEPTH = 3


def bendystraw_operations(root):
    """The checked-in operations serve.py relays: {operation id: (document, {variable: GraphQL type})}.

    Raises OSError when the file is missing, and ValueError when it is empty, an id is not its document's
    SHA-256, or a document is not a named query with parseable variables.
    """
    registry = json.loads((root / BENDYSTRAW_OPERATIONS).read_text(encoding="utf-8"))
    if not isinstance(registry, dict) or not registry:
        raise ValueError("empty Bendystraw operation registry")
    operations = {}
    for operation, document in registry.items():
        if not isinstance(document, str) or hashlib.sha256(document.encode()).hexdigest() != operation:
            raise ValueError("Bendystraw operation id does not match its document")
        header = DECLARATIONS.match(document)
        if not header:
            raise ValueError("Bendystraw operation is not a named query")
        declared = {}
        for part in filter(None, (part.strip() for part in (header[1] or "").split(","))):
            variable = DECLARATION.fullmatch(part)
            if not variable:
                raise ValueError("unparseable Bendystraw variable")
            declared[variable[1]] = re.sub(r"\s+", "", variable[2])
        operations[operation] = (document, declared)
    return operations


def plain(value):
    return value is None or isinstance(value, (bool, int, float)) or (isinstance(value, str) and len(value) <= MAX_STRING)


def input_object(value, depth=0):
    """A filter argument: a small object of scalars, lists of scalars and nested objects."""
    if not isinstance(value, dict) or len(value) > MAX_FIELDS or depth > MAX_DEPTH:
        return False
    for field, item in value.items():
        if not FIELD.fullmatch(field):
            return False
        if isinstance(item, list):
            if len(item) > MAX_LIST or not all(plain(entry) for entry in item):
                return False
        elif isinstance(item, dict):
            if not input_object(item, depth + 1):
                return False
        elif not plain(item):
            return False
    return True


def variable_fits(value, kind):
    if kind.endswith("!"):
        return value is not None and variable_fits(value, kind[:-1])
    if value is None:
        return True
    if kind.startswith("["):
        return isinstance(value, list) and len(value) <= MAX_LIST and all(variable_fits(item, kind[1:-1]) for item in value)
    if kind in ("String", "ID"):
        return isinstance(value, str) and len(value) <= MAX_STRING
    if kind == "Int":
        return isinstance(value, int) and not isinstance(value, bool) and -2**31 <= value < 2**31
    if kind == "Float":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind == "Boolean":
        return isinstance(value, bool)
    return input_object(value)


def variables_fit(variables, declared):
    return (isinstance(variables, dict) and set(variables) <= set(declared)
            and all(variable_fits(variables.get(name), kind) for name, kind in declared.items()))


def reject_constant(name):
    raise ValueError(f"{name} is not JSON")


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
    """The configured Bendystraw GraphQL endpoints, by network."""
    try:
        config = read_config(root)
    except (OSError, ValueError, TypeError):
        return {}
    upstreams = {}
    for network, key in (("mainnet", "bendystrawUrl"), ("testnet", "testnetBendystrawUrl")):
        url = config.get(key)
        if isinstance(url, str) and BENDYSTRAW_URL.fullmatch(url):
            url = url.rstrip("/")
            upstreams[network] = url if url.endswith("/graphql") else url + "/graphql"
    return upstreams


def error_body(message):
    return json.dumps({"error": message}).encode()


class BendystrawRelay:
    """Relays the page's persisted Bendystraw queries, the same way juicebox.money and revnet.money do.

    The page posts {"operation": <SHA-256 of a document>, "variables": {...}}; only documents in
    bendystraw-operations.json are forwarded, with variables that fit their declared types, so this is not an
    open GraphQL proxy. Bendystraw's CORS list does not include this site, and local serving goes through this
    same relay. Identical requests within a few seconds share one upstream answer. Success is {"data": ...};
    any failure is {"error": ...} and the page falls back to chain reads.
    """

    def __init__(self, upstreams, operations, fetch=None):
        self.upstreams = upstreams
        self.operations = operations
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

    def __call__(self, network, body):
        upstream = self.upstreams.get(network)
        if not upstream:
            return 404, error_body("Bendystraw is not configured.")
        try:
            request = json.loads(body, parse_constant=reject_constant)
        except (ValueError, UnicodeDecodeError):
            request = None
        operation = request.get("operation") if isinstance(request, dict) else None
        known = self.operations.get(operation) if isinstance(operation, str) and OPERATION_ID.fullmatch(operation) else None
        if not known or set(request) != {"operation", "variables"} or not variables_fit(request["variables"], known[1]):
            return 400, error_body("unknown or invalid operation")
        variables = request["variables"]
        key = (network, operation, json.dumps(variables, sort_keys=True, separators=(",", ":")))
        now = time.monotonic()
        with self.lock:
            hit = self.cache.get(key)
            if hit and now - hit[0] < BENDYSTRAW_TTL:
                return 200, hit[1]
        try:
            status, payload = self.fetch(upstream, json.dumps({"query": known[0], "variables": variables}).encode())
            answer = json.loads(payload) if status == 200 else None
        except urllib.error.HTTPError as error:
            return 502, error_body(f"Bendystraw returned HTTP {error.code}.")
        except (OSError, ValueError):
            return 502, error_body("Bendystraw is unavailable.")
        if status != 200:
            return 502, error_body(f"Bendystraw returned HTTP {status}.")
        errors = answer.get("errors") if isinstance(answer, dict) else None
        if isinstance(errors, list) and errors:
            message = errors[0].get("message") if isinstance(errors[0], dict) else None
            return 502, error_body(f"Bendystraw: {str(message or 'query failed')[:300]}")
        if not isinstance(answer, dict) or not isinstance(answer.get("data"), dict):
            return 502, error_body("Bendystraw returned no data.")
        payload = json.dumps({"data": answer["data"]}, separators=(",", ":")).encode()
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
    relay = BendystrawRelay(bendystraw_upstreams(root) if state["ok"] else {},
                            bendystraw_operations(root) if state["ok"] else {}, bendystraw_fetch)

    def bendystraw(environ, start_response, network):
        if environ.get("REQUEST_METHOD") != "POST":
            return respond(environ, start_response, "405 Method Not Allowed", b"Method not allowed\n", extra=[("Allow", "POST")])
        if not environ.get("CONTENT_TYPE", "").lower().startswith("application/json"):
            return respond(environ, start_response, "415 Unsupported Media Type", error_body("content type must be application/json"),
                           "application/json")
        try:
            length = int(environ.get("CONTENT_LENGTH") or 0)
        except ValueError:
            length = -1
        if not 0 < length <= BENDYSTRAW_MAX_BODY:
            return respond(environ, start_response, "413 Content Too Large", error_body("request is too large"), "application/json")
        status, payload = relay(network, environ["wsgi.input"].read(length))
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
    # Bendystraw operations are the only request bodies; each relay can hold a thread for its upstream timeout.
    serve(app, host=host, port=port, threads=8, connection_limit=100,
          channel_timeout=30, cleanup_interval=5, max_request_header_size=16384,
          max_request_body_size=BENDYSTRAW_MAX_BODY, ident="Sticky")


if __name__ == "__main__":
    main()

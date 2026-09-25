"""Public config and production HTTP regression tests; no network or wallet required."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from wsgiref.util import setup_testing_defaults

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


build = module("sticky_build", ROOT / "build-config.py")
server = module("sticky_server", ROOT / "serve.py")
DEPLOYER = "0x" + "12" * 20
OTHER = "0x" + "34" * 20
# The 8-chain deployment shape. Addresses change on redeploy; these tests check shape only.
FROM_BLOCKS = {1: "26057164", 10: "157386536", 8453: "51791252", 42161: "508887149",
               11155111: "11781859", 11155420: "49284433", 84532: "47301559", 421614: "312706619"}
LIVE_ENV = {
    "STICKY_DEPLOYER": "0xdA38Ec48B5b1d186B02BA99F297e95153BEE33a9",
    "STICKY_DISTRIBUTOR": "0xc62b3fED668Cd8a3879ba34890a67C48a52b1Bb8",
    "STICKY_REWARD_RECEIVER_FACTORY": "0xF65743b76C062762D19eecb4Ab5C7a943e128720",
    "STICKY_AUTOSTICK_ADAPTER": "0x9B091e21d25c424De67751F4b6Ae8494351218C5",
    **{f"STICKY_FROM_BLOCK_{chain_id}": block for chain_id, block in FROM_BLOCKS.items()},
}
SIGNA_ENV = {
    "STICKY_CENTER_WALLET_ENABLED": "true",
    "STICKY_CENTER_WALLET_MANIFEST_ID": "base-wallet:v1",
    "STICKY_CENTER_WALLET_MANIFEST_REVISION": "0x" + "ab" * 32,
    "STICKY_CENTER_WALLET_MAXIMUM_NETWORK_FEE_WEI": "2000000000000000",
}


class ConfigTests(unittest.TestCase):
    def test_missing_live_configuration_fails_instead_of_showing_demo(self):
        for env in ({}, {"STICKY_DEMO": "false"}, {"STICKY_DEPLOYER_8453": DEPLOYER}):
            with self.subTest(env=env), self.assertRaisesRegex(ValueError, "Live mode requires"):
                build.build_config(env)

    def test_demo_is_explicit(self):
        config = build.build_config({"STICKY_DEMO": "true"})
        self.assertIs(config["demoMode"], True)
        self.assertEqual(config["defaultChainId"], 1)
        self.assertEqual(len(config["chains"]), 8)
        self.assertTrue(all(value["rpcUrl"].startswith("https://") for value in config["chains"].values()))

    def test_selected_per_chain_configuration_becomes_boot_configuration(self):
        config = build.build_config({
            "STICKY_DEFAULT_CHAIN": "8453", "STICKY_DEPLOYER_8453": DEPLOYER,
            "STICKY_DISTRIBUTOR_8453": OTHER, "STICKY_REWARD_RECEIVER_FACTORY_8453": OTHER,
            "STICKY_AUTOSTICK_ADAPTER_8453": OTHER, "STICKY_FROM_BLOCK_8453": "25100000",
        })
        self.assertEqual(config["deployer"], DEPLOYER)
        self.assertEqual(config["defaultChainId"], 8453)
        self.assertEqual(config["fromBlock"], "25100000")
        self.assertIs(config["demoMode"], False)
        for field in ("rpcUrl", "distributor", "rewardReceiverFactory", "autoStickAdapter"):
            self.assertEqual(config[field], config["chains"]["8453"][field])
        self.assertNotIn("deployer", config["chains"]["1"])

    def test_live_configuration_covers_all_eight_chains_without_fixtures(self):
        config = build.build_config(LIVE_ENV)
        self.assertIs(config["demoMode"], False)
        self.assertEqual(set(config["chains"]), {str(chain_id) for chain_id in FROM_BLOCKS})
        for chain_id, block in FROM_BLOCKS.items():
            entry = config["chains"][str(chain_id)]
            with self.subTest(chain=chain_id):
                self.assertEqual(entry["fromBlock"], block)
                for field, variable in (("deployer", "STICKY_DEPLOYER"), ("distributor", "STICKY_DISTRIBUTOR"),
                                        ("rewardReceiverFactory", "STICKY_REWARD_RECEIVER_FACTORY"),
                                        ("autoStickAdapter", "STICKY_AUTOSTICK_ADAPTER")):
                    self.assertEqual(entry[field], LIVE_ENV[variable])
        self.assertFalse([key for key in config if key != "demoMode" and (key.startswith("demo") or key.endswith("Overrides"))])

    def test_app_fallback_rpcs_match_build_config(self):
        source = (ROOT / "app.js").read_text(encoding="utf-8")
        origins = source[source.index("const ORIGINS = ["):source.index("const chainById")]
        found = {int(chain_id.replace("_", "")): url
                 for chain_id, url in re.findall(r'chainId: ([0-9_]+),.*?rpcUrl: "([^"]+)"', origins)}
        self.assertEqual(found, build.PUBLIC_RPC)

    def test_rpc_override_takes_precedence_over_dwellir(self):
        config = build.build_config({"STICKY_DEPLOYER": DEPLOYER, "NEXT_PUBLIC_DWELLIR_API_KEY": "public-key",
                                     "STICKY_RPC_8453": "https://base.example/rpc"})
        self.assertEqual(config["chains"]["8453"]["rpcUrl"], "https://base.example/rpc")
        self.assertIn("dwellir.com/public-key", config["rpcUrl"])

    def test_contract_override_takes_precedence_over_global(self):
        config = build.build_config({"STICKY_DEPLOYER": DEPLOYER, "STICKY_DEPLOYER_1": OTHER})
        self.assertEqual(config["deployer"], OTHER)
        self.assertEqual(config["chains"]["10"]["deployer"], DEPLOYER)

    def test_rejects_invalid_configuration_without_echoing_values(self):
        cases = {
            "STICKY_DEFAULT_CHAIN": "999", "STICKY_DEPLOYER_10": "0x" + "0" * 40,
            "STICKY_REWARD_RECEIVER_FACTORY": "secret-not-an-address", "STICKY_DEMO": "treu",
            "STICKY_PROJECT_ID": "9007199254740992", "STICKY_FROM_BLOCK": "latest",
            "STICKY_RELAYR_URL": "javascript:private-value", "STICKY_RPC_1": "https://user:private-value@example.com",
        }
        for key, value in cases.items():
            with self.subTest(key=key), self.assertRaises(ValueError) as error:
                build.build_config({"STICKY_DEPLOYER": DEPLOYER, key: value})
            self.assertNotIn("private-value", str(error.exception))

    def test_local_rpc_allowed_but_remote_http_rejected(self):
        config = build.build_config({"STICKY_DEPLOYER": DEPLOYER, "STICKY_RPC_1": "http://127.0.0.1:8545"})
        self.assertEqual(config["rpcUrl"], "http://127.0.0.1:8545")
        for url in ("http://example.com", "https://example.com/#secret", "https://example.com:bad"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                build.build_config({"STICKY_DEPLOYER": DEPLOYER, "STICKY_RPC_1": url})

    def test_emitter_runs_from_any_directory_and_writes_json(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "config.js"
            result = subprocess.run([sys.executable, str(ROOT / "build-config.py"), "--output", str(target)],
                                    cwd=directory, env={"STICKY_DEMO": "true"}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = target.read_text().split("window.STICKY_CONFIG = ", 1)[1].rstrip(";\n")
            self.assertIs(json.loads(payload)["demoMode"], True)
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            self.assertEqual(list(Path(directory).iterdir()), [target])

    def test_failed_build_preserves_existing_config(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "config.js"
            target.write_text("existing")
            result = subprocess.run([sys.executable, str(ROOT / "build-config.py"), "--output", str(target)],
                                    env={}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), "existing")

class CenterListingConfigTests(unittest.TestCase):
    def test_defaults_to_juicebox_center(self):
        self.assertEqual(build.build_config({"STICKY_DEPLOYER": DEPLOYER})["centerUrl"], "https://juicebox.center")

    def test_accepts_another_https_origin(self):
        config = build.build_config({"STICKY_DEPLOYER": DEPLOYER, "STICKY_CENTER_URL": "https://dev.juicebox.center"})
        self.assertEqual(config["centerUrl"], "https://dev.juicebox.center")

    def test_rejects_anything_but_an_https_origin(self):
        for value in ("http://juicebox.center", "http://localhost:3000", "https://juicebox.center/",
                      "https://juicebox.center/v1", "https://user@juicebox.center", "juicebox.center", "https://Juicebox.center"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "STICKY_CENTER_URL must be an HTTPS origin"):
                build.build_config({"STICKY_DEPLOYER": DEPLOYER, "STICKY_CENTER_URL": value})


class SignaConfigTests(unittest.TestCase):
    def config(self, **overrides):
        return build.build_config({"STICKY_DEPLOYER": DEPLOYER, **SIGNA_ENV, **overrides})

    def test_off_unless_enabled(self):
        for env in ({}, {"STICKY_CENTER_WALLET_ENABLED": "false"},
                    {"STICKY_CENTER_WALLET_ENABLED": "false", "STICKY_CENTER_WALLET_ISSUER": "https://evil.example"}):
            with self.subTest(env=env):
                self.assertIsNone(build.build_config({"STICKY_DEPLOYER": DEPLOYER, **env})["centerWallet"])

    def test_enabled_defaults_to_the_signa_pins(self):
        self.assertEqual(self.config()["centerWallet"], {
            "issuer": "https://signa.center", "audience": "https://api.signa.center",
            "manifest": {"id": "base-wallet:v1", "revision": "0x" + "ab" * 32},
            "maximumNetworkFee": "2000000000000000",
        })

    def test_local_signa_is_allowed_over_http_loopback_only(self):
        wallet = self.config(STICKY_CENTER_WALLET_ISSUER="http://localhost:3000",
                             STICKY_CENTER_WALLET_AUDIENCE="http://127.0.0.1:3001")["centerWallet"]
        self.assertEqual((wallet["issuer"], wallet["audience"]), ("http://localhost:3000", "http://127.0.0.1:3001"))

    def test_rejects_anything_but_the_pinned_https_signa(self):
        cases = [
            {"STICKY_CENTER_WALLET_ENABLED": "yes"},
            {"STICKY_CENTER_WALLET_ISSUER": "https://evil.example"},
            {"STICKY_CENTER_WALLET_AUDIENCE": "https://evil.example"},
            {"STICKY_CENTER_WALLET_AUDIENCE": "http://localhost:3001"},
            {"STICKY_CENTER_WALLET_ISSUER": "https://signa.center/"},
            {"STICKY_CENTER_WALLET_ISSUER": "https://signa.center:443"},
            {"STICKY_CENTER_WALLET_ISSUER": "http://signa.center"},
            {"STICKY_CENTER_WALLET_ISSUER": "https://user@signa.center"},
            {"STICKY_CENTER_WALLET_ISSUER": "http://localhost:3000", "STICKY_CENTER_WALLET_AUDIENCE": "http://localhost:3000"},
            {"STICKY_CENTER_WALLET_ISSUER": "http://localhost:3000", "STICKY_CENTER_WALLET_AUDIENCE": "http://example.com"},
            {"STICKY_CENTER_WALLET_MANIFEST_ID": ""},
            {"STICKY_CENTER_WALLET_MANIFEST_ID": "has space"},
            {"STICKY_CENTER_WALLET_MANIFEST_ID": "x" * 129},
            {"STICKY_CENTER_WALLET_MANIFEST_REVISION": "0x" + "0" * 64},
            {"STICKY_CENTER_WALLET_MANIFEST_REVISION": "0x" + "AB" * 32},
            {"STICKY_CENTER_WALLET_MANIFEST_REVISION": "0x" + "ab" * 31},
            {"STICKY_CENTER_WALLET_MAXIMUM_NETWORK_FEE_WEI": ""},
            {"STICKY_CENTER_WALLET_MAXIMUM_NETWORK_FEE_WEI": "0"},
            {"STICKY_CENTER_WALLET_MAXIMUM_NETWORK_FEE_WEI": "01"},
            {"STICKY_CENTER_WALLET_MAXIMUM_NETWORK_FEE_WEI": str(2**256)},
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError) as error:
                self.config(**case)
            self.assertNotIn("evil.example", str(error.exception))


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.document = '<html><script src="config.js?v=1"></script><script src="app.js?v=2"></script></html>'
        (self.root / "index.html").write_text(self.document)
        (self.root / "app.js").write_text("window.app = true;")
        (self.root / "hero.png").write_bytes(b"PNG-asset")
        build.write_config(build.build_config({"STICKY_DEPLOYER": DEPLOYER}), self.root / "config.js")
        self.app = server.create_app(self.root, revision="abcdef1")

    def request(self, path="/", method="GET", headers=None, app=None):
        environ = {}
        setup_testing_defaults(environ)
        environ.update(PATH_INFO=path, REQUEST_METHOD=method, **(headers or {}))
        result = {}
        def start_response(status, response_headers, exc_info=None):
            result.update(status=int(status.split()[0]), headers=dict(response_headers))
        response = (app or self.app)(environ, start_response)
        try:
            result["body"] = b"".join(response)
        finally:
            if hasattr(response, "close"):
                response.close()
        return result

    def test_root_and_head_have_correct_types_and_security_headers(self):
        get = self.request()
        head = self.request(method="HEAD")
        self.assertEqual(get["status"], 200)
        self.assertEqual(get["body"].decode(), self.document)
        self.assertEqual(head["body"], b"")
        self.assertEqual(get["headers"], head["headers"])
        self.assertEqual(get["headers"]["X-Frame-Options"], "DENY")
        self.assertEqual(get["headers"]["X-Content-Type-Options"], "nosniff")
        self.assertIn("script-src 'self'", get["headers"]["Content-Security-Policy"])
        self.assertEqual(get["headers"]["Cache-Control"], "no-cache")
        self.assertIn("text/html", get["headers"]["Content-Type"])

    def test_config_not_stored_and_scripts_revalidate(self):
        self.assertEqual(self.request("/config.js")["headers"]["Cache-Control"], "no-store")
        self.assertEqual(self.request("/app.js")["headers"]["Cache-Control"], "no-cache")
        self.assertIn("javascript", self.request("/app.js")["headers"]["Content-Type"])
        image = self.request("/hero.png")
        self.assertEqual(image["headers"]["Cache-Control"], "max-age=86400, public")
        self.assertEqual(image["headers"]["Content-Type"], "image/png")

    def test_conditional_requests_and_ranges(self):
        first = self.request("/app.js")
        cached = self.request("/app.js", headers={"HTTP_IF_NONE_MATCH": first["headers"]["ETag"]})
        self.assertEqual(cached["status"], 304)
        self.assertEqual(cached["body"], b"")
        partial = self.request("/hero.png", headers={"HTTP_RANGE": "bytes=0-2"})
        self.assertEqual(partial["status"], 206)
        self.assertEqual(partial["body"], b"PNG")

    def test_denies_private_files_directories_and_traversal(self):
        for file in (".env", "serve.py", "config.example.js", "README.md", "private.js"):
            (self.root / file).write_text("secret")
        app = server.create_app(self.root)
        for path in ("/.env", "/serve.py", "/config.example.js", "/README.md", "/private.js", "/test/",
                     "/../config.js", "/%2e%2e/config.js", "/%2Fconfig.js", "/./config.js", "/app.js/", "/missing"):
            with self.subTest(path=path):
                result = self.request(path, app=app)
                self.assertEqual(result["status"], 404)
                self.assertNotIn(b"secret", result["body"])

    def test_symlink_with_public_name_is_never_served(self):
        (self.root / "hero.png").unlink()
        with tempfile.TemporaryDirectory() as outside:
            private = Path(outside) / "private.txt"
            private.write_text("secret")
            (self.root / "hero.png").symlink_to(private)
            self.assertEqual(self.request("/hero.png", app=server.create_app(self.root))["status"], 404)

    def test_unreviewed_compressed_variant_cannot_bypass_asset_allowlist(self):
        (self.root / "app.js.gz").write_bytes(b"not-the-reviewed-app")
        result = self.request("/app.js", headers={"HTTP_ACCEPT_ENCODING": "gzip"}, app=server.create_app(self.root))
        self.assertEqual(result["body"], b"window.app = true;")
        self.assertNotIn("Content-Encoding", result["headers"])

    def test_health_is_readiness_with_safe_revision_and_no_configuration(self):
        result = self.request("/healthz")
        self.assertEqual(result["status"], 200)
        self.assertEqual(json.loads(result["body"]), {"ok": True, "mode": "live", "revision": "abcdef1"})
        self.assertEqual(result["headers"]["Cache-Control"], "no-store")
        self.assertEqual(self.request("/healthz", method="HEAD")["body"], b"")
        self.assertNotIn(DEPLOYER.encode(), result["body"])

    def test_incomplete_or_invalid_config_is_not_ready(self):
        for contents in ("", "window.STICKY_CONFIG = {};", 'window.STICKY_CONFIG = {"demoMode":false};'):
            with self.subTest(contents=contents):
                (self.root / "config.js").write_text(contents)
                app = server.create_app(self.root)
                self.assertFalse(app.ready)
                self.assertEqual(self.request("/healthz", app=app)["status"], 503)

    def test_missing_referenced_script_is_not_ready(self):
        (self.root / "app.js").unlink()
        self.assertFalse(server.create_app(self.root).ready)

    def test_symlinked_config_cannot_report_healthy_when_not_served(self):
        with tempfile.TemporaryDirectory() as outside:
            config = self.root / "config.js"
            target = Path(outside) / "config.js"
            target.write_bytes(config.read_bytes())
            config.unlink()
            config.symlink_to(target)
            app = server.create_app(self.root)
            self.assertFalse(app.ready)
            self.assertEqual(self.request("/config.js", app=app)["status"], 404)

    def test_explicit_demo_reports_demo(self):
        build.write_config(build.build_config({"STICKY_DEMO": "true"}), self.root / "config.js")
        result = self.request("/healthz", app=server.create_app(self.root))
        self.assertEqual(json.loads(result["body"]), {"ok": True, "mode": "demo"})

    def test_unsupported_methods_are_rejected_even_for_health(self):
        for path in ("/", "/healthz", "/config.js"):
            result = self.request(path, method="POST")
            self.assertEqual(result["status"], 405)
            self.assertEqual(result["headers"]["Allow"], "GET, HEAD")

    def test_root_does_not_follow_working_directory(self):
        previous = Path.cwd()
        try:
            os.chdir("/")
            app = server.create_app(self.root)
            self.assertEqual(self.request(app=app)["body"].decode(), self.document)
        finally:
            os.chdir(previous)

    def signa_app(self):
        build.write_config(build.build_config({"STICKY_DEPLOYER": DEPLOYER, **SIGNA_ENV}), self.root / "config.js")
        (self.root / "center-callback.html").write_text("<main>callback</main>")
        (self.root / "center-callback.js").write_text("// callback")
        (self.root / "center-connect.js").write_text("// sdk")
        return server.create_app(self.root)

    def test_page_policy_lets_the_page_reach_juicebox_center(self):
        # Center listings, RPCs and Relayr are fetched from the page; only scripts are pinned to 'self'.
        for app in (None, self.signa_app()):
            policy = self.request(app=app)["headers"]["Content-Security-Policy"]
            with self.subTest(policy=policy):
                self.assertNotIn("connect-src", policy)
                self.assertNotIn("default-src", policy)

    def test_without_signa_pages_refuse_framing_forms_and_referrers(self):
        headers = self.request()["headers"]
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        self.assertIn("form-action 'none'", headers["Content-Security-Policy"])
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        (self.root / "center-callback.html").write_text("<main>callback</main>")
        app = server.create_app(self.root)
        for path in ("/center/callback", "/center-callback.html"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path, app=app)["status"], 404)

    def test_signa_pages_post_only_to_signa_and_send_their_origin(self):
        app = self.signa_app()
        self.assertTrue(app.ready)
        for path in ("/", "/app.js", "/healthz", "/missing"):
            with self.subTest(path=path):
                headers = self.request(path, app=app)["headers"]
                self.assertEqual(headers["Referrer-Policy"], "strict-origin")
                self.assertEqual(headers["X-Frame-Options"], "DENY")
                self.assertEqual(headers["Content-Security-Policy"],
                                 "script-src 'self'; frame-ancestors 'none'; object-src 'none'; base-uri 'self'; "
                                 "form-action https://signa.center")

    def test_callback_is_frameable_by_this_site_only_and_never_stored(self):
        app = self.signa_app()
        for method in ("GET", "HEAD"):
            result = self.request("/center/callback", method=method, app=app,
                                  headers={"QUERY_STRING": "code=secret&state=s&iss=https%3A%2F%2Fsigna.center"})
            with self.subTest(method=method):
                self.assertEqual(result["status"], 200)
                self.assertIn("text/html", result["headers"]["Content-Type"])
                self.assertEqual(result["headers"]["Cache-Control"], "no-store")
                self.assertEqual(result["headers"]["Referrer-Policy"], "strict-origin")
                self.assertEqual(result["headers"]["X-Frame-Options"], "SAMEORIGIN")
                csp = result["headers"]["Content-Security-Policy"]
                self.assertIn("frame-ancestors 'self'", csp)
                self.assertIn("form-action 'none'", csp)
                self.assertIn("script-src 'self'", csp)
        self.assertEqual(self.request("/center/callback", app=app)["body"], b"<main>callback</main>")
        for path in ("/center-callback.html", "/center/callback/", "/center/"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path, app=app)["status"], 404)

    def test_signa_build_is_not_ready_without_its_callback_files(self):
        self.signa_app()
        for name in ("center-callback.html", "center-callback.js", "center-connect.js"):
            with self.subTest(name=name):
                moved = self.root / name
                content = moved.read_bytes()
                moved.unlink()
                self.assertFalse(server.create_app(self.root).ready)
                moved.write_bytes(content)

    def test_unusable_issuer_in_config_is_not_ready_and_never_reaches_a_header(self):
        (self.root / "config.js").write_text('window.STICKY_CONFIG = ' + json.dumps({
            "demoMode": False, "deployer": DEPLOYER, "centerWallet": {"issuer": "https://signa.center; script-src *"}}) + ';\n')
        app = server.create_app(self.root)
        self.assertFalse(app.ready)
        self.assertIn("form-action 'none'", self.request(app=app)["headers"]["Content-Security-Policy"])

    def test_production_startup_refuses_invalid_configuration(self):
        (self.root / "config.js").unlink()
        app = server.create_app(self.root)
        with patch.dict(os.environ, {"PORT": "8080"}), patch.object(server, "create_app", return_value=app):
            with self.assertRaisesRegex(SystemExit, "Refusing to start"):
                server.main()


if __name__ == "__main__":
    unittest.main()

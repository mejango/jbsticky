"""Public config and production HTTP regression tests; no network or wallet required."""

import importlib.util
import json
import os
from pathlib import Path
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
            "STICKY_DISTRIBUTOR_8453": OTHER, "STICKY_POCKETS_8453": OTHER,
            "STICKY_AUTOSTICK_ADAPTER_8453": OTHER, "STICKY_FROM_BLOCK_8453": "25100000",
        })
        self.assertEqual(config["deployer"], DEPLOYER)
        self.assertEqual(config["defaultChainId"], 8453)
        self.assertEqual(config["fromBlock"], "25100000")
        self.assertIs(config["demoMode"], False)
        for field in ("rpcUrl", "distributor", "pockets", "autoStickAdapter"):
            self.assertEqual(config[field], config["chains"]["8453"][field])
        self.assertNotIn("deployer", config["chains"]["1"])

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
            "STICKY_POCKETS": "secret-not-an-address", "STICKY_DEMO": "treu",
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

    def test_production_startup_refuses_invalid_configuration(self):
        (self.root / "config.js").unlink()
        app = server.create_app(self.root)
        with patch.dict(os.environ, {"PORT": "8080"}), patch.object(server, "create_app", return_value=app):
            with self.assertRaisesRegex(SystemExit, "Refusing to start"):
                server.main()


if __name__ == "__main__":
    unittest.main()

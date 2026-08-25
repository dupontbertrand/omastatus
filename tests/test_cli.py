#!/usr/bin/env python3

import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/omastatus"


class QuietHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


class OmastatusCliTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.root = root
        self.env = os.environ.copy()
        self.env["OMASTATUS_CONFIG_DIR"] = str(root / "config")
        self.env["OMASTATUS_STATE_DIR"] = str(root / "state")

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *arguments, expected=0):
        completed = subprocess.run(
            [str(CLI), *arguments],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            completed.returncode,
            expected,
            msg=f"stdout={completed.stdout}\nstderr={completed.stderr}",
        )
        return completed

    def json_cli(self, *arguments):
        return json.loads(self.run_cli(*arguments).stdout)

    def fake_command(self, name, python_body):
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        path = directory / name
        path.write_text(f"#!/usr/bin/env python3\n{python_body}\n", encoding="utf-8")
        path.chmod(0o755)
        self.env["PATH"] = f"{directory}:{self.env['PATH']}"

    def test_init_creates_private_default_configuration(self):
        config = self.json_cli("init")
        path = Path(self.env["OMASTATUS_CONFIG_DIR"]) / "config.json"
        self.assertEqual(config["settings"]["viewMode"], "grouped")
        self.assertEqual(config["services"], [])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_auto_detection_and_unique_ids(self):
        web = self.json_cli("add", "--name", "API", "--target", "https://example.com")
        tcp = self.json_cli("add", "--name", "API", "--target", "localhost:5432")
        database = self.json_cli("add", "--name", "Redis", "--target", "redis://localhost")
        unit = self.json_cli("add", "--name", "Worker", "--target", "worker.service")
        docker = self.json_cli("add", "--name", "Container", "--target", "docker://api")
        kubernetes = self.json_cli(
            "add", "--name", "Deployment", "--target", "k8s://production/deployment/api"
        )
        self.assertEqual(
            (
                web["type"],
                tcp["type"],
                database["type"],
                unit["type"],
                docker["type"],
                kubernetes["type"],
            ),
            ("http", "tcp", "tcp", "systemd", "docker", "kubernetes"),
        )
        self.assertEqual((web["id"], tcp["id"]), ("api", "api-2"))

    def test_docker_and_kubernetes_checks(self):
        self.fake_command(
            "docker",
            "import json\nprint(json.dumps({'Status': 'running', 'Running': True, "
            "'Health': {'Status': 'healthy'}}))",
        )
        self.fake_command(
            "kubectl",
            "import json\nprint(json.dumps({'kind': 'Deployment', "
            "'metadata': {'generation': 3}, 'spec': {'replicas': 2}, "
            "'status': {'observedGeneration': 3, 'readyReplicas': 2}}))",
        )
        self.json_cli("add", "--name", "API container", "--target", "docker://api")
        self.json_cli(
            "add",
            "--name", "API deployment",
            "--target", "k8s://production/deployment/api",
        )
        status = self.json_cli("check")
        self.assertEqual(status["summary"]["overall"], "up")
        self.assertEqual(status["summary"]["total"], 2)
        self.assertEqual(status["summary"]["active"], 2)
        self.assertEqual(status["summary"]["up"], 2)
        self.assertEqual(status["services"][0]["message"], "running · healthy")
        self.assertEqual(status["services"][1]["message"], "2/2 replicas ready")

    def test_container_and_kubernetes_references_are_validated(self):
        docker = self.run_cli(
            "add", "--name", "Bad container", "--target", "docker://bad/name", expected=2
        )
        kubernetes = self.run_cli(
            "add", "--name", "Bad resource", "--target", "k8s://default/deployment", expected=2
        )
        self.assertIn("docker://container-name", docker.stderr)
        self.assertIn("k8s://namespace/kind/name", kubernetes.stderr)

    def test_credentials_are_rejected(self):
        result = self.run_cli(
            "add",
            "--name", "Private DB",
            "--target", "postgres://user:secret@localhost:5432/database",
            expected=2,
        )
        self.assertIn("Credentials are not stored", result.stderr)

    def test_category_removal_reassigns_services(self):
        category = self.json_cli("add-category", "Local dev")
        service = self.json_cli(
            "add", "--name", "App", "--target", "localhost:3000", "--category", category["id"]
        )
        self.assertEqual(service["categoryId"], category["id"])
        self.json_cli("remove-category", category["id"])
        config = self.json_cli("config")
        self.assertEqual(config["categories"], [])
        self.assertEqual(config["services"][0]["categoryId"], "")

    def test_existing_service_can_be_recategorised(self):
        service = self.json_cli("add", "--name", "App", "--target", "localhost:3000")
        category = self.json_cli("add-category", "Production")
        updated = self.json_cli("set-category", service["id"], category["id"])
        self.assertEqual(updated["categoryId"], category["id"])
        updated = self.json_cli("set-category", service["id"])
        self.assertEqual(updated["categoryId"], "")

    def test_http_and_failed_tcp_aggregate_to_down(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        unused = socket.socket()
        unused.bind(("127.0.0.1", 0))
        closed_port = unused.getsockname()[1]
        unused.close()
        try:
            self.json_cli(
                "add", "--name", "Healthy web", "--target", f"http://127.0.0.1:{server.server_port}/"
            )
            self.json_cli(
                "add", "--name", "Missing DB", "--target", f"127.0.0.1:{closed_port}"
            )
            status = self.json_cli("check")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertEqual(status["summary"]["overall"], "down")
        self.assertEqual(status["summary"]["up"], 1)
        self.assertEqual(status["summary"]["down"], 1)
        self.assertEqual(status["services"][0]["status"], "up")
        self.assertEqual(status["services"][0]["statusCode"], 204)

    def test_disabled_service_does_not_make_aggregate_red(self):
        service = self.json_cli("add", "--name", "Offline", "--target", "127.0.0.1:1")
        self.json_cli("toggle", service["id"])
        status = self.json_cli("check")
        self.assertEqual(status["summary"]["overall"], "unknown")
        self.assertEqual(status["summary"]["total"], 1)
        self.assertEqual(status["summary"]["active"], 0)
        self.assertEqual(status["summary"]["disabled"], 1)
        self.assertEqual(status["services"][0]["status"], "disabled")

    def test_view_and_interval_are_persisted_and_clamped(self):
        self.json_cli("set-view", "grid")
        interval = self.json_cli("set-interval", "1")
        config = self.json_cli("config")
        self.assertEqual(interval["intervalSeconds"], 5)
        self.assertEqual(config["settings"]["viewMode"], "grid")
        self.assertEqual(config["settings"]["intervalSeconds"], 5)

    def test_manifest_declares_service_and_bar_widget(self):
        manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "io.github.dupontbertrand.omastatus")
        self.assertEqual(set(manifest["kinds"]), {"service", "bar-widget"})
        for entry_point in manifest["entryPoints"].values():
            self.assertTrue((ROOT / entry_point).is_file())

    def test_invalid_collection_shape_fails_cleanly(self):
        self.json_cli("init")
        config_file = Path(self.env["OMASTATUS_CONFIG_DIR"]) / "config.json"
        config_file.write_text('{"categories": {}, "services": []}\n', encoding="utf-8")
        result = self.run_cli("config", expected=2)
        self.assertIn("categories must be a JSON array", result.stderr)

    def test_configuration_file_size_is_limited_before_decoding(self):
        self.json_cli("init")
        config_file = Path(self.env["OMASTATUS_CONFIG_DIR"]) / "config.json"
        config_file.write_bytes(b" " * (1024 * 1024 + 1))
        result = self.run_cli("config", expected=2)
        self.assertIn("is limited to 1048576 bytes", result.stderr)

    def test_configuration_collection_counts_are_limited(self):
        self.json_cli("init")
        config_file = Path(self.env["OMASTATUS_CONFIG_DIR"]) / "config.json"
        config_file.write_text(
            json.dumps({"categories": [{}] * 129, "services": []}),
            encoding="utf-8",
        )
        categories = self.run_cli("config", expected=2)
        self.assertIn("categories are limited to 128 entries", categories.stderr)

        config_file.write_text(
            json.dumps({"categories": [], "services": [{}] * 257}),
            encoding="utf-8",
        )
        services = self.run_cli("config", expected=2)
        self.assertIn("services are limited to 256 entries", services.stderr)

    def test_kubectl_output_is_bounded_before_json_decoding(self):
        self.fake_command(
            "kubectl",
            "import sys\nsys.stdout.write('x' * (300 * 1024))",
        )
        self.json_cli(
            "add",
            "--name", "Oversized deployment",
            "--target", "k8s://default/deployment/api",
        )
        status = self.json_cli("check")
        self.assertEqual(status["services"][0]["status"], "down")
        self.assertEqual(
            status["services"][0]["message"],
            "kubectl output exceeded 256 KiB limit",
        )


if __name__ == "__main__":
    unittest.main()

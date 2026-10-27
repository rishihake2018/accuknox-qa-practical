"""Docker-backed integration tests for the Wisecow HTTP server.

Build the image first with:
    docker build -t ghcr.io/rishihake2018/accuknox-qa-practical:latest .
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import subprocess
import time
import unittest
import urllib.request
import uuid


IMAGE = os.environ.get("WISECOW_IMAGE", "ghcr.io/rishihake2018/accuknox-qa-practical:latest")


class WisecowHttpIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.container_name = f"wisecow-test-{uuid.uuid4().hex[:12]}"
        subprocess.run(
            [
                "docker",
                "run",
                "--detach",
                "--name",
                cls.container_name,
                "--read-only",
                "--cpus=0.2",
                "--memory=128m",
                "--tmpfs",
                "/tmp:rw,noexec,nosuid,size=16m",
                "--publish",
                "127.0.0.1::4499",
                IMAGE,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        try:
            port_mapping = subprocess.run(
                ["docker", "port", cls.container_name, "4499/tcp"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            cls.url = f"http://{port_mapping.rsplit(':', 1)[0]}:{port_mapping.rsplit(':', 1)[1]}/"
            cls._wait_until_healthy()
        except Exception:
            subprocess.run(
                ["docker", "logs", cls.container_name],
                check=False,
                text=True,
            )
            cls._remove_container()
            raise

    @classmethod
    def tearDownClass(cls) -> None:
        cls._remove_container()

    @classmethod
    def _docker_inspect(cls) -> dict:
        result = subprocess.run(
            ["docker", "inspect", cls.container_name],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)[0]

    @classmethod
    def _wait_until_healthy(cls) -> None:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            inspection = cls._docker_inspect()
            health = inspection["State"].get("Health", {}).get("Status")
            if health == "healthy":
                return
            if inspection["State"]["Status"] != "running":
                raise AssertionError(
                    f"Wisecow container exited: {inspection['State'].get('ExitCode')}"
                )
            time.sleep(0.5)
        raise AssertionError("Wisecow Docker health check did not become healthy")

    @classmethod
    def _remove_container(cls) -> None:
        if hasattr(cls, "container_name"):
            subprocess.run(
                ["docker", "rm", "--force", cls.container_name],
                check=False,
                capture_output=True,
                text=True,
            )

    def _assert_http_response(self) -> None:
        with urllib.request.urlopen(self.url, timeout=10) as response:
            body = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers.get_content_type(), "text/html")
            self.assertEqual(response.headers.get_content_charset(), "utf-8")
            self.assertEqual(response.headers.get("Connection"), "close")
            self.assertIn("<pre>", body)
            self.assertIn("</pre>", body)

    def test_server_handles_successive_health_requests(self) -> None:
        for _ in range(20):
            with self.subTest(request_number=_):
                self._assert_http_response()

    def test_server_handles_concurrent_probe_requests(self) -> None:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda _: self._assert_http_response(), range(12)))
        self.assertEqual(len(results), 12)

    def test_health_check_and_container_security_settings(self) -> None:
        inspection = self._docker_inspect()
        self.assertEqual(inspection["State"]["Health"]["Status"], "healthy")
        self.assertTrue(inspection["HostConfig"]["ReadonlyRootfs"])
        self.assertEqual(inspection["Config"]["User"], "10001:10001")


if __name__ == "__main__":
    unittest.main()

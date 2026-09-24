#!/usr/bin/env python3
"""External soak contracts: explicit ports, real forwarding, bounded duration."""

import json
import pathlib
import socket
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENTRY = ROOT / "scripts/reliability/run-soak-real.sh"


class Soak(unittest.TestCase):
    def test_production_port_is_rejected(self):
        result = subprocess.run(
            ["bash", ENTRY, "--seconds", "1", "--port", "7899"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("7899", result.stderr)

    def test_short_run_measures_real_forwarding_and_cleans_up(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with tempfile.TemporaryDirectory() as work:
            report = pathlib.Path(work) / "soak.json"
            result = subprocess.run(
                [
                    "bash",
                    ENTRY,
                    "--seconds",
                    "2",
                    "--interval",
                    "0.5",
                    "--port",
                    str(port),
                    "--output",
                    report,
                ],
                capture_output=True,
                text=True,
                timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            data = json.loads(report.read_text())
            self.assertEqual(data["status"], "PASS")
            self.assertGreaterEqual(data["elapsed_seconds"], 2)
            self.assertGreaterEqual(data["samples"], 3)
            self.assertTrue(all(s["forward_ok"] for s in data["measurements"]))
            self.assertFalse(data["historical_soak_complete"])
            self.assertFalse(pathlib.Path(data["isolated_home"]).exists())
            with socket.socket() as probe:
                self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0)

    def test_busy_port_fails_without_stopping_owner(self):
        with socket.socket() as owner, tempfile.TemporaryDirectory() as work:
            owner.bind(("127.0.0.1", 0))
            owner.listen()
            port = owner.getsockname()[1]
            result = subprocess.run(
                [
                    "bash",
                    ENTRY,
                    "--seconds",
                    "1",
                    "--port",
                    str(port),
                    "--output",
                    str(pathlib.Path(work) / "busy.json"),
                ],
                capture_output=True,
                text=True,
                timeout=90,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(owner.getsockname()[1], port)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Diagnostic-only regressions at helper CLI and real loopback socket seams."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ORACLE = Path(
    os.environ.get("DIAG_ORACLE", ROOT / "target/debug/examples/e2e_ss_udp_oracle")
)
ZC = Path(os.environ.get("DIAG_ZC", ROOT / "target/debug/zc"))
SSSERVER = Path(os.environ.get("DIAG_SSSERVER", ROOT / "target/e2e-fixtures/ssserver"))


def reap(child):
    if child.poll() is None:
        child.terminate()
    try:
        child.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate()


def exact(stream, size):
    data = b""
    while len(data) < size:
        part = stream.recv(size - len(data))
        if not part:
            raise AssertionError("Unexpected EOF")
        data += part
    return data


class ProbeContext(unittest.TestCase):
    def probe_result(self, response=None, greeting_only=False):
        with (
            tempfile.TemporaryDirectory() as home,
            socket.socket() as listener,
            socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as relay,
        ):
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(3)
            relay.bind(("127.0.0.1", 0))
            relay.settimeout(3)
            env = dict(
                os.environ,
                HOME=home,
                XDG_CONFIG_HOME=home,
                XDG_RUNTIME_DIR=home,
                ZC_E2E_UDP_DIAGNOSTIC="1",
            )
            start = time.monotonic()
            child = subprocess.Popen(
                [
                    str(ORACLE),
                    "probe",
                    "roundtrip",
                    str(listener.getsockname()[1]),
                    str(relay.getsockname()[1]),
                    "context-test",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.addCleanup(reap, child)
            with listener.accept()[0] as control:
                control.settimeout(3)
                self.assertEqual(exact(control, 3), b"\x05\x01\x00")
                if not greeting_only:
                    control.sendall(b"\x05\x00")
                    self.assertEqual(exact(control, 10), b"\x05\x03\x00\x01" + bytes(6))
                    control.sendall(
                        b"\x05\x00\x00\x01\x7f\x00\x00\x01"
                        + relay.getsockname()[1].to_bytes(2, "big")
                    )
                    packet, peer = relay.recvfrom(65536)
                    self.assertTrue(packet.endswith(b"context-test"))
                    if response is not None:
                        relay.sendto(response, peer)
                # A missing response is an intentional public-socket negative control.
                out, err = child.communicate(timeout=7)
            self.assertNotEqual(child.returncode, 0)
            self.assertNotIn("PROBE_PASS", out)
            self.assertLess(time.monotonic() - start, 7)
            return err

    def test_real_socket_timeout_names_receive_stage_and_packet_counts(self):
        err = self.probe_result()
        self.assertIn("stage=udp-receive", err)
        self.assertIn("tx_packets=1 rx_packets=0", err)
        self.assertIn("deadline has elapsed", err)

    def test_stalled_greeting_is_not_mislabelled_as_udp_timeout(self):
        err = self.probe_result(greeting_only=True)
        self.assertIn("stage=greeting-receive", err)
        self.assertIn("tx_packets=0 rx_packets=0", err)
        self.assertIn("deadline has elapsed", err)
        self.assertNotIn("stage=udp-receive", err)

    def test_received_malformed_packet_is_not_mislabelled_as_timeout(self):
        err = self.probe_result(response=b"\x00\x00\x01\x01\x7f\x00\x00\x01\x00\x09bad")
        self.assertIn("stage=response-header", err)
        self.assertIn("tx_packets=1 rx_packets=1", err)
        self.assertIn("InvalidSocksDatagram", err)
        self.assertNotIn("deadline has elapsed", err)


class HarnessCLI(unittest.TestCase):
    def run_harness(self, ssserver=SSSERVER):
        # Preserve every artifact, including negative controls, under target/.
        base = ROOT / "target/diagnose-ss-udp"
        base.mkdir(parents=True, exist_ok=True)
        artifacts = Path(tempfile.mkdtemp(prefix="test-", dir=base)) / "run"
        child = subprocess.Popen(
            [
                sys.executable,
                str(ROOT / "scripts/e2e/diagnose-ss-udp.py"),
                "--zc",
                str(ZC),
                "--oracle",
                str(ORACLE),
                "--ssserver",
                str(ssserver),
                "--iterations",
                "2",
                "--artifacts",
                str(artifacts),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            out, err = child.communicate(timeout=60)
        finally:
            # Let the harness reap fixtures before reaping the harness itself.
            if child.poll() is None:
                child.terminate()
            child.communicate(timeout=40)
        result = subprocess.CompletedProcess(child.args, child.returncode, out, err)
        self.assertTrue(
            (artifacts / "summary.json").exists(), result.stdout + result.stderr
        )
        return result, artifacts, json.loads((artifacts / "summary.json").read_text())

    def test_sigterm_reaps_live_owned_fixtures_and_preserves_failure(self):
        base = ROOT / "target/diagnose-ss-udp"
        base.mkdir(parents=True, exist_ok=True)
        artifacts = Path(tempfile.mkdtemp(prefix="signal-test-", dir=base)) / "run"
        with (
            (artifacts.parent / "harness.stdout").open("w") as out,
            (artifacts.parent / "harness.stderr").open("w") as err,
        ):
            child = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "scripts/e2e/diagnose-ss-udp.py"),
                    "--zc",
                    str(ZC),
                    "--oracle",
                    str(ORACLE),
                    "--ssserver",
                    str(SSSERVER),
                    "--iterations",
                    "100",
                    "--artifacts",
                    str(artifacts),
                ],
                stdout=out,
                stderr=err,
            )
            try:
                deadline = time.monotonic() + 10
                ready = artifacts / "0001/echo-ipv4.stdout"
                while (
                    not ready.exists() or "E2E_UDP_ECHO_READY" not in ready.read_text()
                ):
                    self.assertIsNone(child.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.01)
                child.terminate()
                child.wait(timeout=30)
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=30)
        self.assertNotEqual(child.returncode, 0)
        summary = json.loads((artifacts / "summary.json").read_text())
        self.assertEqual(summary["failed"], 1)
        self.assertTrue(summary["iterations"][0]["interrupted"])
        for record in summary["iterations"][0]["children"]:
            self.assertTrue(record["reaped"])
            self.assertNotEqual(record["returncode"], -9)
            with self.assertRaises(ProcessLookupError):
                os.kill(record["pid"], 0)

    def test_failure_then_pass_is_retained_and_final_exit_stays_nonzero(self):
        base = ROOT / "target/diagnose-ss-udp"
        base.mkdir(parents=True, exist_ok=True)
        fixture = (
            Path(tempfile.mkdtemp(prefix="negative-fixture-", dir=base)) / "ssserver"
        )
        # External process seam: exec the real independent server with a wrong
        # password only in iteration 1. No production internals are replaced.
        fixture.write_text(f"""#!{sys.executable}
import os
from pathlib import Path
import sys
args = sys.argv[1:]
if Path.cwd().name == '0001' and '-k' in args:
    args[args.index('-k') + 1] = 'negative-control-wrong-password'
os.execv({str(SSSERVER)!r}, [{str(SSSERVER)!r}, *args])
""")
        fixture.chmod(0o700)
        result, artifacts, summary = self.run_harness(fixture)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((summary["passed"], summary["failed"]), (1, 1))
        self.assertFalse(summary["iterations"][0]["ok"])
        self.assertTrue(summary["iterations"][1]["ok"])
        first_error = (artifacts / "0001/probe-roundtrip.stderr").read_text()
        self.assertIn("stage=udp-receive", first_error)
        self.assertIn("deadline has elapsed", first_error)
        self.assertIn("tx_packets=1 rx_packets=0", first_error)
        self.assertTrue(
            all(c["reaped"] for i in summary["iterations"] for c in i["children"])
        )

    def test_independent_server_real_socks_echo_loop_and_child_reaping(self):
        result, artifacts, summary = self.run_harness()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((summary["passed"], summary["failed"]), (2, 0))
        for item in summary["iterations"]:
            iteration = artifacts / item["directory"]
            self.assertIn(
                "E2E_SS_UDP_PROBE_PASS=roundtrip",
                (iteration / "probe-roundtrip.stdout").read_text(),
            )
            self.assertIn(
                "created udp association for",
                (iteration / "ssserver.stdout").read_text(),
            )
            self.assertIn(
                "E2E_UDP_ECHO_PACKET=ipv4:1",
                (iteration / "echo-ipv4.stdout").read_text(),
            )
            self.assertTrue(all(child["reaped"] for child in item["children"]))
            for child in item["children"]:
                self.assertNotEqual(
                    child["returncode"],
                    -9,
                    "Child inherited a blocked termination signal",
                )
            self.assertTrue(item["config_unchanged"])


if __name__ == "__main__":
    unittest.main()

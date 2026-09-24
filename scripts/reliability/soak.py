#!/usr/bin/env python3
"""Real foreground soak: isolated state, owned child, loopback CONNECT echo probes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            while data := self.request.recv(65536):
                self.request.sendall(data)
        except (OSError, TimeoutError):
            return


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


def forward(port, origin):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
        client.sendall(
            f"CONNECT 127.0.0.1:{origin} HTTP/1.1\r\nHost: 127.0.0.1:{origin}\r\n\r\n".encode()
        )
        headers = bytearray()
        while not headers.endswith(b"\r\n\r\n") and len(headers) < 8192:
            data = client.recv(1)
            if not data:
                raise RuntimeError("proxy closed before CONNECT response")
            headers.extend(data)
        if not bytes(headers).startswith(b"HTTP/1.1 200 "):
            raise RuntimeError(f"CONNECT failed: {headers[:200]!r}")
        payload = bytes(range(256)) * 16
        client.sendall(payload)
        response = bytearray()
        while len(response) < len(payload):
            data = client.recv(len(payload) - len(response))
            if not data:
                raise RuntimeError("truncated echo response")
            response.extend(data)
        if response != payload:
            raise RuntimeError("echo content mismatch")


def stop(child):
    if child is not None:
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)


def interrupted(signum, _frame):
    raise InterruptedError(f"interrupted by signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hours", nargs="?", type=int, choices=[24, 72])
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--interval", type=float, default=300)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--scenario", choices=["soak", "process-exit"], default="soak")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or args.port == 7899:
        parser.error("an explicit non-production port is required; 7899 is forbidden")
    if (args.hours is None) == (args.seconds is None):
        parser.error("choose 24/72 hours or --seconds, not both")
    duration = args.hours * 3600 if args.hours else args.seconds
    if not 0 < duration <= 72 * 3600 or not 0 < args.interval <= 3600:
        parser.error("duration must be in (0,259200] and interval in (0,3600]")
    if args.config and not args.config.is_file():
        parser.error("config file does not exist")
    output = (
        args.output or ROOT / f"target/reliability/soak-{time.time_ns()}.json"
    ).resolve()
    if output == ROOT or ROOT / "docs" in output.parents:
        parser.error(
            "write exploratory output under target/ or a temporary directory, not docs/"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    binary = ROOT / "target/release/zc"

    def source_hashes():
        paths = [
            ROOT / "Cargo.toml",
            ROOT / "Cargo.lock",
            *sorted((ROOT / "src").rglob("*.rs")),
        ]
        return {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths
        }

    source_before = source_hashes()
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "--bin",
            "zc",
            "--target-dir",
            "target",
        ],
        cwd=ROOT,
        check=True,
    )
    source_after = source_hashes()
    report = {
        "schema_version": 1,
        "formal_baseline": False,
        "kind": "reliability",
        "scope": args.scenario,
        "status": "FAIL",
        "duration_hours": args.hours,
        "requested_seconds": duration,
        "historical_soak_complete": False,
        "mixed_port": args.port,
        "measurements": [],
        "crashes": 0,
        "port_failures": 0,
        "provenance": {
            "source_files_sha256": source_after,
            "source_changed_during_build": source_before != source_after,
            "binary": str(binary),
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "subject_commit": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip(),
            "worktree_status": subprocess.check_output(
                ["git", "status", "--porcelain", "--untracked-files=all"],
                cwd=ROOT,
                text=True,
            ),
        },
        "omitted": [
            "DNS timeout injection",
            "proxy failover",
            "hot reload rollback",
            "historical throughput/latency thresholds",
        ],
    }
    child = None
    start = None
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        with (
            tempfile.TemporaryDirectory(prefix="zc-soak-") as work,
            Server(("127.0.0.1", 0), Echo) as origin,
        ):
            work = Path(work).resolve()
            # Freeze the executable so concurrent builds cannot change a recovery launch.
            frozen_binary = work / "zc"
            frozen_binary.write_bytes(binary.read_bytes())
            frozen_binary.chmod(0o700)
            binary = frozen_binary
            report["provenance"]["launched_binary_sha256"] = hashlib.sha256(
                binary.read_bytes()
            ).hexdigest()
            env = dict(os.environ)
            for key, directory in [
                ("HOME", "home"),
                ("XDG_CONFIG_HOME", "config"),
                ("XDG_RUNTIME_DIR", "run"),
                ("XDG_STATE_HOME", "state"),
                ("XDG_CACHE_HOME", "cache"),
            ]:
                path = work / directory
                path.mkdir(mode=0o700)
                env[key] = str(path)
            report["isolated_home"] = env["HOME"]
            config = work / "fixture.yaml"
            if args.config:
                # Validate the exact captured bytes, not a mutable caller path.
                with args.config.open("rb") as source:
                    config_bytes = source.read(16 * 1024 * 1024 + 1)
                if len(config_bytes) > 16 * 1024 * 1024:
                    raise RuntimeError("soak config exceeds 16 MiB")
                config.write_bytes(config_bytes)
                result = subprocess.run(
                    [binary, "config", "dump", "-c", config, "--no-override", "--json"],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=True,
                )
                document = json.loads(result.stdout)
                if (
                    document.get("external-controller")
                    or document.get("allow-lan")
                    or document.get("bind-address") not in (None, "127.0.0.1")
                ):
                    raise RuntimeError(
                        "soak config must be loopback-only with no external controller"
                    )
            else:
                config.write_text(
                    f"mixed-port: {args.port}\nallow-lan: false\nrules:\n  - MATCH,DIRECT\n"
                )
            report["config_sha256"] = hashlib.sha256(config.read_bytes()).hexdigest()
            # Refuse a busy port without sending commands to its owner or selecting a new port.
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", args.port))
            threading.Thread(target=origin.serve_forever, daemon=True).start()
            log_path = output.with_suffix(".log")
            report["log"] = str(log_path)
            with log_path.open("w") as log:

                def launch():
                    return subprocess.Popen(
                        [
                            binary,
                            "start",
                            "--foreground",
                            "-c",
                            config,
                            "--port",
                            str(args.port),
                        ],
                        env=env,
                        stdout=log,
                        stderr=log,
                    )

                child = launch()
                try:
                    ready_deadline = time.monotonic() + 15
                    while True:
                        if child.poll() is not None:
                            raise RuntimeError(
                                f"foreground process exited: {child.returncode}"
                            )
                        try:
                            forward(args.port, origin.server_address[1])
                            break
                        except (OSError, RuntimeError):
                            if time.monotonic() >= ready_deadline:
                                raise RuntimeError(
                                    "startup readiness deadline exceeded"
                                )
                            time.sleep(0.05)
                    start = time.monotonic()
                    if args.scenario == "process-exit":
                        recovery_start = time.monotonic_ns()
                        child.kill()
                        child.wait(timeout=5)
                        report["injected_exit_code"] = child.returncode
                        child = launch()
                        while True:
                            if child.poll() is not None:
                                raise RuntimeError(
                                    "restarted foreground process exited"
                                )
                            try:
                                forward(args.port, origin.server_address[1])
                                break
                            except (OSError, RuntimeError):
                                if (
                                    time.monotonic_ns() - recovery_start
                                    > 30_000_000_000
                                ):
                                    raise RuntimeError(
                                        "process recovery exceeded 30 seconds"
                                    )
                                time.sleep(0.05)
                        report["recover_time_ms"] = (
                            time.monotonic_ns() - recovery_start
                        ) / 1e6
                        report["recover_actions"] = [
                            "harness restarted owned foreground child",
                            "verified CONNECT echo",
                        ]
                    while True:
                        sample = {
                            "elapsed_seconds": time.monotonic() - start,
                            "alive": child.poll() is None,
                            "forward_ok": False,
                        }
                        if not sample["alive"]:
                            report["crashes"] += 1
                        probe_start = time.monotonic_ns()
                        try:
                            if not sample["alive"]:
                                raise RuntimeError("foreground process exited")
                            forward(args.port, origin.server_address[1])
                            sample["forward_ok"] = True
                        except (OSError, RuntimeError) as error:
                            sample["error"] = str(error)
                            report["port_failures"] += 1
                        sample["probe_ns"] = time.monotonic_ns() - probe_start
                        report["measurements"].append(sample)
                        remaining = duration - (time.monotonic() - start)
                        if remaining <= 0 or not sample["alive"]:
                            break
                        time.sleep(min(args.interval, remaining))
                    report["elapsed_seconds"] = time.monotonic() - start
                    if (
                        report["crashes"] == 0
                        and report["port_failures"] == 0
                        and report["elapsed_seconds"] >= duration
                    ):
                        report["status"] = "PASS"
                finally:
                    stop(child)
                    child = None
                    origin.shutdown()
    except (Exception, KeyboardInterrupt) as error:
        report["error"] = str(error)
    finally:
        stop(child)
        report["samples"] = len(report["measurements"])
        report["elapsed_seconds"] = report.get(
            "elapsed_seconds", 0 if start is None else time.monotonic() - start
        )
        output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"SOAK_RESULT={report['status']}")
    print(f"SOAK_REPORT={output}")
    print(f"SOAK_CRASHES={report['crashes']}")
    print(f"SOAK_SAMPLES={report['samples']}")
    print(f"SOAK_PORT_FAILURES={report['port_failures']}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())

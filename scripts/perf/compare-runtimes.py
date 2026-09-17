#!/usr/bin/env python3
"""Exploratory same-machine release comparison at CLI and real loopback interfaces."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import socket
import socketserver
import statistics
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_state():
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).decode().split("\0")
    files = {name: digest(ROOT / name) for name in sorted(set(names)) if name and (name.endswith((".rs", ".zig", ".zon")) or name in ("Cargo.toml", "Cargo.lock", "scripts/perf/compare-runtimes.py")) and (ROOT / name).is_file()}
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, text=True)
    return {"subject_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "worktree_dirty": bool(status), "worktree_status": status,
            "diff_sha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)).hexdigest(),
            "source_files_sha256": files,
            "source_manifest_sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        try:
            while data := self.request.recv(65536):
                self.request.sendall(data)
        except OSError:
            return


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        if port == 7899:
            raise RuntimeError("refusing production port")
        return port


def tunnel(port, origin):
    client = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        client.sendall(f"CONNECT 127.0.0.1:{origin} HTTP/1.1\r\nHost: 127.0.0.1:{origin}\r\n\r\n".encode())
        response = bytearray()
        while not response.endswith(b"\r\n\r\n") and len(response) < 8192:
            data = client.recv(1)
            if not data:
                raise RuntimeError("truncated CONNECT response")
            response.extend(data)
        if not response.startswith(b"HTTP/1.1 200 "):
            raise RuntimeError(f"CONNECT failed: {response[:200]!r}")
        return client
    except BaseException:
        client.close()
        raise


def exchange(client, payload):
    client.sendall(payload)
    response = bytearray()
    while len(response) < len(payload):
        data = client.recv(len(payload) - len(response))
        if not data:
            raise RuntimeError("truncated loopback response")
        response.extend(data)
    if response != payload:
        raise RuntimeError("loopback payload mismatch")


def stop(child):
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)


def sample(operation, iterations):
    begin = time.perf_counter_ns()
    for _ in range(iterations):
        operation()
    elapsed = time.perf_counter_ns() - begin
    return {"iterations": iterations, "elapsed_ns": elapsed, "ns_per_op": elapsed / iterations}


def paired(name, operations, iterations, count):
    samples = {runtime: [] for runtime in operations}
    # One whole unrecorded sample per runtime, then alternate order each round.
    for operation in operations.values():
        sample(operation, iterations)
    for index in range(count):
        order = list(operations) if index % 2 == 0 else list(reversed(operations))
        for runtime in order:
            samples[runtime].append(sample(operations[runtime], iterations))
    result = {"name": name, "runtimes": {}}
    for runtime, values in samples.items():
        ordered = sorted(value["ns_per_op"] for value in values)
        result["runtimes"][runtime] = {"samples": values, "median_ns_per_op": statistics.median(ordered), "p95_ns_per_op": ordered[math.ceil(len(ordered) * .95) - 1]}
    result["rust_over_zig_median"] = result["runtimes"]["rust"]["median_ns_per_op"] / result["runtimes"]["zig"]["median_ns_per_op"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust", type=Path, default=ROOT / "target/release/zc")
    parser.add_argument("--zig", type=Path, default=ROOT / "target/zig-reference/bin/zc")
    parser.add_argument("--build", action="store_true", help="build both default release candidates and record source hashes across the build")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--iterations", type=int, default=100)
    args = parser.parse_args()
    if args.samples < 5 or args.iterations < 1:
        parser.error("at least five samples and positive iterations required")
    binaries = {"zig": args.zig.resolve(), "rust": args.rust.resolve()}
    output = args.output.resolve()
    if ROOT / "docs" in output.parents:
        parser.error("exploratory artifacts must not overwrite tracked reports")
    output.parent.mkdir(parents=True, exist_ok=True)
    before = source_state()
    build_evidence = {"performed": False}
    if args.build:
        if binaries != {"zig": ROOT / "target/zig-reference/bin/zc", "rust": ROOT / "target/release/zc"}:
            parser.error("--build requires the default candidate paths")
        # Freeze dirty inputs without a commit, stash, reset or Git worktree mutation.
        snapshot = output.parent / f"candidate-source-{time.time_ns()}"
        snapshot.mkdir()
        names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).decode().split("\0")
        manifest = {}
        for name in sorted(set(names)):
            if not name or not (ROOT / name).exists():
                continue
            source = ROOT / name
            if source.is_symlink():
                raise RuntimeError(f"snapshot refuses a symlink: {name}")
            data = source.read_bytes()
            target = snapshot / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(source.stat().st_mode & 0o777)
            manifest[name] = hashlib.sha256(data).hexdigest()
        cargo_target = ROOT / "target/perf/comparison-cargo"
        zig_prefix = snapshot / "target/zig-reference"
        commands = [["cargo", "build", "--locked", "--release", "--bin", "zc", "--target-dir", str(cargo_target)],
                    ["zig", "build", "-Doptimize=ReleaseFast", "--prefix", str(zig_prefix)]]
        build_log = output.with_suffix(".build.log")
        with build_log.open("w") as log:
            for command in commands:
                subprocess.run(command, cwd=snapshot, stdout=log, stderr=log, check=True)
        # Retain immutable candidate binaries separately from the reusable Cargo target.
        frozen_rust = snapshot / "target/rust-release/zc"
        frozen_rust.parent.mkdir(parents=True)
        frozen_rust.write_bytes((cargo_target / "release/zc").read_bytes())
        frozen_rust.chmod(0o755)
        binaries = {"zig": zig_prefix / "bin/zc", "rust": frozen_rust}
        build_evidence = {"performed": True, "commands": commands, "cwd": str(snapshot), "log": str(build_log),
                          "log_sha256": digest(build_log), "snapshot_files_sha256": manifest,
                          "snapshot_manifest_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
                          "snapshot_changed_during_build": any(digest(snapshot / name) != value for name, value in manifest.items())}
        before = source_state()
    report = {"schema_version": 1, "kind": "exploratory-runtime-comparison", "formal_baseline": False,
              "provenance_before": before, "build_evidence": build_evidence,
              "environment": {"platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
                              "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
                              "zig": subprocess.check_output(["zig", "version"], text=True).strip()},
              "binaries": {name: {"path": str(path), "sha256": digest(path)} for name, path in binaries.items()},
              "build_contract": {"rust": "cargo build --locked --release --bin zc", "zig": "zig build -Doptimize=ReleaseFast --prefix target/zig-reference", "note": "--build records build/source binding; without it the caller is responsible for build mode; binary hashes identify supplied candidates"},
              "method": {"warmup_runs": 1, "sample_count": args.samples, "clock": "time.perf_counter_ns", "order": "alternating runtime order per sample", "network": "loopback only", "CLI": "config dump --no-override --json; includes process startup, parse/validation, serialization and output capture", "connection": "HTTP CONNECT + verified 4KiB echo, new connection per operation", "stream": "persistent CONNECT + verified 64KiB echo per operation"},
              "fixtures": [], "benchmarks": [], "omitted": ["in-process parser/route microbenchmarks", "external DNS", "WAN throughput", "long-duration soak", "formal threshold judgment"]}
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError("terminated")))
    try:
        with tempfile.TemporaryDirectory(prefix="zc-runtime-compare-") as work, Server(("127.0.0.1", 0), Echo) as origin:
            work = Path(work).resolve()
            threading.Thread(target=origin.serve_forever, daemon=True).start()
            try:
                for rule_count in (100, 10000):
                    fixture = work / f"rules-{rule_count}.yaml"
                    fixture.write_text("mixed-port: 18080\nallow-lan: false\nmode: rule\nrules:\n" + "".join(f"  - DOMAIN,bench-{index}.invalid,DIRECT\n" for index in range(rule_count)) + "  - MATCH,DIRECT\n")
                    report["fixtures"].append({"rules": rule_count + 1, "bytes": fixture.stat().st_size, "sha256": digest(fixture)})
                    environments = {}
                    for name in binaries:
                        env = dict(os.environ)
                        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
                            path = work / f"{rule_count}-{name}-{key}"
                            path.mkdir(mode=0o700)
                            env[key] = str(path)
                        environments[name] = env

                    def dump(name):
                        result = subprocess.run([binaries[name], "config", "dump", "-c", fixture, "--no-override", "--json"], env=environments[name], capture_output=True, timeout=60, check=True)
                        parsed = json.loads(result.stdout)
                        if len(parsed["rules"]) != rule_count + 1:
                            raise RuntimeError("config dump lost fixture rules")

                    report["benchmarks"].append(paired(f"config_dump_rules_{rule_count}", {name: lambda name=name: dump(name) for name in binaries}, 3, args.samples))
                    children = {}
                    logs = []
                    clients = {}
                    ports = {}
                    try:
                        for name, binary in binaries.items():
                            ports[name] = free_port()
                            log_path = output.with_suffix(f".{rule_count}.{name}.log")
                            log = log_path.open("w")
                            logs.append(log)
                            children[name] = subprocess.Popen([binary, "start", "--foreground", "-c", fixture, "--port", str(ports[name])], env=environments[name], stdout=log, stderr=log)
                            deadline = time.monotonic() + 30
                            while True:
                                if children[name].poll() is not None:
                                    raise RuntimeError(f"{name} exited during startup; see {log_path}")
                                try:
                                    with tunnel(ports[name], origin.server_address[1]) as client:
                                        exchange(client, b"ready")
                                    break
                                except (OSError, RuntimeError):
                                    if time.monotonic() >= deadline:
                                        raise RuntimeError(f"{name} startup timed out; see {log_path}")
                                    time.sleep(.02)

                        def connection(name):
                            with tunnel(ports[name], origin.server_address[1]) as client:
                                exchange(client, bytes(range(256)) * 16)

                        report["benchmarks"].append(paired(f"connect_echo_4k_rules_{rule_count}", {name: lambda name=name: connection(name) for name in binaries}, args.iterations, args.samples))
                        for name in binaries:
                            clients[name] = tunnel(ports[name], origin.server_address[1])
                        payload = bytes(range(256)) * 256
                        report["benchmarks"].append(paired(f"stream_echo_64k_rules_{rule_count}", {name: lambda name=name: exchange(clients[name], payload) for name in binaries}, args.iterations, args.samples))
                    finally:
                        for client in clients.values():
                            client.close()
                        for child in children.values():
                            stop(child)
                        for log in logs:
                            log.close()
            finally:
                origin.shutdown()
        report["status"] = "measured"
    except (Exception, KeyboardInterrupt) as error:
        report["status"] = "error"
        report["error"] = str(error)
    finally:
        report["provenance_after"] = source_state()
        report["shared_source_changed_during_run"] = report["provenance_before"]["source_manifest_sha256"] != report["provenance_after"]["source_manifest_sha256"]
        if args.build:
            report["snapshot_changed_during_run"] = any(digest(snapshot / name) != value for name, value in manifest.items())
        report["binary_sha256_after"] = {name: digest(path) for name, path in binaries.items()}
        output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"EXPLORATORY_MEASUREMENT={report['status']}")
    print(f"EXPLORATORY_REPORT={output}")
    return 0 if report["status"] == "measured" else 1


if __name__ == "__main__":
    raise SystemExit(main())

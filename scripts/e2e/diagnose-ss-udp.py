#!/usr/bin/env python3
"""Diagnostic-only SS UDP isolation; no installation, downloads, or UDP retries.

Uses the failing run-core.sh command path: managed config -> Proxy selection ->
existing oracle probe -> shadowsocks-rust 1.24.0 -> real UDP echo. Each iteration
is a cold, isolated run. Foreground zc permits owning/reaping its actual process;
this deliberately does not reproduce the full core suite's earlier history.
Probe/echo deadlines remain in the existing helper (5s/180s). Readiness and quiet
checks retain run-core.sh's 100 x 50ms and 10 x 50ms budgets. Nothing is retried
except readiness observations. Every failure and all raw output are retained.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
INTERRUPTED = None


def check_interrupt():
    if INTERRUPTED is not None:
        raise KeyboardInterrupt(f"Signal {INTERRUPTED}")


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def digest(path):
    with path.open("rb") as source:
        h = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
        return h.hexdigest()


def read(path):
    return path.read_text(errors="replace") if path.exists() else ""


def wait_until(check, description):
    for _ in range(100):
        check_interrupt()
        if check():
            return
        time.sleep(0.05)
    raise RuntimeError("Readiness deadline: " + description)


class Children:
    def __init__(self, directory, env):
        self.directory, self.env = directory, env
        self.items = []

    def start(self, name, argv):
        check_interrupt()
        # Signal handlers only set a flag: spawning/registration and cleanup
        # cannot be interrupted, and no blocked signal mask reaches children.
        with (
            (self.directory / (name + ".stdout")).open("w") as out,
            (self.directory / (name + ".stderr")).open("w") as err,
        ):
            child = subprocess.Popen(
                list(map(str, argv)),
                cwd=self.directory,
                env=self.env,
                stdout=out,
                stderr=err,
            )
            record = {
                "name": name,
                "pid": child.pid,
                "argv": list(map(str, argv)),
                "started_monotonic_ns": time.monotonic_ns(),
                "reaped": False,
            }
            self.items.append((child, record))
            save(self.directory / "children.json", [r for _, r in self.items])
            return child

    def run(self, name, argv):
        child = self.start(name, argv)
        # Watchdog only; the oracle still owns its unchanged 5-second deadline.
        child.wait(timeout=10)
        check_interrupt()
        if child.returncode:
            raise RuntimeError(f"{name} exited {child.returncode}; see {name}.stderr")
        return read(self.directory / (name + ".stdout"))

    def close(self):
        for child, record in reversed(self.items):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            record.update(returncode=child.returncode, reaped=True)
        save(self.directory / "children.json", [r for _, r in self.items])


def alive(child):
    if child.poll() is not None:
        raise RuntimeError(f"Fixture {child.pid} exited {child.returncode}")
    return True


def reserve(held):
    candidate = socket.socket()
    try:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
        if port == 7899:
            raise RuntimeError("Refusing production port")
        held.append(candidate)
        return port
    except BaseException:
        candidate.close()
        raise


def echo_count(directory, family):
    return len(
        re.findall(
            r"^E2E_UDP_ECHO_PACKET=", read(directory / f"echo-{family}.stdout"), re.M
        )
    )


def association_count(directory):
    return read(directory / "ssserver.stdout").count("created udp association for")


def iteration(args, directory):
    directory.mkdir(mode=0o700)
    for name in ("home", "run", "config", "cache", "state", "tmp"):
        (directory / name).mkdir(mode=0o700)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(directory / "home"),
        "XDG_RUNTIME_DIR": str(directory / "run"),
        "XDG_CONFIG_HOME": str(directory / "config"),
        "XDG_CACHE_HOME": str(directory / "cache"),
        "XDG_STATE_HOME": str(directory / "state"),
        "TMPDIR": str(directory / "tmp"),
        "NO_PROXY": "*",
        "no_proxy": "*",
        "NO_COLOR": "1",
        "ZC_E2E_UDP_DIAGNOSTIC": "1",
    }
    children = Children(directory, env)
    result = {"directory": directory.name, "ok": False, "errors": [], "probes": []}
    held = []
    started = time.monotonic()
    config = directory / "core.yaml"
    services = []
    try:
        version = children.run("ssserver-version", [args.ssserver, "--version"])
        if not re.search(r"\b1\.24\.0\b", version):
            raise RuntimeError("Expected independent shadowsocks-rust 1.24.0")
        mixed, controller, server_port = (reserve(held) for _ in range(3))
        # Keep mixed/controller reservations until just before zc starts.
        held.pop().close()
        server = children.start(
            "ssserver",
            [
                args.ssserver,
                "-U",
                "-s",
                f"127.0.0.1:{server_port}",
                "-k",
                "e2e-password",
                "-m",
                args.cipher,
                "-v",
                "--log-without-time",
            ],
        )
        services.append(server)
        wait_until(
            lambda: (
                alive(server)
                and "shadowsocks udp server listening on"
                in read(directory / "ssserver.stdout")
            ),
            "ssserver UDP",
        )

        def tcp_ready():
            alive(server)
            try:
                with socket.create_connection(("127.0.0.1", server_port), timeout=0.05):
                    return True
            except OSError:
                return False

        wait_until(tcp_ready, "ssserver TCP")
        echo4 = children.start("echo-ipv4", [args.oracle, "echo", "ipv4", "0"])
        services.append(echo4)
        wait_until(
            lambda: (
                alive(echo4)
                and "E2E_UDP_ECHO_READY=ipv4:" in read(directory / "echo-ipv4.stdout")
            ),
            "IPv4 echo",
        )
        echo_port = int(
            re.search(
                r"E2E_UDP_ECHO_READY=ipv4:(\d+)", read(directory / "echo-ipv4.stdout")
            )[1]
        )
        if echo_port in (0, 7899):
            raise RuntimeError("Invalid echo port")
        echo6 = children.start(
            "echo-ipv6", [args.oracle, "echo", "ipv6", str(echo_port)]
        )
        services.append(echo6)
        wait_until(
            lambda: (
                alive(echo6)
                and f"E2E_UDP_ECHO_READY=ipv6:{echo_port}"
                in read(directory / "echo-ipv6.stdout")
            ),
            "IPv6 echo",
        )
        config.write_text(f"""mixed-port: {mixed}
external-controller: 127.0.0.1:{controller}
secret: e2e-secret
proxies:
  - name: ss-target
    type: ss
    server: 127.0.0.1
    port: {server_port}
    cipher: {args.cipher}
    password: e2e-password
    udp: true
proxy-groups:
  - name: Proxy
    type: select
    proxies: [DIRECT, REJECT, ss-target]
rules:
  - DST-PORT,9,DIRECT
  - MATCH,Proxy
""")
        config.chmod(0o400)
        result.update(
            config_sha256=digest(config),
            ports={
                "mixed": mixed,
                "controller": controller,
                "ssserver": server_port,
                "echo": echo_port,
            },
        )
        load = json.loads(
            children.run("config-load", [args.zc, "config", "load", config, "--json"])
        )
        if not load.get("ok") or not load.get("data", {}).get("active"):
            raise RuntimeError("Managed config not active")
        for reservation in held:
            reservation.close()
        held.clear()
        daemon = children.start(
            "zc", [args.zc, "start", "--foreground", "--port", str(mixed)]
        )
        services.append(daemon)
        # Same public CLI authority as core E2E, no readiness inferred from a socket.
        status_index = 0

        def ready():
            nonlocal status_index
            alive(daemon)
            status_index += 1
            value = json.loads(
                children.run(f"status-{status_index}", [args.zc, "status", "--json"])
            )
            return value.get("ok") and value.get("data", {}).get("state") == "running"

        wait_until(ready, "zc ready descriptor")
        selection = json.loads(
            children.run(
                "select",
                [
                    args.zc,
                    "proxy",
                    "select",
                    "-g",
                    "Proxy",
                    "-p",
                    "ss-target",
                    "--json",
                ],
            )
        )
        if (
            not selection.get("ok")
            or selection.get("data", {}).get("applied") is not True
        ):
            raise RuntimeError("Selection was not applied")
        for kind in args.kinds:
            before = [echo_count(directory, family) for family in ("ipv4", "ipv6")]
            associations = association_count(directory)
            probe = {"kind": kind, "ok": False}
            tick = time.monotonic()
            try:
                for service in services:
                    alive(service)
                output = children.run(
                    "probe-" + kind,
                    [
                        args.oracle,
                        "probe",
                        kind,
                        str(mixed),
                        str(echo_port),
                        f"rust-{args.cipher}-{kind}",
                    ],
                )
                if f"E2E_SS_UDP_PROBE_PASS={kind}" not in output:
                    raise RuntimeError("Missing probe pass marker")
                wait_until(
                    lambda: (
                        sum(echo_count(directory, f) for f in ("ipv4", "ipv6"))
                        == sum(before) + 1
                    ),
                    "echo attestation",
                )
                wait_until(
                    lambda: association_count(directory) == associations + 1,
                    "ssserver association",
                )
                for _ in range(10):
                    time.sleep(0.05)
                    after = [echo_count(directory, f) for f in ("ipv4", "ipv6")]
                    if (
                        sum(after) != sum(before) + 1
                        or association_count(directory) != associations + 1
                    ):
                        raise RuntimeError(
                            "Protocol counters changed during quiet period"
                        )
                expected = {"roundtrip": [1, 0], "roundtrip-ipv6": [0, 1]}.get(kind)
                if expected and [a - b for a, b in zip(after, before)] != expected:
                    raise RuntimeError("Unexpected echo address family")
                for service in services:
                    alive(service)
                probe["ok"] = True
            except Exception as error:
                probe["error"] = str(error)
                result["errors"].append(f"{kind}: {error}")
            finally:
                probe.update(
                    elapsed_ms=round((time.monotonic() - tick) * 1000, 3),
                    echo_before=before,
                    echo_after=[echo_count(directory, f) for f in ("ipv4", "ipv6")],
                    associations_before=associations,
                    associations_after=association_count(directory),
                )
                result["probes"].append(probe)
                save(directory / "result.json", result)
    except BaseException as error:
        result["errors"].append(f"{type(error).__name__}: {error}")
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            result["interrupted"] = True
    finally:
        for reservation in held:
            reservation.close()
        # Preserve/reap owned handles; never signal unrelated daemon PIDs.
        children.close()
        result["children"] = [record for _, record in children.items]
        if INTERRUPTED is not None:
            result["interrupted"] = True
            result["errors"].append(f"Interrupted by signal {INTERRUPTED}")
        result["config_unchanged"] = config.exists() and digest(config) == result.get(
            "config_sha256"
        )
        if config.exists() and not result["config_unchanged"]:
            result["errors"].append("Frozen config changed")
        result["ok"] = not result["errors"] and len(result["probes"]) == len(args.kinds)
        result["elapsed_ms"] = round((time.monotonic() - started) * 1000, 3)
        save(directory / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zc", type=Path, default=ROOT / "target/debug/zc")
    parser.add_argument(
        "--oracle", type=Path, default=ROOT / "target/debug/examples/e2e_ss_udp_oracle"
    )
    parser.add_argument(
        "--ssserver", type=Path, default=ROOT / "target/e2e-fixtures/ssserver"
    )
    parser.add_argument(
        "--artifacts",
        type=Path,
        required=True,
        help="New directory; never overwritten or deleted",
    )
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument(
        "--cipher",
        choices=("aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"),
        default="aes-128-gcm",
    )
    parser.add_argument(
        "--kinds",
        nargs="+",
        choices=("roundtrip", "roundtrip-domain", "roundtrip-ipv6"),
        default=["roundtrip"],
    )
    args = parser.parse_args()
    if not 1 <= args.iterations <= 1000 or len(args.kinds) != len(set(args.kinds)):
        parser.error("Use 1..1000 iterations and unique probe kinds")
    os.umask(0o077)
    args.artifacts = args.artifacts.resolve()
    args.artifacts.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name in ("zc", "oracle", "ssserver"):
        setattr(args, name, getattr(args, name).resolve())
    summary = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "requested": args.iterations,
        "cipher": args.cipher,
        "kinds": args.kinds,
        "probe_deadline_seconds": 5,
        "iterations": [],
        "passed": 0,
        "failed": 0,
        "binaries": {
            name: {
                "path": str(getattr(args, name)),
                "sha256": digest(getattr(args, name))
                if getattr(args, name).is_file()
                else None,
            }
            for name in ("zc", "oracle", "ssserver")
        },
    }
    save(args.artifacts / "summary.json", summary)

    def interrupted(signum, frame):
        global INTERRUPTED
        INTERRUPTED = signum

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    for number in range(1, args.iterations + 1):
        result = iteration(args, args.artifacts / f"{number:04d}")
        summary["iterations"].append(result)
        summary["passed" if result["ok"] else "failed"] += 1
        save(args.artifacts / "summary.json", summary)
        print(
            f"[DEBUG-udp-harness] iteration={number} ok={result['ok']} artifacts={args.artifacts / result['directory']}",
            flush=True,
        )
        if result.get("interrupted"):
            break
    print(
        f"[DEBUG-udp-harness] passed={summary['passed']} failed={summary['failed']} requested={args.iterations} artifacts={args.artifacts}"
    )
    return int(summary["failed"] != 0 or len(summary["iterations"]) != args.iterations)


if __name__ == "__main__":
    sys.exit(main())

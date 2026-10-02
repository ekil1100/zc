#!/usr/bin/env python3
"""Optional native AnyTLS gate against pinned, unmodified official Go servers."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import hashlib
import importlib
import json
import os
from pathlib import Path
import platform
import socket
import ssl
import struct
import subprocess
import tempfile

# Reuse CLI/socket lifecycle utilities, not a protocol implementation or oracle.
harness = importlib.import_module("run-rust-tcp")
ROOT = Path(__file__).resolve().parents[2]


def failed_target(mixed):
    # A reserved but non-listening port cannot accidentally reach another service.
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        with harness.tunnel(mixed, reserved.getsockname()) as stream:
            stream.sendall(b"target-failure-probe")
            try:
                assert stream.recv(1) == b"", "failed target returned data"
            except ConnectionError:
                pass
            # Timeout is NOT an acceptable failure signal.


def denied(mixed, origin, kind="socks"):
    before = origin.connections()
    try:
        with harness.tunnel(mixed, origin.server_address, kind) as stream:
            stream.sendall(b"rejected-probe")
            try:
                assert stream.recv(1) == b"", "rejected session returned data"
            except ConnectionError:
                pass
    except AssertionError as error:
        if str(error) not in ("CONNECT was refused", "SOCKS CONNECT was refused"):
            raise
    assert origin.connections() == before, "failure fell back to DIRECT"


def wire_shapes(zc, work):
    """OpenSSL recv preserves TLS records, unlike tokio-rustls' coalescing reader."""
    name, version = subprocess.check_output(
        [str(zc), "--version"], timeout=harness.WAIT
    ).split()
    assert name == b"zc", "unexpected candidate version output"
    client = name + b"/" + version
    update = b"stop=3\n0=9-9\n1=200-200\n2=20-20,40-40\n"
    md5s = [b"75cff2ad89aadf5e257059ee571ebe11", b"8d29f7a84b60406b4144b7461f63b0fb"]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(
        ROOT / "testdata/e2e/trojan-cert.pem", ROOT / "testdata/e2e/trojan-key.pem"
    )
    records = []

    def frames(data):
        result = []
        while data:
            assert len(data) >= 7
            command, stream_id, size = struct.unpack("!BIH", data[:7])
            assert len(data) >= 7 + size
            result.append((command, stream_id, data[7 : 7 + size]))
            data = data[7 + size :]
        return result

    with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as pool:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(harness.WAIT)

        def serve():
            for index, padding in enumerate([30, 9]):
                raw, _ = listener.accept()
                raw.settimeout(harness.WAIT)
                with context.wrap_socket(raw, server_side=True) as stream:
                    auth = stream.recv(16384)
                    assert auth == hashlib.sha256(
                        b"anytls-fixture-only"
                    ).digest() + struct.pack("!H", padding) + bytes(padding)
                    first = stream.recv(16384)
                    if index == 0:
                        assert len(first) == 100 or 108 <= len(first) < 400
                    else:
                        assert len(first) == 200
                    opened = frames(first)
                    assert [f[:2] for f in opened[:3]] == [(4, 0), (1, 1), (2, 1)]
                    assert (
                        opened[0][2]
                        == b"v=2\nclient=" + client + b"\npadding-md5=" + md5s[index]
                    )
                    assert opened[2][2] == b"\x03\x0bexample.com\x01\xbb"
                    assert all(f[0:2] == (0, 0) for f in opened[3:])
                    if index == 0:
                        stream.sendall(struct.pack("!BIH", 6, 0, len(update)) + update)
                    stream.sendall(b"\x02\0\0\0\x01\0\x01!")
                    data = stream.recv(16384)
                    if index == 0:
                        assert 400 <= len(data) < 500
                    else:
                        assert len(data) == 20
                        pure = stream.recv(16384)
                        assert pure == b"\0\0\0\0\0\0\x28" + bytes(40)
                    assert frames(data)[0] == (2, 1, b"hey")
                    assert all(f[0:2] == (0, 0) for f in frames(data)[1:])
                    records.append(
                        {
                            "auth": len(auth),
                            "opening": len(first),
                            "data": len(data),
                            "pure_padding": 47 if index else 0,
                        }
                    )
                    stream.sendall(b"\x02\0\0\0\x01\0\x03hey\x03\0\0\0\x01\0\0")

        future = pool.submit(serve)
        proxy = {
            "type": "anytls",
            "server": "127.0.0.1",
            "port": listener.getsockname()[1],
            "password": "anytls-fixture-only",
            "sni": "localhost.localdomain",
        }
        # Positive trusted identity with an independent OpenSSL peer.
        with harness.runtime(
            zc, work, "tls-record-shapes", proxy, trusted=True
        ) as mixed:
            for _ in range(2):
                with harness.tunnel(mixed, ("example.com", 443)) as stream:
                    assert harness.exact(stream, 1) == b"!"
                    stream.sendall(b"hey")
                    assert harness.exact(stream, 3) == b"hey"
                    assert stream.recv(1) == b""
            future.result(timeout=harness.WAIT)
    (work / "record-shapes.json").write_text(json.dumps(records, indent=2) + "\n")
    print(
        "PASS trusted OpenSSL TLS record shapes: atomic auth, default padding, next-session raw-MD5 update, pure padding length+7"
    )


def run(zc, fixtures, work):
    system = platform.system().lower()
    arch = {"aarch64": "arm64", "x86_64": "x64"}.get(
        platform.machine(), platform.machine()
    )
    manifest = json.loads((ROOT / "testdata/e2e/anytls-fixtures.json").read_text())
    pins = manifest.get(f"{system}-{arch}")
    assert pins is not None, "no reviewed fixture hashes for this platform"
    # Verify every fixture before executing anything. No downloads or builds here.
    for version, pin in pins.items():
        binary = fixtures / "bin" / f"anytls-server-{version}"
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == pin["sha256"], (
            f"fixture SHA256 mismatch: {version}"
        )
    wire_shapes(zc, work)
    results = []
    with contextlib.ExitStack() as stack:
        echo = stack.enter_context(harness.origin())
        banner = stack.enter_context(harness.origin("banner"))
        http = stack.enter_context(harness.origin("http"))
        ipv6 = stack.enter_context(harness.origin(family=socket.AF_INET6))
        for version, pin in pins.items():
            listen = harness.port()
            home = work / f"go-home-{version}"
            home.mkdir(mode=0o700)
            env = dict(os.environ, HOME=str(home), LOG_LEVEL="debug")
            args = [
                str(fixtures / "bin" / f"anytls-server-{version}"),
                "-l",
                f"127.0.0.1:{listen}",
                "-p",
                "anytls-fixture-only",
            ]
            with harness.process(args, work / f"go-{version}.log", listen, env):
                proxy = {
                    "type": "anytls",
                    "server": "127.0.0.1",
                    "port": listen,
                    "password": "anytls-fixture-only",
                    "skip-cert-verify": True,
                    "sni": "localhost.localdomain",
                }
                with harness.runtime(zc, work, version, proxy) as mixed:
                    harness.roundtrip(mixed, echo, host="localhost")
                    harness.roundtrip(mixed, echo, "connect")
                    harness.roundtrip(mixed, banner)
                    harness.roundtrip(mixed, banner, "connect")
                    harness.roundtrip(mixed, ipv6)
                    harness.forward(mixed, http)
                    failed_target(mixed)
                with harness.runtime(
                    zc,
                    work,
                    f"{version}-bad-password",
                    dict(proxy, password="wrong-password"),
                ) as mixed:
                    # Exact origin count proves no fallback to DIRECT.
                    denied(mixed, echo)
                    denied(mixed, echo, "connect")
                with harness.runtime(
                    zc,
                    work,
                    f"{version}-untrusted",
                    dict(proxy, **{"skip-cert-verify": False}),
                ) as mixed:
                    denied(mixed, echo)
                results.append(
                    {
                        "version": version,
                        **pin,
                        "result": "PASS",
                        "cases": 10,
                    }
                )
                print(
                    f"PASS AnyTLS {version}: echo/server-first, SOCKS/CONNECT/forward, domain/IPv4/IPv6, local FIN, wrong password, target failure, untrusted TLS"
                )
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print("ANYTLS_E2E_RESULT=PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zc", type=Path)
    parser.add_argument("fixtures", type=Path)
    args = parser.parse_args()
    root = ROOT / "target/anytls-reference"
    root.mkdir(parents=True, exist_ok=True)
    # Preserve isolated logs and evidence, never use real HOME/runtime configuration.
    work = Path(tempfile.mkdtemp(prefix="rust-e2e-", dir=root)).resolve()
    print(f"Evidence: {work}")
    run(args.zc.resolve(), args.fixtures.resolve(), work)


if __name__ == "__main__":
    main()

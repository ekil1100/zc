#!/usr/bin/env python3
"""Exercise the Rust CLI against independent, fixed SS/Trojan server binaries."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
WAIT = 8
PAYLOAD = bytes(range(256)) * 257
BANNER = b"220 independent fixture ready\r\n"


def exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.recv(count - len(result))
        if not chunk:
            raise AssertionError("unexpected EOF before complete payload")
        result.extend(chunk)
    return bytes(result)


def http_head(stream):
    result = bytearray()
    while not result.endswith(b"\r\n\r\n"):
        result.extend(exact(stream, 1))
        assert len(result) <= 16384, "oversized HTTP response header"
    return bytes(result)


class Origin(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False
    block_on_close = False

    def __init__(self, mode="echo", family=socket.AF_INET):
        self.address_family = family
        self.mode = mode
        self.count = 0
        self.lock = threading.Lock()
        self.requests = []
        super().__init__(("::1" if family == socket.AF_INET6 else "127.0.0.1", 0), Handler)

    def connections(self):
        with self.lock:
            return self.count


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(WAIT)
        with self.server.lock:
            self.server.count += 1
        try:
            if self.server.mode == "sink":
                return
            if self.server.mode == "http":
                head = http_head(self.request)
                with self.server.lock:
                    self.server.requests.append(head)
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nfixture-origin")
                return
            if self.server.mode == "banner":
                self.request.sendall(BANNER)
            while True:
                data = self.request.recv(65536)
                if not data:
                    self.request.shutdown(socket.SHUT_WR)
                    return
                self.request.sendall(data)
        except (ConnectionError, TimeoutError, OSError):
            # Negative paths close sockets deliberately; positives assert exact payload.
            return


@contextlib.contextmanager
def origin(mode="echo", family=socket.AF_INET):
    with Origin(mode, family) as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02})
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join(WAIT)
            assert not thread.is_alive(), "origin did not stop"


def port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        result = reservation.getsockname()[1]
        assert result != 7899
        return result


@contextlib.contextmanager
def process(args, log, ready_port, env=None, readiness=None):
    with log.open("wb") as output:
        child = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, env=env)
        try:
            deadline = time.monotonic() + WAIT
            while True:
                assert child.poll() is None, f"process exited during startup: {args[0]}"
                if readiness is not None:
                    ready = readiness in log.read_text(errors="replace")
                else:
                    try:
                        with socket.create_connection(("127.0.0.1", ready_port), 0.1):
                            ready = True
                    except OSError:
                        ready = False
                if ready:
                    break
                assert time.monotonic() < deadline, "startup timed out"
                time.sleep(0.01)
            yield child
            assert child.poll() is None, "server unexpectedly exited during probes"
        except BaseException:
            print(log.read_text(errors="replace"))
            raise
        finally:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=WAIT)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
                raise AssertionError("child did not stop after SIGTERM")


@contextlib.contextmanager
def runtime(zc, directory, label, proxy=None, trusted=False, reject=False):
    directory = directory / label
    directory.mkdir()
    listen_port = port()
    config = {"mixed-port": 7892, "rules": ["DOMAIN,blocked.invalid,REJECT", "MATCH,REJECT" if reject else "MATCH,DIRECT"]}
    if proxy:
        config["proxies"] = [dict(name="edge", **proxy)]
        config["proxy-groups"] = [{"name": "outer", "type": "select", "proxies": ["inner", "REJECT"]}, {"name": "inner", "type": "select", "proxies": ["edge"]}]
        config["rules"][-1] = "MATCH,outer"
    config_file = directory / "config.yaml"
    config_file.write_text(json.dumps(config))
    config_file.chmod(0o600)
    home = directory / "home"
    home.mkdir()
    run = directory / "run"
    run.mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / "config"), XDG_RUNTIME_DIR=str(run))
    if trusted:
        env["SSL_CERT_FILE"] = str(ROOT / "testdata/e2e/trojan-cert.pem")
        env["SSL_CERT_DIR"] = str(directory / "empty-certs")
        Path(env["SSL_CERT_DIR"]).mkdir()
    else:
        env.pop("SSL_CERT_FILE", None)
        env.pop("SSL_CERT_DIR", None)
    args = [str(zc), "start", "--config", str(config_file), "--port", str(listen_port), "--foreground"]
    with process(args, directory / "zc.log", listen_port, env, f"listening on 127.0.0.1:{listen_port}"):
        yield listen_port
    assert not (home / ".config/zc").exists(), "unmanaged runtime created a managed catalog"
    assert not (home / "config/zc").exists(), "unmanaged runtime created an XDG managed catalog"
    # Foreground now participates in the same nonce-bound lifecycle as daemon mode.
    # Persistent locks/key/log are allowed; live identity and prepared inputs are not.
    assert not (run / "zc.pid").exists(), "foreground left a live PID file"
    assert not (run / "zc.daemon.json").exists(), "foreground left a live descriptor"
    assert not list(run.glob("zc.start.*")), "foreground leaked prepared inputs"
    assert not list(run.glob("zc.stop.*")), "foreground leaked a stop request"
    assert run.stat().st_mode & 0o777 == 0o700, "runtime directory is not private"
    for state_file in run.iterdir():
        assert not state_file.is_symlink(), "lifecycle file is a symlink"
        assert state_file.is_file(), "unexpected lifecycle file type"
        assert state_file.stat().st_mode & 0o777 == 0o600, "lifecycle file is not private"


def tunnel(mixed_port, target, kind="socks", host=None):
    host = host or target[0]
    stream = socket.create_connection(("127.0.0.1", mixed_port), WAIT)
    stream.settimeout(WAIT)
    try:
        if kind == "connect":
            authority = f"[{host}]:{target[1]}" if ":" in host else f"{host}:{target[1]}"
            stream.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
            assert http_head(stream).startswith(b"HTTP/1.1 200 "), "CONNECT was refused"
        else:
            stream.sendall(b"\x05\x01\x00")
            assert exact(stream, 2) == b"\x05\x00"
            try:
                address = b"\x01" + socket.inet_pton(socket.AF_INET, host)
            except OSError:
                try:
                    address = b"\x04" + socket.inet_pton(socket.AF_INET6, host)
                except OSError:
                    address = b"\x03" + bytes([len(host)]) + host.encode()
            stream.sendall(b"\x05\x01\x00" + address + struct.pack("!H", target[1]))
            assert exact(stream, 10)[:4] == b"\x05\x00\x00\x01", "SOCKS CONNECT was refused"
        return stream
    except BaseException:
        stream.close()
        raise


def roundtrip(mixed_port, server, kind="socks", host=None, half_close=True):
    before = server.connections()
    with tunnel(mixed_port, server.server_address, kind, host) as stream:
        if server.mode == "banner":
            assert exact(stream, len(BANNER)) == BANNER, "server-first response missing"
        stream.sendall(PAYLOAD)
        # Read before FIN: trojan-go does not promise reverse response delivery after EOF.
        assert exact(stream, len(PAYLOAD)) == PAYLOAD, "payload mismatch"
        if half_close:
            stream.shutdown(socket.SHUT_WR)
            assert stream.recv(1) == b"", "EOF was not propagated"
    assert server.connections() == before + 1, "traffic did not traverse independent origin"


def denied(mixed_port, server, kind="socks"):
    before = server.connections()
    try:
        with tunnel(mixed_port, server.server_address, kind) as stream:
            stream.sendall(PAYLOAD[:256])
            try:
                received = stream.recv(256)
            except (OSError, TimeoutError):
                received = b""
            assert received != PAYLOAD[:256], "rejected request transferred payload"
    except AssertionError as error:
        if str(error) not in ["CONNECT was refused", "SOCKS CONNECT was refused"]:
            raise
    assert server.connections() == before, "failure fell back to DIRECT"


def forward(mixed_port, server):
    before = server.connections()
    with socket.create_connection(("127.0.0.1", mixed_port), WAIT) as stream:
        stream.settimeout(WAIT)
        address = f"127.0.0.1:{server.server_address[1]}"
        stream.sendall(f"GET http://{address}/probe HTTP/1.1\r\nHost: {address}\r\nProxy-Authorization: Basic never-forward\r\n\r\n".encode())
        assert http_head(stream).startswith(b"HTTP/1.1 200 ")
        assert exact(stream, 14) == b"fixture-origin"
    assert server.connections() == before + 1
    with server.lock:
        head = server.requests[-1]
    assert head.startswith(b"GET /probe HTTP/1.1\r\n")
    assert b"never-forward" not in head


def run(zc, fixtures, work):
    assert "shadowsocks 1.24.0" in subprocess.check_output([str(fixtures / "ssserver"), "--version"], text=True)
    assert "Trojan-Go v0.10.6" in subprocess.check_output([str(fixtures / "trojan-go"), "-version"], text=True)
    with contextlib.ExitStack() as stack:
        echo = stack.enter_context(origin())
        banner = stack.enter_context(origin("banner"))
        http = stack.enter_context(origin("http"))
        ipv6 = stack.enter_context(origin(family=socket.AF_INET6))
        with runtime(zc, work, "direct") as mixed:
            roundtrip(mixed, echo)
            roundtrip(mixed, banner, "connect")
            forward(mixed, http)
        with runtime(zc, work, "reject", reject=True) as mixed:
            denied(mixed, echo)
            denied(mixed, echo, "connect")
        print("PASS DIRECT/REJECT and HTTP forward")
        for index, cipher in enumerate(["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "chacha20-poly1305"]):
            listen = port()
            server_cipher = "chacha20-ietf-poly1305" if cipher == "chacha20-poly1305" else cipher
            args = [str(fixtures / "ssserver"), "-s", f"127.0.0.1:{listen}", "-k", "e2e-password", "-m", server_cipher]
            with process(args, work / f"ss-{index}.log", listen):
                proxy = {"type": "ss", "server": "localhost", "port": listen, "password": "e2e-password", "cipher": cipher}
                with runtime(zc, work, f"ss-{index}", proxy) as mixed:
                    roundtrip(mixed, echo, host="localhost")
                    roundtrip(mixed, banner, "connect")
                    roundtrip(mixed, ipv6)
                    forward(mixed, http)
                with runtime(zc, work, f"ss-{index}-bad-password", dict(proxy, password="wrong-password")) as mixed:
                    denied(mixed, echo)
            print(f"PASS Shadowsocks {cipher}: domain/IPv4/IPv6, server-first, forward, wrong password")
        listen = port()
        fallback = stack.enter_context(origin("sink"))
        trojan_file = work / "trojan.json"
        trojan_file.write_text(json.dumps({"run_type": "server", "log_level": 2, "local_addr": "127.0.0.1", "local_port": listen, "remote_addr": "127.0.0.1", "remote_port": fallback.server_address[1], "password": ["e2e-password"], "ssl": {"cert": str(ROOT / "testdata/e2e/trojan-cert.pem"), "key": str(ROOT / "testdata/e2e/trojan-key.pem")}, "router": {"enabled": False}}))
        with process([str(fixtures / "trojan-go"), "-config", str(trojan_file)], work / "trojan.log", listen):
            proxy = {"type": "trojan", "server": "localhost", "port": listen, "password": "e2e-password", "sni": "localhost.localdomain"}
            with runtime(zc, work, "trojan-verified", proxy, trusted=True) as mixed:
                roundtrip(mixed, echo, host="localhost")
                roundtrip(mixed, banner, "connect")
                roundtrip(mixed, ipv6)
                forward(mixed, http)
            for label, settings, trust in [
                ("untrusted", proxy, False),
                ("wrong-sni", dict(proxy, sni="wrong.example"), True),
                ("wrong-password", dict(proxy, password="wrong-password"), True),
            ]:
                with runtime(zc, work, f"trojan-{label}", settings, trusted=trust) as mixed:
                    denied(mixed, echo, "connect")
            with runtime(zc, work, "trojan-explicit-skip", dict(proxy, **{"skip-cert-verify": True})) as mixed:
                roundtrip(mixed, echo)
        print("PASS Trojan: verified TLS, domain/IPv4/IPv6, forward, SNI/trust/password rejection, explicit skip")
    print("PASS Rust TCP independent fixture E2E")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zc", type=Path)
    parser.add_argument("fixtures", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zc-rust-e2e-") as directory:
        run(args.zc.resolve(), args.fixtures.resolve(), Path(directory).resolve())


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Independent real-process regressions; optional original Zig transition oracle."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

RUST = Path(sys.argv[1]).resolve()
ZIG = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
BASE = "proxy-groups:\n  - name: pick\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,pick']\n"


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        result = s.getsockname()[1]
        assert result != 7899
        return result


def wait(check):
    deadline = time.monotonic() + 5
    while not check():
        assert time.monotonic() < deadline, 'condition timed out'
        time.sleep(.002)


def http(endpoint, wire):
    with socket.create_connection(('127.0.0.1', endpoint), timeout=4) as s:
        s.sendall(wire)
        result = b''
        while True:
            try:
                chunk = s.recv(65536)
            except ConnectionResetError:
                break
            if not chunk:
                break
            result += chunk
        return result


class Fixture:
    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='daemon_external_')
        self.home = Path(self.temp.name).resolve()
        self.runtime = self.home / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.config = self.home / 'source.yaml'
        self.config.write_text(BASE + f"mixed-port: {port()}\n")
        self.env = dict(os.environ, HOME=str(self.home), XDG_RUNTIME_DIR=str(self.runtime),
                        XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_STATE_HOME=str(self.home / '.local/state'),
                        XDG_CACHE_HOME=str(self.home / '.cache'))
        self.processes = []
        self.launcher = None
        return self

    def spawn(self, args, binary=RUST):
        p = subprocess.Popen([str(binary), *map(str, args)], cwd=self.home, env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.processes.append(p)
        return p

    def run(self, args, binary=RUST, success=True):
        p = self.spawn(args, binary)
        out, err = p.communicate(timeout=20)
        assert bool(p.returncode == 0) == success, (p.returncode, out, err)
        return json.loads(out)

    def start(self, binary=RUST, controller=False, managed=False):
        mixed, api = port(), port()
        if controller:
            self.config.write_text(BASE + f'mixed-port: {mixed}\nexternal-controller: 127.0.0.1:{api}\nsecret: test-secret\n')
        if managed:
            self.run(['config', 'load', self.config, '--json'], binary)
        args = ['start', '--port', mixed, '--json']
        if not managed:
            args += ['-c', self.config]
        p = self.spawn(args, binary)
        self.launcher = p.pid
        out, err = p.communicate(timeout=20)
        assert p.returncode == 0, (out, err)
        return mixed, api, self.descriptor()

    def descriptor(self):
        return json.loads((self.runtime / 'zc.daemon.json').read_text())

    def __exit__(self, *_):
        (self.home / 'release').touch()
        # Only signal the daemon captured from this private runtime, never host PIDs.
        with contextlib.suppress(Exception):
            d = self.descriptor()
            os.kill(d['pid'], signal.SIGCONT)
            name = self.runtime / ('zc.stop.' + d['nonce'])
            name.write_text(d['nonce'] + '\n')
            name.chmod(0o600)
            time.sleep(.3)
        for p in self.processes:
            if p.poll() is None:
                p.kill()
                p.wait()
        self.temp.cleanup()


def rust_regressions():
    with Fixture() as f:
        mixed, api, d = f.start(controller=True)
        assert os.getpgid(d['pid']) == d['pid']
        assert os.getsid(d['pid']) == d['pid']
        # The launcher has exited; its old group may no longer exist.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(f.launcher, signal.SIGHUP)
        assert f.run(['status', '--json'])['data']['state'] == 'running'
        for scheme in ['Bearer', 'bearer', 'BEARER']:
            wire = (f'PUT /proxies/pick HTTP/1.1\r\nAuthorization: {scheme} test-secret\r\n'
                    'Content-Length: 17\r\n\r\n{"name":"DIRECT"}').encode()
            assert http(api, wire).startswith(b'HTTP/1.1 200')
        wire = (b'PUT /proxies/pick HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n'
                b'Content-Length: 17\n\nContent-Length: 0\r\n\r\n{"name":"REJECT"}')
        assert http(api, wire).startswith(b'HTTP/1.1 400')
        status = http(api, b'GET /status HTTP/1.1\r\n\r\n').split(b'\r\n\r\n', 1)[1]
        assert json.loads(status)['selected_proxies'][0]['proxy'] == 'DIRECT'
        print('PASS detached session, Bearer scheme, exact hidden-framing mutation')

    with Fixture() as f:
        _, _, d = f.start()
        os.kill(d['pid'], signal.SIGSTOP)
        f.run(['stop', '--json'], success=False)
        assert not (f.runtime / ('zc.stop.' + d['nonce'])).exists()
        os.kill(d['pid'], signal.SIGCONT)
        time.sleep(.2)
        assert f.run(['status', '--json'])['data']['pid'] == d['pid']
        print('PASS stop timeout revocation')

    with Fixture() as f:
        guardian = f.home / '.local/state/zc'
        guardian.mkdir(parents=True, mode=0o700)
        with open(guardian / 'zc.lifecycle.lock', 'w+b') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            mixed = port()
            p = f.spawn(['start', '-c', f.config, '--port', mixed, '--json'])
            wait(lambda: list(f.runtime.glob('zc.prepared.*.snapshot')))
            fd = os.open(f.runtime / 'zc.daemon.json', os.O_CREAT | os.O_WRONLY, 0o600)
            os.write(fd, b'{}\n')
            os.close(fd)
            p.communicate(timeout=3)
            assert p.returncode != 0
        time.sleep(.35)
        with socket.socket() as s:
            assert s.connect_ex(('127.0.0.1', mixed)) != 0
        with open(f.runtime / 'zc.lock', 'r+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('PASS failed readiness handoff leaves no child/listener')

    with Fixture() as f:
        f.start()
        gate, release = f.home / 'gate', f.home / 'release'
        script = f.home / 'daemon_block.sh'
        script.write_text(f'#!/bin/sh\n: > "{gate}"\nwhile [ ! -e "{release}" ]; do /bin/sleep 0.01; done\n')
        script.chmod(0o700)
        p = f.spawn(['restart', '-c', f.config, '--port', port(), '--override-script', script,
                     '--override-timeout-ms', '10000', '--json'])
        wait(gate.exists)
        f.run(['restart', '-c', f.config, '--port', port(), '--json'])
        newer = f.descriptor()
        release.touch()
        out, _ = p.communicate(timeout=15)
        assert p.returncode != 0 and b'RESTART_CONTENDED' in out
        assert f.descriptor() == newer
        print('PASS independent CLI restart preparation race')


def zig_transition():
    with Fixture() as f:
        mixed, _, d = f.start(ZIG, controller=True)
        assert (f.runtime / 'zc.lock').read_bytes() == b''
        assert f.run(['status', '--json'])['data']['mixed_port'] == mixed
        f.config.unlink()
        assert f.run(['start', '-c', f.config, '--json'])['data']['pid'] == d['pid']
        f.run(['stop', '--json'])
        assert f.run(['status', '--json'])['data']['state'] == 'stopped'
        print('PASS native Zig status/idempotent start/safe unowned-child stop')

    with Fixture() as f:
        mixed, api, d = f.start(ZIG, controller=True, managed=True)
        selection = f.run(['proxy', 'select', '-g', 'pick', '-p', 'REJECT', '--json'])
        assert selection['data']['applied'] is True
        assert f.run(['status', '--json'])['data']['selected_proxies'][0]['proxy'] == 'REJECT'
        # The old authenticated YAML has no instance nonce or applied selections.
        # Capture live selection metadata before replacement; rollback must freeze it.
        occupied = socket.socket()
        occupied.bind(('127.0.0.1', 0))
        occupied.listen()
        try:
            target = f.home / 'broken.yaml'
            target.write_text(f'mixed-port: {port()}\nrules: ["MATCH,DIRECT"]\nexternal-controller: 127.0.0.1:{occupied.getsockname()[1]}\n')
            result = f.run(['restart', '-c', target, '--port', port(), '--json'], success=False)
            assert result['error']['code'] == 'RESTART_FAILED_ROLLED_BACK', result
            state = f.run(['status', '--json'])['data']
            assert state['mixed_port'] == mixed and state['selected_proxies'][0]['proxy'] == 'REJECT', state
        finally:
            occupied.close()
        print('PASS native Zig managed PUT and frozen rollback to Rust')

    with Fixture() as f:
        mixed, _, _ = f.start(ZIG, controller=True)
        f.config.unlink()
        before = f.descriptor()
        result = f.run(['reload', '--json'], success=False)
        assert result['error']['code'] == 'RELOAD_FAILED'
        assert f.descriptor() == before
        f.run(['restart', '--json'])
        assert f.run(['status', '--json'])['data']['mixed_port'] == mixed
        print('PASS native Zig missing-source reload refusal and frozen restart')


if __name__ == '__main__':
    rust_regressions()
    if ZIG:
        zig_transition()

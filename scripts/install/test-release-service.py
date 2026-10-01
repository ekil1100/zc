"""Root stdin handoff -> Rust transaction with the existing injected manager.

Only this test binary can select the fake runner. Production Native is unchanged.
"""

import hashlib
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import time

repo, fixture, root = (pathlib.Path(arg).resolve() for arg in sys.argv[1:])
version = subprocess.check_output([fixture, "--version"], text=True).strip().split()[1]
package = f"zc-v{version}-{'macos' if sys.platform == 'darwin' else 'linux'}-"
package += {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64"}[os.uname().machine]
release = root / "service-releases" / f"v{version}"
release.mkdir(parents=True)
archive = release / f"{package}.tar.gz"
with tarfile.open(archive, "w:gz") as tar:
    tar.add(fixture, arcname=f"{package}/zc")
archive.with_suffix(".gz.sha256").write_text(
    f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n"
)

for platform in ("launchd", "systemd"):
    home = root / f"service-{platform}"
    home.mkdir(mode=0o700)
    bin_dir = home / "bin with spaces"
    bin_dir.mkdir()
    binary = bin_dir / "zc"
    shutil.copyfile(fixture, binary)
    binary.chmod(0o700)
    # Old bytes must differ, but both versions remain real executable candidates.
    if sys.platform == "darwin":
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                "org.zc.test.old-release",
                binary,
            ],
            check=True,
            capture_output=True,
        )
    else:
        with binary.open("ab") as file:
            file.write(b"zc-old-release-test")
    old_bytes = binary.read_bytes()
    assert old_bytes != fixture.read_bytes()
    config = home / "source.yaml"
    config.write_text("rules: ['MATCH,DIRECT']\n")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    assert port != 7899
    env = dict(
        os.environ,
        HOME=str(home),
        ZC_SERVICE_TEST_CHILD=platform,
        ZC_INSTALL_DIR=str(bin_dir),
        ZC_VERSION=f"v{version}",
        ZC_RELEASE_BASE_URL=release.parent.as_uri(),
    )
    env.pop("XDG_RUNTIME_DIR", None)

    def service(verb, *args):
        result = subprocess.run(
            [binary, "--fixture-service", verb, *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=25,
        )
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def install():
        with (repo / "install.sh").open("rb") as stdin:
            return subprocess.run(
                ["/bin/sh"],
                stdin=stdin,
                env=env,
                cwd=home,
                capture_output=True,
                text=True,
                timeout=45,
            )

    def assert_state(running, enabled):
        state = service("status")
        assert state["running"] == running and state["enabled"] == enabled, state
        assert state["configured_port"] == port, state
        if running:
            assert state["mixed_port"] == port, state
        return state

    try:
        service("enable", str(config), str(port))
        config.unlink()  # Restoration must use the frozen invocation, not source.
        for running in (False, True):
            for enabled in (False, True):
                service("enable" if enabled else "disable")
                if running:
                    service("start")
                before = assert_state(running, enabled)
                result = install()
                assert result.returncode == 0, result.stderr
                assert binary.read_bytes() == fixture.read_bytes()
                after = assert_state(running, enabled)
                if running:
                    assert before["pid"] != after["pid"]
                else:
                    assert after["pid"] is None
                assert not (bin_dir / ".zc.install.lock").exists()
                service("stop")
                binary.write_bytes(old_bytes)
                print(
                    f"ROOT_SERVICE_STATE={platform} running={running} enabled={enabled} PASS"
                )
                if running:
                    service("start")
                hook = home / "fail-publish.sh"
                hook.write_text("#!/bin/sh\nexit 9\n")
                hook.chmod(0o700)
                env["ZC_INSTALL_BEFORE_PROMOTE_HOOK"] = str(hook)
                result = install()
                del env["ZC_INSTALL_BEFORE_PROMOTE_HOOK"]
                assert result.returncode != 0 and "ROLLED_BACK" in result.stderr, result
                assert binary.read_bytes() == old_bytes
                assert_state(running, enabled)
                service("stop")
                print(
                    f"ROOT_SERVICE_PUBLISH_ROLLBACK={platform} running={running} enabled={enabled} PASS"
                )
        # Candidate check failure precedes stop and leaves the exact old PID.
        before = service("start")
        broken = home / "bad-releases" / f"v{version}"
        broken.mkdir(parents=True)
        legacy = home / "legacy"
        legacy.write_text(f"#!/bin/sh\necho 'zc {version}'\n")
        legacy.chmod(0o700)
        bad_archive = broken / archive.name
        with tarfile.open(bad_archive, "w:gz") as tar:
            tar.add(legacy, arcname=f"{package}/zc")
        bad_archive.with_suffix(".gz.sha256").write_text(
            f"{hashlib.sha256(bad_archive.read_bytes()).hexdigest()}  {archive.name}\n"
        )
        env["ZC_RELEASE_BASE_URL"] = broken.parent.as_uri()
        result = install()
        env["ZC_RELEASE_BASE_URL"] = release.parent.as_uri()
        assert result.returncode != 0 and "ZC_VERSION" in result.stderr, result
        assert binary.read_bytes() == old_bytes
        assert assert_state(True, True)["pid"] == before["pid"]
        print(f"ROOT_SERVICE_LEGACY_UNSUPPORTED_PRESERVES_PID={platform} PASS")
        # Real activation failure restores different old executable bytes.
        (home / "fail-start-once").touch()
        result = install()
        assert result.returncode != 0 and "ROLLED_BACK" in result.stderr, result
        assert binary.read_bytes() == old_bytes
        after = assert_state(True, True)
        assert after["pid"] != before["pid"]
        print(f"ROOT_SERVICE_ACTIVATION_ROLLBACK={platform} PASS")
        # Signals at the handoff's real manager stop, including recovery overlap.
        for sig in (signal.SIGINT, signal.SIGTERM):
            (home / "pause-post-stop").touch()
            for name in ("entered", "release", "late-publication"):
                (home / name).unlink(missing_ok=True)
            with (
                (repo / "install.sh").open("rb") as stdin,
                (home / "output").open("wb") as output,
            ):
                child = subprocess.Popen(
                    ["/bin/sh"],
                    stdin=stdin,
                    env=env,
                    cwd=home,
                    stdout=output,
                    stderr=output,
                )
                try:
                    deadline = time.monotonic() + 20
                    while not (home / "entered").exists():
                        assert child.poll() is None, (home / "output").read_text()
                        assert time.monotonic() < deadline
                        time.sleep(0.01)
                    child.send_signal(sig)
                    time.sleep(0.03)
                    child.send_signal(sig)
                    assert child.wait(timeout=25) != 0
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
            message = (home / "output").read_text()
            assert "INTERRUPTED" in message and "ROLLED_BACK" in message, message
            assert binary.read_bytes() == old_bytes
            assert_state(True, True)
            assert not (bin_dir / ".zc.install.lock").exists()
            (home / "release").touch()
            time.sleep(0.2)
            assert not (home / "late-publication").exists()
            print(
                f"ROOT_SERVICE_SIGNAL={platform} {sig.name} recovered/no-late-publication PASS"
            )
        service("stop")
    finally:
        subprocess.run(
            [
                "/usr/bin/python3",
                repo / "tests/support/service_manager.py",
                home,
                platform,
                "test-cleanup",
            ],
            env=env,
            check=True,
        )

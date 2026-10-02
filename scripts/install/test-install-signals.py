"""Interrupt the stdin release installer; only temporary binaries/HOME are used."""

import os
import pathlib
import signal
import subprocess
import sys
import time

installer, releases, candidate, root = (
    pathlib.Path(arg).resolve() for arg in sys.argv[1:3] + sys.argv[4:]
)
version = sys.argv[3]
root.mkdir(parents=True, exist_ok=True)
for sig in (signal.SIGINT, signal.SIGTERM):
    home = root / sig.name
    home.mkdir(mode=0o700)
    target = home / "bin"
    target.mkdir()
    old = b"#!/bin/sh\necho old-signal-sentinel\n"
    binary = target / "zc"
    binary.write_bytes(old)
    binary.chmod(0o700)
    hook = home / "hook.sh"
    hook.write_text("""#!/bin/bash
set -eu
# The publisher is embedded, private and bounded, not read from the checkout.
for script in "$HOME"/bin/.zc.publisher.*; do
  test -f "$script"
  test "$(wc -c < "$script")" -lt 65537
  ls -l "$script" > "$HOME/publisher-mode"
done
(
  touch "$HOME/entered"
  while [ ! -e "$HOME/release" ]; do sleep .01; done
  touch "$HOME/late-publication"
) &
wait
""")
    hook.chmod(0o700)
    env = dict(
        os.environ,
        HOME=str(home),
        ZC_INSTALL_DIR=str(target),
        ZC_VERSION=str(version),
        ZC_RELEASE_BASE_URL=releases.as_uri(),
        ZC_INSTALL_BEFORE_PROMOTE_HOOK=str(hook),
    )
    env.pop("XDG_RUNTIME_DIR", None)
    with installer.open("rb") as stdin, (home / "output").open("wb") as output:
        child = subprocess.Popen(
            ["/bin/sh"], stdin=stdin, stdout=output, stderr=output, cwd=home, env=env
        )
        try:
            deadline = time.monotonic() + 20
            while not (home / "entered").exists():
                assert child.poll() is None, (home / "output").read_text()
                assert time.monotonic() < deadline, "handoff barrier not reached"
                time.sleep(0.01)
            assert (target / ".zc.install.lock").is_dir()
            assert (home / "publisher-mode").read_text().startswith("-rw-------")
            child.send_signal(sig)
            # Repeated signals must leave the original cleanup/recovery alive.
            child.send_signal(signal.SIGTERM)
            assert child.wait(timeout=20) != 0
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    output = (home / "output").read_text()
    assert "INTERRUPTED" in output and "ROLLED_BACK" in output, output
    assert binary.read_bytes() == old
    assert not (target / ".zc.install.lock").exists()
    assert not list(target.glob(".zc.publisher.*"))
    assert not list(target.glob(".zc.candidate.*"))
    assert not list(target.glob(".zc.recovery.*"))
    (home / "release").touch()
    time.sleep(0.2)
    assert not (home / "late-publication").exists(), "late publication after shell exit"
    assert binary.read_bytes() == old
    print(f"INSTALLER_{sig.name}_JOINED_RECOVERY=PASS")

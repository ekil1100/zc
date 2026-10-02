"""Exercise release preflight deadlines and shell-only cancellation via stdin."""

import hashlib
import io
import os
from pathlib import Path
import platform
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallChecks(unittest.TestCase):
    def exercise(self, check, sig):
        with tempfile.TemporaryDirectory(prefix="zc-check-") as directory:
            root = Path(directory).resolve()
            target = root / "bin"
            target.mkdir()
            old = b"old-installation\n"
            (target / "zc").write_bytes(old)
            package = "zc-v1.2.3-{}-{}".format(
                "macos" if platform.system() == "Darwin" else "linux",
                "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64",
            )
            release = root / "releases" / "v1.2.3"
            release.mkdir(parents=True)
            # Ignore graceful termination to exercise forced cleanup. The check
            # creates a descendant so group cleanup, not just parent exit, matters.
            source = f'''#!/bin/bash
if [ "$1" = "{check}" ]; then
  trap '' INT TERM
  echo $$ > "$HOME/check-pid"
  echo $PPID > "$HOME/supervisor-pid"
  sleep 60 &
  echo $! > "$HOME/descendant-pid"
  touch "$HOME/entered"
  wait
  touch "$HOME/late-check"
fi
case "$1" in
  --version) echo 'zc 1.2.3' ;;
  --install-check) echo zc-release-install-v1 ;;
  --local-install) touch "$HOME/published"; echo changed > "$3/zc" ;;
esac
'''.encode()
            archive = release / f"{package}.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                member = tarfile.TarInfo(f"{package}/zc")
                member.mode = 0o700
                member.size = len(source)
                output.addfile(member, io.BytesIO(source))
            archive.with_suffix(".gz.sha256").write_text(
                f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n"
            )
            env = dict(
                os.environ,
                HOME=str(root),
                TMPDIR=str(root),
                ZC_VERSION="v1.2.3",
                ZC_INSTALL_DIR=str(target),
                ZC_RELEASE_BASE_URL=(root / "releases").as_uri(),
            )
            with (
                (ROOT / "install.sh").open("rb") as stdin,
                (root / "output").open("wb") as output,
            ):
                child = subprocess.Popen(
                    ["/bin/sh"],
                    stdin=stdin,
                    stdout=output,
                    stderr=output,
                    env=env,
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 5
                    while not (root / "entered").exists():
                        self.assertIsNone(child.poll(), (root / "output").read_text())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                    if sig:
                        child.send_signal(sig)
                    try:
                        status = child.wait(timeout=5 if sig else 20)
                    except subprocess.TimeoutExpired:
                        self.fail(f"{check} did not stop after {sig or 'deadline'}")
                    self.assertEqual(status, 128 + sig if sig else 1)
                    self.assertEqual((target / "zc").read_bytes(), old)
                    self.assertEqual(list(target.iterdir()), [target / "zc"])
                    for name in ("supervisor-pid", "check-pid", "descendant-pid"):
                        pid = int((root / name).read_text())
                        # A reparented zombie is terminated; direct children must
                        # have been waited before the installer exits.
                        probe = subprocess.run(
                            ["ps", "-o", "stat=", "-p", str(pid)],
                            capture_output=True,
                            text=True,
                        )
                        self.assertTrue(
                            not probe.stdout.strip()
                            or (
                                name == "descendant-pid"
                                and probe.stdout.strip().startswith("Z")
                            ),
                            probe.stdout,
                        )
                    time.sleep(0.2)
                    self.assertFalse((root / "published").exists())
                    self.assertFalse((root / "late-check").exists())
                    self.assertFalse(list(root.glob("zc-install.*")))
                    if not sig:
                        self.assertIn("timed out", (root / "output").read_text())
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    for name in ("check-pid", "descendant-pid"):
                        if (root / name).exists():
                            try:
                                os.kill(int((root / name).read_text()), signal.SIGKILL)
                            except ProcessLookupError:
                                pass

    def test_stalled_checks(self):
        for check in ("--version", "--install-check"):
            for sig in (None, signal.SIGINT, signal.SIGTERM):
                with self.subTest(check=check, signal=sig):
                    self.exercise(check, sig)


if __name__ == "__main__":
    unittest.main()

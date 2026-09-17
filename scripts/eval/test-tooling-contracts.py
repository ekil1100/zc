#!/usr/bin/env python3
"""Tooling process-boundary contracts; all packaging outputs stay in a temp tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Tooling(unittest.TestCase):
    def test_deb_uses_cargo_package_version_and_release_binary(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/build-deb.sh", root / "scripts/build-deb.sh")
            shutil.copy(ROOT / "Cargo.toml", root / "Cargo.toml")
            bin_dir = root / "mock-bin"
            bin_dir.mkdir()
            programs = {
                "cargo": '#!/bin/sh\n[ "$*" = "build --locked --release --bin zc --target-dir target" ] || exit 91\nmkdir -p target/release\nprintf "rust-release" > target/release/zc\n',
                "dpkg": '#!/bin/sh\nprintf "arm64\\n"\n',
                "dpkg-deb": '#!/bin/sh\n[ "$1" = "--build" ] || exit 92\nprintf "package" > "$2.deb"\n',
                "uname": '#!/bin/sh\nprintf "Linux\\n"\n',
                "zig": '#!/bin/sh\nexit 93\n',
            }
            for name, text in programs.items():
                (bin_dir / name).write_text(text)
                (bin_dir / name).chmod(0o755)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
            result = subprocess.run(["bash", root / "scripts/build-deb.sh"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            version = next(line.split('"')[1] for line in (ROOT / "Cargo.toml").read_text().splitlines() if line.startswith("version ="))
            self.assertTrue((root / f"dist/zc_{version}_arm64.deb").is_file())
            staged = root / f"build-deb/zc-{version}"
            self.assertEqual((staged / "usr/bin/zc").read_text(), "rust-release")
            self.assertIn("in Rust", (staged / "DEBIAN/control").read_text())

    def test_formal_recorder_refuses_dirty_tree_without_artifact(self):
        dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)
        if not dirty:
            self.skipTest("dirty-worktree guard requires a dirty candidate")
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "formal.json"
            result = subprocess.run(["bash", ROOT / "scripts/perf/run-control-plane-baseline.sh", "--output", output], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("dirty worktree", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

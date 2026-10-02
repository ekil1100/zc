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
                "zig": "#!/bin/sh\nexit 93\n",
            }
            for name, text in programs.items():
                (bin_dir / name).write_text(text)
                (bin_dir / name).chmod(0o755)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
            result = subprocess.run(
                ["bash", root / "scripts/build-deb.sh"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            version = next(
                line.split('"')[1]
                for line in (ROOT / "Cargo.toml").read_text().splitlines()
                if line.startswith("version =")
            )
            self.assertTrue((root / f"dist/zc_{version}_arm64.deb").is_file())
            staged = root / f"build-deb/zc-{version}"
            self.assertEqual((staged / "usr/bin/zc").read_text(), "rust-release")
            self.assertIn("in Rust", (staged / "DEBIAN/control").read_text())

    def test_formal_recorder_protects_docs_and_archives_after_resolving_paths(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work).resolve()
            root = work / "repo"
            script = root / "scripts/perf/run-control-plane-baseline.sh"
            script.parent.mkdir(parents=True)
            shutil.copy(ROOT / "scripts/perf/run-control-plane-baseline.sh", script)
            (root / ".gitignore").write_text("/target/\n")
            (root / "target").mkdir()
            for directory in ("docs", ".agents"):
                archive = root / directory / "reports"
                archive.mkdir(parents=True)
                (archive / "history.json").write_text("preserved evidence\n")
            (root / "docs-alias").symlink_to("docs", target_is_directory=True)
            (root / "archive-alias").symlink_to(".agents", target_is_directory=True)
            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GIT_")
            }
            for command in (
                ["init", "-q"],
                ["add", "."],
                [
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "fixture",
                ],
            ):
                subprocess.run(["git", *command], cwd=root, env=env, check=True)
            bin_dir = work / "bin"
            bin_dir.mkdir()
            cargo = bin_dir / "cargo"
            cargo.write_text("#!/bin/sh\necho BUILD_BOUNDARY_REACHED >&2\nexit 91\n")
            cargo.chmod(0o755)
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            denied = [
                "docs/reports/history.json",
                ".agents/reports/history.json",
                "target/../docs/reports/history.json",
                "target/../.agents/reports/history.json",
                "docs-alias/reports/history.json",
                "archive-alias/reports/history.json",
                str(root / ".agents/reports/history.json"),
            ]
            for alias, original in (("Docs", "docs"), (".AGENTS", ".agents")):
                if (root / alias).exists() and (root / alias).samefile(root / original):
                    denied.append(f"{alias}/reports/history.json")
            allowed = [
                "target/perf/new/report.json",
                str(work / "external/report.json"),
            ]
            for output in denied + allowed:
                with self.subTest(output=output):
                    result = subprocess.run(
                        ["bash", script, "--output", output],
                        cwd=root,
                        env=env,
                        capture_output=True,
                        text=True,
                    )
                    if output in denied:
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn("refusing to overwrite", result.stderr)
                        self.assertNotIn("BUILD_BOUNDARY_REACHED", result.stderr)
                    else:
                        self.assertEqual(result.returncode, 91, result.stderr)
                        self.assertIn("BUILD_BOUNDARY_REACHED", result.stderr)
                        self.assertFalse((root / output).exists())
                    for directory in ("docs", ".agents"):
                        self.assertEqual(
                            (root / directory / "reports/history.json").read_text(),
                            "preserved evidence\n",
                        )
            self.assertEqual(
                subprocess.check_output(
                    ["git", "status", "--porcelain"], cwd=root, env=env
                ),
                b"",
            )

    def test_python_recorders_refuse_archive_aliases_before_measurement(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work).resolve()
            for directory in ("docs", ".agents", "target"):
                (root / directory).mkdir()
            for directory in ("docs", ".agents"):
                (root / directory / "history.json").write_text("preserved evidence\n")
            (root / "docs-alias").symlink_to("docs", target_is_directory=True)
            (root / "archive-alias").symlink_to(".agents", target_is_directory=True)
            denied = [
                "docs/history.json",
                ".agents/history.json",
                "target/../docs/history.json",
                "target/../.agents/history.json",
                "docs-alias/history.json",
                "archive-alias/history.json",
            ]
            for alias, original in (("Docs", "docs"), (".AGENTS", ".agents")):
                if (root / alias).exists() and (root / alias).samefile(root / original):
                    denied.append(f"{alias}/history.json")
            for name, args, message in (
                ("scripts/perf/compare-runtimes.py", [], "must not overwrite"),
                (
                    "scripts/reliability/soak.py",
                    ["--seconds", "1", "--port", "17890"],
                    "write exploratory output",
                ),
            ):
                script = root / name
                script.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / name, script)
                for output in denied:
                    with self.subTest(script=name, output=output):
                        result = subprocess.run(
                            ["python3", script, *args, "--output", output],
                            cwd=root,
                            capture_output=True,
                            text=True,
                        )
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn(message, result.stderr)
                        for directory in ("docs", ".agents"):
                            self.assertEqual(
                                (root / directory / "history.json").read_text(),
                                "preserved evidence\n",
                            )

    def test_formal_recorder_refuses_dirty_tree_without_artifact(self):
        dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)
        if not dirty:
            self.skipTest("dirty-worktree guard requires a dirty candidate")
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "formal.json"
            result = subprocess.run(
                [
                    "bash",
                    ROOT / "scripts/perf/run-control-plane-baseline.sh",
                    "--output",
                    output,
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("dirty worktree", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

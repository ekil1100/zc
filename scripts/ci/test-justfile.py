#!/usr/bin/env python3
"""Check the public task-runner contract without building or starting a daemon."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class JustfileContract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="zc-just-")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.log = self.work / "commands.jsonl"
        tools = self.work / "bin"
        tools.mkdir()
        recorder = tools / "recorder"
        recorder.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "with open(os.environ['ZC_JUST_TEST_LOG'], 'a') as output:\n"
            "    output.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')\n"
            "sys.exit(int(os.environ.get('ZC_JUST_TEST_EXIT', '0')))\n"
        )
        recorder.chmod(0o755)
        for tool in ["cargo", "zig"]:
            (tools / tool).symlink_to(recorder)
        self.env = dict(os.environ, PATH=f"{tools}{os.pathsep}{os.environ['PATH']}", ZC_JUST_TEST_LOG=str(self.log))

    def just(self, *args, dry_run=False):
        command = ["just", "--justfile", str(ROOT / "Justfile"), "--working-directory", str(self.work)]
        if dry_run:
            command.append("--dry-run")
        return subprocess.run([*command, "--", *args], env=self.env, text=True, capture_output=True, timeout=10)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_build_defaults_to_locked_rust(self):
        result = self.just("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["cargo", "build", "--locked"]])

    def test_rust_checks_and_release_use_cargo(self):
        for recipe, expected in [
            ("release", [["cargo", "build", "--locked", "--release"]]),
            ("fmt", [["cargo", "fmt", "--all"]]),
            ("check", [["cargo", "fmt", "--all", "--", "--check"], ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"]]),
        ]:
            with self.subTest(recipe=recipe):
                self.log.write_text("")
                result = self.just(recipe)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls(), expected)

    def test_extra_cargo_arguments_preserve_word_boundaries(self):
        result = self.just("build", "--release", "--target-dir", "build output")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["cargo", "build", "--locked", "--release", "--target-dir", "build output"]])
        self.log.write_text("")
        result = self.just("test", "--test", "cli", "--", "--nocapture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["cargo", "test", "--locked", "--test", "cli", "--", "--nocapture"]])

    def test_run_defaults_to_foreground_and_nonproduction_port(self):
        result = self.just("run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["cargo", "run", "--locked", "--", "start", "--config", "testdata/config/rust-tcp.yaml", "--port", "17890", "--foreground"]])

    def test_run_parameters_are_literal_and_production_port_is_rejected(self):
        marker = self.work / "injected"
        config = f"config with spaces'; touch {marker}; echo '$(touch {marker}).yaml"
        result = self.just("run", config, "17891")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["cargo", "run", "--locked", "--", "start", "--config", config, "--port", "17891", "--foreground"]])
        self.assertFalse(marker.exists())
        self.log.write_text("")
        for reserved in ["7899", "07899", "+7899", "+007899"]:
            result = self.just("run", "config.yaml", reserved)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("reserved for production", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_zig_commands_are_explicit_and_retired_entries_are_removed(self):
        for recipe, arguments in [
            ("zig-build", ["build", "-Dcpu=baseline"]),
            ("zig-test", ["build", "test", "-Dcpu=baseline"]),
            ("zig-e2e", ["build", "e2e", "--summary", "all"]),
        ]:
            self.log.write_text("")
            result = self.just(recipe)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.calls(), [["zig", *arguments]])
        for recipe in ["install", "rust-build", "rust-test", "rust-check", "rust-e2e", "eval", "beta-gate", "soak"]:
            result = self.just(recipe, dry_run=True)
            self.assertNotEqual(result.returncode, 0, recipe)

    def test_validate_contains_rust_checks_and_independent_e2e_only(self):
        result = self.just("validate", dry_run=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ["cargo fmt", "cargo clippy", "cargo test --locked", "cargo build --locked", "scripts/e2e/fetch-static-fixtures.sh", "scripts/e2e/run-rust-tcp.py"]:
            self.assertIn(command, result.stderr)
        for forbidden in ["zig build", "local-dev-install", "run-full-validation", "7899"]:
            self.assertNotIn(forbidden, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_ci_keeps_rust_and_zig_tasks_separate(self):
        rust = (ROOT / ".github/workflows/rust.yml").read_text()
        for recipe in ["check", "test", "e2e"]:
            self.assertIn(f"run: just {recipe}\n", rust)
        self.assertIn("RUSTUP_TOOLCHAIN: 1.98.1", rust)
        self.assertIn("python3 scripts/ci/test-justfile.py", rust)
        self.assertEqual(rust.count("- 'Justfile'"), 2)
        self.assertEqual(rust.count("- 'scripts/ci/test-justfile.py'"), 2)
        zig = (ROOT / ".github/workflows/ci.yml").read_text()
        for recipe in ["zig-build", "zig-test", "zig-migrator-test", "zig-install-test", "zig-eval-selfcheck"]:
            self.assertIn(f"run: just {recipe}\n", zig)
        self.assertNotIn("run: just build\n", zig)
        self.assertNotIn("run: just test\n", zig)

    def test_task_failure_is_not_hidden(self):
        self.env["ZC_JUST_TEST_EXIT"] = "7"
        result = self.just("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["cargo", "fmt", "--all", "--", "--check"]])


if __name__ == "__main__":
    unittest.main()

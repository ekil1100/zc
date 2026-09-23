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

    def prepare_install(self):
        scripts = self.work / "scripts" / "install"
        scripts.mkdir(parents=True)
        (scripts / "local-dev-install.sh").write_bytes((ROOT / "scripts/install/local-dev-install.sh").read_bytes())
        release = self.work / "target" / "release"
        release.mkdir(parents=True)
        binary = release / "zc"
        binary.write_text("#!/bin/sh\necho rust-release-source\n")
        binary.chmod(0o755)
        home = self.work / "home"
        home.mkdir(mode=0o700)
        self.env["HOME"] = str(home)
        return home, binary

    def test_install_builds_release_and_installs_in_isolated_home(self):
        home, binary = self.prepare_install()
        result = self.just("install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["cargo", "build", "--locked", "--release"]])
        installed = home / ".local" / "bin" / "zc"
        self.assertEqual(installed.read_bytes(), binary.read_bytes())
        probe = subprocess.run([str(installed), "--version"], text=True, capture_output=True, timeout=5)
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertEqual(probe.stdout, "rust-release-source\n")

    def test_install_target_arguments_are_literal_and_leave_default_untouched(self):
        home, binary = self.prepare_install()
        destination = self.work / "bin with spaces; $(touch injected)"
        result = self.just("install", "--target-dir", str(destination))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "zc").read_bytes(), binary.read_bytes())
        self.assertFalse((home / ".local").exists())
        self.assertFalse((self.work / "injected").exists())

    def test_install_build_failure_preserves_existing_binary(self):
        home, _ = self.prepare_install()
        target = home / ".local" / "bin" / "zc"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"previous-installation\n")
        self.env["ZC_JUST_TEST_EXIT"] = "7"
        result = self.just("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["cargo", "build", "--locked", "--release"]])
        self.assertEqual(target.read_bytes(), b"previous-installation\n")
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_install_propagates_unsafe_target_refusal(self):
        home, _ = self.prepare_install()
        target = home / ".local" / "bin" / "zc"
        target.parent.mkdir(parents=True)
        original = self.work / "original"
        original.write_bytes(b"previous-installation\n")
        target.symlink_to(original)
        result = self.just("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link", result.stderr)
        self.assertTrue(target.is_symlink())
        self.assertEqual(original.read_bytes(), b"previous-installation\n")

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
        for recipe in ["rust-build", "rust-test", "rust-check", "rust-e2e", "eval", "beta-gate", "soak"]:
            result = self.just(recipe, dry_run=True)
            self.assertNotEqual(result.returncode, 0, recipe)

    def test_validate_contains_rust_checks_and_independent_e2e_only(self):
        result = self.just("validate", dry_run=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ["cargo fmt", "cargo clippy", "cargo test --locked", "cargo build --locked", "scripts/e2e/fetch-static-fixtures.sh", "scripts/e2e/run-rust-tcp.py", "scripts/e2e/run-core.sh", "cargo build --locked --examples", "examples/support/test-helpers.py", "scripts/install/test-oneline-installer.sh", "cargo build --locked --release"]:
            self.assertIn(command, result.stderr)
        for forbidden in ["zig build", "local-dev-install", "run-full-validation", "7899"]:
            self.assertNotIn(forbidden, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_ci_requires_full_rust_delivery_matrix(self):
        rust = (ROOT / ".github/workflows/rust.yml").read_text()
        self.assertIn("uses: ./.github/workflows/ci.yml", rust)
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        for recipe in ["check", "test", "delivery-test", "e2e", "install-test"]:
            self.assertIn(f"run: just {recipe}\n", ci)
        for platform in ["ubuntu-latest", "ubuntu-24.04-arm", "macos-latest", "macos-15-intel"]:
            self.assertIn(platform, ci)
        self.assertIn("RUSTUP_TOOLCHAIN: 1.98.1", ci)
        self.assertIn("actions/setup-node@", ci)
        self.assertNotIn("Setup Zig", ci)
        self.assertNotIn("zig build", ci)

    def test_delivery_gates_propagate_failures_without_zig(self):
        repo = self.work / "repo"
        scripts = repo / "scripts"
        scripts.mkdir(parents=True)
        for name in ["run-beta-gate.sh", "run-full-validation.sh"]:
            (scripts / name).write_text((ROOT / "scripts" / name).read_text())
        tool = self.work / "bin" / "just"
        tool.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$ZC_GATE_LOG\"\n[[ $1 != ${ZC_FAIL_GATE:-test} ]]\n")
        tool.chmod(0o755)
        self.env["ZC_GATE_LOG"] = str(self.work / "gates.log")
        for name, marker in [("run-beta-gate.sh", "BETA_GATE"), ("run-full-validation.sh", "VALIDATION")]:
            result = subprocess.run(["bash", str(scripts / name)], env=self.env, text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(f"{marker}_RESULT=FAIL", result.stdout)
            self.assertIn("test", result.stdout)
            self.assertIn(f"{marker}_PASS=5/6", result.stdout)
            calls = Path(self.env["ZC_GATE_LOG"]).read_text().splitlines()
            self.assertCountEqual(calls, ["release", "check", "test", "delivery-test", "e2e", "install-test"])
            Path(self.env["ZC_GATE_LOG"]).write_text("")
            result = subprocess.run(["bash", str(scripts / name)], env=dict(self.env, ZC_FAIL_GATE="none"), text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn(f"{marker}_RESULT=PASS", result.stdout)
            self.assertIn(f"{marker}_PASS=6/6", result.stdout)
            Path(self.env["ZC_GATE_LOG"]).write_text("")
        self.assertEqual(self.calls(), [])

    def test_local_installer_defaults_to_rust_release_in_isolated_home(self):
        repo = self.work / "installer-repo"
        scripts = repo / "scripts" / "install"
        scripts.mkdir(parents=True)
        installer = scripts / "local-dev-install.sh"
        installer.write_text((ROOT / "scripts/install/local-dev-install.sh").read_text())
        release = repo / "target" / "release"
        release.mkdir(parents=True)
        binary = release / "zc"
        binary.write_text("#!/bin/sh\necho rust-release-source\n")
        binary.chmod(0o755)
        home = self.work / "home"
        home.mkdir(mode=0o700)
        result = subprocess.run(["bash", str(installer)], env=dict(self.env, HOME=str(home)), text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = home / ".local" / "bin" / "zc"
        self.assertEqual(installed.read_bytes(), binary.read_bytes())
        self.assertEqual(list(installed.parent.iterdir()), [installed])

    def test_task_failure_is_not_hidden(self):
        self.env["ZC_JUST_TEST_EXIT"] = "7"
        result = self.just("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["cargo", "fmt", "--all", "--", "--check"]])


if __name__ == "__main__":
    unittest.main()

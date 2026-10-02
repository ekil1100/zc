#!/usr/bin/env python3
"""Exercise the format hook through real commits in isolated repositories."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".pre-commit-config.yaml"
FORMATTED = 'fn main() {\n    println!("hello");\n}\n'
UNFORMATTED = 'fn main(){println!("hello");}\n'


class FormatHookTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zc-format-hook-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith("GIT_"):
                self.env.pop(key)
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"
        self.env["GIT_CONFIG_GLOBAL"] = os.devnull
        self.git("init", "-q")
        self.git("config", "user.name", "Hook Test")
        self.git("config", "user.email", "hook-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.root / ".pre-commit-config.yaml").write_text(CONFIG.read_text())
        (self.root / "ruff.toml").write_text((ROOT / "ruff.toml").read_text())
        subprocess.run(
            ["pre-commit", "install"],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        (self.root / "src").mkdir()
        (self.root / "Cargo.toml").write_text(
            '[package]\nname = "format-hook-fixture"\nversion = "0.1.0"\nedition = "2024"\n'
        )
        self.source = self.root / "src/main.rs"

    def git(self, *args, check=True):
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=check,
            timeout=30,
        )

    def stage(self, text):
        self.source.write_text(text)
        self.git(
            "add", ".pre-commit-config.yaml", "ruff.toml", "Cargo.toml", "src/main.rs"
        )

    def test_rejects_unformatted_staged_content_without_mutating_it(self):
        self.stage(UNFORMATTED)
        # A corrected working tree must not conceal unformatted staged content.
        self.source.write_text(FORMATTED)
        before = self.git("write-tree").stdout
        result = self.git("commit", "-m", "test: unformatted", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cargo fmt --all", result.stdout + result.stderr)
        self.assertEqual(self.git("write-tree").stdout, before)
        self.assertEqual(self.source.read_text(), FORMATTED)
        self.assertEqual(self.git("show", ":src/main.rs").stdout, UNFORMATTED)

    def test_rejects_unformatted_python_without_changing_files(self):
        self.stage(FORMATTED)
        (self.root / "scripts").mkdir()
        source = self.root / "scripts/check.py"
        source.write_text("value=1\n")
        self.git("add", "scripts/check.py")
        before = self.git("write-tree").stdout
        result = self.git("commit", "-m", "test: unformatted python", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ruff format", result.stdout + result.stderr)
        self.assertEqual(self.git("write-tree").stdout, before)
        self.assertEqual(source.read_text(), "value=1\n")

    def test_accepts_formatted_index_without_touching_unstaged_edits(self):
        self.stage(FORMATTED)
        self.source.write_text(UNFORMATTED)
        result = self.git("commit", "-m", "test: formatted", check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("show", "HEAD:src/main.rs").stdout, FORMATTED)
        self.assertEqual(self.source.read_text(), UNFORMATTED)


if __name__ == "__main__":
    unittest.main()

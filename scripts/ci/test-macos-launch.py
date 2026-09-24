#!/usr/bin/env python3
"""Assert short CLI commands do not eagerly initialize native network frameworks."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORKS = (
    "CoreFoundation.framework/",
    "Security.framework/",
    "SystemConfiguration.framework/",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    artifact = args.artifact.resolve(strict=True)
    version = re.search(
        r'^version = "([^"]+)"$', (ROOT / "Cargo.toml").read_text(), re.M
    )[1]
    with tempfile.TemporaryDirectory(prefix="zc-macos-launch-") as temporary:
        directory = Path(temporary).resolve()
        env = {"PATH": "/usr/bin:/bin", "DYLD_PRINT_INITIALIZERS": "1"}
        for key in (
            "HOME",
            "TMPDIR",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_STATE_HOME",
            "XDG_CACHE_HOME",
            "XDG_RUNTIME_DIR",
            "XDG_CONFIG_DIRS",
            "XDG_DATA_DIRS",
        ):
            path = directory / key
            path.mkdir(mode=0o700)
            env[key] = str(path)
        empty = directory / "empty-certs"
        empty.mkdir(mode=0o700)
        # These commands must not enumerate trust or query DNS, even on failure paths.
        env["SSL_CERT_DIR"] = str(empty)
        fixture = directory / "config.yaml"
        fixture.write_text("mixed-port: 18080\nrules: ['MATCH,DIRECT']\n")
        commands = [
            ["--version"],
            ["--help"],
            ["config", "dump", "-c", str(fixture), "--no-override", "--json"],
        ]
        for command in commands:
            result = subprocess.run(
                [str(artifact), *command],
                env=env,
                cwd=directory,
                capture_output=True,
                text=True,
                timeout=15,
                check=True,
            )
            initializers = [
                line
                for line in result.stderr.splitlines()
                if "running initializer" in line.lower()
            ]
            if not initializers:
                raise RuntimeError(
                    "missing dyld initializer trace; cannot verify delayed startup"
                )
            if any(
                framework in line for line in initializers for framework in FRAMEWORKS
            ):
                raise RuntimeError(
                    f"{command[0]} eagerly initialized a network framework"
                )
            if command[0] == "--version" and result.stdout != f"zc {version}\n":
                raise RuntimeError("unexpected version output")
            if command[0] == "--help" and not result.stdout.strip():
                raise RuntimeError("empty help output")
            if command[0] == "config" and json.loads(result.stdout)["rules"] != [
                "MATCH,DIRECT"
            ]:
                raise RuntimeError("dump lost the literal fixture rule")
            print(
                f"PASS cold {command[0]}: {len(initializers)} initializers, no native network framework"
            )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

"""Admit a release from exact-commit main CI evidence and emit its build matrix."""

import argparse
import json
from pathlib import Path
import re
import sys

# This one candidate has an explicitly approved Linux-only publication scope.
# Future candidates and stable releases retain the complete platform gate.
LINUX_ONLY_TAG = "v1.1.0-rc1"
LINUX = [
    {
        "os": "ubuntu-latest",
        "target_os": "linux",
        "target_arch": "amd64",
        "rust_target": "x86_64-unknown-linux-musl",
    },
    {
        "os": "ubuntu-24.04-arm",
        "target_os": "linux",
        "target_arch": "arm64",
        "rust_target": "aarch64-unknown-linux-musl",
    },
]
MACOS = [
    {
        "os": "macos-latest",
        "target_os": "macos",
        "target_arch": "arm64",
        "rust_target": "aarch64-apple-darwin",
    },
    {
        "os": "macos-15-intel",
        "target_os": "macos",
        "target_arch": "amd64",
        "rust_target": "x86_64-apple-darwin",
    },
]
CHECKS = [
    "Format and lint",
    "Test public interfaces",
    "Validate delivery contracts",
    "Validate beta gate contract",
    "Independent core and TCP interoperability",
    "Isolated installer regression",
    "Build production artifact",
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--jobs", type=Path, required=True)
    args = parser.parse_args()
    require(
        re.fullmatch(
            r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc(0|[1-9][0-9]*))?",
            args.tag,
        ),
        "Invalid release tag",
    )
    require(re.fullmatch(r"[0-9a-f]{40}", args.sha), "Invalid commit SHA")
    run = json.loads(args.run.read_text())
    require(isinstance(run, dict), "No main CI run found")
    require(
        run.get("head_sha") == args.sha
        and run.get("head_branch") == "main"
        and run.get("event") == "push"
        and run.get("path") == ".github/workflows/ci.yml",
        "CI must be the exact commit's main push workflow",
    )
    require(type(run.get("id")) is int and run["id"] > 0, "Invalid CI run ID")
    linux_only = args.tag == LINUX_ONLY_TAG
    if not linux_only:
        require(
            run.get("status") == "completed" and run.get("conclusion") == "success",
            "Complete main CI must succeed",
        )
    matrix = LINUX if linux_only else LINUX + MACOS
    required = {"python-check": ["Check Python formatting and lint"]}
    for row in matrix:
        required[f"rust-delivery ({row['os']}, {row['rust_target']})"] = CHECKS + [
            "Verify default runtime port in isolated CI"
            if row["target_os"] == "linux"
            else "Verify native macOS first use in disposable runner"
        ]
    if not linux_only:
        required["rust-delivery (macos-15, aarch64-apple-darwin)"] = CHECKS + [
            "Verify native macOS first use in disposable runner"
        ]
    pages = json.loads(args.jobs.read_text())
    require(isinstance(pages, list), "Expected paginated job evidence")
    jobs = [job for page in pages for job in page["jobs"]]
    for name, checks in required.items():
        matches = [job for job in jobs if job.get("name") == name]
        require(len(matches) == 1, f"Missing or duplicate CI job: {name}")
        job = matches[0]
        require(
            job.get("run_id") == run["id"] and job.get("head_sha") == args.sha,
            f"Unrelated CI job: {name}",
        )
        require(
            job.get("status") == "completed" and job.get("conclusion") == "success",
            f"CI job has not succeeded: {name}",
        )
        for check in checks:
            steps = [s for s in job["steps"] if s.get("name") == check]
            require(
                len(steps) == 1 and steps[0].get("conclusion") == "success",
                f"CI step has not succeeded: {name}: {check}",
            )
    print("matrix=" + json.dumps({"include": matrix}, separators=(",", ":")))
    print(
        f"Verified main CI run {run['id']} for {args.tag}: {'Linux only' if linux_only else 'all platforms'}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Release admission failed: {error}", file=sys.stderr)
        sys.exit(1)

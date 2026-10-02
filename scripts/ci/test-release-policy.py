"""Exercise the release admission CLI with GitHub API response fixtures."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHA = "a" * 40
LINUX = [
    "rust-delivery (ubuntu-latest, x86_64-unknown-linux-musl)",
    "rust-delivery (ubuntu-24.04-arm, aarch64-unknown-linux-musl)",
]
MACOS = [
    "rust-delivery (macos-15, aarch64-apple-darwin)",
    "rust-delivery (macos-latest, aarch64-apple-darwin)",
    "rust-delivery (macos-15-intel, x86_64-apple-darwin)",
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


class ReleasePolicy(unittest.TestCase):
    def setUp(self):
        self.run = {
            "id": 123,
            "head_sha": SHA,
            "head_branch": "main",
            "event": "push",
            "path": ".github/workflows/ci.yml",
            "status": "completed",
            "conclusion": "success",
        }
        self.jobs = []
        for name in ["python-check", *LINUX, *MACOS]:
            checks = (
                ["Check Python formatting and lint"]
                if name == "python-check"
                else CHECKS
                + [
                    "Verify default runtime port in isolated CI"
                    if name in LINUX
                    else "Verify native macOS first use in disposable runner"
                ]
            )
            self.jobs.append(
                {
                    "run_id": 123,
                    "head_sha": SHA,
                    "name": name,
                    "status": "completed",
                    "conclusion": "success",
                    "steps": [{"name": c, "conclusion": "success"} for c in checks],
                }
            )

    def invoke(self, tag="v1.1.0-rc1", accepted=True):
        with tempfile.TemporaryDirectory() as temp:
            run = Path(temp) / "run.json"
            jobs = Path(temp) / "jobs.json"
            run.write_text(json.dumps(self.run))
            # Match gh api --paginate --slurp, including separate result pages.
            jobs.write_text(
                json.dumps([{"jobs": self.jobs[:2]}, {"jobs": self.jobs[2:]}])
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/ci/release-policy.py"),
                    "--tag",
                    tag,
                    "--sha",
                    SHA,
                    "--run",
                    str(run),
                    "--jobs",
                    str(jobs),
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
        if not accepted:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("matrix=", result.stdout)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout.removeprefix("matrix="))["include"]

    def test_approved_rc_requires_linux_and_python_but_does_not_claim_macos(self):
        self.run.update(status="in_progress", conclusion=None)
        for job in self.jobs[3:]:
            job.update(status="completed", conclusion="failure")
        matrix = self.invoke()
        self.assertEqual(
            {r["rust_target"] for r in matrix},
            {"x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"},
        )
        self.assertEqual(len(matrix), 2)
        self.assertEqual({r["target_os"] for r in matrix}, {"linux"})

    def test_stable_and_other_rc_keep_complete_platform_admission(self):
        for tag in ["v1.1.0", "v1.1.0-rc2", "v2.0.0-rc1"]:
            self.assertEqual(len(self.invoke(tag)), 4)
            self.run["conclusion"] = "failure"
            self.invoke(tag, accepted=False)
            self.run["conclusion"] = "success"
            self.jobs[-1]["conclusion"] = "failure"
            self.invoke(tag, accepted=False)
            self.jobs[-1]["conclusion"] = "success"

    def test_missing_failed_pending_skipped_or_duplicate_required_jobs_reject(self):
        original = copy.deepcopy(self.jobs)
        for index in range(3):
            for conclusion in ["failure", "cancelled", "skipped", None]:
                self.jobs = copy.deepcopy(original)
                self.jobs[index]["conclusion"] = conclusion
                self.invoke(accepted=False)
            self.jobs = copy.deepcopy(original)
            self.jobs.pop(index)
            self.invoke(accepted=False)
            self.jobs = copy.deepcopy(original)
            self.jobs.append(copy.deepcopy(self.jobs[index]))
            self.invoke(accepted=False)
        self.jobs = copy.deepcopy(original)
        self.jobs[1]["status"] = "in_progress"
        self.invoke(accepted=False)

    def test_wrong_commit_branch_event_workflow_or_job_run_reject(self):
        for field, value in [
            ("head_sha", "b" * 40),
            ("head_branch", "to-rust"),
            ("event", "pull_request"),
            ("path", ".github/workflows/rust.yml"),
        ]:
            before = self.run[field]
            self.run[field] = value
            self.invoke(accepted=False)
            self.run[field] = before
        for field, value in [("run_id", 456), ("head_sha", "b" * 40)]:
            before = self.jobs[1][field]
            self.jobs[1][field] = value
            self.invoke(accepted=False)
            self.jobs[1][field] = before

    def test_skipped_or_missing_required_step_rejects_successful_job(self):
        self.jobs[1]["steps"][0]["conclusion"] = "skipped"
        self.invoke(accepted=False)
        self.jobs[1]["steps"].pop(0)
        self.invoke(accepted=False)

    def test_malformed_tag_rejects(self):
        for tag in ["v1.1.0-rc01", "1.1.0-rc1", "v1.1.0-dev", "v01.1.0"]:
            self.invoke(tag, accepted=False)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise helper CLI contracts using frozen expectations, never a second matcher."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else ROOT / "target/release/examples").resolve()


class Helpers(unittest.TestCase):
    def matrix(self, text):
        with tempfile.TemporaryDirectory() as work:
            path = pathlib.Path(work) / "matrix.yaml"
            path.write_text(text)
            return subprocess.run([BIN / "eval_rule_matrix", path], capture_output=True, text=True, timeout=20)

    def test_frozen_matrix(self):
        result = self.matrix((ROOT / "testdata/rules/rule-matrix.yaml").read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RULE_MATRIX_TOTAL=6", result.stderr)
        self.assertIn("RULE_MATRIX_RESULT=PASS", result.stderr)

    def test_winning_rule_is_not_inferred_from_target_alone(self):
        text = """rules:
  - DOMAIN,other.test,PROXY
  - DOMAIN,winner.test,PROXY
  - MATCH,PROXY
cases:
  - id: same_target
    input: {host: winner.test}
    expect: {target: PROXY, matched_rule: 'DOMAIN,winner.test'}
"""
        self.assertEqual(self.matrix(text).returncode, 0)
        bad = self.matrix(text.replace("matched_rule: 'DOMAIN,winner.test'", "matched_rule: MATCH"))
        self.assertEqual(bad.returncode, 1)
        self.assertIn("RULE_MATRIX_FAILED_IDS=same_target", bad.stderr)

    def test_matrix_rejects_empty_cases_and_invalid_input(self):
        for text in ["rules: ['MATCH,DIRECT']\ncases: []", "rules: []\ncases: [{id: bad, input: {}, expect: {target: DIRECT}}]"]:
            self.assertNotEqual(self.matrix(text).returncode, 0)

    def perf(self, *args):
        return subprocess.run([BIN / "perf_runner", *args], capture_output=True, text=True, timeout=120)

    def test_perf_rejects_invalid_options(self):
        for args in [("--samples", "4"), ("--iterations", "0"), ("--fixture-bytes", "16777217"), ("--samples", "5", "--samples", "5"), ("--unknown",)]:
            self.assertNotEqual(self.perf(*args).returncode, 0)

    def test_perf_real_samples_and_provenance(self):
        result = self.perf("--samples", "5", "--iterations", "1", "--fixture-bytes", "4096", "--subject-commit", "subject", "--harness-commit", "harness", "--machine", 'machine"quoted')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["provenance"]["subject_commit"], "subject")
        self.assertEqual(report["provenance"]["machine"], 'machine"quoted')
        self.assertEqual(report["method"]["warmup_runs"], 1)
        self.assertEqual(len(report["benchmarks"]), 5)
        for benchmark in report["benchmarks"]:
            samples = benchmark["samples"]
            self.assertEqual(len(samples), 5)
            self.assertTrue(all(s["iterations"] == 1 and s["elapsed_ns"] > 0 for s in samples))
            ordered = sorted(s["ns_per_op"] for s in samples)
            self.assertEqual(benchmark["median_ns_per_op"], ordered[2])
            self.assertEqual(benchmark["p95_ns_per_op"], ordered[-1])
            self.assertNotIn("pass", benchmark)


if __name__ == "__main__":
    unittest.main()

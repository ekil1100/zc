#!/usr/bin/env python3
"""Portable runner harness tests; never invoke native settings or sampling tools."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "native_runner", Path(__file__).with_name("test-macos-native.py")
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class FixtureProcesses:
    """External process boundary only: no real security, OpenSSL, or test binary."""

    def __init__(self, failures=None):
        self.failures = failures or {}
        self.calls = []
        self.directory = None
        self.cases = []
        self.waits = []
        self.search_reads = 0

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        operation = (
            argv[1] if argv[0] != "/usr/bin/sudo" else argv[min(3, len(argv) - 1)]
        )
        if argv[0] == "/usr/bin/openssl":
            for flag in ("-keyout", "-out"):
                Path(argv[argv.index(flag) + 1]).write_text("fixture")
            operation = "certificate"
        if "create-keychain" in argv:
            path = Path(argv[-1])
            self.directory = path.parent
            path.touch()
        if Path(argv[0]).name == "fixture-test":
            manifest = json.loads(
                Path(
                    kwargs["env"]["ZC_MACOS_NATIVE_FIXTURE"], "fixture.json"
                ).read_text()
            )
            self.cases.append(manifest["case"])
            operation = manifest["case"]
            output = (
                "\n".join(
                    f"ZC_MACOS_NATIVE_{stage} {manifest['case']} {manifest['nonce']}"
                    for stage in ("BEGIN", "PASS")
                )
                + "\ntest result: ok. 1 passed; 0 failed; 0 ignored;"
            )
        elif operation == "test":
            output = json.dumps(
                {
                    "reason": "compiler-artifact",
                    "target": {"name": "macos_native", "kind": ["test"]},
                    "profile": {"test": True},
                    "executable": str(self.artifact),
                }
            )
        elif operation == "list-keychains" and "-s" not in argv:
            self.search_reads += 1
            operation = "snapshot" if self.search_reads == 1 else "verify"
            output = '"/original.keychain-db"'
        else:
            output = ""
        if operation == "list-keychains" and "-s" in argv:
            operation = "restore" if argv[-1] == "/original.keychain-db" else "append"
        status, stderr = self.failures.get(operation, (0, ""))
        child = mock.MagicMock()
        child.pid = 43210
        child.returncode = status

        def communicate(timeout):
            self.waits.append((operation, timeout))
            if status is None:
                raise subprocess.TimeoutExpired(
                    "hidden argv", timeout, stderr=stderr.encode()
                )
            return output, stderr

        child.communicate.side_effect = communicate
        child.poll.return_value = status
        child.wait.side_effect = lambda **kw: setattr(
            child, "returncode", -15 if status is None else status
        )
        child.__enter__.return_value = child
        return child


class CleanupTests(unittest.TestCase):
    def exercise(self, failures, *, keychain_probe_error=False):
        processes = FixtureProcesses(failures)
        output = io.StringIO()
        path_exists = Path.exists

        def exists(path):
            if keychain_probe_error and path.name == "owned.keychain-db":
                raise OSError("owned keychain probe failed")
            return path_exists(path)

        with tempfile.TemporaryDirectory() as root:
            make_directory = tempfile.mkdtemp
            with (
                mock.patch.object(
                    runner.tempfile,
                    "mkdtemp",
                    side_effect=lambda **kw: make_directory(dir=root, **kw),
                ),
                mock.patch.object(runner.subprocess, "Popen", side_effect=processes),
                mock.patch.object(Path, "exists", exists),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(output),
            ):
                try:
                    runner.scenarios("fixture-test")
                except (Exception, KeyboardInterrupt) as error:
                    message = str(error)
                else:
                    message = ""
            preserved = processes.directory.exists() if processes.directory else False
            mode = processes.directory.stat().st_mode & 0o777 if preserved else None
        return message, output.getvalue(), processes.calls, preserved, mode

    def test_primary_and_all_cleanup_failures_survive(self):
        message, output, calls, preserved, mode = self.exercise(
            {
                "add-trusted-cert": (23, "setter failed"),
                "remove-trusted-cert": (
                    1,
                    "The specified item could not be found in the keychain.",
                ),
                "restore": (2, "restore failed"),
                "delete-keychain": (3, "delete failed"),
                "verify": (4, "verify failed"),
            }
        )
        self.assertIn(
            "PRIMARY: user owned certificate add-trusted-cert: child failed (exit 23)",
            message,
        )
        for label in (
            "remove-trusted-cert",
            "restore original user keychain search list",
            "delete owned keychain",
            "verify restored search list",
        ):
            self.assertIn(label, message)
        self.assertEqual(calls[-1], [runner.SECURITY, "list-keychains", "-d", "user"])
        self.assertIn("item could not be found", output)
        self.assertTrue(preserved)
        self.assertEqual(mode, 0o700)
        self.assertNotIn("PASS cleanup", output)

    def test_primary_timeout_and_item_not_found_cleanup_both_survive(self):
        message, output, calls, preserved, _ = self.exercise(
            {
                "add-trusted-cert": (None, "partial setter evidence"),
                "remove-trusted-cert": (
                    1,
                    "The specified item could not be found in the keychain.",
                ),
            }
        )
        self.assertIn(
            "PRIMARY: user owned certificate add-trusted-cert: parent watchdog expired after 30s",
            message,
        )
        self.assertIn(
            "CLEANUP: user owned certificate remove-trusted-cert: child failed (exit 1)",
            message,
        )
        self.assertIn("partial setter evidence", output)
        self.assertIn("item could not be found", output)
        self.assertEqual(calls[-1], [runner.SECURITY, "list-keychains", "-d", "user"])
        self.assertTrue(preserved)

    def test_primary_failure_with_successful_cleanup_still_fails(self):
        message, output, _, preserved, _ = self.exercise(
            {"add-trusted-cert": (23, "failed")}
        )
        self.assertIn("PRIMARY: user owned certificate add-trusted-cert", message)
        self.assertIn("PASS cleanup", output)
        self.assertFalse(preserved)

    def test_cleanup_only_failure_still_fails(self):
        message, output, _, preserved, _ = self.exercise(
            {"delete-keychain": (3, "failed")}
        )
        self.assertNotIn("PRIMARY:", message)
        self.assertIn("CLEANUP FAILED", message)
        self.assertTrue(preserved)
        self.assertNotIn("PASS cleanup", output)

    def test_cleanup_probe_error_preserves_primary_and_still_verifies_search(self):
        message, _, calls, preserved, _ = self.exercise(
            {"add-trusted-cert": (23, "failed")}, keychain_probe_error=True
        )
        self.assertIn("PRIMARY: user owned certificate add-trusted-cert", message)
        self.assertIn("CLEANUP: owned keychain probe failed", message)
        self.assertEqual(calls[-1], [runner.SECURITY, "list-keychains", "-d", "user"])
        self.assertTrue(preserved)

    def test_partial_keychain_creation_still_restores_and_deletes(self):
        message, _, calls, preserved, _ = self.exercise(
            {"create-keychain": (4, "partial write")}
        )
        self.assertIn("PRIMARY: create owned keychain", message)
        self.assertTrue(any("delete-keychain" in call for call in calls))
        self.assertEqual(calls[-1], [runner.SECURITY, "list-keychains", "-d", "user"])
        self.assertFalse(preserved)


class CommandTests(unittest.TestCase):
    def test_timeout_keeps_partial_stderr_label_and_reaps_owned_child(self):
        children = []
        popen = subprocess.Popen

        def spawn(*args, **kwargs):
            child = popen(*args, **kwargs)
            children.append(child)
            return child

        output = io.StringIO()
        with (
            mock.patch.object(runner.subprocess, "Popen", side_effect=spawn),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            with self.assertRaisesRegex(
                RuntimeError, "exact primary label: parent watchdog expired"
            ):
                runner.command(
                    [
                        sys.executable,
                        "-c",
                        "import sys,time; print('partial evidence', file=sys.stderr, flush=True); time.sleep(60)",
                    ],
                    "exact primary label",
                    timeout=0.3,
                )
        self.assertIn("partial evidence", output.getvalue())
        self.assertIn("BEGIN exact primary label", output.getvalue())
        self.assertIn("FAIL exact primary label", output.getvalue())
        self.assertIn(f"pid={children[0].pid}", output.getvalue())
        self.assertIsNotNone(children[0].returncode)
        with self.assertRaises(ChildProcessError):
            os.waitpid(children[0].pid, os.WNOHANG)

    def test_password_is_redacted_before_truncation_even_on_timeout(self):
        output = io.StringIO()
        secret = "test-only-secret-" * 300
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(RuntimeError):
                runner.command(
                    [
                        sys.executable,
                        "-c",
                        "import sys,time; print('cause '+sys.argv[-1], file=sys.stderr, flush=True); time.sleep(60)",
                        "-p",
                        secret,
                    ],
                    "password stage",
                    timeout=0.3,
                )
        self.assertIn("cause <REDACTED>", output.getvalue())
        self.assertNotIn("test-only-secret-", output.getvalue())
        self.assertNotIn("import sys", output.getvalue())

    def test_real_sampler_substitute_and_setter_are_both_reaped(self):
        popen = subprocess.Popen
        children = []

        def spawn(argv, **kwargs):
            if argv[0] == "/usr/bin/sample":
                self.assertIsNone(children[0].returncode)
                self.assertEqual(argv[1], str(children[0].pid))
                argv = [
                    sys.executable,
                    "-c",
                    "import time; print('Call graph:\\n  harmless frame', flush=True); time.sleep(60)",
                ]
            else:
                self.assertEqual(argv[0], sys.executable)
            child = popen(argv, **kwargs)
            children.append(child)
            return child

        output = io.StringIO()
        with (
            mock.patch.object(runner.subprocess, "Popen", side_effect=spawn),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            with self.assertRaisesRegex(
                RuntimeError, "setter: parent watchdog expired"
            ):
                runner.command(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    "setter",
                    timeout=0.8,
                    sample_trust=True,
                )
        self.assertEqual(len(children), 2)
        self.assertIn("FAIL sample", output.getvalue())
        for child in children:
            self.assertIsNotNone(child.returncode)
            with self.assertRaises(ChildProcessError):
                os.waitpid(child.pid, os.WNOHANG)

    def test_stream_cleanup_errors_do_not_mask_timeout_or_skip_other_stream(self):
        child = mock.MagicMock(pid=123, returncode=None)
        child.communicate.side_effect = subprocess.TimeoutExpired(
            "private argv", 1, stderr=b"evidence"
        )
        child.poll.return_value = None
        child.stdout.close.side_effect = OSError("private stream details")
        child.stderr.close.side_effect = OSError("private stream details")
        output = io.StringIO()
        with (
            mock.patch.object(runner.subprocess, "Popen", return_value=child),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            with self.assertRaisesRegex(
                RuntimeError, "original: parent watchdog expired"
            ) as error:
                runner.command(["not-executed"], "original", timeout=1)
        self.assertIn("stream close failed", str(error.exception))
        child.stdout.close.assert_called_once()
        child.stderr.close.assert_called_once()
        self.assertNotIn("private", output.getvalue())
        self.assertIn("evidence", output.getvalue())

    def test_nonzero_password_failure_and_spawn_error_do_not_leak_argv(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(RuntimeError, r"child failed \(exit 7\)"):
                runner.command(
                    [
                        sys.executable,
                        "-c",
                        "import sys; print(sys.argv[-1],file=sys.stderr); sys.exit(7)",
                        "-p",
                        "private-password",
                    ],
                    "password stage",
                    diagnostics=True,
                )
            with mock.patch.object(
                runner.subprocess, "Popen", side_effect=OSError(2, "private-password")
            ):
                with self.assertRaisesRegex(RuntimeError, "could not start child"):
                    runner.command(["private-password"], "spawn stage")
        self.assertNotIn("private-password", output.getvalue())
        self.assertIn("<REDACTED>", output.getvalue())

    def test_success_logs_stage_and_pid_not_output_or_argv(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = runner.command(
                [sys.executable, "-c", "print('private-output')"], "safe stage"
            )
        self.assertEqual(result, "private-output\n")
        self.assertIn("BEGIN safe stage", output.getvalue())
        self.assertIn("END safe stage", output.getvalue())
        self.assertNotIn("private-output", output.getvalue())


class SamplingTests(unittest.TestCase):
    def exercise(
        self,
        *,
        sample_status=0,
        sample_time=1,
        sample_error=None,
        setter_finishes=False,
        exited_at_half=False,
        timeout=30,
        last_stderr_missing=False,
        sample_spawn_error=False,
        sample_close_error=False,
    ):
        clock = [100.0]
        calls = []
        waits = []
        setter = mock.MagicMock(pid=101, returncode=None)
        sampler = mock.MagicMock(pid=202, returncode=None)
        if sample_close_error:
            sampler.stdout.close.side_effect = OSError("private stream details")
        setter.poll.side_effect = lambda: setter.returncode
        sampler.poll.side_effect = lambda: sampler.returncode
        setter.wait.side_effect = lambda **kw: setattr(setter, "returncode", -15)
        sampler.wait.side_effect = lambda **kw: setattr(sampler, "returncode", -9)

        def communicate_setter(timeout):
            waits.append(("setter", timeout))
            if setter_finishes:
                clock[0] += 0.1
                setter.returncode = 0
                return "done", ""
            clock[0] += timeout
            if exited_at_half:
                setter.returncode = 7
            stderr = (
                None
                if last_stderr_missing and len(waits) > 1
                else b"partial setter stderr"
            )
            raise subprocess.TimeoutExpired(
                "never log this argv", timeout, stderr=stderr
            )

        def communicate_sampler(timeout):
            waits.append(("sampler", timeout))
            clock[0] += min(sample_time, timeout)
            if sample_error:
                raise sample_error
            if sample_time > timeout:
                raise subprocess.TimeoutExpired("sample argv", timeout)
            sampler.returncode = sample_status
            return (
                "Command: private-command-and-password\nCall graph:\n"
                + "frame é\n" * 5000,
                "",
            )

        setter.communicate.side_effect = communicate_setter
        sampler.communicate.side_effect = communicate_sampler

        def spawn(argv, **kwargs):
            calls.append(argv)
            if argv[0] == "/usr/bin/sample":
                self.assertIsNone(
                    setter.returncode, "only sample an owned, unreaped child"
                )
                self.assertEqual(argv[1:3], ["101", "1"])
                self.assertEqual(clock[0], 100 + timeout / 2)
                if sample_spawn_error:
                    raise OSError("private spawn arguments")
                return sampler
            self.assertEqual(len(calls), 1)
            return setter

        output = io.StringIO()
        with (
            mock.patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]),
            mock.patch.object(runner.subprocess, "Popen", side_effect=spawn),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            try:
                runner.command(
                    ["fake-setter"],
                    "user owned certificate add-trusted-cert",
                    timeout=timeout,
                    sample_trust=True,
                )
            except RuntimeError as error:
                message = str(error)
            else:
                message = ""
        return message, output.getvalue(), calls, waits, setter, sampler, clock[0]

    def test_sampling_shares_original_absolute_thirty_second_budget(self):
        message, output, calls, waits, setter, _, finished = self.exercise()
        self.assertIn(
            "user owned certificate add-trusted-cert: parent watchdog expired after 30s",
            message,
        )
        self.assertEqual(waits, [("setter", 15), ("sampler", 3), ("setter", 14)])
        self.assertEqual(finished, 130)
        self.assertEqual(len(calls), 2)
        self.assertIn("BEGIN sample", output)
        self.assertIn("END sample", output)
        self.assertIn("partial setter stderr", output)
        self.assertIsNotNone(setter.returncode)

    def test_sample_stack_output_is_bounded_and_omits_command_header(self):
        _, output, _, _, _, _, _ = self.exercise()
        self.assertNotIn("private-command-and-password", output)
        stack = output[output.index("Call graph:") : output.index("END sample")]
        self.assertLessEqual(len(stack.encode("utf-8")), 16384)
        self.assertIn("frame", stack)

    def test_sampler_timeout_is_capped_and_does_not_replace_primary(self):
        message, output, _, waits, _, sampler, finished = self.exercise(sample_time=60)
        self.assertIn("add-trusted-cert: parent watchdog expired after 30s", message)
        self.assertIn("FAIL sample", output)
        self.assertEqual(waits, [("setter", 15), ("sampler", 3), ("setter", 12)])
        self.assertEqual(finished, 130)
        sampler.kill.assert_called_once()
        sampler.wait.assert_called()

    def test_sampler_cannot_exceed_remaining_original_budget(self):
        _, _, _, waits, _, _, finished = self.exercise(timeout=4, sample_time=60)
        self.assertEqual(waits, [("setter", 2), ("sampler", 2), ("setter", 0)])
        self.assertEqual(finished, 104)

    def test_sample_nonzero_and_exception_are_reported_without_hiding_primary(self):
        for options in (
            {"sample_status": 9},
            {"sample_error": OSError("secret argv")},
            {"sample_error": KeyboardInterrupt()},
        ):
            with self.subTest(options=options):
                message, output, _, _, _, _, _ = self.exercise(**options)
                self.assertIn("add-trusted-cert: parent watchdog expired", message)
                self.assertIn("FAIL sample", output)
                self.assertNotIn("secret argv", output + message)

    def test_halfway_partial_stderr_survives_empty_final_timeout(self):
        message, output, _, _, _, _, _ = self.exercise(last_stderr_missing=True)
        self.assertIn("partial setter stderr", output)
        self.assertIn("add-trusted-cert: parent watchdog expired", message)

    def test_sampler_stream_cleanup_failure_does_not_replace_primary(self):
        message, output, _, _, _, sampler, _ = self.exercise(sample_close_error=True)
        self.assertIn("add-trusted-cert: parent watchdog expired", message)
        self.assertIn("FAIL sample", output)
        self.assertNotIn("private stream details", output + message)
        sampler.stderr.close.assert_called_once()

    def test_sampler_spawn_failure_is_reported_without_argv(self):
        message, output, _, waits, _, _, _ = self.exercise(sample_spawn_error=True)
        self.assertIn("FAIL sample", output)
        self.assertIn("add-trusted-cert: parent watchdog expired", message)
        self.assertNotIn("private spawn arguments", output + message)
        self.assertEqual(waits, [("setter", 15), ("setter", 15)])

    def test_fast_setter_is_not_sampled(self):
        message, output, calls, _, _, _, _ = self.exercise(setter_finishes=True)
        self.assertEqual(message, "")
        self.assertEqual(len(calls), 1)
        self.assertNotIn("BEGIN sample", output)

    def test_setter_that_exits_at_half_is_not_sampled(self):
        _, output, calls, _, _, _, _ = self.exercise(exited_at_half=True)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("BEGIN sample", output)


class EntryPointTests(unittest.TestCase):
    def test_refusal_precedes_subprocesses_temporary_files_and_platform_reads(self):
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(
                sys, "argv", ["runner", "--target", "aarch64-apple-darwin"]
            ),
            mock.patch.object(runner.subprocess, "Popen") as popen,
            mock.patch.object(runner.tempfile, "mkdtemp") as mkdtemp,
            mock.patch.object(runner.platform, "mac_ver") as mac_ver,
        ):
            with self.assertRaisesRegex(RuntimeError, "REFUSED"):
                runner.main()
        popen.assert_not_called()
        mkdtemp.assert_not_called()
        mac_ver.assert_not_called()

    def test_cleanup_only_failure_exits_nonzero_and_only_trust_setters_opt_in(self):
        processes = FixtureProcesses({"delete-keychain": (3, "delete failed")})
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as root:
            processes.artifact = Path(root) / "fixture-test"
            processes.artifact.touch()
            make_directory = tempfile.mkdtemp
            with (
                mock.patch.dict(
                    os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS"}
                ),
                mock.patch.object(sys, "platform", "darwin"),
                mock.patch.object(runner.platform, "machine", return_value="arm64"),
                mock.patch.object(
                    runner.platform, "mac_ver", return_value=("15.0", (), "")
                ),
                mock.patch.object(
                    sys,
                    "argv",
                    [
                        "runner",
                        "--ephemeral-runner",
                        "--target",
                        "aarch64-apple-darwin",
                    ],
                ),
                mock.patch.object(runner.time, "monotonic", return_value=100),
                mock.patch.object(
                    runner.tempfile,
                    "mkdtemp",
                    side_effect=lambda **kw: make_directory(dir=root, **kw),
                ),
                mock.patch.object(runner.subprocess, "Popen", side_effect=processes),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(output),
            ):
                with self.assertRaises(SystemExit) as exit_context:
                    runpy.run_path(str(Path(runner.__file__)), run_name="__main__")
            self.assertEqual(exit_context.exception.code, 1)
            self.assertTrue(processes.directory.exists())
        self.assertIn("FAIL: CLEANUP FAILED", output.getvalue())
        self.assertNotIn("PASS all 9", output.getvalue())
        self.assertEqual(
            processes.cases,
            [
                "baseline-untrusted",
                "security-first",
                "dns-first",
                "wrong-sni",
                "concurrent-independent",
                "concurrent-shared",
                "user-deny",
                "admin-trust",
                "user-deny-admin-trust",
            ],
        )
        for operation, budget in processes.waits:
            expected = (
                15
                if operation == "add-trusted-cert"
                else 1800
                if operation == "test"
                else 30
            )
            self.assertEqual(budget, expected, operation)


if __name__ == "__main__":
    unittest.main()

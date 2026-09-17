#!/usr/bin/env python3
"""Portable diagnostic contracts: external process stubs only, never local trust."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("diagnose-macos-trust.py")


def load_runner():
    spec = importlib.util.spec_from_file_location("trust_diagnostic", SCRIPT)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    return runner


class FixtureProcesses:
    """Simulate partial external writes and a pinned 30s deadline, not internal helpers."""

    def __init__(self, failures=None, *, log_output=None, log_spawn_error=False,
                 real_popen=None, log_close_error=False, setter_spawn_error=False):
        self.failures = failures or {}
        self.log_output = log_output
        self.log_spawn_error = log_spawn_error
        self.real_popen = real_popen
        self.real_children = []
        self.log_close_error = log_close_error
        self.setter_spawn_error = setter_spawn_error
        self.calls = []
        self.waits = []
        self.clock = 100.0
        self.directory = None
        self.reads = 0
        self.children = []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        executable = argv[0]
        assert executable in ("/usr/bin/security", "/usr/bin/openssl", "/usr/bin/sample", "/usr/bin/log"), argv
        operation = argv[1]
        if operation == "add-trusted-cert" and self.setter_spawn_error:
            raise OSError(1, "private setter argv")
        if self.real_popen is not None and (executable == "/usr/bin/log" or operation == "add-trusted-cert"):
            if executable == "/usr/bin/log":
                code = "import os,time; os.write(1,b'trustd: request\\n'+b'x'*100000); time.sleep(60)"
            else:
                code = "import sys,time; time.sleep(0.3); print('setter failure',file=sys.stderr); sys.exit(7)"
            child = self.real_popen([sys.executable, "-c", code], **kwargs)
            self.real_children.append(child)
            self.children.append(child)
            return child
        output = ""
        if executable == "/usr/bin/openssl":
            operation = "certificate"
            for flag in ("-keyout", "-out"):
                Path(argv[argv.index(flag) + 1]).write_text("fixture")
        elif executable == "/usr/bin/sample":
            operation = "sample"
            output = "Call graph:\n  SecTrustSettingsXPCWrite\n"
        elif executable == "/usr/bin/log":
            operation = "logs"
            if self.log_spawn_error:
                raise OSError(1, "private spawn arguments")
        elif operation == "create-keychain":
            self.directory = Path(argv[-1]).parent
            Path(argv[-1]).touch()
        elif operation == "list-keychains":
            if "-s" in argv:
                operation = "restore" if argv[-1] == "/original.keychain-db" else "append"
            else:
                self.reads += 1
                operation = "snapshot" if self.reads == 1 else "verify"
                output = '"/original.keychain-db"'
        status, stderr = self.failures.get(operation, (0, ""))
        if operation == "delete-keychain" and status == 0:
            Path(argv[-1]).unlink()
        child = mock.MagicMock(pid=42000 + len(self.calls), returncode=None)
        child.stdout = io.BytesIO(self.log_output if self.log_output is not None else
                                  b"trustd: trust settings request\nauthd: authorization request\n")
        if operation == "logs" and status:
            child.returncode = status
        if operation == "logs" and self.log_close_error:
            child.stdout = mock.Mock(wraps=child.stdout)
            child.stdout.close.side_effect = OSError("private stream details")
        child.stderr = io.BytesIO()
        child.poll.side_effect = lambda: child.returncode
        child.kill.side_effect = lambda: setattr(child, "returncode", -9)
        child.terminate.side_effect = lambda: setattr(child, "returncode", -15)
        child.wait.side_effect = lambda **kw: child.returncode

        def communicate(timeout):
            self.waits.append((operation, timeout))
            if status is None:
                self.clock += timeout
                raise subprocess.TimeoutExpired("private argv", timeout, stderr=stderr.encode())
            if operation == "sample":
                self.clock += 1
            child.returncode = status
            return output, stderr

        child.communicate.side_effect = communicate
        self.children.append(child)
        return child


class DiagnosticTests(unittest.TestCase):
    def exercise(self, failures=None, flags=(), **options):
        runner = load_runner()
        processes = FixtureProcesses(failures, **options)
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as root:
            make_directory = tempfile.mkdtemp
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS"}), \
                    mock.patch.object(sys, "platform", "darwin"), \
                    mock.patch("platform.machine", return_value="arm64"), \
                    mock.patch("platform.mac_ver", return_value=("15.0", (), "")), \
                    mock.patch.object(sys, "argv", [str(SCRIPT), "--ephemeral-runner", "--target",
                                                   "aarch64-apple-darwin", *flags]), \
                    mock.patch("time.monotonic", side_effect=lambda: processes.clock), \
                    mock.patch("tempfile.mkdtemp", side_effect=lambda **kw: make_directory(dir=root, **kw)), \
                    mock.patch("subprocess.Popen", side_effect=processes), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                try:
                    runner.main()
                except (Exception, KeyboardInterrupt) as error:
                    message = str(error)
                else:
                    message = ""
            preserved = processes.directory is not None and processes.directory.exists()
            mode = processes.directory.stat().st_mode & 0o777 if preserved else None
        return message, output.getvalue(), processes, preserved, mode

    def test_primary_and_all_cleanup_errors_survive_item_not_found(self):
        message, output, processes, preserved, mode = self.exercise({
            "add-trusted-cert": (23, "setter failure"),
            "remove-trusted-cert": (1, "The specified item could not be found in the keychain."),
            "restore": (2, "restore failure"),
            "delete-keychain": (3, "delete failure"),
            "verify": (4, "verify failure"),
        })
        self.assertIn("PRIMARY: user owned certificate add-trusted-cert: child failed (exit 23)", message)
        for label in ("remove-trusted-cert", "restore original user keychain search list",
                      "delete owned keychain", "verify restored search list"):
            self.assertIn("CLEANUP: " + ("user owned certificate " if label == "remove-trusted-cert" else "") + label,
                          message)
        self.assertIn("item could not be found", output)
        self.assertTrue(preserved)
        self.assertEqual(mode, 0o700)
        self.assertEqual(processes.calls[-1], ["/usr/bin/security", "list-keychains", "-d", "user"])
        self.assertNotIn("PASS cleanup", output)

    def test_partial_keychain_creation_is_registered_before_attempt(self):
        message, _, processes, preserved, _ = self.exercise({"create-keychain": (4, "partial write")})
        self.assertIn("PRIMARY: create owned keychain", message)
        self.assertTrue(any("delete-keychain" in call for call in processes.calls))
        self.assertTrue(any("-s" in call for call in processes.calls))
        self.assertFalse(any("remove-trusted-cert" in call for call in processes.calls))
        self.assertFalse(preserved)

    def test_cleanup_only_failure_is_not_success(self):
        message, output, _, preserved, _ = self.exercise({"delete-keychain": (3, "failed")})
        self.assertNotIn("PRIMARY:", message)
        self.assertIn("CLEANUP FAILED", message)
        self.assertTrue(preserved)
        self.assertNotIn("DIAGNOSTIC ONLY complete", output)

    def test_setter_sampling_and_logs_do_not_restart_thirty_second_watchdog(self):
        message, output, processes, preserved, _ = self.exercise({
            "add-trusted-cert": (None, "partial setter evidence"),
            "remove-trusted-cert": (1, "item not found"),
        })
        self.assertIn("PRIMARY: user owned certificate add-trusted-cert: parent watchdog expired after 30s", message)
        self.assertIn("CLEANUP: user owned certificate remove-trusted-cert", message)
        self.assertIn("partial setter evidence", output)
        self.assertTrue(preserved)
        waits = [(op, budget) for op, budget in processes.waits if op in ("add-trusted-cert", "sample")]
        self.assertEqual(waits, [("add-trusted-cert", 15), ("sample", 3), ("add-trusted-cert", 14)])
        self.assertEqual(processes.clock, 130)
        for child in processes.children:
            self.assertIsNotNone(child.returncode)

    def test_default_uses_exact_user_setter_and_no_rust_or_native_pass_claim(self):
        message, output, processes, preserved, _ = self.exercise()
        self.assertEqual(message, "")
        setters = [call for call in processes.calls if "add-trusted-cert" in call]
        self.assertEqual(len(setters), 1)
        self.assertEqual(setters[0], ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k",
                                    str(processes.directory / "owned.keychain-db"),
                                    str(processes.directory / "cert.pem")])
        self.assertFalse(preserved)
        self.assertIn("DIAGNOSTIC ONLY", output)
        self.assertNotIn("PASS all 9", output)
        self.assertNotIn("PASS native", output)

    def test_keychain_only_control_never_touches_trust_settings(self):
        message, output, processes, preserved, _ = self.exercise(flags=["--keychain-only"])
        self.assertEqual(message, "")
        self.assertFalse(preserved)
        self.assertFalse(any("trusted-cert" in str(call) for call in processes.calls))
        calls = [call for call in processes.calls if "add-certificates" in call]
        self.assertEqual(calls, [["/usr/bin/security", "add-certificates", "-k",
                                 str(processes.directory / "owned.keychain-db"),
                                 str(processes.directory / "cert.pem")]])
        self.assertIn("keychain-only", output)

    def test_service_logs_span_only_the_write_and_are_bounded(self):
        message, output, processes, _, _ = self.exercise(log_output=b"trustd: authorization " + b"x" * 100000)
        self.assertEqual(message, "")
        calls = processes.calls
        log_indices = [i for i, call in enumerate(calls) if call[0] == "/usr/bin/log"]
        self.assertEqual(len(log_indices), 1)
        i = log_indices[0]
        self.assertIn("append", output)
        self.assertEqual(calls[i - 1][1], "list-keychains")
        self.assertEqual(calls[i + 1][1], "add-trusted-cert")
        self.assertEqual(calls[i][1], "stream")
        predicate = calls[i][calls[i].index("--predicate") + 1]
        for name in ("trustd", "authd", "securityd"):
            self.assertIn('process == "' + name + '"', predicate)
        for signal in ("trust", "auth", "xpc", "lock", "session", "interaction"):
            self.assertIn('eventMessage CONTAINS[c] "' + signal + '"', predicate)
        log_child = processes.children[i]
        log_child.kill.assert_called_once()
        log_child.wait.assert_called()
        self.assertTrue(log_child.stdout.closed)
        self.assertIn("EVIDENCE service logs", output)
        self.assertIn("truncated", output)
        self.assertLess(len(output.encode()), 20000)
        self.assertLess(output.index("END service logs"), output.index("BEGIN user owned certificate remove-trusted-cert"))

    def test_log_failure_never_hides_setter_timeout_or_cleanup_failure(self):
        for options in ({"log_spawn_error": True}, {"log_output": b"log access denied"}):
            with self.subTest(options=options):
                message, output, _, _, _ = self.exercise({
                    "logs": (1, ""), "add-trusted-cert": (None, "setter evidence"),
                    "remove-trusted-cert": (1, "not found"),
                }, **options)
                self.assertIn("parent watchdog expired after 30s", message)
                self.assertIn("CLEANUP:", message)
                self.assertIn("WARN service logs", output)
                self.assertNotIn("private spawn arguments", output + message)

    def test_empty_logs_explicitly_do_not_rule_out_authorization_wait(self):
        message, output, _, _, _ = self.exercise(log_output=b"")
        self.assertEqual(message, "")
        self.assertIn("no evidence", output)
        self.assertIn("does not rule out", output)

    def test_harmless_real_log_producer_is_capped_killed_and_reaped(self):
        message, output, processes, _, _ = self.exercise(real_popen=subprocess.Popen)
        self.assertIn("PRIMARY: user owned certificate add-trusted-cert: child failed (exit 7)", message)
        self.assertIn("setter failure", output)
        self.assertIn("trustd: request", output)
        self.assertLess(len(output.encode()), 20000)
        self.assertEqual(len(processes.real_children), 2)
        for child in processes.real_children:
            self.assertIsNotNone(child.returncode)
            self.assertTrue(child.stdout.closed)
            with self.assertRaises(ChildProcessError):
                os.waitpid(child.pid, os.WNOHANG)

    def test_log_cleanup_failure_is_preserved_with_primary_and_does_not_skip_trust_cleanup(self):
        message, output, processes, preserved, _ = self.exercise(
            {"add-trusted-cert": (23, "failed"), "remove-trusted-cert": (1, "not found")},
            log_close_error=True,
        )
        self.assertIn("PRIMARY:", message)
        self.assertIn("CLEANUP: service log stream close failed (OSError)", message)
        self.assertIn("CLEANUP: user owned certificate remove-trusted-cert", message)
        self.assertNotIn("private stream details", message + output)
        self.assertTrue(preserved)
        self.assertEqual(processes.calls[-1], ["/usr/bin/security", "list-keychains", "-d", "user"])

    def test_failed_setter_spawn_still_attempts_trust_cleanup(self):
        message, output, processes, _, _ = self.exercise(setter_spawn_error=True)
        self.assertIn("PRIMARY: user owned certificate add-trusted-cert: could not start child", message)
        self.assertTrue(any("remove-trusted-cert" in call for call in processes.calls))
        self.assertNotIn("private setter argv", message + output)

    def test_log_redaction_precedes_byte_cap(self):
        secret = "test-only-password" * 4
        data = b"trustd: " + b"x" * (16350 - len(b"trustd: ")) + secret.encode() + b" tail"
        with mock.patch("secrets.token_hex", return_value=secret):
            message, output, _, _, _ = self.exercise(log_output=data)
        self.assertEqual(message, "")
        self.assertNotIn("test-only-password", output)
        self.assertIn("<REDACTED>", output)

    def test_valid_flags_still_refuse_wrong_host_target_or_os_version(self):
        runner = load_runner()
        for host, arch, version in (("linux", "arm64", "15.0"),
                                    ("darwin", "x86_64", "15.0"),
                                    ("darwin", "arm64", "14.0")):
            with self.subTest(host=host, arch=arch, version=version), \
                    mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS"}), \
                    mock.patch.object(sys, "platform", host), \
                    mock.patch("platform.machine", return_value=arch), \
                    mock.patch("platform.mac_ver", return_value=(version, (), "")), \
                    mock.patch.object(sys, "argv", [str(SCRIPT), "--ephemeral-runner", "--target",
                                                   "aarch64-apple-darwin"]), \
                    mock.patch("subprocess.Popen") as popen, \
                    mock.patch("tempfile.mkdtemp") as mkdir:
                with self.assertRaisesRegex(RuntimeError, "REFUSED"):
                    runner.main()
                popen.assert_not_called()
                mkdir.assert_not_called()

    def test_guard_precedes_processes_files_and_platform_queries(self):
        runner = load_runner()
        for env, flags in (({}, []), ({"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS"}, []),
                           ({"RUNNER_OS": "macOS"}, ["--ephemeral-runner"]),
                           ({"GITHUB_ACTIONS": "true"}, ["--ephemeral-runner"])):
            with self.subTest(env=env, flags=flags), \
                    mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.object(sys, "argv", [str(SCRIPT), "--target", "aarch64-apple-darwin", *flags]), \
                    mock.patch("subprocess.Popen") as popen, \
                    mock.patch("tempfile.mkdtemp") as mkdir, \
                    mock.patch("platform.machine") as machine, \
                    mock.patch("platform.mac_ver") as version:
                with self.assertRaisesRegex(RuntimeError, "REFUSED"):
                    runner.main()
                popen.assert_not_called()
                mkdir.assert_not_called()
                machine.assert_not_called()
                version.assert_not_called()


if __name__ == "__main__":
    unittest.main()

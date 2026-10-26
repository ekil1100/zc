"""Check process-disappearance races without signalling real processes."""

import ast
import json
import os
import pathlib
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch


class ManagerProcessLiveness(unittest.TestCase):
    def setUp(self):
        source = pathlib.Path(__file__).with_name("service_manager.py")
        tree = ast.parse(source.read_text())
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "alive"
        )
        self.kill = Mock()
        self.stat = Mock()
        self.stat.exists.return_value = True
        self.stat.read_text.return_value = "12345 (test daemon) S 1 2 3"
        namespace = {
            "os": types.SimpleNamespace(kill=self.kill),
            "pathlib": types.SimpleNamespace(Path=Mock(return_value=self.stat)),
            "state": {"pid": 12345},
            "diagnostics": False,
            "last_probe": None,
            "time": time,
        }
        # Load only the helper: importing the manager executes its command CLI.
        exec(
            compile(ast.Module(body=[function], type_ignores=[]), source, "exec"),
            namespace,
        )
        self.alive = namespace["alive"]

    def test_reaped_between_proc_exists_and_read_is_stopped(self):
        self.stat.read_text.side_effect = FileNotFoundError(2, "process disappeared")
        self.assertFalse(self.alive())
        self.kill.assert_called_once_with(12345, 0)

    def test_already_reaped_process_is_stopped(self):
        self.kill.side_effect = ProcessLookupError(3, "process disappeared")
        self.assertFalse(self.alive())

    def test_zombie_is_stopped(self):
        self.stat.read_text.return_value = "12345 (test daemon) Z 1 2 3"
        self.assertFalse(self.alive())

    def test_live_process_and_non_proc_platform_remain_alive(self):
        self.assertTrue(self.alive())
        self.stat.exists.return_value = False
        self.assertTrue(self.alive())

    def test_permission_failure_is_not_reported_as_stopped(self):
        self.kill.side_effect = PermissionError(1, "access denied")
        with self.assertRaises(PermissionError):
            self.alive()


class ManagerStopDiagnostics(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        source = pathlib.Path(__file__).with_name("service_manager.py")
        tree = ast.parse(source.read_text())
        helpers = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
        self.now = 100.0
        self.kill = Mock()
        self.process_stat = "12345 (zc) S " + " ".join(["0"] * 18 + ["4242"])
        self.proc = Mock()
        self.proc.exists.return_value = True
        self.proc.read_text.return_value = self.process_stat
        self.proc.iterdir.side_effect = PermissionError(13, "denied")
        self.ns = {
            "root": self.root,
            "state": {"pid": 12345},
            "program": "/bin/launchctl",
            "platform": "launchd",
            "args": ["bootout", "gui/501/org.zc.user"],
            "os": types.SimpleNamespace(kill=self.kill, getpid=lambda: 999),
            "pathlib": types.SimpleNamespace(Path=Mock(return_value=self.proc)),
            "time": types.SimpleNamespace(
                monotonic=lambda: self.now,
                time_ns=lambda: int(self.now * 1_000_000_000),
                sleep=self.advance,
            ),
            "signal": __import__("signal"),
            "sys": sys,
            "json": json,
            "diagnostics": True,
            "last_probe": None,
        }
        exec(
            compile(ast.Module(body=helpers, type_ignores=[]), source, "exec"), self.ns
        )
        self.ns["save"] = Mock()
        self.ns["barrier"] = Mock()

    def advance(self, seconds):
        self.now += seconds

    def events(self):
        return [
            json.loads(line)
            for line in (self.root / "manager-stop-diagnostics.jsonl")
            .read_text()
            .splitlines()
        ]

    def test_timeout_preserves_actual_probe_and_original_failure(self):
        with self.assertRaisesRegex(AssertionError, "test daemon failed to stop"):
            self.ns["stop"]()
        events = self.events()
        self.assertEqual([event["phase"] for event in events], ["sigterm", "timeout"])
        timeout = events[-1]
        self.assertEqual(timeout["deadline"], 105.0)
        self.assertGreaterEqual(timeout["probe"]["monotonic"], 105.0)
        self.assertLess(timeout["probe"]["monotonic"], 105.05)
        self.assertEqual(timeout["probe"]["pid"], 12345)
        self.assertEqual(timeout["probe"]["stat"], self.process_stat)
        self.assertEqual(timeout["probe"]["parsed_state"], "S")
        self.assertEqual(timeout["probe"]["kill_errno"], 0)
        self.assertEqual(timeout["probe"]["alive"], True)
        self.assertEqual(timeout["threads_errno"], 13)
        self.assertEqual(
            self.kill.call_args_list.count(((12345, self.ns["signal"].SIGTERM),)), 1
        )
        self.ns["save"].assert_not_called()

    def test_success_and_recovery_query_keep_distinct_observations(self):
        # Initial live check succeeds; all checks after SIGTERM see disappearance.
        def kill(pid, sig):
            if sig == self.ns["signal"].SIGTERM:
                self.kill.side_effect = ProcessLookupError(3, "gone")

        self.kill.side_effect = kill
        self.ns["stop"]()
        events = self.events()
        self.assertEqual([event["phase"] for event in events], ["sigterm", "stopped"])
        self.assertFalse(events[-1]["probe"]["alive"])
        self.assertEqual(events[-1]["probe"]["kill_errno"], 3)
        self.assertEqual(self.ns["state"]["pid"], 0)
        self.assertFalse(self.ns["alive"]())
        self.ns["record_diagnostic"]("command-end")
        self.assertEqual(self.events()[-1]["probe"]["pid"], 0)
        # Diagnostics must not perform a second kill/procfs liveness probe.
        self.assertEqual(self.kill.call_count, 4)

    def test_timeout_thread_capture_is_bounded_and_reports_read_errors(self):
        task = self.root / "task"
        task.mkdir()
        for tid in range(34):
            thread = task / str(tid)
            thread.mkdir()
            (thread / "stat").write_text(self.process_stat)
            (thread / "wchan").write_text("futex_wait" * 1000)
        self.ns["pathlib"].Path.return_value = task
        self.ns["record_diagnostic"]("timeout", 105.0)
        event = self.events()[0]
        self.assertEqual(event["thread_count"], 34)
        self.assertEqual(len(event["threads"]), 32)
        for thread in event["threads"]:
            self.assertEqual(len(thread["wchan"]), 4096)
            self.assertEqual(thread["stack_errno"], 2)
        self.kill.assert_not_called()

    def test_probe_preserves_disappearance_between_exists_and_read(self):
        self.proc.read_text.side_effect = FileNotFoundError(2, "gone")
        self.assertFalse(self.ns["alive"]())
        self.ns["record_diagnostic"]("command-end")
        probe = self.events()[0]["probe"]
        self.assertTrue(probe["proc_exists"])
        self.assertEqual(probe["kill_errno"], 0)
        self.assertEqual(probe["errno"], 2)
        self.assertFalse(probe["alive"])
        self.kill.assert_called_once_with(12345, 0)

    def test_diagnostics_disabled_creates_no_file(self):
        self.ns["diagnostics"] = False
        self.ns["state"]["pid"] = 0
        self.ns["stop"]()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_diagnostic_write_error_does_not_replace_timeout(self):
        (self.root / "manager-stop-diagnostics.jsonl").mkdir()
        with self.assertRaisesRegex(AssertionError, "test daemon failed to stop"):
            self.ns["stop"]()


class ManagerStatePublication(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / "fake-manager.json"
        self.previous = {"pid": 12345, "loaded": True}
        self.updated = {"pid": 0, "loaded": False}
        self.path.write_text(json.dumps(self.previous))
        source = pathlib.Path(__file__).with_name("service_manager.py")
        tree = ast.parse(source.read_text())
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "save"
        )
        namespace = {
            "state_path": self.path,
            "state": self.updated,
            "json": json,
            "os": os,
        }
        exec(
            compile(ast.Module(body=[function], type_ignores=[]), source, "exec"),
            namespace,
        )
        self.save = namespace["save"]

    def test_interrupted_write_keeps_previous_complete_state(self):
        write_text = pathlib.Path.write_text

        def interrupted(path, text, *args, **kwargs):
            write_text(path, text[:1], *args, **kwargs)
            raise InterruptedError("manager killed during state write")

        with patch.object(pathlib.Path, "write_text", interrupted):
            with self.assertRaises(InterruptedError):
                self.save()
        self.assertEqual(json.loads(self.path.read_text()), self.previous)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_reader_never_sees_partial_state_before_publication(self):
        write_text = pathlib.Path.write_text
        observed = []

        def partial(path, text, *args, **kwargs):
            write_text(path, text[:1], *args, **kwargs)
            observed.append(self.path.read_text())
            return write_text(path, text, *args, **kwargs)

        with patch.object(pathlib.Path, "write_text", partial):
            self.save()
        self.assertEqual([json.loads(text) for text in observed], [self.previous])
        self.assertEqual(json.loads(self.path.read_text()), self.updated)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])


if __name__ == "__main__":
    unittest.main()

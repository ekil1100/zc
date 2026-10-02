"""Check process-disappearance races without signalling real processes."""

import ast
import pathlib
import types
import unittest
from unittest.mock import Mock


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


if __name__ == "__main__":
    unittest.main()

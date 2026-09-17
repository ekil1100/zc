import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("generate", Path(__file__).with_name("generate.py"))
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)


class NoticesTests(unittest.TestCase):
    def test_closure_excludes_dev_but_keeps_build_and_target_edges(self):
        def edge(package, kind):
            return {"pkg": package, "dep_kinds": [{"kind": kind, "target": "cfg(windows)"}]}
        metadata = {"resolve": {"root": "root", "nodes": [
            {"id": "root", "deps": [edge("run", None), edge("build", "build"), edge("dev", "dev")]},
            {"id": "run", "deps": [edge("shared", None), edge("nested-dev", "dev")]},
            {"id": "build", "deps": []}, {"id": "shared", "deps": []},
            {"id": "dev", "deps": []}, {"id": "nested-dev", "deps": []},
        ]}}
        self.assertEqual(generate.production_closure(metadata), {"root", "run", "build", "shared"})

    def test_collects_nested_notices_authors_and_native_comments_verbatim(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "native").mkdir()
            (root / "native/NOTICE").write_bytes(b"Native attribution\r\n")
            (root / "AUTHORS").write_text("Copyright Author\nPermission is hereby granted\n")
            header = "/* Copyright Native Author\n * Permission is hereby granted\n */"
            (root / "native/lua.h").write_text(header + "\nint example;\n")
            texts = generate.collect_texts(root)
            self.assertIn(("native/NOTICE", "Native attribution\r\n"), texts)
            self.assertIn(("native/lua.h:1", header), texts)
            self.assertTrue(any(path == "AUTHORS" for path, _ in texts))

    def test_collects_hidden_license_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".licenses").mkdir()
            (root / ".licenses/OriginalAuthor-MIT").write_text("Permission is hereby granted")
            self.assertEqual(generate.collect_texts(root), [(".licenses/OriginalAuthor-MIT", "Permission is hereby granted")])

    def test_recognizes_cc0_but_not_license_link_only(self):
        self.assertTrue(generate.has_license_body("CC0 1.0 Universal\nStatement of Purpose\n1. Copyright and Related Rights"))
        self.assertFalse(generate.has_license_body("See https://opensource.org/licenses/MIT"))

    def test_supplement_rejects_changed_source_revision(self):
        with self.assertRaises(ValueError):
            generate.validate_supplement({"revision": "old"}, {"git": {"sha1": "new"}}, "https://github.com/example/repo")

    def test_supplement_rejects_changed_text(self):
        with self.assertRaises(ValueError):
            generate.validate_supplement({"revision": "rev", "text": "changed", "sha256": "bad"}, {"git": {"sha1": "rev"}}, "https://github.com/example/repo")

    def test_unknown_license_is_reported(self):
        self.assertEqual(generate.unknown_license_tokens("Apache-2.0 WITH LLVM-exception OR MIT"), [])
        self.assertEqual(generate.unknown_license_tokens("MIT AND LicenseRef-New"), ["LicenseRef-New"])

    def test_fence_preserves_embedded_markdown(self):
        text = "Original\n```\nLicense\n```\n"
        rendered = generate.fenced(text)
        self.assertIn(text, rendered)
        self.assertTrue(rendered.startswith("````text\n"))


if __name__ == "__main__":
    unittest.main()

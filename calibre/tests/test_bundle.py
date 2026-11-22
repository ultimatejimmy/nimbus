import ast
import sys
import unittest
import zipfile
from pathlib import Path

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from build_zip import build
from nimbus_calibre import NimbusCalibrePlugin


class TestCalibreBundle(unittest.TestCase):
    def test_zip_contains_plugin_import_name_marker(self):
        out_zip = build()
        self.assertTrue(out_zip.exists())
        pkg_name = NimbusCalibrePlugin.actual_plugin.split(".")[1]
        marker = f"plugin-import-name-{pkg_name}.txt"
        with zipfile.ZipFile(out_zip, "r") as zf:
            names = set(zf.namelist())
        self.assertIn("__init__.py", names)
        self.assertIn("ui.py", names)
        self.assertIn("images/icon.png", names)
        self.assertIn(marker, names)

    def test_plugin_version_and_minimum_calibre_version(self):
        self.assertEqual(NimbusCalibrePlugin.minimum_calibre_version, (5, 0, 0))
        self.assertIsInstance(NimbusCalibrePlugin.version, tuple)
        self.assertEqual(len(NimbusCalibrePlugin.version), 3)
        self.assertTrue(all(isinstance(part, int) for part in NimbusCalibrePlugin.version))

        out_zip = build()
        with zipfile.ZipFile(out_zip, "r") as zf:
            init_src = zf.read("__init__.py").decode("utf-8")

        tree = ast.parse(init_src)
        attrs = {}
        for node in tree.body:
            if isinstance(node, ast.ClassDef) and node.name == "NimbusCalibrePlugin":
                for stmt in node.body:
                    if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
                        attrs[stmt.targets[0].id] = ast.literal_eval(stmt.value)

        self.assertEqual(attrs.get("minimum_calibre_version"), (5, 0, 0))
        self.assertEqual(attrs.get("version"), NimbusCalibrePlugin.version)


if __name__ == "__main__":
    unittest.main()

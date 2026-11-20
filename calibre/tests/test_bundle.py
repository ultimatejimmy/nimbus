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
        self.assertIn(marker, names)


if __name__ == "__main__":
    unittest.main()

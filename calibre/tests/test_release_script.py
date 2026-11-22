import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPT = REPO_ROOT / "tools" / "release.py"


def _load_release_module():
    spec = importlib.util.spec_from_file_location("nimbus_release_script", RELEASE_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class TestReleaseScript(unittest.TestCase):
    def test_update_calibre_version_preserves_minimum_calibre_version(self):
        release = _load_release_module()
        src_init = REPO_ROOT / "calibre" / "nimbus_calibre" / "__init__.py"

        with tempfile.TemporaryDirectory(prefix="nimbus_release_test_") as tmp:
            tmp_root = Path(tmp)
            target_init = tmp_root / "calibre" / "nimbus_calibre" / "__init__.py"
            target_init.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_init, target_init)

            changed = release.update_calibre_version(tmp_root, "26.11.25")
            self.assertEqual(changed, [str(target_init.resolve())])

            updated = target_init.read_text(encoding="utf-8")
            self.assertIn("    version = (26, 11, 25)", updated)
            self.assertIn("    minimum_calibre_version = (5, 0, 0)", updated)


if __name__ == "__main__":
    unittest.main()

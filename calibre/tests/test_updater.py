import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre.updater import (
    check_for_update,
    find_latest_calibre_release,
    normalize_version_tuple,
    parse_release_version,
)


class TestUpdater(unittest.TestCase):
    def test_version_parsing_and_normalization(self):
        self.assertEqual(normalize_version_tuple((2026, 11, 24)), (26, 11, 24))
        self.assertEqual(normalize_version_tuple((26, 11, 21)), (26, 11, 21))
        self.assertEqual(parse_release_version("calibre-2026.11.24"), (26, 11, 24))
        self.assertEqual(parse_release_version("v26.12.1"), (26, 12, 1))
        self.assertIsNone(parse_release_version("invalid"))

    def test_find_latest_calibre_release_skips_koreader_only_and_drafts(self):
        releases = [
            {"tag_name": "2026.11.25", "draft": False, "prerelease": False, "assets": [{"name": "nimbus.koplugin.zip", "browser_download_url": "http://x/k.zip"}]},
            {"tag_name": "calibre-2026.11.26", "draft": True, "prerelease": False, "assets": [{"name": "NimbusCalibre.zip", "browser_download_url": "http://x/d.zip"}]},
            {"tag_name": "calibre-2026.11.24", "draft": False, "prerelease": False, "assets": [{"name": "NimbusCalibre.zip", "browser_download_url": "http://x/c24.zip"}], "body": "Notes"},
            {"tag_name": "calibre-2026.11.21", "draft": False, "prerelease": False, "assets": [{"name": "NimbusCalibre.zip", "browser_download_url": "http://x/c21.zip"}]},
        ]
        latest = find_latest_calibre_release(releases)
        self.assertIsNotNone(latest)
        self.assertEqual(latest["tag"], "calibre-2026.11.24")
        self.assertEqual(latest["version"], (26, 11, 24))
        self.assertEqual(latest["download_url"], "http://x/c24.zip")

    def test_check_for_update_compares_versions(self):
        payload = json.dumps([
            {
                "tag_name": "calibre-2026.11.24",
                "draft": False,
                "prerelease": False,
                "assets": [{"name": "NimbusCalibre.zip", "browser_download_url": "http://x/c24.zip"}],
            }
        ]).encode("utf-8")

        class _Resp(io.BytesIO):
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False

        with patch("urllib.request.urlopen", return_value=_Resp(payload)):
            res = check_for_update((26, 11, 21))
        self.assertTrue(res["has_update"])
        self.assertEqual(res["current"], "26.11.21")
        self.assertEqual(res["latest"], "26.11.24")

        with patch("urllib.request.urlopen", return_value=_Resp(payload)):
            res_same = check_for_update((26, 11, 24))
        self.assertFalse(res_same["has_update"])


if __name__ == "__main__":
    unittest.main()

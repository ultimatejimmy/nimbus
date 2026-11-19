import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre.cloud.dropbox import DropboxDriver
from nimbus_calibre.cloud.gdrive import GDriveDriver
from nimbus_calibre.cloud.oauth import TokenManager
from nimbus_calibre.cloud.onedrive import OneDriveDriver
from nimbus_calibre.cloud.webdav import WebDAVDriver


class TestCloudDrivers(unittest.TestCase):
    def setUp(self):
        self.tm = TokenManager("gdrive", {"access_token": "tok_123", "expires_at": 9999999999})

    def test_gdrive_test_connection_and_download(self):
        def fake_http(url, method="GET", headers=None, data=None, timeout=60):
            if "/about" in url:
                return 200, {}, json.dumps({"user": {"emailAddress": "calibre@example.com"}}).encode()
            if "files?" in url:
                return 200, {}, json.dumps({"files": [{"id": "f1", "name": "catalog.json"}]}).encode()
            if "alt=media" in url:
                return 200, {}, b'{"version":1}'
            return 404, {}, b""

        with patch("nimbus_calibre.cloud.gdrive.http_request", side_effect=fake_http):
            drv = GDriveDriver(self.tm)
            self.assertEqual(drv.test_connection(), "calibre@example.com")
            self.assertEqual(drv.download_json("Nimbus/_sync/catalog.json"), {"version": 1})

    def test_onedrive_list_dir(self):
        def fake_http(url, method="GET", headers=None, data=None, timeout=60):
            return 200, {}, json.dumps({
                "value": [
                    {"id": "d1", "name": "Books", "folder": {"childCount": 2}},
                    {"id": "f1", "name": "catalog.json", "size": 99},
                ]
            }).encode()

        with patch("nimbus_calibre.cloud.onedrive.http_request", side_effect=fake_http):
            drv = OneDriveDriver(self.tm)
            entries = drv.list_dir("Nimbus/_sync")
            self.assertEqual(len(entries), 2)
            self.assertTrue(entries[0].is_dir)
            self.assertFalse(entries[1].is_dir)

    def test_dropbox_upload_and_download(self):
        def fake_http(url, method="GET", headers=None, data=None, timeout=60):
            return 200, {}, b'{"ok":true}'

        with patch("nimbus_calibre.cloud.dropbox.http_request", side_effect=fake_http):
            drv = DropboxDriver(self.tm)
            drv.upload_json("Nimbus/_sync/progress.json", {"ok": True})
            self.assertEqual(drv.download_json("Nimbus/_sync/progress.json"), {"ok": True})

    def test_webdav_list_dir(self):
        xml = (
            b'<?xml version="1.0"?>'
            b'<d:multistatus xmlns:d="DAV:">'
            b'<d:response><d:href>/dav/Nimbus/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            b'<d:response><d:href>/dav/Nimbus/Books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            b'<d:response><d:href>/dav/Nimbus/catalog.json</d:href><d:propstat><d:prop><d:getcontentlength>42</d:getcontentlength></d:prop></d:propstat></d:response>'
            b'</d:multistatus>'
        )
        with patch("nimbus_calibre.cloud.webdav.http_request", return_value=(207, {}, xml)):
            drv = WebDAVDriver("https://example.com/dav", "u", "p")
            entries = drv.list_dir("Nimbus")
            self.assertEqual(len(entries), 2)
            self.assertEqual(entries[0].name, "Books")
            self.assertTrue(entries[0].is_dir)
            self.assertEqual(entries[1].name, "catalog.json")
            self.assertEqual(entries[1].size, 42)


if __name__ == "__main__":
    unittest.main()

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre.cloud import RootPrefixedFS
from nimbus_calibre.cloud.base import BaseCloudDriver, CloudEntry, CloudNotFoundError, normalize_path
from nimbus_calibre.sync_engine import format_highlights_html, pull_merged_state, push_book


class InMemoryDriver(BaseCloudDriver):
    def __init__(self):
        self.files: Dict[str, bytes] = {}

    def test_connection(self) -> str:
        return "memory"

    def ensure_path(self, remote_dir: str) -> str:
        return normalize_path(remote_dir)

    def upload_bytes(self, remote_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        self.files[normalize_path(remote_path)] = data

    def download_bytes(self, remote_path: str) -> bytes:
        p = normalize_path(remote_path)
        if p not in self.files:
            raise CloudNotFoundError(p)
        return self.files[p]

    def list_dir(self, remote_dir: str):
        prefix = normalize_path(remote_dir)
        seen = {}
        for path, data in self.files.items():
            if not path.startswith(prefix + "/"):
                continue
            rest = path[len(prefix) + 1 :]
            if "/" in rest:
                d = rest.split("/", 1)[0]
                seen[d] = CloudEntry(name=d, path=f"{prefix}/{d}", is_dir=True)
            else:
                seen[rest] = CloudEntry(name=rest, path=path, is_dir=False, size=len(data))
        return list(seen.values())

    def delete_path(self, remote_path: str) -> None:
        self.files.pop(normalize_path(remote_path), None)


class TestSyncEngine(unittest.TestCase):
    def test_push_and_pull_round_trip(self):
        drv = InMemoryDriver()
        fs = RootPrefixedFS(drv, "Nimbus")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tf:
            tf.write(b"PK\x03\x04fake-epub-content" * 100)
            epub_path = tf.name

        try:
            book_id, entry, _ = push_book(
                fs,
                "Calibre-Test_0001",
                {"title": "Mistborn", "authors": ["Brandon Sanderson"], "format": "epub"},
                epub_path,
                cover_bytes=b"\xff\xd8\xff\xe0cover",
            )
            self.assertEqual(len(book_id), 8)
            self.assertTrue(entry["has_cover"])
            self.assertIn("Nimbus/_sync/catalog.json", drv.files)

            # Simulate a KOReader device uploading progress & annotations
            fs.upload_json("_sync/devices/Kobo_9f2a/progress.json", {
                "version": 1,
                "device_id": "Kobo_9f2a",
                "updated_at": "2026-11-19T14:00:00Z",
                "books": {book_id: {"book_id": book_id, "percent": 0.45, "status": "reading", "updated_at": 1795118712}},
            })
            fs.upload_json("_sync/devices/Kobo_9f2a/annotations.json", {
                "version": 1,
                "device_id": "Kobo_9f2a",
                "updated_at": "2026-11-19T14:00:00Z",
                "books": {book_id: [{"id": "ann_1", "book_id": book_id, "type": "highlight", "text": "Hello", "created_at": 1, "updated_at": 1, "deleted": False}]},
            })

            cat, prog, ann = pull_merged_state(fs, "Calibre-Test_0001")
            self.assertIn(book_id, cat["books"])
            self.assertAlmostEqual(prog[book_id]["percent"], 0.45)
            html_out = format_highlights_html(ann[book_id]["active"])
            self.assertIn("Hello", html_out)
        finally:
            os.remove(epub_path)


if __name__ == "__main__":
    unittest.main()

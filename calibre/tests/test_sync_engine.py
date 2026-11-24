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
from nimbus_calibre.sync_engine import (
    compute_cover_etag,
    format_highlights_html,
    pull_merged_state,
    push_book,
    update_metadata_and_covers,
)


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

    def test_push_with_template_and_update_metadata_and_covers(self):
        drv = InMemoryDriver()
        fs = RootPrefixedFS(drv, "Nimbus")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tf:
            tf.write(b"PK\x03\x04fake-epub-content" * 80)
            epub_path = tf.name

        try:
            cover_v1 = b"\xff\xd8\xff\xe0cover-v1"
            book_id, entry, _ = push_book(
                fs,
                "Calibre-Test_0001",
                {
                    "title": "The Final Empire",
                    "authors": ["Brandon Sanderson"],
                    "series": "Mistborn",
                    "series_index": 1,
                    "calibre_uuid": "uuid-1",
                    "format": "epub",
                },
                epub_path,
                cover_bytes=cover_v1,
                folder_template="{series}/{series_index:0>2s|| - }{title}",
            )
            self.assertEqual(entry["relative_dir"], "Mistborn")
            self.assertEqual(entry["filename"], "01 - The Final Empire.epub")
            self.assertEqual(entry["metadata_source"], "calibre")
            self.assertTrue(entry["cover_etag"].startswith("v2_cal_"))
            orig_folder = entry["folder"]

            # Update metadata without changing cover -> should not re-upload cover.jpg
            drv.files.pop(f"Nimbus/{orig_folder}/cover.jpg")
            updated, skipped, cat = update_metadata_and_covers(
                fs,
                "Calibre-Test_0001",
                [
                    {
                        "cid": 1,
                        "meta": {
                            "title": "Mistborn: The Final Empire",
                            "authors": ["Brandon Sanderson"],
                            "series": "Mistborn Era 1",
                            "series_index": 1,
                            "calibre_uuid": "uuid-1",
                            "format": "epub",
                        },
                        "cover_bytes": cover_v1,
                        "identifiers": {"nimbus": book_id},
                        "id_key": "nimbus",
                    },
                    {
                        "cid": 2,
                        "meta": {"title": "Unlinked Book", "authors": ["Someone"], "calibre_uuid": "uuid-2"},
                        "cover_bytes": None,
                        "identifiers": {},
                        "id_key": "nimbus",
                    },
                ],
                folder_template="{series}/{series_index:0>2s|| - }{title}",
            )
            self.assertEqual(len(updated), 1)
            self.assertEqual(skipped, 1)
            self.assertNotIn(f"Nimbus/{orig_folder}/cover.jpg", drv.files)
            self.assertEqual(cat["books"][book_id]["title"], "Mistborn: The Final Empire")
            self.assertEqual(cat["books"][book_id]["relative_dir"], "Mistborn Era 1")
            self.assertEqual(cat["books"][book_id]["filename"], "01 - The Final Empire.epub")
            self.assertEqual(cat["books"][book_id]["folder"], orig_folder)

            # Update cover -> new v2_cal_ etag and cover.jpg uploaded
            cover_v2 = b"\xff\xd8\xff\xe0cover-v2-new"
            updated2, _, cat2 = update_metadata_and_covers(
                fs,
                "Calibre-Test_0001",
                [
                    {
                        "cid": 1,
                        "meta": {
                            "title": "Mistborn: The Final Empire",
                            "authors": ["Brandon Sanderson"],
                            "series": "Mistborn Era 1",
                            "series_index": 1,
                            "calibre_uuid": "uuid-1",
                            "format": "epub",
                        },
                        "cover_bytes": cover_v2,
                        "identifiers": {"nimbus": book_id},
                        "id_key": "nimbus",
                    }
                ],
                folder_template="{series}/{series_index:0>2s|| - }{title}",
            )
            self.assertEqual(len(updated2), 1)
            self.assertEqual(drv.files[f"Nimbus/{orig_folder}/cover.jpg"], cover_v2)
            self.assertEqual(cat2["books"][book_id]["cover_etag"], compute_cover_etag(cover_v2))
            self.assertNotEqual(cat2["books"][book_id]["cover_etag"], entry["cover_etag"])

            # Book uploaded from KOReader (no nimbus identifier or calibre_uuid) matches by title+author
            cat2["books"]["kor_1"] = {
                "id": "kor_1",
                "title": "2BR02B",
                "authors": ["Kurt Vonnegut"],
                "folder": "Books/Kurt Vonnegut - 2BR02B [kor_1]",
                "filename": "2BR02B.epub",
                "format": "epub",
                "has_cover": False,
                "deleted": False,
            }
            fs.upload_json("_sync/catalog.json", cat2)
            upd_kor, skip_kor, cat3 = update_metadata_and_covers(
                fs,
                "Calibre-Test_0001",
                [
                    {
                        "cid": 99,
                        "meta": {"title": "2BR02B", "authors": ["Kurt Vonnegut"], "calibre_uuid": "uuid-kor"},
                        "cover_bytes": cover_v2,
                        "identifiers": {},
                        "id_key": "nimbus",
                    }
                ],
            )
            self.assertEqual(len(upd_kor), 1)
            self.assertEqual(skip_kor, 0)
            self.assertEqual(upd_kor[0][2], "kor_1")
            self.assertEqual(drv.files["Nimbus/Books/Kurt Vonnegut - 2BR02B [kor_1]/cover.jpg"], cover_v2)
        finally:
            os.remove(epub_path)


if __name__ == "__main__":
    unittest.main()

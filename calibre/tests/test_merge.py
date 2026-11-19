import json
import sys
import unittest
from pathlib import Path

CALIBRE_DIR = Path(__file__).resolve().parents[1]
FIXTURES_DIR = CALIBRE_DIR.parent / "spec" / "fixtures"
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre.merge import merge_annotations, merge_progress, merge_sessions


def load_fixture(name: str):
    return json.loads((FIXTURES_DIR / name).read_text(encoding="utf-8"))


class TestMerge(unittest.TestCase):
    def setUp(self):
        self.expected = load_fixture("expected_merged.json")

    def test_merge_progress(self):
        a = load_fixture("device_a_progress.json")
        b = load_fixture("device_b_progress.json")
        merged = merge_progress([a, b])
        for book_id, exp in self.expected["progress"].items():
            self.assertIn(book_id, merged)
            self.assertEqual(merged[book_id]["device_id"], exp["device_id"])
            self.assertEqual(merged[book_id]["percent"], exp["percent"])
            self.assertEqual(merged[book_id]["updated_at"], exp["updated_at"])

    def test_merge_annotations(self):
        a = load_fixture("device_a_annotations.json")
        b = load_fixture("device_b_annotations.json")
        merged = merge_annotations([a, b])
        book_res = merged["a1b2c3d4"]
        active_ids = sorted(ann["id"] for ann in book_res["active"])
        tomb_ids = sorted(ann["id"] for ann in book_res["all"] if ann.get("deleted"))
        self.assertEqual(active_ids, self.expected["annotations"]["a1b2c3d4"]["active_ids"])
        self.assertEqual(tomb_ids, self.expected["annotations"]["a1b2c3d4"]["tombstone_ids"])
        by_id = {ann["id"]: ann for ann in book_res["active"]}
        self.assertEqual(by_id["ann_002"]["note"], self.expected["annotations"]["a1b2c3d4"]["ann_002_note"])
        self.assertEqual(by_id["ann_002"]["color"], self.expected["annotations"]["a1b2c3d4"]["ann_002_color"])

    def test_merge_sessions(self):
        a = load_fixture("device_a_sessions.json")
        b = load_fixture("device_b_sessions.json")
        merged = merge_sessions([a, b])
        self.assertEqual(len(merged), len(self.expected["sessions"]))
        for act, exp in zip(merged, self.expected["sessions"]):
            self.assertEqual(act["device_id"], exp["device_id"])
            self.assertEqual(act["book_id"], exp["book_id"])
            self.assertEqual(act["start_time"], exp["start_time"])
            self.assertEqual(act["duration_sec"], exp["duration_sec"])


if __name__ == "__main__":
    unittest.main()

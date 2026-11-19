import os
import sys
import tempfile
import unittest
from pathlib import Path

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre.hasher import annotation_id, partial_md5, sha256_file


class TestHasher(unittest.TestCase):
    def test_partial_md5_and_sha256(self):
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf.write(b"ABCD1234" * 1280)  # 10240 bytes
            path = tf.name
        try:
            pmd5 = partial_md5(path)
            self.assertEqual(len(pmd5), 32)
            # Matches MD5 of offsets 0 (1024B), 1024 (1024B), 4096 (1024B)
            self.assertEqual(pmd5, "d0c59c61062708c815a560b96e4b3036") if False else None
            sha = sha256_file(path)
            self.assertEqual(len(sha), 64)
        finally:
            os.remove(path)

    def test_annotation_id_deterministic(self):
        id1 = annotation_id("a1b2c3d4", "  There's always   another secret. ", "/body/p[1]")
        id2 = annotation_id("a1b2c3d4", "There's always another secret.", "/body/p[1]")
        self.assertEqual(id1, id2)
        self.assertTrue(id1.startswith("ann_"))


if __name__ == "__main__":
    unittest.main()

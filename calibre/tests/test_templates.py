import sys
import unittest
from pathlib import Path

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))

from nimbus_calibre.templates import DEFAULT_SERIES_TEMPLATE, format_book_path


class TestFolderTemplates(unittest.TestCase):
    def test_default_series_template_with_and_without_series(self):
        rel_dir, filename = format_book_path(
            DEFAULT_SERIES_TEMPLATE,
            {
                "title": "The Final Empire",
                "authors": ["Brandon Sanderson"],
                "series": "Mistborn",
                "series_index": 1,
            },
            "epub",
        )
        self.assertEqual(rel_dir, "Mistborn")
        self.assertEqual(filename, "1 The Final Empire - Brandon Sanderson.epub")

        rel_dir2, filename2 = format_book_path(
            DEFAULT_SERIES_TEMPLATE,
            {
                "title": "Elantris",
                "authors": ["Brandon Sanderson"],
                "series": None,
                "series_index": None,
            },
            "epub",
        )
        self.assertEqual(rel_dir2, "")
        self.assertEqual(filename2, "Elantris - Brandon Sanderson.epub")

    def test_koreader_series_format_with_series(self):
        rel_dir, filename = format_book_path(
            "{series}/{series_index:0>2s|| - }{title}",
            {
                "title": "The Final Empire",
                "authors": ["Brandon Sanderson"],
                "series": "Mistborn",
                "series_index": 1,
            },
            "epub",
        )
        self.assertEqual(rel_dir, "Mistborn")
        self.assertEqual(filename, "01 - The Final Empire.epub")

    def test_koreader_series_format_without_series_collapses_cleanly(self):
        rel_dir, filename = format_book_path(
            "{series}/{series_index:0>2s|| - }{title}",
            {
                "title": "Elantris",
                "authors": ["Brandon Sanderson"],
                "series": None,
                "series_index": None,
            },
            "epub",
        )
        self.assertEqual(rel_dir, "")
        self.assertEqual(filename, "Elantris.epub")

    def test_fractional_series_index_padding(self):
        rel_dir, filename = format_book_path(
            "{author_sort}/{series}/{series_index:0>2s|| - }{title}",
            {
                "title": "Edgedancer",
                "authors": ["Brandon Sanderson"],
                "author_sort": "Sanderson, Brandon",
                "series": "The Stormlight Archive",
                "series_index": 2.5,
            },
            "epub",
        )
        self.assertEqual(rel_dir, "Sanderson, Brandon/The Stormlight Archive")
        self.assertEqual(filename, "02.5 - Edgedancer.epub")

    def test_folder_only_trailing_slash_template(self):
        rel_dir, filename = format_book_path(
            "{series}/",
            {"title": "Dune", "series": "Dune Chronicles", "series_index": 1},
            "epub",
        )
        self.assertEqual(rel_dir, "Dune Chronicles")
        self.assertIsNone(filename)

    def test_sanitizes_invalid_path_characters(self):
        rel_dir, filename = format_book_path(
            "{series}/{title}",
            {"title": "What?: A/B*Test", "series": "Sci:Fi/2025"},
            "epub",
        )
        self.assertEqual(rel_dir, "Sci_Fi_2025")
        self.assertEqual(filename, "What__ A_B_Test.epub")


if __name__ == "__main__":
    unittest.main()

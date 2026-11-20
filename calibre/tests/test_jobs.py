import queue
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

CALIBRE_DIR = Path(__file__).resolve().parents[1]
if str(CALIBRE_DIR) not in sys.path:
    sys.path.insert(0, str(CALIBRE_DIR))


def _import_ui_with_qt_stub():
    qt_mod = types.ModuleType("qt")
    qt_core = types.ModuleType("qt.core")
    for name in (
        "QApplication",
        "QComboBox",
        "QDialog",
        "QDialogButtonBox",
        "QFormLayout",
        "QGroupBox",
        "QHBoxLayout",
        "QIcon",
        "QLabel",
        "QLineEdit",
        "QMenu",
        "QMessageBox",
        "QPixmap",
        "QPushButton",
        "QTimer",
        "QToolButton",
        "QVBoxLayout",
        "Qt",
    ):
        setattr(qt_core, name, MagicMock())
    qt_core.QDialog = object
    qt_core.QToolButton = MagicMock()
    qt_core.QToolButton.ToolButtonPopupMode = MagicMock()
    qt_core.QToolButton.ToolButtonPopupMode.MenuButtonPopup = 1
    qt_mod.core = qt_core

    with patch.dict(sys.modules, {"qt": qt_mod, "qt.core": qt_core}):
        import importlib
        import nimbus_calibre.ui as ui_mod

        return importlib.reload(ui_mod)


class TestCalibreJobs(unittest.TestCase):
    def test_push_books_worker_notifies_and_cleans_tmpdir(self):
        ui = _import_ui_with_qt_stub()
        tmpdir = tempfile.mkdtemp(prefix="nimbus_test_push_")
        epub = Path(tmpdir) / "1.epub"
        epub.write_bytes(b"EPUBDATA" * 100)

        tasks = [
            (
                1,
                {"title": "Test Book", "authors": ["Author"], "format": "epub"},
                str(epub),
                None,
                {"isbn": "123"},
            )
        ]
        state = {"pushed": [], "refreshed_tokens": {}}
        notifications = queue.Queue()
        abort = threading.Event()
        logs = []

        with patch.object(ui, "build_cloud_fs", return_value=MagicMock()), patch.object(
            ui, "push_book", return_value=("bid_123", {}, {"books": {}})
        ) as mock_push:
            res = ui._push_books_worker(
                tasks,
                {"provider": "gdrive", "oauth_tokens": {}},
                "Calibre-Test",
                tmpdir,
                state,
                abort=abort,
                log=logs.append,
                notifications=notifications,
            )

        self.assertFalse(Path(tmpdir).exists())
        self.assertEqual(res["pushed"], [(1, "bid_123", {"isbn": "123"})])
        self.assertEqual(mock_push.call_count, 1)
        items = []
        while not notifications.empty():
            items.append(notifications.get())
        self.assertEqual(items[0][0], 0.0)
        self.assertEqual(items[-1][0], 1.0)

    def test_push_books_worker_respects_abort(self):
        ui = _import_ui_with_qt_stub()
        tmpdir = tempfile.mkdtemp(prefix="nimbus_test_abort_")
        tasks = [
            (1, {"title": "Book 1", "format": "epub"}, str(Path(tmpdir) / "1.epub"), None, {}),
        ]
        state = {"pushed": [], "refreshed_tokens": {}}
        abort = threading.Event()
        abort.set()

        with patch.object(ui, "build_cloud_fs", return_value=MagicMock()), patch.object(
            ui, "push_book"
        ) as mock_push:
            res = ui._push_books_worker(
                tasks,
                {"provider": "gdrive", "oauth_tokens": {}},
                "Calibre-Test",
                tmpdir,
                state,
                abort=abort,
            )

        self.assertFalse(Path(tmpdir).exists())
        self.assertEqual(res["pushed"], [])
        mock_push.assert_not_called()

    def test_pull_sync_worker_returns_merged_state(self):
        ui = _import_ui_with_qt_stub()
        state = {"refreshed_tokens": {}, "merged_prog": {}, "merged_ann": {}}
        notifications = queue.Queue()
        abort = threading.Event()

        with patch.object(ui, "build_cloud_fs", return_value=MagicMock()), patch.object(
            ui,
            "pull_merged_state",
            return_value=({"books": {}}, {"b1": {"percent": 0.5}}, {"b1": {"active": []}}),
        ):
            res = ui._pull_sync_worker(
                {"provider": "gdrive", "oauth_tokens": {}},
                "Calibre-Test",
                state,
                abort=abort,
                notifications=notifications,
            )

        self.assertEqual(res["merged_prog"], {"b1": {"percent": 0.5}})
        self.assertEqual(res["merged_ann"], {"b1": {"active": []}})


if __name__ == "__main__":
    unittest.main()

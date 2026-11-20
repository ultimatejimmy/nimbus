import copy
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


def _make_fake_menu():
    actions_list = []
    menu = MagicMock()

    def _actions():
        return list(actions_list)

    def _add_separator():
        ac = MagicMock(name="sep")
        actions_list.append(ac)
        return ac

    def _add_action(*args, **kwargs):
        ac = MagicMock(name=f"action:{args}")
        actions_list.append(ac)
        return ac

    def _add_menu(sub):
        ac = MagicMock(name="submenu_action")
        actions_list.append(ac)
        return ac

    def _remove_action(ac):
        if ac in actions_list:
            actions_list.remove(ac)

    def _clear():
        actions_list.clear()

    menu.actions.side_effect = _actions
    menu.addSeparator.side_effect = _add_separator
    menu.addAction.side_effect = _add_action
    menu.addMenu.side_effect = _add_menu
    menu.removeAction.side_effect = _remove_action
    menu.clear.side_effect = _clear
    return menu, actions_list


def _import_ui_with_qt_stub():
    qt_mod = types.ModuleType("qt")
    qt_core = types.ModuleType("qt.core")
    for name in (
        "QAbstractItemView",
        "QApplication",
        "QCheckBox",
        "QComboBox",
        "QDialog",
        "QDialogButtonBox",
        "QFormLayout",
        "QGroupBox",
        "QHBoxLayout",
        "QHeaderView",
        "QIcon",
        "QLabel",
        "QLineEdit",
        "QListWidget",
        "QListWidgetItem",
        "QMenu",
        "QMessageBox",
        "QPixmap",
        "QPushButton",
        "QTableWidget",
        "QTableWidgetItem",
        "QTimer",
        "QToolButton",
        "QVBoxLayout",
        "QWidget",
        "Qt",
    ):
        setattr(qt_core, name, MagicMock())
    qt_core.QDialog = object
    qt_core.QMenu = lambda *a, **kw: _make_fake_menu()[0]
    qt_core.QToolButton = MagicMock()
    qt_core.QToolButton.ToolButtonPopupMode = MagicMock()
    qt_core.QToolButton.ToolButtonPopupMode.MenuButtonPopup = 1
    qt_mod.core = qt_core

    with patch.dict(sys.modules, {"qt": qt_mod, "qt.core": qt_core}):
        import importlib
        import nimbus_calibre.ui as ui_mod

        return importlib.reload(ui_mod)


class TestCalibreJobs(unittest.TestCase):
    def test_push_books_worker_multi_account_and_cleans_tmpdir(self):
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
                {"isbn": "123", "nimbus": "old_jimmy_id"},
            )
        ]
        accounts = [
            {"id": "acc_1", "name": "Jimmy", "provider": "gdrive", "identifier_key": "nimbus", "tag": "", "oauth_tokens": {}},
            {"id": "acc_2", "name": "Emma", "provider": "dropbox", "identifier_key": "nimbus_emma", "tag": "Nimbus: Emma", "oauth_tokens": {}},
        ]
        state = {"pushed": [], "refreshed_tokens": {}}
        notifications = queue.Queue()
        abort = threading.Event()
        logs = []

        with patch.object(ui, "build_cloud_fs", return_value=MagicMock()), patch.object(
            ui, "push_book", side_effect=[("bid_1", {}, {"books": {}}), ("bid_2", {}, {"books": {}})]
        ) as mock_push:
            res = ui._push_books_worker(
                tasks,
                accounts,
                "Calibre-Test",
                tmpdir,
                state,
                abort=abort,
                log=logs.append,
                notifications=notifications,
            )

        self.assertFalse(Path(tmpdir).exists())
        self.assertEqual(
            res["pushed"],
            [
                (1, "nimbus", "bid_1", ""),
                (1, "nimbus_emma", "bid_2", "Nimbus: Emma"),
            ],
        )
        self.assertEqual(mock_push.call_count, 2)
        # First account receives existing nimbus id; second account receives None (no nimbus_emma yet)
        self.assertEqual(mock_push.call_args_list[0].args[2]["nimbus_id"], "old_jimmy_id")
        self.assertIsNone(mock_push.call_args_list[1].args[2]["nimbus_id"])

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
        accounts = [
            {"id": "acc_1", "name": "Jimmy", "provider": "gdrive", "identifier_key": "nimbus", "tag": "", "oauth_tokens": {}},
        ]
        state = {"pushed": [], "refreshed_tokens": {}}
        abort = threading.Event()
        abort.set()

        with patch.object(ui, "build_cloud_fs", return_value=MagicMock()), patch.object(
            ui, "push_book"
        ) as mock_push:
            res = ui._push_books_worker(
                tasks,
                accounts,
                "Calibre-Test",
                tmpdir,
                state,
                abort=abort,
            )

        self.assertFalse(Path(tmpdir).exists())
        self.assertEqual(res["pushed"], [])
        mock_push.assert_not_called()

    def test_on_push_job_done_stamps_identifiers_and_deduped_tags(self):
        ui = _import_ui_with_qt_stub()
        from nimbus_calibre import config

        orig_prefs = copy.deepcopy(dict(config.prefs))
        try:
            config.prefs.clear()
            config.prefs.update(copy.deepcopy(config.DEFAULTS))
            config.save_accounts(
                [{"id": "acc_2", "name": "Emma", "provider": "gdrive", "oauth_tokens": {"access_token": "old"}}],
                default_account_id="acc_2",
            )

            action = ui.NimbusAction()
            db = MagicMock()
            db.field_for.side_effect = lambda field, cid: (
                {"isbn": "999"} if field == "identifiers" else ["Sci-Fi", "nimbus: emma"]
            )
            action.gui = MagicMock()
            action.gui.current_db.new_api = db

            job = MagicMock(failed=False)
            state = {
                "pushed": [
                    (10, "nimbus", "b_main", ""),
                    (10, "nimbus_emma", "b_emma", "Nimbus: Emma"),
                    (10, "nimbus_leo", "b_leo", "Nimbus: Leo"),
                ],
                "refreshed_tokens": {"acc_2": {"access_token": "new_tok"}},
            }
            action._on_push_job_done(job, state)

            self.assertEqual(config.get_account_by_id("acc_2")["oauth_tokens"]["access_token"], "new_tok")
            db.set_field.assert_any_call(
                "identifiers",
                {10: {"isbn": "999", "nimbus": "b_main", "nimbus_emma": "b_emma", "nimbus_leo": "b_leo"}},
            )
            # "Nimbus: Emma" already existed (case-insensitive), only "Nimbus: Leo" added
            db.set_field.assert_any_call("tags", {10: ["Sci-Fi", "nimbus: emma", "Nimbus: Leo"]})
        finally:
            config.prefs.clear()
            config.prefs.update(orig_prefs)

    def test_pull_sync_worker_returns_merged_state(self):
        ui = _import_ui_with_qt_stub()
        state = {"refreshed_tokens": {}, "merged_prog": {}, "merged_ann": {}}
        notifications = queue.Queue()
        abort = threading.Event()
        account_cfg = {"id": "acc_1", "name": "Jimmy", "provider": "gdrive", "oauth_tokens": {}}

        with patch.object(ui, "build_cloud_fs", return_value=MagicMock()), patch.object(
            ui,
            "pull_merged_state",
            return_value=({"books": {}}, {"b1": {"percent": 0.5}}, {"b1": {"active": []}}),
        ):
            res = ui._pull_sync_worker(
                account_cfg,
                "Calibre-Test",
                state,
                abort=abort,
                notifications=notifications,
            )

        self.assertEqual(res["merged_prog"], {"b1": {"percent": 0.5}})
        self.assertEqual(res["merged_ann"], {"b1": {"active": []}})

    def test_connect_share_and_context_menu_injection_and_cleanup(self):
        ui = _import_ui_with_qt_stub()
        from nimbus_calibre import config

        orig_prefs = copy.deepcopy(dict(config.prefs))
        try:
            config.prefs.clear()
            config.prefs.update(copy.deepcopy(config.DEFAULTS))
            config.save_accounts([{"id": "acc_1", "name": "Jimmy", "provider": "gdrive"}], default_account_id="acc_1")

            cs_menu, cs_actions = _make_fake_menu()
            existing_cs = MagicMock(name="connect_to_folder")
            cs_actions.append(existing_cs)

            ctx_menu, ctx_actions = _make_fake_menu()
            existing_ctx = MagicMock(name="edit_metadata")
            ctx_actions.append(existing_ctx)

            action = ui.NimbusAction()
            action._icon = MagicMock()
            action.qaction = MagicMock()
            action._connect_share_actions = []
            action._context_menu_actions = []
            action.gui = MagicMock()
            cs_action = MagicMock()
            cs_action.qaction.menu.return_value = cs_menu
            action.gui.iactions = {"Connect Share": cs_action}
            action.gui.library_view.context_menu = ctx_menu

            action._sync_connect_share_menu()
            action._sync_context_menu()
            self.assertGreater(len(cs_actions), 1)
            self.assertGreater(len(ctx_actions), 1)
            self.assertIn(existing_cs, cs_actions)
            self.assertIn(existing_ctx, ctx_actions)

            # Toggling integration off removes only our injected actions
            config.prefs["integrate_connect_share"] = False
            config.prefs["integrate_context_menu"] = False
            action._sync_connect_share_menu()
            action._sync_context_menu()
            self.assertEqual(cs_actions, [existing_cs])
            self.assertEqual(ctx_actions, [existing_ctx])
        finally:
            config.prefs.clear()
            config.prefs.update(orig_prefs)

    def test_push_books_worker_shares_refreshed_token_across_shared_login_folders(self):
        ui = _import_ui_with_qt_stub()
        tmpdir = tempfile.mkdtemp(prefix="nimbus_test_shared_")
        epub = Path(tmpdir) / "1.epub"
        epub.write_bytes(b"EPUBDATA" * 50)

        tasks = [(1, {"title": "Book", "format": "epub"}, str(epub), None, {})]
        accounts = [
            {
                "id": "acc_jimmy",
                "token_owner_id": "acc_jimmy",
                "name": "Jimmy",
                "provider": "gdrive",
                "remote_root": "Nimbus",
                "identifier_key": "nimbus",
                "tag": "",
                "oauth_tokens": {"access_token": "old_tok"},
            },
            {
                "id": "acc_emma",
                "token_owner_id": "acc_jimmy",
                "name": "Emma",
                "provider": "gdrive",
                "remote_root": "Nimbus-Emma",
                "identifier_key": "nimbus_emma",
                "tag": "Nimbus: Emma",
                "oauth_tokens": {"access_token": "old_tok"},
            },
        ]
        seen_tokens = []

        def fake_build_fs(acc_cfg, on_save_tokens=None):
            seen_tokens.append((acc_cfg["name"], acc_cfg["oauth_tokens"]["access_token"]))
            if acc_cfg["name"] == "Jimmy" and on_save_tokens:
                on_save_tokens("gdrive", {"access_token": "fresh_tok"})
            return MagicMock()

        state = {"pushed": [], "refreshed_tokens": {}}
        with patch.object(ui, "build_cloud_fs", side_effect=fake_build_fs), patch.object(
            ui, "push_book", side_effect=[("b1", {}, {"books": {}}), ("b2", {}, {"books": {}})]
        ):
            res = ui._push_books_worker(tasks, accounts, "Calibre-Test", tmpdir, state)

        # Second folder destination (Emma) sees the refreshed token from Jimmy in the same job
        self.assertEqual(seen_tokens, [("Jimmy", "old_tok"), ("Emma", "fresh_tok")])
        self.assertEqual(res["refreshed_tokens"], {"acc_jimmy": {"access_token": "fresh_tok"}})


if __name__ == "__main__":
    unittest.main()

"""Calibre InterfaceAction UI for Nimbus Cloud."""

import copy
import datetime
import os
import shutil
import tempfile
from typing import Any, Dict, List, Optional

try:
    from qt.core import QIcon, QMenu, QPixmap, QToolButton
except ImportError:  # pragma: no cover
    from PyQt5.QtGui import QIcon, QPixmap
    from PyQt5.QtWidgets import QMenu, QToolButton

try:
    from calibre.gui2 import Dispatcher, error_dialog, info_dialog
    from calibre.gui2.actions import InterfaceAction
    from calibre.gui2.threaded_jobs import ThreadedJob
except ImportError:  # pragma: no cover
    Dispatcher = None  # type: ignore
    error_dialog = None  # type: ignore
    info_dialog = None  # type: ignore
    ThreadedJob = None  # type: ignore

    class InterfaceAction:  # type: ignore
        pass

from .cloud import build_cloud_fs
from .config import (
    PROVIDER_LABELS,
    get_account_by_id,
    get_accounts,
    get_default_account,
    get_device_id,
    prefs,
    update_account_tokens,
)
from .dialogs import NimbusConfigDialog, SelectAccountsDialog
from .sync_engine import PREFERRED_FORMATS, format_highlights_html, pull_merged_state, push_book


def _push_books_worker(tasks, account_configs, device_id, tmpdir, state, abort=None, log=None, notifications=None):
    """Background ThreadedJob worker to upload staged books to one or more Nimbus Cloud accounts."""
    def _log(msg):
        if log is not None:
            log(msg)

    def _notify(frac, msg):
        if notifications is not None:
            notifications.put((frac, msg))

    try:
        total_ops = max(1, len(tasks) * len(account_configs))
        done_ops = 0
        for acc in account_configs:
            if abort is not None and abort.is_set():
                _log("Upload aborted by user.")
                break

            acc_id = acc["id"]
            acc_name = acc.get("name") or acc_id
            id_key = acc.get("identifier_key") or "nimbus"
            acc_tag = (acc.get("tag") or "").strip()

            def _on_tokens(provider, new_tokens, _aid=acc_id, _acc=acc):
                state["refreshed_tokens"][_aid] = new_tokens
                _acc["oauth_tokens"] = new_tokens

            fs = build_cloud_fs(acc, on_save_tokens=_on_tokens)
            catalog = None

            for cid, meta, dest, cover_bytes, identifiers in tasks:
                if abort is not None and abort.is_set():
                    _log("Upload aborted by user.")
                    break
                title = meta.get("title") or f"Book {cid}"
                _notify(done_ops / total_ops, f"Uploading {title} to {acc_name}…")
                _log(f"Uploading {title} ({meta.get('format')}) to {acc_name}…")

                book_meta = dict(meta)
                book_meta["nimbus_id"] = identifiers.get(id_key)
                bid, _, catalog = push_book(fs, device_id, book_meta, dest, cover_bytes, catalog=catalog)
                state["pushed"].append((cid, id_key, bid, acc_tag))
                _log(f"Uploaded {title} -> {acc_name} ({id_key}:{bid})")
                done_ops += 1

        _notify(1.0, f"Uploaded {len(state['pushed'])} item(s) to Nimbus Cloud")
        return state
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def _pull_sync_worker(account_config, device_id, state, abort=None, log=None, notifications=None):
    """Background ThreadedJob worker to download merged progress & highlights from the default account."""
    def _log(msg):
        if log is not None:
            log(msg)

    def _notify(frac, msg):
        if notifications is not None:
            notifications.put((frac, msg))

    acc_id = account_config["id"]

    def _on_tokens(provider, new_tokens):
        state["refreshed_tokens"][acc_id] = new_tokens
        account_config["oauth_tokens"] = new_tokens

    _notify(0.1, f"Fetching Nimbus Cloud catalog ({account_config.get('name', 'Default')})…")
    _log(f"Fetching catalog and device sync shards from {account_config.get('name', 'Default')}…")
    if abort is not None and abort.is_set():
        return state
    fs = build_cloud_fs(account_config, on_save_tokens=_on_tokens)
    catalog, merged_prog, merged_ann = pull_merged_state(fs, device_id)
    state["catalog"] = catalog
    state["merged_prog"] = merged_prog
    state["merged_ann"] = merged_ann
    _notify(1.0, "Downloaded sync state from Nimbus Cloud")
    _log(f"Merged progress for {len(merged_prog)} book(s), annotations for {len(merged_ann)} book(s).")
    return state


class NimbusAction(InterfaceAction):
    name = "Nimbus Cloud"
    action_spec = (
        "Send to Nimbus Cloud",
        None,
        "Send selected books to Nimbus Cloud (click arrow for accounts, Sync & Settings)",
        None,
    )
    popup_type = QToolButton.ToolButtonPopupMode.MenuButtonPopup if hasattr(QToolButton, "ToolButtonPopupMode") else QToolButton.MenuButtonPopup
    action_type = "current"

    def genesis(self):
        self._icon = QIcon()
        resources = self.load_resources(["images/icon.png"])
        if "images/icon.png" in resources:
            pixmap = QPixmap()
            pixmap.loadFromData(resources["images/icon.png"])
            self._icon = QIcon(pixmap)
            self.qaction.setIcon(self._icon)

        self.menu = QMenu(self.gui)
        self.qaction.setMenu(self.menu)
        self.qaction.triggered.connect(self._on_primary_action)
        self._connect_share_actions: List[Any] = []
        self._context_menu_actions: List[Any] = []
        self._rebuild_menus()

    def initialization_complete(self):
        self._rebuild_menus()

    def _on_primary_action(self):
        default_acc = get_default_account()
        if not default_acc or default_acc.get("provider") == "none":
            self.open_config()
            return
        self.push_selected_books([default_acc["id"]])

    def _populate_nimbus_menu(self, menu, include_sync: bool = True, include_manage: bool = True):
        accounts = get_accounts()
        default_acc = get_default_account()

        if not accounts or not default_acc:
            menu.addAction(self._icon, "Setup Nimbus Cloud account…", self.open_config)
            return

        menu.addAction(
            self._icon,
            f"Send to {default_acc['name']}",
            lambda checked=False, aid=default_acc["id"]: self.push_selected_books([aid]),
        )

        send_sub = QMenu("Send to account", menu)
        for acc in accounts:
            pname = PROVIDER_LABELS.get(acc.get("provider", "none"), acc.get("provider", ""))
            star = " ★" if acc["id"] == default_acc["id"] else ""
            send_sub.addAction(
                f"{acc['name']} ({pname}){star}",
                lambda checked=False, aid=acc["id"]: self.push_selected_books([aid]),
            )
        if len(accounts) >= 2:
            send_sub.addSeparator()
            send_sub.addAction("Select accounts…", self.push_to_selected_accounts)
        menu.addMenu(send_sub)

        if include_sync:
            menu.addAction(
                f"Sync Progress & Highlights ({default_acc['name']})",
                self.pull_from_cloud,
            )

        if include_manage:
            menu.addSeparator()
            menu.addAction("Manage Nimbus Cloud accounts…", self.open_config)

    def _sync_connect_share_menu(self):
        iactions = getattr(self.gui, "iactions", None) or {}
        cs_action = iactions.get("Connect Share")
        cs_menu = cs_action.qaction.menu() if cs_action and getattr(cs_action, "qaction", None) else None
        if cs_menu is None:
            return

        for ac in self._connect_share_actions:
            cs_menu.removeAction(ac)
        self._connect_share_actions = []

        if not prefs.get("integrate_connect_share", True):
            return

        before = set(cs_menu.actions())
        cs_menu.addSeparator()
        self._populate_nimbus_menu(cs_menu, include_sync=True, include_manage=True)
        self._connect_share_actions = [ac for ac in cs_menu.actions() if ac not in before]

    def _sync_context_menu(self):
        lv = getattr(self.gui, "library_view", None)
        ctx_menu = getattr(lv, "context_menu", None) if lv is not None else None
        if ctx_menu is None:
            return

        for ac in self._context_menu_actions:
            ctx_menu.removeAction(ac)
        self._context_menu_actions = []

        if not prefs.get("integrate_context_menu", True):
            return
        if self.qaction in ctx_menu.actions():
            return

        before = set(ctx_menu.actions())
        ctx_menu.addSeparator()
        sub = QMenu("Nimbus Cloud", ctx_menu)
        sub.setIcon(self._icon)
        self._populate_nimbus_menu(sub, include_sync=False, include_manage=False)
        ctx_menu.addMenu(sub)
        self._context_menu_actions = [ac for ac in ctx_menu.actions() if ac not in before]

    def _rebuild_menus(self):
        default_acc = get_default_account()
        if default_acc:
            self.qaction.setText(f"Send to Nimbus ({default_acc['name']})")
            self.qaction.setToolTip(
                f"Send selected books to {default_acc['name']} (click arrow for all accounts, Sync & Settings)"
            )
        else:
            self.qaction.setText("Send to Nimbus Cloud")
            self.qaction.setToolTip("Configure Nimbus Cloud accounts")

        self.menu.clear()
        self._populate_nimbus_menu(self.menu, include_sync=True, include_manage=True)
        self._sync_connect_share_menu()
        self._sync_context_menu()

    def _persist_refreshed_tokens(self, refreshed_tokens: Dict[str, Dict[str, Any]]):
        for account_id, tok in (refreshed_tokens or {}).items():
            update_account_tokens(account_id, tok)

    def _show_status(self, message: str):
        sb = getattr(self.gui, "status_bar", None)
        if sb is not None and hasattr(sb, "show_message"):
            sb.show_message(message, 5000)
        else:
            info_dialog(self.gui, "Nimbus Cloud", message, show=True)

    def _job_error_details(self, job) -> str:
        log = getattr(job, "log", None)
        return log.plain_text if log is not None and hasattr(log, "plain_text") else ""

    def open_config(self):
        db = self.gui.current_db.new_api
        cols = db.field_metadata.custom_field_metadata()
        dlg = NimbusConfigDialog(self.gui, cols)
        if dlg.exec():
            self._rebuild_menus()

    def push_to_selected_accounts(self):
        accounts = get_accounts()
        if not accounts:
            self.open_config()
            return
        default_acc = get_default_account()
        dlg = SelectAccountsDialog(self.gui, accounts, default_id=default_acc["id"] if default_acc else "")
        if not dlg.exec():
            return
        selected_ids = dlg.selected_account_ids()
        if not selected_ids:
            info_dialog(self.gui, "Nimbus Cloud", "Select at least one cloud account.", show=True)
            return
        self.push_selected_books(selected_ids)

    def push_selected_books(self, account_ids: Optional[List[str]] = None):
        target_accounts: List[Dict[str, Any]] = []
        if account_ids:
            for aid in account_ids:
                acc = get_account_by_id(aid)
                if acc and acc.get("provider") != "none":
                    target_accounts.append(copy.deepcopy(acc))
        else:
            default_acc = get_default_account()
            if default_acc and default_acc.get("provider") != "none":
                target_accounts.append(copy.deepcopy(default_acc))

        if not target_accounts:
            self.open_config()
            return

        rows = self.gui.library_view.selectionModel().selectedRows()
        book_ids = [self.gui.library_view.model().id(r) for r in rows]
        if not book_ids:
            info_dialog(self.gui, "Nimbus Cloud", "Select one or more books first.", show=True)
            return

        db = self.gui.current_db.new_api
        tmpdir = tempfile.mkdtemp(prefix="nimbus_push_")
        tasks = []
        try:
            for cid in book_ids:
                mi = db.get_metadata(cid, get_cover=False)
                fmts = [f.lower() for f in (db.formats(cid) or [])]
                chosen_fmt = next((f for f in PREFERRED_FORMATS if f in fmts), fmts[0] if fmts else None)
                if not chosen_fmt:
                    continue
                dest = os.path.join(tmpdir, f"{cid}.{chosen_fmt}")
                db.copy_format_to(cid, chosen_fmt, dest)
                cover_bytes = db.cover(cid)
                identifiers = dict(mi.get_identifiers() or {})
                meta = {
                    "title": mi.title,
                    "authors": mi.authors,
                    "series": mi.series,
                    "series_index": mi.series_index,
                    "tags": mi.tags,
                    "language": mi.language,
                    "isbn": identifiers.get("isbn"),
                    "calibre_uuid": mi.uuid,
                    "format": chosen_fmt,
                }
                tasks.append((cid, meta, dest, cover_bytes, identifiers))
        except Exception as e:
            shutil.rmtree(tmpdir, ignore_errors=True)
            error_dialog(self.gui, "Nimbus Cloud Error", str(e), show=True)
            return

        if not tasks:
            shutil.rmtree(tmpdir, ignore_errors=True)
            info_dialog(self.gui, "Nimbus Cloud", "Selected book(s) have no uploadable format.", show=True)
            return

        state = {"pushed": [], "refreshed_tokens": {}}
        device_id = get_device_id()
        target_names = ", ".join(a["name"] for a in target_accounts)
        desc = f"Send {len(tasks)} book(s) to Nimbus ({target_names})"

        job = ThreadedJob(
            "nimbus_push_books",
            desc,
            _push_books_worker,
            (tasks, target_accounts, device_id, tmpdir, state),
            {},
            Dispatcher(lambda j, st=state: self._on_push_job_done(j, st), parent=self.gui),
            max_concurrent_count=1,
            killable=True,
        )
        self.gui.job_manager.run_threaded_job(job)
        self._show_status(f"{desc}…")

    def _on_push_job_done(self, job, state):
        self._persist_refreshed_tokens(state.get("refreshed_tokens"))
        pushed = state.get("pushed") or []
        if pushed:
            db = self.gui.current_db.new_api
            id_updates: Dict[int, Dict[str, str]] = {}
            tag_additions: Dict[int, List[str]] = {}
            for cid, id_key, bid, acc_tag in pushed:
                if cid not in id_updates:
                    id_updates[cid] = dict(db.field_for("identifiers", cid) or {})
                id_updates[cid][id_key] = bid
                if acc_tag:
                    tag_additions.setdefault(cid, []).append(acc_tag)

            if id_updates:
                db.set_field("identifiers", id_updates)

            if tag_additions:
                tag_updates: Dict[int, List[str]] = {}
                for cid, new_tags in tag_additions.items():
                    existing = list(db.field_for("tags", cid) or [])
                    lower_set = {t.lower() for t in existing}
                    changed = False
                    for t in new_tags:
                        if t.lower() not in lower_set:
                            existing.append(t)
                            lower_set.add(t.lower())
                            changed = True
                    if changed:
                        tag_updates[cid] = existing
                if tag_updates:
                    db.set_field("tags", tag_updates)

        if getattr(job, "failed", False):
            error_dialog(
                self.gui,
                "Nimbus Cloud Error",
                str(getattr(job, "exception", "Upload failed")),
                det_msg=self._job_error_details(job),
                show=True,
            )
            return

        self._show_status(f"Nimbus Cloud: uploaded {len(pushed)} item(s).")

    def pull_from_cloud(self):
        default_acc = get_default_account()
        if not default_acc or default_acc.get("provider") == "none":
            self.open_config()
            return

        id_key = default_acc.get("identifier_key") or "nimbus"
        db = self.gui.current_db.new_api
        linked_books = []
        for cid in db.all_book_ids():
            identifiers = db.field_for("identifiers", cid) or {}
            bid = identifiers.get(id_key)
            if bid:
                linked_books.append((cid, bid))

        if not linked_books:
            info_dialog(
                self.gui,
                "Nimbus Cloud",
                f"No books in this library are linked to {default_acc['name']} ({id_key}) yet. Send books first.",
                show=True,
            )
            return

        state = {"refreshed_tokens": {}, "merged_prog": {}, "merged_ann": {}, "linked_books": linked_books}
        acc_snapshot = copy.deepcopy(default_acc)
        device_id = get_device_id()

        job = ThreadedJob(
            "nimbus_pull_sync",
            f"Sync progress & highlights from {default_acc['name']}",
            _pull_sync_worker,
            (acc_snapshot, device_id, state),
            {},
            Dispatcher(lambda j, st=state: self._on_pull_job_done(j, st), parent=self.gui),
            max_concurrent_count=1,
            killable=True,
        )
        self.gui.job_manager.run_threaded_job(job)
        self._show_status(f"Syncing progress & highlights from {default_acc['name']}…")

    def _on_pull_job_done(self, job, state):
        self._persist_refreshed_tokens(state.get("refreshed_tokens"))
        if getattr(job, "failed", False):
            error_dialog(
                self.gui,
                "Nimbus Cloud Error",
                str(getattr(job, "exception", "Sync failed")),
                det_msg=self._job_error_details(job),
                show=True,
            )
            return

        db = self.gui.current_db.new_api
        merged_prog = state.get("merged_prog") or {}
        merged_ann = state.get("merged_ann") or {}
        linked_books = state.get("linked_books") or []

        pct_updates = {}
        status_updates = {}
        date_updates = {}
        rating_updates = {}
        hl_updates = {}
        updated = 0

        for cid, bid in linked_books:
            prog = merged_prog.get(bid)
            ann_entry = merged_ann.get(bid)
            if prog:
                if prefs.get("col_percent"):
                    pct_updates[cid] = round(float(prog.get("percent", 0)) * 100.0, 2)
                if prefs.get("col_status") and prog.get("status"):
                    status_updates[cid] = prog["status"]
                if prefs.get("col_last_read") and prog.get("updated_at"):
                    date_updates[cid] = datetime.datetime.fromtimestamp(int(prog["updated_at"]), tz=datetime.timezone.utc)
                if prefs.get("col_rating") and prog.get("rating") is not None:
                    rating_updates[cid] = int(prog["rating"]) * 2
                updated += 1
            if ann_entry and prefs.get("col_highlights"):
                active = ann_entry.get("active") or []
                if active:
                    hl_updates[cid] = format_highlights_html(active)

        if pct_updates and prefs.get("col_percent"):
            db.set_field(prefs["col_percent"], pct_updates)
        if status_updates and prefs.get("col_status"):
            db.set_field(prefs["col_status"], status_updates)
        if date_updates and prefs.get("col_last_read"):
            db.set_field(prefs["col_last_read"], date_updates)
        if rating_updates and prefs.get("col_rating"):
            db.set_field(prefs["col_rating"], rating_updates)
        if hl_updates and prefs.get("col_highlights"):
            db.set_field(prefs["col_highlights"], hl_updates)

        self._show_status(f"Nimbus Cloud: synced reading progress & highlights for {updated} book(s).")

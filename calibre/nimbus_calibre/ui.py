"""Calibre InterfaceAction UI for Nimbus Cloud."""

import copy
import datetime
import os
import shutil
import tempfile

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
from .config import get_device_id, prefs
from .dialogs import NimbusConfigDialog
from .sync_engine import PREFERRED_FORMATS, format_highlights_html, pull_merged_state, push_book


def _push_books_worker(tasks, prefs_snapshot, device_id, tmpdir, state, abort=None, log=None, notifications=None):
    """Background ThreadedJob worker to upload staged books to Nimbus Cloud."""
    def _log(msg):
        if log is not None:
            log(msg)

    def _notify(frac, msg):
        if notifications is not None:
            notifications.put((frac, msg))

    def _on_tokens(provider, new_tokens):
        state["refreshed_tokens"][provider] = new_tokens
        prefs_snapshot.setdefault("oauth_tokens", {})[provider] = new_tokens

    try:
        fs = build_cloud_fs(prefs_snapshot, on_save_tokens=_on_tokens)
        catalog = None
        total = max(1, len(tasks))
        for idx, (cid, meta, dest, cover_bytes, identifiers) in enumerate(tasks):
            if abort is not None and abort.is_set():
                _log("Upload aborted by user.")
                break
            title = meta.get("title") or f"Book {cid}"
            _notify(idx / total, f"Uploading {title}…")
            _log(f"Uploading {title} ({meta.get('format')})…")
            bid, _, catalog = push_book(fs, device_id, meta, dest, cover_bytes, catalog=catalog)
            state["pushed"].append((cid, bid, identifiers))
            _log(f"Uploaded {title} -> nimbus:{bid}")
        _notify(1.0, f"Uploaded {len(state['pushed'])} book(s) to Nimbus Cloud")
        return state
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def _pull_sync_worker(prefs_snapshot, device_id, state, abort=None, log=None, notifications=None):
    """Background ThreadedJob worker to download merged progress & highlights."""
    def _log(msg):
        if log is not None:
            log(msg)

    def _notify(frac, msg):
        if notifications is not None:
            notifications.put((frac, msg))

    def _on_tokens(provider, new_tokens):
        state["refreshed_tokens"][provider] = new_tokens
        prefs_snapshot.setdefault("oauth_tokens", {})[provider] = new_tokens

    _notify(0.1, "Fetching Nimbus Cloud catalog and device shards…")
    _log("Fetching catalog and device sync shards from Nimbus Cloud…")
    if abort is not None and abort.is_set():
        return state
    fs = build_cloud_fs(prefs_snapshot, on_save_tokens=_on_tokens)
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
        "Send selected books to Nimbus Cloud (click arrow for Sync & Settings)",
        None,
    )
    popup_type = QToolButton.ToolButtonPopupMode.MenuButtonPopup if hasattr(QToolButton, "ToolButtonPopupMode") else QToolButton.MenuButtonPopup
    action_type = "current"

    def genesis(self):
        resources = self.load_resources(["images/icon.png"])
        if "images/icon.png" in resources:
            pixmap = QPixmap()
            pixmap.loadFromData(resources["images/icon.png"])
            self.qaction.setIcon(QIcon(pixmap))

        self.menu = QMenu(self.gui)
        self.qaction.setMenu(self.menu)
        self.qaction.triggered.connect(self._on_primary_action)

        self.menu.addAction("Send Selected Books to Nimbus Cloud", self.push_selected_books)
        self.menu.addAction("Sync Progress & Highlights from Cloud", self.pull_from_cloud)
        self.menu.addSeparator()
        self.menu.addAction("Configure Nimbus Cloud…", self.open_config)

    def _on_primary_action(self):
        if (prefs.get("provider") or "none") == "none":
            self.open_config()
            return
        self.push_selected_books()

    def _save_tokens(self, provider: str, new_tokens: dict):
        all_toks = dict(prefs.get("oauth_tokens") or {})
        all_toks[provider] = new_tokens
        prefs["oauth_tokens"] = all_toks

    def _persist_refreshed_tokens(self, refreshed_tokens: dict):
        for provider, tok in (refreshed_tokens or {}).items():
            self._save_tokens(provider, tok)

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
        dlg.exec()

    def push_selected_books(self):
        if (prefs.get("provider") or "none") == "none":
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
                    "nimbus_id": identifiers.get("nimbus"),
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
        prefs_snapshot = copy.deepcopy(dict(prefs))
        device_id = get_device_id()

        job = ThreadedJob(
            "nimbus_push_books",
            f"Send {len(tasks)} book(s) to Nimbus Cloud",
            _push_books_worker,
            (tasks, prefs_snapshot, device_id, tmpdir, state),
            {},
            Dispatcher(lambda j, st=state: self._on_push_job_done(j, st), parent=self.gui),
            max_concurrent_count=1,
            killable=True,
        )
        self.gui.job_manager.run_threaded_job(job)
        self._show_status(f"Sending {len(tasks)} book(s) to Nimbus Cloud…")

    def _on_push_job_done(self, job, state):
        self._persist_refreshed_tokens(state.get("refreshed_tokens"))
        pushed = state.get("pushed") or []
        if pushed:
            db = self.gui.current_db.new_api
            id_updates = {}
            for cid, bid, identifiers in pushed:
                updated_ids = dict(identifiers)
                updated_ids["nimbus"] = bid
                id_updates[cid] = updated_ids
            db.set_field("identifiers", id_updates)

        if getattr(job, "failed", False):
            error_dialog(
                self.gui,
                "Nimbus Cloud Error",
                str(getattr(job, "exception", "Upload failed")),
                det_msg=self._job_error_details(job),
                show=True,
            )
            return

        self._show_status(f"Nimbus Cloud: uploaded {len(pushed)} book(s).")

    def pull_from_cloud(self):
        if (prefs.get("provider") or "none") == "none":
            self.open_config()
            return

        db = self.gui.current_db.new_api
        linked_books = []
        for cid in db.all_book_ids():
            identifiers = db.field_for("identifiers", cid) or {}
            bid = identifiers.get("nimbus")
            if bid:
                linked_books.append((cid, bid))

        if not linked_books:
            info_dialog(
                self.gui,
                "Nimbus Cloud",
                "No books in this library are linked to Nimbus Cloud yet. Send books first.",
                show=True,
            )
            return

        state = {"refreshed_tokens": {}, "merged_prog": {}, "merged_ann": {}, "linked_books": linked_books}
        prefs_snapshot = copy.deepcopy(dict(prefs))
        device_id = get_device_id()

        job = ThreadedJob(
            "nimbus_pull_sync",
            "Sync progress & highlights from Nimbus Cloud",
            _pull_sync_worker,
            (prefs_snapshot, device_id, state),
            {},
            Dispatcher(lambda j, st=state: self._on_pull_job_done(j, st), parent=self.gui),
            max_concurrent_count=1,
            killable=True,
        )
        self.gui.job_manager.run_threaded_job(job)
        self._show_status("Syncing progress & highlights from Nimbus Cloud…")

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

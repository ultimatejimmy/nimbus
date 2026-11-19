"""Calibre InterfaceAction UI for Nimbus Cloud."""

import datetime
import os
import tempfile

try:
    from qt.core import QMenu, QToolButton
except ImportError:  # pragma: no cover
    from PyQt5.QtWidgets import QMenu, QToolButton

from calibre.gui2 import error_dialog, info_dialog
from calibre.gui2.actions import InterfaceAction

from .cloud import build_cloud_fs
from .config import get_device_id, prefs
from .dialogs import NimbusConfigDialog
from .sync_engine import PREFERRED_FORMATS, format_highlights_html, pull_merged_state, push_book


class NimbusAction(InterfaceAction):
    name = "Nimbus Cloud"
    action_spec = ("Nimbus Cloud", None, "Sync books, progress, and highlights with Nimbus Cloud", None)
    popup_type = QToolButton.ToolButtonPopupMode.MenuButtonPopup if hasattr(QToolButton, "ToolButtonPopupMode") else QToolButton.MenuButtonPopup
    action_type = "current"

    def genesis(self):
        self.menu = QMenu(self.gui)
        self.qaction.setMenu(self.menu)
        self.qaction.triggered.connect(self.open_config)

        self.menu.addAction("Send Selected Books to Nimbus Cloud", self.push_selected_books)
        self.menu.addAction("Sync Progress & Highlights from Cloud", self.pull_from_cloud)
        self.menu.addSeparator()
        self.menu.addAction("Configure Nimbus Cloud…", self.open_config)

    def _save_tokens(self, provider: str, new_tokens: dict):
        all_toks = dict(prefs.get("oauth_tokens") or {})
        all_toks[provider] = new_tokens
        prefs["oauth_tokens"] = all_toks

    def open_config(self):
        db = self.gui.current_db.new_api
        cols = db.field_metadata.custom_field_metadata()
        dlg = NimbusConfigDialog(self.gui, cols)
        dlg.exec()

    def push_selected_books(self):
        rows = self.gui.library_view.selectionModel().selectedRows()
        book_ids = [self.gui.library_view.model().id(r) for r in rows]
        if not book_ids:
            info_dialog(self.gui, "Nimbus Cloud", "Select one or more books first.", show=True)
            return
        try:
            fs = build_cloud_fs(dict(prefs), on_save_tokens=self._save_tokens)
            db = self.gui.current_db.new_api
            device_id = get_device_id()
            pushed = 0
            with tempfile.TemporaryDirectory() as tmpdir:
                catalog = None
                for cid in book_ids:
                    mi = db.get_metadata(cid, get_cover=False)
                    fmts = [f.lower() for f in (db.formats(cid) or [])]
                    chosen_fmt = next((f for f in PREFERRED_FORMATS if f in fmts), fmts[0] if fmts else None)
                    if not chosen_fmt:
                        continue
                    dest = os.path.join(tmpdir, f"{cid}.{chosen_fmt}")
                    db.copy_format_to(cid, chosen_fmt, dest)
                    cover_bytes = db.cover(cid, as_bytes=True)
                    identifiers = mi.get_identifiers() or {}
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
                    bid, _, catalog = push_book(fs, device_id, meta, dest, cover_bytes, catalog=catalog)
                    identifiers["nimbus"] = bid
                    db.set_field("identifiers", {cid: identifiers})
                    pushed += 1
            info_dialog(self.gui, "Nimbus Cloud", f"Uploaded {pushed} book(s) to Nimbus Cloud.", show=True)
        except Exception as e:
            error_dialog(self.gui, "Nimbus Cloud Error", str(e), show=True)

    def pull_from_cloud(self):
        try:
            fs = build_cloud_fs(dict(prefs), on_save_tokens=self._save_tokens)
            db = self.gui.current_db.new_api
            device_id = get_device_id()
            catalog, merged_prog, merged_ann = pull_merged_state(fs, device_id)

            updated = 0
            all_ids = db.all_book_ids()
            for cid in all_ids:
                identifiers = db.field_for("identifiers", cid) or {}
                bid = identifiers.get("nimbus")
                if not bid:
                    continue
                prog = merged_prog.get(bid)
                ann_entry = merged_ann.get(bid)
                if prog:
                    if prefs.get("col_percent"):
                        db.set_field(prefs["col_percent"], {cid: round(float(prog.get("percent", 0)) * 100.0, 2)})
                    if prefs.get("col_status") and prog.get("status"):
                        db.set_field(prefs["col_status"], {cid: prog["status"]})
                    if prefs.get("col_last_read") and prog.get("updated_at"):
                        dt = datetime.datetime.fromtimestamp(int(prog["updated_at"]), tz=datetime.timezone.utc)
                        db.set_field(prefs["col_last_read"], {cid: dt})
                    if prefs.get("col_rating") and prog.get("rating") is not None:
                        db.set_field(prefs["col_rating"], {cid: int(prog["rating"]) * 2})
                    updated += 1
                if ann_entry and prefs.get("col_highlights"):
                    active = ann_entry.get("active") or []
                    if active:
                        db.set_field(prefs["col_highlights"], {cid: format_highlights_html(active)})

            info_dialog(self.gui, "Nimbus Cloud", f"Synced reading progress & highlights for {updated} book(s).", show=True)
        except Exception as e:
            error_dialog(self.gui, "Nimbus Cloud Error", str(e), show=True)

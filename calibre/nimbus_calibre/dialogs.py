"""PyQt configuration & OAuth login dialog for nimbus-calibre."""

import webbrowser
from typing import Any, Dict, List

try:
    from qt.core import (
        QComboBox,
        QDialog,
        QDialogButtonBox,
        QFormLayout,
        QGroupBox,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QMessageBox,
        QPushButton,
        QTimer,
        QVBoxLayout,
    )
except ImportError:  # pragma: no cover
    from PyQt5.QtCore import QTimer
    from PyQt5.QtWidgets import (
        QComboBox,
        QDialog,
        QDialogButtonBox,
        QFormLayout,
        QGroupBox,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QMessageBox,
        QPushButton,
        QVBoxLayout,
    )

from .cloud import build_cloud_fs
from .cloud.oauth import poll_token_once, request_device_code
from .config import prefs


class NimbusConfigDialog(QDialog):
    def __init__(self, parent, custom_columns: Dict[str, Dict[str, Any]]):
        super().__init__(parent)
        self.setWindowTitle("Nimbus Cloud Configuration")
        self.setMinimumWidth(480)
        self.custom_columns = custom_columns or {}
        self._poll_timer = None
        self._device_code = None
        self._oauth_provider = None

        layout = QVBoxLayout(self)

        # Provider group
        prov_group = QGroupBox("Cloud Storage Provider")
        prov_form = QFormLayout(prov_group)

        self.provider_combo = QComboBox()
        self.provider_combo.addItem("Not Configured", "none")
        self.provider_combo.addItem("Google Drive", "gdrive")
        self.provider_combo.addItem("Microsoft OneDrive", "onedrive")
        self.provider_combo.addItem("Dropbox", "dropbox")
        self.provider_combo.addItem("WebDAV", "webdav")
        idx = self.provider_combo.findData(prefs.get("provider", "none"))
        if idx >= 0:
            self.provider_combo.setCurrentIndex(idx)
        self.provider_combo.currentIndexChanged.connect(self._on_provider_changed)
        prov_form.addRow("Provider:", self.provider_combo)

        self.root_edit = QLineEdit(prefs.get("remote_root", "Nimbus"))
        prov_form.addRow("Remote Root Folder:", self.root_edit)

        # OAuth row
        oauth_row = QHBoxLayout()
        self.oauth_btn = QPushButton("Sign In with Browser")
        self.oauth_btn.clicked.connect(self._start_oauth)
        self.oauth_status = QLabel("")
        oauth_row.addWidget(self.oauth_btn)
        oauth_row.addWidget(self.oauth_status, 1)
        prov_form.addRow("OAuth Sign-In:", oauth_row)

        # WebDAV fields
        self.wd_url = QLineEdit((prefs.get("webdav") or {}).get("url", ""))
        self.wd_user = QLineEdit((prefs.get("webdav") or {}).get("username", ""))
        self.wd_pass = QLineEdit((prefs.get("webdav") or {}).get("password", ""))
        self.wd_pass.setEchoMode(QLineEdit.EchoMode.Password if hasattr(QLineEdit, "EchoMode") else QLineEdit.Password)
        prov_form.addRow("WebDAV URL:", self.wd_url)
        prov_form.addRow("WebDAV Username:", self.wd_user)
        prov_form.addRow("WebDAV Password:", self.wd_pass)

        self.test_btn = QPushButton("Test Connection")
        self.test_btn.clicked.connect(self._test_connection)
        prov_form.addRow("", self.test_btn)
        layout.addWidget(prov_group)

        # Column mapping group
        col_group = QGroupBox("Calibre Custom Column Mapping (Optional)")
        col_form = QFormLayout(col_group)
        self.col_combos: Dict[str, QComboBox] = {}
        for key, label in (
            ("col_percent", "Reading Progress (%):"),
            ("col_status", "Reading Status:"),
            ("col_last_read", "Last Read Date:"),
            ("col_highlights", "Highlights / Notes:"),
            ("col_rating", "Rating:"),
        ):
            cb = self._make_col_combo(prefs.get(key, ""))
            self.col_combos[key] = cb
            col_form.addRow(label, cb)

        self.sync_tag_edit = QLineEdit(prefs.get("sync_tag", ""))
        self.sync_tag_edit.setPlaceholderText("e.g. Nimbus (leave blank for selected books)")
        col_form.addRow("Auto-Sync Tag:", self.sync_tag_edit)
        layout.addWidget(col_group)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
                                   if hasattr(QDialogButtonBox, "StandardButton") else QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._save_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

        self._on_provider_changed()

    def _make_col_combo(self, current_val: str) -> QComboBox:
        cb = QComboBox()
        cb.addItem("(None)", "")
        for key, meta in sorted(self.custom_columns.items()):
            cb.addItem(f"{meta.get('name', key)} (#{key})", f"#{key}")
        idx = cb.findData(current_val or "")
        if idx >= 0:
            cb.setCurrentIndex(idx)
        return cb

    def _on_provider_changed(self):
        p = self.provider_combo.currentData()
        is_oauth = p in ("gdrive", "onedrive", "dropbox")
        is_wd = p == "webdav"
        self.oauth_btn.setEnabled(is_oauth)
        self.wd_url.setEnabled(is_wd)
        self.wd_user.setEnabled(is_wd)
        self.wd_pass.setEnabled(is_wd)
        if is_oauth:
            tok = (prefs.get("oauth_tokens") or {}).get(p)
            self.oauth_status.setText("Signed in ✓" if (tok and tok.get("access_token")) else "Not signed in")
        else:
            self.oauth_status.setText("")

    def _start_oauth(self):
        p = self.provider_combo.currentData()
        if p not in ("gdrive", "onedrive", "dropbox"):
            return
        try:
            info = request_device_code(p)
        except Exception as e:
            QMessageBox.warning(self, "Nimbus OAuth", f"Failed to start sign-in:\n{e}")
            return

        self._oauth_provider = p
        self._device_code = info["device_code"]
        self.oauth_status.setText(f"Code: {info['user_code']} (waiting…)")
        if info.get("verification_url"):
            webbrowser.open(info["verification_url"])

        if self._poll_timer:
            self._poll_timer.stop()
        self._poll_timer = QTimer(self)
        self._poll_timer.timeout.connect(self._poll_oauth_once)
        self._poll_timer.start(max(3000, info.get("interval", 5) * 1000))

    def _poll_oauth_once(self):
        if not self._oauth_provider or not self._device_code:
            return
        try:
            tok = poll_token_once(self._oauth_provider, self._device_code)
            if tok:
                self._poll_timer.stop()
                all_toks = dict(prefs.get("oauth_tokens") or {})
                all_toks[self._oauth_provider] = tok
                prefs["oauth_tokens"] = all_toks
                self.oauth_status.setText("Signed in ✓")
                QMessageBox.information(self, "Nimbus OAuth", "Successfully connected!")
        except Exception as e:
            self._poll_timer.stop()
            self.oauth_status.setText("Error")
            QMessageBox.warning(self, "Nimbus OAuth", str(e))

    def _collect_temp_config(self) -> Dict[str, Any]:
        return {
            "provider": self.provider_combo.currentData(),
            "remote_root": self.root_edit.text().strip() or "Nimbus",
            "webdav": {
                "url": self.wd_url.text().strip(),
                "username": self.wd_user.text().strip(),
                "password": self.wd_pass.text(),
            },
            "oauth_tokens": prefs.get("oauth_tokens") or {},
        }

    def _test_connection(self):
        try:
            fs = build_cloud_fs(self._collect_temp_config())
            identity = fs.test_connection()
            QMessageBox.information(self, "Nimbus Cloud", f"Connected successfully:\n{identity}")
        except Exception as e:
            QMessageBox.warning(self, "Nimbus Cloud", f"Connection failed:\n{e}")

    def _save_and_accept(self):
        prefs["provider"] = self.provider_combo.currentData()
        prefs["remote_root"] = self.root_edit.text().strip() or "Nimbus"
        prefs["webdav"] = {
            "url": self.wd_url.text().strip(),
            "username": self.wd_user.text().strip(),
            "password": self.wd_pass.text(),
        }
        for key, cb in self.col_combos.items():
            prefs[key] = cb.currentData() or ""
        prefs["sync_tag"] = self.sync_tag_edit.text().strip()
        self.accept()

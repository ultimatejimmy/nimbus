"""PyQt configuration, account manager, and OAuth login dialogs for nimbus-calibre."""

import copy
import webbrowser
from typing import Any, Dict, List, Optional, Set

try:
    from qt.core import (
        QAbstractItemView,
        QApplication,
        QCheckBox,
        QComboBox,
        QDialog,
        QDialogButtonBox,
        QFormLayout,
        QGroupBox,
        QHBoxLayout,
        QHeaderView,
        QLabel,
        QLineEdit,
        QListWidget,
        QListWidgetItem,
        QMessageBox,
        QPushButton,
        QTableWidget,
        QTableWidgetItem,
        QTimer,
        Qt,
        QVBoxLayout,
    )
except ImportError:  # pragma: no cover
    from PyQt5.QtCore import QTimer, Qt
    from PyQt5.QtWidgets import (
        QAbstractItemView,
        QApplication,
        QCheckBox,
        QComboBox,
        QDialog,
        QDialogButtonBox,
        QFormLayout,
        QGroupBox,
        QHBoxLayout,
        QHeaderView,
        QLabel,
        QLineEdit,
        QListWidget,
        QListWidgetItem,
        QMessageBox,
        QPushButton,
        QTableWidget,
        QTableWidgetItem,
        QVBoxLayout,
    )

from .cloud import build_cloud_fs
from .cloud.oauth import poll_token_once, request_device_code
from .config import (
    PROVIDER_LABELS,
    get_accounts,
    make_identifier_key,
    new_account_id,
    prefs,
    save_accounts,
)


def _expanding_policy():
    return (
        QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow
        if hasattr(QFormLayout, "FieldGrowthPolicy")
        else QFormLayout.ExpandingFieldsGrow
    )


def _dialog_ok_cancel():
    return (
        QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        if hasattr(QDialogButtonBox, "StandardButton")
        else QDialogButtonBox.Ok | QDialogButtonBox.Cancel
    )


def _user_role():
    return Qt.ItemDataRole.UserRole if hasattr(Qt, "ItemDataRole") else Qt.UserRole


def _check_state(checked: bool):
    if hasattr(Qt, "CheckState"):
        return Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked
    return Qt.Checked if checked else Qt.Unchecked


class NimbusAccountDialog(QDialog):
    """Add or edit a single Nimbus Cloud account."""

    def __init__(
        self,
        parent,
        account: Optional[Dict[str, Any]] = None,
        existing_identifier_keys: Optional[Set[str]] = None,
    ):
        super().__init__(parent)
        self._is_new = account is None
        self._account = copy.deepcopy(account) if account else {
            "id": new_account_id(),
            "name": "",
            "provider": "gdrive",
            "remote_root": "Nimbus",
            "identifier_key": "",
            "tag": "",
            "webdav": {"url": "", "username": "", "password": ""},
            "oauth_tokens": {},
            "identity": "",
        }
        self._existing_keys = set(existing_identifier_keys or set())
        self._poll_timer = None
        self._device_code = None
        self._user_code = ""
        self._oauth_provider = None

        self.setWindowTitle("Add Nimbus Cloud Account" if self._is_new else "Edit Nimbus Cloud Account")
        self.setMinimumWidth(560)

        layout = QVBoxLayout(self)
        form = QFormLayout()
        form.setFieldGrowthPolicy(_expanding_policy())

        self.name_edit = QLineEdit(self._account.get("name", ""))
        self.name_edit.setPlaceholderText("e.g. Jimmy, Emma, Leo")
        self.name_edit.textChanged.connect(self._update_identifier_preview)
        form.addRow("Account Name:", self.name_edit)

        self.provider_combo = QComboBox()
        for code in ("gdrive", "onedrive", "dropbox", "webdav"):
            self.provider_combo.addItem(PROVIDER_LABELS[code], code)
        idx = self.provider_combo.findData(self._account.get("provider", "gdrive"))
        if idx >= 0:
            self.provider_combo.setCurrentIndex(idx)
        self.provider_combo.currentIndexChanged.connect(self._on_provider_changed)
        form.addRow("Provider:", self.provider_combo)

        self.root_edit = QLineEdit(self._account.get("remote_root", "Nimbus"))
        form.addRow("Remote Root Folder:", self.root_edit)

        oauth_row = QHBoxLayout()
        self.oauth_btn = QPushButton("Sign In with Browser")
        self.oauth_btn.clicked.connect(self._start_oauth)
        self.oauth_status = QLabel("")
        self.oauth_status.setWordWrap(True)
        self.oauth_status.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
            if hasattr(Qt, "TextInteractionFlag")
            else Qt.TextSelectableByMouse
        )
        self.copy_code_btn = QPushButton("Copy Code")
        self.copy_code_btn.setVisible(False)
        self.copy_code_btn.clicked.connect(self._copy_user_code)
        oauth_row.addWidget(self.oauth_btn)
        oauth_row.addWidget(self.oauth_status, 1)
        oauth_row.addWidget(self.copy_code_btn)
        form.addRow("OAuth Sign-In:", oauth_row)

        wd = self._account.get("webdav") or {}
        self.wd_url = QLineEdit(wd.get("url", ""))
        self.wd_user = QLineEdit(wd.get("username", ""))
        self.wd_pass = QLineEdit(wd.get("password", ""))
        self.wd_pass.setEchoMode(QLineEdit.EchoMode.Password if hasattr(QLineEdit, "EchoMode") else QLineEdit.Password)
        form.addRow("WebDAV URL:", self.wd_url)
        form.addRow("WebDAV Username:", self.wd_user)
        form.addRow("WebDAV Password:", self.wd_pass)

        self.tag_edit = QLineEdit(self._account.get("tag", ""))
        self.tag_edit.setPlaceholderText("e.g. Nimbus: Emma (optional tag added on send)")
        form.addRow("Tag on Send (Optional):", self.tag_edit)

        self.id_key_label = QLabel("")
        form.addRow("Calibre Identifier Key:", self.id_key_label)

        self.test_btn = QPushButton("Test Connection")
        self.test_btn.clicked.connect(self._test_connection)
        form.addRow("", self.test_btn)

        layout.addLayout(form)

        buttons = QDialogButtonBox(_dialog_ok_cancel())
        buttons.accepted.connect(self._save_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

        self._on_provider_changed()
        self._update_identifier_preview()

    def _update_identifier_preview(self):
        key = self._account.get("identifier_key") or make_identifier_key(self.name_edit.text(), self._existing_keys)
        self.id_key_label.setText(f"{key}  (searchable as identifiers:{key}:true)")

    def _on_provider_changed(self):
        p = self.provider_combo.currentData()
        is_oauth = p in ("gdrive", "onedrive", "dropbox")
        is_wd = p == "webdav"
        self.oauth_btn.setEnabled(is_oauth)
        self.wd_url.setEnabled(is_wd)
        self.wd_user.setEnabled(is_wd)
        self.wd_pass.setEnabled(is_wd)
        self._user_code = ""
        self.copy_code_btn.setVisible(False)
        if is_oauth:
            tok = self._account.get("oauth_tokens") or {}
            if tok.get("access_token") and p == self._account.get("provider"):
                ident = self._account.get("identity")
                self.oauth_status.setText(f"Signed in ✓ ({ident})" if ident else "Signed in ✓")
            else:
                self.oauth_status.setText("Not signed in")
        else:
            self.oauth_status.setText("")

    def _copy_user_code(self):
        if not self._user_code:
            return
        clipboard = QApplication.clipboard()
        if clipboard is not None:
            clipboard.setText(self._user_code)
            self.copy_code_btn.setText("Copied ✓")
            QTimer.singleShot(2000, lambda: self.copy_code_btn.setText("Copy Code"))

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
        self._user_code = info["user_code"]
        clipboard = QApplication.clipboard()
        if clipboard is not None:
            clipboard.setText(self._user_code)
        self.copy_code_btn.setText("Copy Code")
        self.copy_code_btn.setVisible(True)
        self.oauth_status.setText(f"Code: {self._user_code} (waiting…)")
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
                self._account["provider"] = self._oauth_provider
                self._account["oauth_tokens"] = tok
                self._account["identity"] = ""
                self._user_code = ""
                self.copy_code_btn.setVisible(False)
                self.oauth_status.setText("Signed in ✓")
                QMessageBox.information(self, "Nimbus OAuth", "Successfully connected!")
        except Exception as e:
            self._poll_timer.stop()
            self._user_code = ""
            self.copy_code_btn.setVisible(False)
            self.oauth_status.setText("Error")
            QMessageBox.warning(self, "Nimbus OAuth", str(e))

    def _collect_temp_config(self) -> Dict[str, Any]:
        provider = self.provider_combo.currentData()
        tokens = dict(self._account.get("oauth_tokens") or {}) if provider == self._account.get("provider") else {}
        return {
            "provider": provider,
            "remote_root": self.root_edit.text().strip() or "Nimbus",
            "webdav": {
                "url": self.wd_url.text().strip(),
                "username": self.wd_user.text().strip(),
                "password": self.wd_pass.text(),
            },
            "oauth_tokens": tokens,
        }

    def _test_connection(self):
        try:
            fs = build_cloud_fs(self._collect_temp_config())
            identity = fs.test_connection()
            self._account["identity"] = str(identity or "").strip()
            if self.provider_combo.currentData() != "webdav":
                self.oauth_status.setText(f"Signed in ✓ ({self._account['identity']})" if self._account["identity"] else "Signed in ✓")
            QMessageBox.information(self, "Nimbus Cloud", f"Connected successfully:\n{identity}")
        except Exception as e:
            QMessageBox.warning(self, "Nimbus Cloud", f"Connection failed:\n{e}")

    def _save_and_accept(self):
        provider = self.provider_combo.currentData()
        name = self.name_edit.text().strip() or PROVIDER_LABELS.get(provider, "Nimbus Cloud")
        if provider != self._account.get("provider"):
            self._account["oauth_tokens"] = {}
            self._account["identity"] = ""
        self._account["name"] = name
        self._account["provider"] = provider
        self._account["remote_root"] = self.root_edit.text().strip() or "Nimbus"
        self._account["tag"] = self.tag_edit.text().strip()
        self._account["webdav"] = {
            "url": self.wd_url.text().strip(),
            "username": self.wd_user.text().strip(),
            "password": self.wd_pass.text(),
        }
        if not self._account.get("identifier_key"):
            self._account["identifier_key"] = make_identifier_key(name, self._existing_keys)
        self.accept()

    def get_account(self) -> Dict[str, Any]:
        return copy.deepcopy(self._account)


class NimbusConfigDialog(QDialog):
    """Multi-account Nimbus Cloud manager and Calibre integration settings."""

    def __init__(self, parent, custom_columns: Dict[str, Dict[str, Any]]):
        super().__init__(parent)
        self.setWindowTitle("Nimbus Cloud Configuration")
        self.setMinimumWidth(680)
        self.custom_columns = custom_columns or {}
        self._accounts = get_accounts()
        self._default_id = prefs.get("default_account_id") or (self._accounts[0]["id"] if self._accounts else "")

        layout = QVBoxLayout(self)

        # Cloud Accounts group
        acc_group = QGroupBox("Cloud Accounts")
        acc_layout = QVBoxLayout(acc_group)

        self.acc_table = QTableWidget(0, 6)
        self.acc_table.setHorizontalHeaderLabels(["Name", "Provider", "Folder", "Status", "Tag on Send", "Default"])
        sel_beh = (
            QAbstractItemView.SelectionBehavior.SelectRows
            if hasattr(QAbstractItemView, "SelectionBehavior")
            else QAbstractItemView.SelectRows
        )
        sel_mode = (
            QAbstractItemView.SelectionMode.SingleSelection
            if hasattr(QAbstractItemView, "SelectionMode")
            else QAbstractItemView.SingleSelection
        )
        no_edit = (
            QAbstractItemView.EditTrigger.NoEditTriggers
            if hasattr(QAbstractItemView, "EditTrigger")
            else QAbstractItemView.NoEditTriggers
        )
        self.acc_table.setSelectionBehavior(sel_beh)
        self.acc_table.setSelectionMode(sel_mode)
        self.acc_table.setEditTriggers(no_edit)
        hdr = self.acc_table.horizontalHeader()
        stretch = QHeaderView.ResizeMode.Stretch if hasattr(QHeaderView, "ResizeMode") else QHeaderView.Stretch
        hdr.setSectionResizeMode(stretch)
        self.acc_table.doubleClicked.connect(self._edit_selected_account)
        acc_layout.addWidget(self.acc_table)

        btn_row = QHBoxLayout()
        self.add_btn = QPushButton("Add Account…")
        self.add_btn.clicked.connect(self._add_account)
        self.edit_btn = QPushButton("Edit…")
        self.edit_btn.clicked.connect(self._edit_selected_account)
        self.remove_btn = QPushButton("Remove")
        self.remove_btn.clicked.connect(self._remove_selected_account)
        self.default_btn = QPushButton("Set as Default")
        self.default_btn.clicked.connect(self._set_selected_default)
        btn_row.addWidget(self.add_btn)
        btn_row.addWidget(self.edit_btn)
        btn_row.addWidget(self.remove_btn)
        btn_row.addStretch(1)
        btn_row.addWidget(self.default_btn)
        acc_layout.addLayout(btn_row)
        layout.addWidget(acc_group)

        # Calibre Integration group
        int_group = QGroupBox("Calibre Integration")
        int_layout = QVBoxLayout(int_group)
        self.chk_connect_share = QCheckBox("Show Nimbus Cloud inside Calibre's Connect/share menu")
        self.chk_connect_share.setChecked(bool(prefs.get("integrate_connect_share", True)))
        self.chk_context_menu = QCheckBox("Show Nimbus Cloud in Book List right-click menu")
        self.chk_context_menu.setChecked(bool(prefs.get("integrate_context_menu", True)))
        int_layout.addWidget(self.chk_connect_share)
        int_layout.addWidget(self.chk_context_menu)
        layout.addWidget(int_group)

        # Column mapping group (syncs from Default account)
        col_group = QGroupBox("Calibre Custom Column Mapping (Optional — syncs from Default account)")
        col_form = QFormLayout(col_group)
        col_form.setFieldGrowthPolicy(_expanding_policy())
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

        buttons = QDialogButtonBox(_dialog_ok_cancel())
        buttons.accepted.connect(self._save_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

        self._refresh_table()

    def _make_col_combo(self, current_val: str) -> QComboBox:
        cb = QComboBox()
        cb.addItem("(None)", "")
        for key, meta in sorted(self.custom_columns.items()):
            cb.addItem(f"{meta.get('name', key)} (#{key})", f"#{key}")
        idx = cb.findData(current_val or "")
        if idx >= 0:
            cb.setCurrentIndex(idx)
        return cb

    def _account_status_text(self, acc: Dict[str, Any]) -> str:
        p = acc.get("provider", "none")
        if p == "webdav":
            url = (acc.get("webdav") or {}).get("url", "")
            return url or "WebDAV (no URL)"
        tok = acc.get("oauth_tokens") or {}
        if tok.get("access_token"):
            return acc.get("identity") or "Signed in ✓"
        return "Not signed in"

    def _refresh_table(self):
        self.acc_table.setRowCount(0)
        for row, acc in enumerate(self._accounts):
            self.acc_table.insertRow(row)
            is_def = acc["id"] == self._default_id
            vals = [
                acc.get("name", ""),
                PROVIDER_LABELS.get(acc.get("provider", "none"), acc.get("provider", "")),
                acc.get("remote_root", "Nimbus"),
                self._account_status_text(acc),
                acc.get("tag", "") or "—",
                "★ Default" if is_def else "",
            ]
            for col, text in enumerate(vals):
                item = QTableWidgetItem(text)
                if col == 0:
                    item.setData(_user_role(), acc["id"])
                self.acc_table.setItem(row, col, item)
        if self._accounts and self.acc_table.currentRow() < 0:
            self.acc_table.selectRow(0)

    def _selected_index(self) -> int:
        row = self.acc_table.currentRow()
        if 0 <= row < len(self._accounts):
            return row
        return -1

    def _add_account(self):
        existing_keys = {a.get("identifier_key") for a in self._accounts if a.get("identifier_key")}
        dlg = NimbusAccountDialog(self, account=None, existing_identifier_keys=existing_keys)
        if dlg.exec():
            new_acc = dlg.get_account()
            self._accounts.append(new_acc)
            if not self._default_id or len(self._accounts) == 1:
                self._default_id = new_acc["id"]
            self._refresh_table()

    def _edit_selected_account(self):
        idx = self._selected_index()
        if idx < 0:
            return
        existing_keys = {
            a.get("identifier_key")
            for i, a in enumerate(self._accounts)
            if i != idx and a.get("identifier_key")
        }
        dlg = NimbusAccountDialog(self, account=self._accounts[idx], existing_identifier_keys=existing_keys)
        if dlg.exec():
            self._accounts[idx] = dlg.get_account()
            self._refresh_table()

    def _remove_selected_account(self):
        idx = self._selected_index()
        if idx < 0:
            return
        removed = self._accounts.pop(idx)
        if removed["id"] == self._default_id:
            self._default_id = self._accounts[0]["id"] if self._accounts else ""
        self._refresh_table()

    def _set_selected_default(self):
        idx = self._selected_index()
        if idx < 0:
            return
        self._default_id = self._accounts[idx]["id"]
        self._refresh_table()

    def _save_and_accept(self):
        save_accounts(self._accounts, self._default_id)
        prefs["integrate_connect_share"] = bool(self.chk_connect_share.isChecked())
        prefs["integrate_context_menu"] = bool(self.chk_context_menu.isChecked())
        for key, cb in self.col_combos.items():
            prefs[key] = cb.currentData() or ""
        prefs["sync_tag"] = self.sync_tag_edit.text().strip()
        self.accept()


class SelectAccountsDialog(QDialog):
    """Multi-account picker to send selected books to several clouds at once."""

    def __init__(self, parent, accounts: List[Dict[str, Any]], default_id: str = ""):
        super().__init__(parent)
        self.setWindowTitle("Send to Nimbus Cloud Accounts")
        self.setMinimumWidth(420)
        layout = QVBoxLayout(self)

        layout.addWidget(QLabel("Select the cloud account(s) to send the selected books to:"))
        self.list_widget = QListWidget()
        checkable = Qt.ItemFlag.ItemIsUserCheckable if hasattr(Qt, "ItemFlag") else Qt.ItemIsUserCheckable
        for acc in accounts:
            pname = PROVIDER_LABELS.get(acc.get("provider", "none"), acc.get("provider", ""))
            suffix = " ★ Default" if acc["id"] == default_id else ""
            item = QListWidgetItem(f"{acc['name']} ({pname}){suffix}")
            item.setFlags(item.flags() | checkable)
            item.setCheckState(_check_state(acc["id"] == default_id))
            item.setData(_user_role(), acc["id"])
            self.list_widget.addItem(item)
        layout.addWidget(self.list_widget)

        buttons = QDialogButtonBox(_dialog_ok_cancel())
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def selected_account_ids(self) -> List[str]:
        checked_val = _check_state(True)
        out: List[str] = []
        for i in range(self.list_widget.count()):
            item = self.list_widget.item(i)
            if item.checkState() == checked_val:
                out.append(item.data(_user_role()))
        return out

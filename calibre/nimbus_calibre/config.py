"""Configuration store for nimbus-calibre."""

import copy
import re
import socket
import uuid
from typing import Any, Dict, Iterable, List, Optional

from .templates import DEFAULT_SERIES_TEMPLATE

PROVIDER_LABELS: Dict[str, str] = {
    "none": "Not Configured",
    "gdrive": "Google Drive",
    "onedrive": "Microsoft OneDrive",
    "dropbox": "Dropbox",
    "webdav": "WebDAV",
}

DEFAULTS: Dict[str, Any] = {
    "provider": "none",
    "remote_root": "Nimbus",
    "device_id": "",
    "webdav": {"url": "", "username": "", "password": ""},
    "oauth_tokens": {},
    "accounts": [],
    "default_account_id": "",
    "integrate_connect_share": True,
    "integrate_context_menu": True,
    "col_percent": "",
    "col_status": "",
    "col_last_read": "",
    "col_highlights": "",
    "col_rating": "",
    "sync_tag": "",
}

try:
    from calibre.utils.config import JSONConfig
    prefs = JSONConfig("plugins/nimbus_calibre")
    prefs.defaults = dict(DEFAULTS)
except ImportError:
    class _MemConfig(dict):
        def __init__(self, d):
            super().__init__(copy.deepcopy(d))
            self.defaults = copy.deepcopy(d)
    prefs = _MemConfig(DEFAULTS)


def get_device_id() -> str:
    dev = prefs.get("device_id")
    if not dev:
        host = socket.gethostname().replace(" ", "-")[:20] or "Calibre"
        dev = f"Calibre-{host}_{uuid.uuid4().hex[:4]}"
        prefs["device_id"] = dev
    return dev


def new_account_id() -> str:
    return f"acc_{uuid.uuid4().hex[:8]}"


def make_identifier_key(name: str, existing_keys: Iterable[str]) -> str:
    used = {k for k in existing_keys if k}
    if "nimbus" not in used:
        return "nimbus"
    slug = re.sub(r"[^a-z0-9]+", "_", (name or "").strip().lower()).strip("_") or "cloud"
    base = f"nimbus_{slug[:24].strip('_') or 'cloud'}"
    candidate = base
    n = 2
    while candidate in used:
        candidate = f"{base}_{n}"
        n += 1
    return candidate


def normalize_remote_root(val: str) -> str:
    return "/".join(p for p in str(val or "").replace("\\", "/").split("/") if p).strip().lower()


def _normalize_account(acc: Dict[str, Any], existing_keys: Iterable[str]) -> Dict[str, Any]:
    out = copy.deepcopy(acc)
    out.setdefault("id", new_account_id())
    out["name"] = str(out.get("name") or PROVIDER_LABELS.get(out.get("provider", ""), "Nimbus Cloud")).strip()
    out["provider"] = out.get("provider") or "none"
    out["auth_source_id"] = str(out.get("auth_source_id") or "").strip()
    out["remote_root"] = str(out.get("remote_root") or "Nimbus").strip() or "Nimbus"
    out["tag"] = str(out.get("tag") or "").strip()
    if "folder_template" in out:
        out["folder_template"] = str(out.get("folder_template") or "").strip()
    else:
        out["folder_template"] = DEFAULT_SERIES_TEMPLATE
    out["identity"] = str(out.get("identity") or "").strip()
    wd = out.get("webdav") or {}
    out["webdav"] = {
        "url": str(wd.get("url") or "").strip(),
        "username": str(wd.get("username") or "").strip(),
        "password": str(wd.get("password") or ""),
    }
    out["oauth_tokens"] = dict(out.get("oauth_tokens") or {})
    if not out.get("identifier_key"):
        out["identifier_key"] = make_identifier_key(out["name"], existing_keys)
    return out


def resolve_account_for_cloud(
    acc: Dict[str, Any],
    all_accounts: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Resolve shared login credentials (auth_source_id) into a ready-to-use cloud config dict."""
    resolved = copy.deepcopy(acc)
    accounts_list = all_accounts if all_accounts is not None else get_accounts()
    by_id = {a["id"]: a for a in accounts_list}

    visited = {resolved.get("id")}
    owner = resolved
    src_id = resolved.get("auth_source_id") or ""
    while src_id and src_id in by_id and src_id not in visited:
        visited.add(src_id)
        owner = by_id[src_id]
        src_id = owner.get("auth_source_id") or ""

    resolved["token_owner_id"] = owner["id"]
    if owner["id"] != resolved.get("id"):
        resolved["provider"] = owner.get("provider") or "none"
        resolved["oauth_tokens"] = copy.deepcopy(owner.get("oauth_tokens") or {})
        resolved["webdav"] = copy.deepcopy(owner.get("webdav") or {})
        resolved["identity"] = owner.get("identity") or ""
    return resolved


def promote_credentials_on_remove(
    accounts: List[Dict[str, Any]],
    removed_acc: Dict[str, Any],
) -> List[Dict[str, Any]]:
    """Promote the first dependent account if a parent account sharing credentials is removed."""
    removed_id = removed_acc.get("id")
    updated = [copy.deepcopy(a) for a in accounts if a.get("id") != removed_id]
    dependents = [a for a in updated if a.get("auth_source_id") == removed_id]
    if not dependents:
        return updated

    new_owner = dependents[0]
    new_owner["auth_source_id"] = ""
    new_owner["provider"] = removed_acc.get("provider") or new_owner.get("provider") or "none"
    new_owner["oauth_tokens"] = copy.deepcopy(removed_acc.get("oauth_tokens") or {})
    new_owner["webdav"] = copy.deepcopy(removed_acc.get("webdav") or {})
    new_owner["identity"] = removed_acc.get("identity") or ""
    for dep in dependents[1:]:
        dep["auth_source_id"] = new_owner["id"]
    return updated


def migrate_legacy_config() -> bool:
    """Migrate legacy single-account prefs into prefs['accounts'] once, if needed."""
    existing = prefs.get("accounts") or []
    if existing:
        return False
    legacy_provider = prefs.get("provider") or "none"
    if legacy_provider == "none":
        return False

    legacy_tokens = dict((prefs.get("oauth_tokens") or {}).get(legacy_provider) or {})
    acc = _normalize_account(
        {
            "id": new_account_id(),
            "name": PROVIDER_LABELS.get(legacy_provider, "Primary"),
            "provider": legacy_provider,
            "remote_root": prefs.get("remote_root") or "Nimbus",
            "identifier_key": "nimbus",
            "tag": "",
            "webdav": dict(prefs.get("webdav") or {}),
            "oauth_tokens": legacy_tokens,
            "identity": "",
        },
        existing_keys=(),
    )
    prefs["accounts"] = [acc]
    prefs["default_account_id"] = acc["id"]
    return True


def get_accounts() -> List[Dict[str, Any]]:
    migrate_legacy_config()
    raw = prefs.get("accounts") or []
    result: List[Dict[str, Any]] = []
    used_keys = {a.get("identifier_key") for a in raw if a.get("identifier_key")}
    for a in raw:
        norm = _normalize_account(a, used_keys)
        used_keys.add(norm["identifier_key"])
        result.append(norm)
    return result


def save_accounts(accounts: List[Dict[str, Any]], default_account_id: str = "") -> List[Dict[str, Any]]:
    used_keys = set()
    normalized: List[Dict[str, Any]] = []
    for a in accounts:
        norm = _normalize_account(a, used_keys)
        used_keys.add(norm["identifier_key"])
        normalized.append(norm)

    ids = {a["id"] for a in normalized}
    for a in normalized:
        src_id = a.get("auth_source_id") or ""
        if src_id and (src_id not in ids or src_id == a["id"]):
            a["auth_source_id"] = ""

    if default_account_id not in ids:
        default_account_id = normalized[0]["id"] if normalized else ""

    prefs["accounts"] = normalized
    prefs["default_account_id"] = default_account_id

    # Keep legacy fields roughly in sync with the default account for compatibility
    default_acc = next((a for a in normalized if a["id"] == default_account_id), None)
    if default_acc:
        resolved_def = resolve_account_for_cloud(default_acc, normalized)
        prefs["provider"] = resolved_def["provider"]
        prefs["remote_root"] = resolved_def["remote_root"]
        prefs["webdav"] = dict(resolved_def["webdav"])
    else:
        prefs["provider"] = "none"
    return normalized


def get_default_account() -> Optional[Dict[str, Any]]:
    accounts = get_accounts()
    if not accounts:
        return None
    def_id = prefs.get("default_account_id") or ""
    for a in accounts:
        if a["id"] == def_id:
            return a
    return accounts[0]


def get_account_by_id(account_id: str) -> Optional[Dict[str, Any]]:
    for a in get_accounts():
        if a["id"] == account_id:
            return a
    return None


def update_account_tokens(account_id: str, new_tokens: Dict[str, Any]) -> None:
    accounts = get_accounts()
    changed = False
    for a in accounts:
        if a["id"] == account_id:
            a["oauth_tokens"] = dict(new_tokens or {})
            changed = True
            break
    if changed:
        prefs["accounts"] = accounts

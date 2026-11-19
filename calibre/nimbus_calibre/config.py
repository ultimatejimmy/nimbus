"""Configuration store for nimbus-calibre."""

import socket
import uuid
from typing import Any, Dict

DEFAULTS: Dict[str, Any] = {
    "provider": "none",
    "remote_root": "Nimbus",
    "device_id": "",
    "webdav": {"url": "", "username": "", "password": ""},
    "oauth_tokens": {},
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
            super().__init__(d)
            self.defaults = dict(d)
    prefs = _MemConfig(DEFAULTS)


def get_device_id() -> str:
    dev = prefs.get("device_id")
    if not dev:
        host = socket.gethostname().replace(" ", "-")[:20] or "Calibre"
        dev = f"Calibre-{host}_{uuid.uuid4().hex[:4]}"
        prefs["device_id"] = dev
    return dev

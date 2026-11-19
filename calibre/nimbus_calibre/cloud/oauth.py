"""OAuth2 Device Authorization Grant & token refresh for Calibre."""

import json
import time
import urllib.parse
from typing import Any, Callable, Dict, Optional

from .base import CloudFSError, http_request

DEFAULT_RELAY_URL = "https://backup.ultimatejimmy.workers.dev"

OAUTH_PROVIDERS = {
    "gdrive": {
        "name": "Google Drive",
        "client_id": "444320595925-2mlkslggov1f25qv45th2tq3dl466f9u.apps.googleusercontent.com",
        "device_code_url": "https://oauth2.googleapis.com/device/code",
        "scope": "https://www.googleapis.com/auth/drive.file",
        "relay_poll": f"{DEFAULT_RELAY_URL}/api/oauth/gdrive/poll",
        "relay_refresh": f"{DEFAULT_RELAY_URL}/api/oauth/gdrive/refresh",
    },
    "onedrive": {
        "name": "Microsoft OneDrive",
        "client_id": "982359c5-d74b-408c-8ff0-7d43c678195e",
        "device_code_url": "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
        "token_url": "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
        "scope": "Files.ReadWrite offline_access",
    },
    "dropbox": {
        "name": "Dropbox",
        "client_id": "khboin1ohr74q7y",
        "device_code_url": f"{DEFAULT_RELAY_URL}/api/oauth/dropbox/init",
        "relay_poll": f"{DEFAULT_RELAY_URL}/api/oauth/dropbox/poll",
        "relay_refresh": f"{DEFAULT_RELAY_URL}/api/oauth/dropbox/refresh",
    },
}


def request_device_code(provider: str) -> Dict[str, Any]:
    pdef = OAUTH_PROVIDERS.get(provider)
    if not pdef:
        raise CloudFSError(f"Unsupported OAuth provider: {provider}")
    form = urllib.parse.urlencode({
        "client_id": pdef["client_id"],
        "scope": pdef.get("scope", ""),
    }).encode("utf-8")
    status, _, body = http_request(
        pdef["device_code_url"],
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=form,
    )
    if status not in (200, 201):
        raise CloudFSError(f"Device code request failed (HTTP {status}): {body.decode('utf-8', 'replace')}")
    data = json.loads(body.decode("utf-8"))
    return {
        "device_code": data["device_code"],
        "user_code": data["user_code"],
        "verification_url": data.get("verification_uri_complete") or data.get("verification_url") or data.get("verification_uri"),
        "interval": int(data.get("interval") or 5),
        "expires_in": int(data.get("expires_in") or 600),
    }


def poll_token_once(provider: str, device_code: str) -> Optional[Dict[str, Any]]:
    pdef = OAUTH_PROVIDERS[provider]
    if "relay_poll" in pdef:
        payload = json.dumps({"device_code": device_code, "client_id": pdef["client_id"]}).encode("utf-8")
        status, _, body = http_request(
            pdef["relay_poll"],
            method="POST",
            headers={"Content-Type": "application/json"},
            data=payload,
        )
    else:
        form = urllib.parse.urlencode({
            "client_id": pdef["client_id"],
            "device_code": device_code,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        }).encode("utf-8")
        status, _, body = http_request(
            pdef["token_url"],
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data=form,
        )

    data = json.loads(body.decode("utf-8"))
    if status in (200, 201) and data.get("access_token"):
        return {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token"),
            "expires_at": int(time.time()) + int(data.get("expires_in") or 3600),
            "token_type": data.get("token_type", "Bearer"),
        }
    err = data.get("error")
    if err in ("authorization_pending", "slow_down"):
        return None
    raise CloudFSError(f"OAuth failed: {data.get('error_description') or err or status}")


def refresh_access_token(provider: str, tokens: Dict[str, Any]) -> Dict[str, Any]:
    pdef = OAUTH_PROVIDERS[provider]
    refresh_tok = tokens.get("refresh_token")
    if not refresh_tok:
        raise CloudFSError("Missing refresh_token; please sign in again.")

    if "relay_refresh" in pdef:
        payload = json.dumps({"refresh_token": refresh_tok, "client_id": pdef["client_id"]}).encode("utf-8")
        status, _, body = http_request(
            pdef["relay_refresh"],
            method="POST",
            headers={"Content-Type": "application/json"},
            data=payload,
        )
    else:
        form = urllib.parse.urlencode({
            "client_id": pdef["client_id"],
            "refresh_token": refresh_tok,
            "grant_type": "refresh_token",
        }).encode("utf-8")
        status, _, body = http_request(
            pdef["token_url"],
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data=form,
        )

    data = json.loads(body.decode("utf-8"))
    if status not in (200, 201) or not data.get("access_token"):
        raise CloudFSError(f"Token refresh failed (HTTP {status}): {data}")

    updated = dict(tokens)
    updated["access_token"] = data["access_token"]
    if data.get("refresh_token"):
        updated["refresh_token"] = data["refresh_token"]
    updated["expires_at"] = int(time.time()) + int(data.get("expires_in") or 3600)
    return updated


class TokenManager:
    """Manages OAuth access tokens with automatic refresh and persistence callback."""

    def __init__(self, provider: str, tokens: Dict[str, Any], on_save: Optional[Callable[[Dict[str, Any]], None]] = None):
        self.provider = provider
        self.tokens = dict(tokens or {})
        self.on_save = on_save

    def get_access_token(self) -> str:
        if not self.tokens.get("access_token"):
            raise CloudFSError(f"Not signed in to {self.provider}.")
        expires_at = int(self.tokens.get("expires_at") or 0)
        if expires_at and time.time() >= (expires_at - 120):
            self.tokens = refresh_access_token(self.provider, self.tokens)
            if self.on_save:
                self.on_save(self.tokens)
        return self.tokens["access_token"]

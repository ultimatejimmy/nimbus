"""Dropbox API v2 CloudFS driver for Calibre."""

import json
from typing import Dict, List, Optional

from .base import BaseCloudDriver, CloudEntry, CloudFSError, CloudNotFoundError, http_request, normalize_path
from .oauth import TokenManager

RPC_API = "https://api.dropboxapi.com/2"
CONTENT_API = "https://content.dropboxapi.com/2"


class DropboxDriver(BaseCloudDriver):
    def __init__(self, token_manager: TokenManager):
        self.tm = token_manager

    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        h = {"Authorization": f"Bearer {self.tm.get_access_token()}"}
        if extra:
            h.update(extra)
        return h

    @staticmethod
    def _dbx_path(remote_path: str) -> str:
        norm = normalize_path(remote_path)
        return f"/{norm}" if norm else ""

    def test_connection(self) -> str:
        status, _, body = http_request(
            f"{RPC_API}/users/get_current_account",
            method="POST",
            headers=self._headers(),
        )
        if status != 200:
            raise CloudFSError(f"Dropbox connection failed (HTTP {status})")
        data = json.loads(body.decode("utf-8"))
        return data.get("email") or data.get("name", {}).get("display_name") or "Dropbox"

    def ensure_path(self, remote_dir: str) -> str:
        p = self._dbx_path(remote_dir)
        if not p:
            return ""
        status, _, body = http_request(
            f"{RPC_API}/files/create_folder_v2",
            method="POST",
            headers=self._headers({"Content-Type": "application/json"}),
            data=json.dumps({"path": p, "autorename": False}).encode("utf-8"),
        )
        if status not in (200, 409):
            raise CloudFSError(f"Dropbox folder create failed (HTTP {status}): {body.decode('utf-8', 'replace')}")
        return p

    def upload_bytes(self, remote_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        p = self._dbx_path(remote_path)
        status, _, body = http_request(
            f"{CONTENT_API}/files/upload",
            method="POST",
            headers=self._headers({
                "Content-Type": "application/octet-stream",
                "Dropbox-API-Arg": json.dumps({"path": p, "mode": "overwrite", "mute": True}),
            }),
            data=data,
            timeout=300,
        )
        if status != 200:
            raise CloudFSError(f"Dropbox upload failed (HTTP {status}): {body.decode('utf-8', 'replace')}")

    def download_bytes(self, remote_path: str) -> bytes:
        p = self._dbx_path(remote_path)
        status, _, body = http_request(
            f"{CONTENT_API}/files/download",
            method="POST",
            headers=self._headers({"Dropbox-API-Arg": json.dumps({"path": p})}),
            timeout=300,
        )
        if status == 409:
            raise CloudNotFoundError(remote_path)
        if status != 200:
            raise CloudFSError(f"Dropbox download failed (HTTP {status})")
        return body

    def list_dir(self, remote_dir: str) -> List[CloudEntry]:
        p = self._dbx_path(remote_dir)
        url = f"{RPC_API}/files/list_folder"
        payload: dict = {"path": p, "recursive": False}
        entries: List[CloudEntry] = []
        while True:
            status, _, body = http_request(
                url,
                method="POST",
                headers=self._headers({"Content-Type": "application/json"}),
                data=json.dumps(payload).encode("utf-8"),
            )
            if status == 409:
                return []
            if status != 200:
                raise CloudFSError(f"Dropbox list failed (HTTP {status})")
            data = json.loads(body.decode("utf-8"))
            for item in data.get("entries") or []:
                rel = (item.get("path_display") or item.get("path_lower") or "").lstrip("/")
                entries.append(CloudEntry(
                    name=item["name"],
                    path=rel,
                    is_dir=(item.get(".tag") == "folder"),
                    size=int(item.get("size") or 0),
                    mtime=item.get("server_modified"),
                    file_id=item.get("id"),
                ))
            if not data.get("has_more"):
                break
            url = f"{RPC_API}/files/list_folder/continue"
            payload = {"cursor": data["cursor"]}
        return entries

    def delete_path(self, remote_path: str) -> None:
        p = self._dbx_path(remote_path)
        status, _, _ = http_request(
            f"{RPC_API}/files/delete_v2",
            method="POST",
            headers=self._headers({"Content-Type": "application/json"}),
            data=json.dumps({"path": p}).encode("utf-8"),
        )
        if status not in (200, 409):
            raise CloudFSError(f"Dropbox delete failed (HTTP {status})")

"""Google Drive v3 CloudFS driver for Calibre."""

import json
import urllib.parse
from typing import Dict, List, Optional, Tuple

from .base import BaseCloudDriver, CloudEntry, CloudFSError, CloudNotFoundError, http_request, normalize_path
from .oauth import TokenManager

DRIVE_API = "https://www.googleapis.com/drive/v3"
DRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3"


class GDriveDriver(BaseCloudDriver):
    def __init__(self, token_manager: TokenManager):
        self.tm = token_manager
        self._folder_cache: Dict[str, str] = {}

    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        h = {"Authorization": f"Bearer {self.tm.get_access_token()}"}
        if extra:
            h.update(extra)
        return h

    @staticmethod
    def _escape_q(val: str) -> str:
        return val.replace("\\", "\\\\").replace("'", "\\'")

    def _find_in_parent(self, parent_id: str, name: str, is_dir: Optional[bool] = None) -> Optional[dict]:
        mime_clause = ""
        if is_dir is True:
            mime_clause = " and mimeType = 'application/vnd.google-apps.folder'"
        elif is_dir is False:
            mime_clause = " and mimeType != 'application/vnd.google-apps.folder'"
        q = f"name = '{self._escape_q(name)}' and '{self._escape_q(parent_id)}' in parents and trashed = false{mime_clause}"
        url = f"{DRIVE_API}/files?q={urllib.parse.quote(q)}&fields=files(id,name,mimeType,size,modifiedTime)&pageSize=5"
        status, _, body = http_request(url, headers=self._headers())
        if status == 200:
            files = json.loads(body.decode("utf-8")).get("files") or []
            if files:
                return files[0]
        return None

    def _resolve_dir_id(self, remote_dir: str, create: bool) -> Optional[str]:
        norm = normalize_path(remote_dir)
        if not norm:
            return "root"
        if norm in self._folder_cache:
            return self._folder_cache[norm]

        parent_id = "root"
        acc = ""
        for part in norm.split("/"):
            acc = f"{acc}/{part}" if acc else part
            if acc in self._folder_cache:
                parent_id = self._folder_cache[acc]
                continue
            existing = self._find_in_parent(parent_id, part, is_dir=True)
            if existing and existing.get("id"):
                parent_id = existing["id"]
                self._folder_cache[acc] = parent_id
            elif create:
                meta = json.dumps({
                    "name": part,
                    "mimeType": "application/vnd.google-apps.folder",
                    "parents": [parent_id],
                }).encode("utf-8")
                status, _, body = http_request(
                    f"{DRIVE_API}/files?fields=id",
                    method="POST",
                    headers=self._headers({"Content-Type": "application/json; charset=UTF-8"}),
                    data=meta,
                )
                if status not in (200, 201):
                    raise CloudFSError(f"Failed to create Google Drive folder '{acc}' (HTTP {status})")
                parent_id = json.loads(body.decode("utf-8"))["id"]
                self._folder_cache[acc] = parent_id
            else:
                return None
        return parent_id

    def _resolve_item(self, remote_path: str) -> Tuple[str, Optional[dict]]:
        norm = normalize_path(remote_path)
        if "/" in norm:
            dir_part, name = norm.rsplit("/", 1)
        else:
            dir_part, name = "", norm
        parent_id = self._resolve_dir_id(dir_part, create=False)
        if not parent_id:
            return "", None
        return parent_id, self._find_in_parent(parent_id, name, is_dir=None)

    def test_connection(self) -> str:
        status, _, body = http_request(
            f"{DRIVE_API}/about?fields=user(displayName,emailAddress)",
            headers=self._headers(),
        )
        if status != 200:
            raise CloudFSError(f"Google Drive connection failed (HTTP {status})")
        user = json.loads(body.decode("utf-8")).get("user") or {}
        return user.get("emailAddress") or user.get("displayName") or "Google Drive"

    def ensure_path(self, remote_dir: str) -> str:
        folder_id = self._resolve_dir_id(remote_dir, create=True)
        if not folder_id:
            raise CloudFSError(f"Could not ensure directory: {remote_dir}")
        return folder_id

    def upload_bytes(self, remote_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        norm = normalize_path(remote_path)
        dir_part, name = norm.rsplit("/", 1) if "/" in norm else ("", norm)
        parent_id = self.ensure_path(dir_part)
        existing = self._find_in_parent(parent_id, name, is_dir=False)

        if existing and existing.get("id"):
            status, _, body = http_request(
                f"{DRIVE_UPLOAD}/files/{existing['id']}?uploadType=media",
                method="PATCH",
                headers=self._headers({"Content-Type": content_type}),
                data=data,
                timeout=300,
            )
        else:
            boundary = "nimbus_calibre_boundary"
            meta = json.dumps({"name": name, "parents": [parent_id]}).encode("utf-8")
            body_bytes = (
                f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".encode("utf-8")
                + meta
                + f"\r\n--{boundary}\r\nContent-Type: {content_type}\r\n\r\n".encode("utf-8")
                + data
                + f"\r\n--{boundary}--".encode("utf-8")
            )
            status, _, body = http_request(
                f"{DRIVE_UPLOAD}/files?uploadType=multipart",
                method="POST",
                headers=self._headers({"Content-Type": f"multipart/related; boundary={boundary}"}),
                data=body_bytes,
                timeout=300,
            )
        if status not in (200, 201):
            raise CloudFSError(f"Google Drive upload failed (HTTP {status}): {body.decode('utf-8', 'replace')}")

    def download_bytes(self, remote_path: str) -> bytes:
        _, item = self._resolve_item(remote_path)
        if not item:
            raise CloudNotFoundError(remote_path)
        status, _, body = http_request(
            f"{DRIVE_API}/files/{item['id']}?alt=media",
            headers=self._headers(),
            timeout=300,
        )
        if status == 404:
            raise CloudNotFoundError(remote_path)
        if status != 200:
            raise CloudFSError(f"Google Drive download failed (HTTP {status})")
        return body

    def list_dir(self, remote_dir: str) -> List[CloudEntry]:
        norm = normalize_path(remote_dir)
        parent_id = self._resolve_dir_id(norm, create=False)
        if not parent_id:
            return []
        entries: List[CloudEntry] = []
        page_token = None
        while True:
            q = f"'{self._escape_q(parent_id)}' in parents and trashed = false"
            url = f"{DRIVE_API}/files?q={urllib.parse.quote(q)}&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime)&pageSize=200"
            if page_token:
                url += f"&pageToken={urllib.parse.quote(page_token)}"
            status, _, body = http_request(url, headers=self._headers())
            if status != 200:
                raise CloudFSError(f"Google Drive list failed (HTTP {status})")
            data = json.loads(body.decode("utf-8"))
            for f in data.get("files") or []:
                is_dir = f.get("mimeType") == "application/vnd.google-apps.folder"
                entries.append(CloudEntry(
                    name=f["name"],
                    path=f"{norm}/{f['name']}" if norm else f["name"],
                    is_dir=is_dir,
                    size=int(f.get("size") or 0),
                    mtime=f.get("modifiedTime"),
                    file_id=f.get("id"),
                ))
            page_token = data.get("nextPageToken")
            if not page_token:
                break
        return entries

    def delete_path(self, remote_path: str) -> None:
        _, item = self._resolve_item(remote_path)
        if not item:
            return
        status, _, _ = http_request(f"{DRIVE_API}/files/{item['id']}", method="DELETE", headers=self._headers())
        if status not in (200, 204, 404):
            raise CloudFSError(f"Google Drive delete failed (HTTP {status})")
        self._folder_cache.clear()

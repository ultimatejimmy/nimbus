"""Microsoft Graph OneDrive CloudFS driver for Calibre."""

import json
import urllib.parse
from typing import Dict, List, Optional

from .base import BaseCloudDriver, CloudEntry, CloudFSError, CloudNotFoundError, http_request, normalize_path
from .oauth import TokenManager

GRAPH_API = "https://graph.microsoft.com/v1.0/me/drive"


class OneDriveDriver(BaseCloudDriver):
    def __init__(self, token_manager: TokenManager):
        self.tm = token_manager

    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        h = {"Authorization": f"Bearer {self.tm.get_access_token()}"}
        if extra:
            h.update(extra)
        return h

    def test_connection(self) -> str:
        status, _, body = http_request(GRAPH_API, headers=self._headers())
        if status != 200:
            raise CloudFSError(f"OneDrive connection failed (HTTP {status})")
        data = json.loads(body.decode("utf-8"))
        return data.get("owner", {}).get("user", {}).get("displayName") or "OneDrive"

    def ensure_path(self, remote_dir: str) -> str:
        norm = normalize_path(remote_dir)
        if not norm:
            return ""
        acc = ""
        for part in norm.split("/"):
            parent_url = f"{GRAPH_API}/root/children" if not acc else f"{GRAPH_API}/root:/{urllib.parse.quote(acc)}:/children"
            acc = f"{acc}/{part}" if acc else part
            check_status, _, _ = http_request(f"{GRAPH_API}/root:/{urllib.parse.quote(acc)}", headers=self._headers())
            if check_status != 200:
                payload = json.dumps({
                    "name": part,
                    "folder": {},
                    "@microsoft.graph.conflictBehavior": "replace",
                }).encode("utf-8")
                mk_status, _, _ = http_request(
                    parent_url,
                    method="POST",
                    headers=self._headers({"Content-Type": "application/json"}),
                    data=payload,
                )
                if mk_status not in (200, 201, 409):
                    raise CloudFSError(f"OneDrive folder create failed '{acc}' (HTTP {mk_status})")
        return norm

    def upload_bytes(self, remote_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        norm = normalize_path(remote_path)
        if "/" in norm:
            self.ensure_path(norm.rsplit("/", 1)[0])
        if len(data) <= 4 * 1024 * 1024:
            status, _, body = http_request(
                f"{GRAPH_API}/root:/{urllib.parse.quote(norm)}:/content",
                method="PUT",
                headers=self._headers({"Content-Type": content_type}),
                data=data,
                timeout=300,
            )
            if status not in (200, 201):
                raise CloudFSError(f"OneDrive upload failed (HTTP {status}): {body.decode('utf-8', 'replace')}")
            return

        status, _, body = http_request(
            f"{GRAPH_API}/root:/{urllib.parse.quote(norm)}:/createUploadSession",
            method="POST",
            headers=self._headers({"Content-Type": "application/json"}),
            data=json.dumps({"item": {"@microsoft.graph.conflictBehavior": "replace"}}).encode("utf-8"),
        )
        if status not in (200, 201):
            raise CloudFSError(f"OneDrive upload session failed (HTTP {status})")
        upload_url = json.loads(body.decode("utf-8"))["uploadUrl"]
        chunk_size = 5 * 1024 * 1024
        total = len(data)
        for offset in range(0, total, chunk_size):
            chunk = data[offset : offset + chunk_size]
            end_byte = offset + len(chunk) - 1
            c_status, _, _ = http_request(
                upload_url,
                method="PUT",
                headers={"Content-Range": f"bytes {offset}-{end_byte}/{total}"},
                data=chunk,
                timeout=300,
            )
            if c_status not in (200, 201, 202):
                raise CloudFSError(f"OneDrive chunk upload failed (HTTP {c_status})")

    def download_bytes(self, remote_path: str) -> bytes:
        norm = normalize_path(remote_path)
        status, _, body = http_request(
            f"{GRAPH_API}/root:/{urllib.parse.quote(norm)}:/content",
            headers=self._headers(),
            timeout=300,
        )
        if status == 404:
            raise CloudNotFoundError(remote_path)
        if status != 200:
            raise CloudFSError(f"OneDrive download failed (HTTP {status})")
        return body

    def list_dir(self, remote_dir: str) -> List[CloudEntry]:
        norm = normalize_path(remote_dir)
        url = f"{GRAPH_API}/root/children" if not norm else f"{GRAPH_API}/root:/{urllib.parse.quote(norm)}:/children"
        entries: List[CloudEntry] = []
        while url:
            status, _, body = http_request(url, headers=self._headers())
            if status == 404:
                return []
            if status != 200:
                raise CloudFSError(f"OneDrive list failed (HTTP {status})")
            data = json.loads(body.decode("utf-8"))
            for item in data.get("value") or []:
                entries.append(CloudEntry(
                    name=item["name"],
                    path=f"{norm}/{item['name']}" if norm else item["name"],
                    is_dir="folder" in item,
                    size=int(item.get("size") or 0),
                    mtime=item.get("lastModifiedDateTime"),
                    file_id=item.get("id"),
                ))
            url = data.get("@odata.nextLink")
        return entries

    def delete_path(self, remote_path: str) -> None:
        norm = normalize_path(remote_path)
        status, _, _ = http_request(
            f"{GRAPH_API}/root:/{urllib.parse.quote(norm)}",
            method="DELETE",
            headers=self._headers(),
        )
        if status not in (200, 204, 404):
            raise CloudFSError(f"OneDrive delete failed (HTTP {status})")

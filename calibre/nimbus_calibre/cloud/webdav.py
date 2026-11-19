"""WebDAV CloudFS driver for Calibre."""

import base64
import urllib.parse
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional

from .base import BaseCloudDriver, CloudEntry, CloudFSError, CloudNotFoundError, http_request, normalize_path


class WebDAVDriver(BaseCloudDriver):
    def __init__(self, url: str, username: str = "", password: str = ""):
        self.base_url = (url or "").rstrip("/")
        self.username = username or ""
        self.password = password or ""

    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        h: Dict[str, str] = {}
        if self.username:
            token = base64.b64encode(f"{self.username}:{self.password}".encode("utf-8")).decode("ascii")
            h["Authorization"] = f"Basic {token}"
        if extra:
            h.update(extra)
        return h

    def _url(self, remote_path: str) -> str:
        norm = normalize_path(remote_path)
        if not norm:
            return f"{self.base_url}/"
        return f"{self.base_url}/{urllib.parse.quote(norm, safe='/')}"

    def test_connection(self) -> str:
        if not self.base_url:
            raise CloudFSError("WebDAV URL is not configured.")
        status, _, _ = http_request(
            self._url(""),
            method="PROPFIND",
            headers=self._headers({"Depth": "0"}),
        )
        if status not in (200, 207):
            raise CloudFSError(f"WebDAV connection failed (HTTP {status})")
        return self.base_url

    def ensure_path(self, remote_dir: str) -> str:
        norm = normalize_path(remote_dir)
        if not norm:
            return ""
        acc = ""
        for part in norm.split("/"):
            acc = f"{acc}/{part}" if acc else part
            u = self._url(acc) + "/"
            status, _, _ = http_request(u, method="MKCOL", headers=self._headers())
            if status not in (200, 201, 204, 405):
                p_status, _, _ = http_request(u, method="PROPFIND", headers=self._headers({"Depth": "0"}))
                if p_status not in (200, 207):
                    raise CloudFSError(f"WebDAV MKCOL failed for '{acc}' (HTTP {status})")
        return norm

    def upload_bytes(self, remote_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        norm = normalize_path(remote_path)
        if "/" in norm:
            self.ensure_path(norm.rsplit("/", 1)[0])
        status, _, _ = http_request(
            self._url(norm),
            method="PUT",
            headers=self._headers({"Content-Type": content_type}),
            data=data,
            timeout=300,
        )
        if status not in (200, 201, 204):
            raise CloudFSError(f"WebDAV PUT failed (HTTP {status})")

    def download_bytes(self, remote_path: str) -> bytes:
        status, _, body = http_request(self._url(remote_path), headers=self._headers(), timeout=300)
        if status == 404:
            raise CloudNotFoundError(remote_path)
        if status != 200:
            raise CloudFSError(f"WebDAV GET failed (HTTP {status})")
        return body

    def list_dir(self, remote_dir: str) -> List[CloudEntry]:
        norm = normalize_path(remote_dir)
        target_url = self._url(norm)
        if not target_url.endswith("/"):
            target_url += "/"
        propfind_body = (
            b'<?xml version="1.0" encoding="utf-8"?>'
            b'<d:propfind xmlns:d="DAV:"><d:prop>'
            b"<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>"
            b"</d:prop></d:propfind>"
        )
        status, _, body = http_request(
            target_url,
            method="PROPFIND",
            headers=self._headers({"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}),
            data=propfind_body,
        )
        if status == 404:
            return []
        if status not in (200, 207):
            raise CloudFSError(f"WebDAV PROPFIND failed (HTTP {status})")

        root = ET.fromstring(body)
        req_path = urllib.parse.unquote(urllib.parse.urlparse(target_url).path).rstrip("/")
        entries: List[CloudEntry] = []

        for resp in root.findall(".//{DAV:}response"):
            href_el = resp.find("{DAV:}href")
            if href_el is None or not href_el.text:
                continue
            href_raw = href_el.text
            href_path = urllib.parse.unquote(urllib.parse.urlparse(href_raw).path).rstrip("/")
            if href_path == req_path:
                continue
            name = href_path.rsplit("/", 1)[-1]
            if not name:
                continue
            is_dir = resp.find(".//{DAV:}collection") is not None or href_raw.endswith("/")
            size_el = resp.find(".//{DAV:}getcontentlength")
            mtime_el = resp.find(".//{DAV:}getlastmodified")
            entries.append(CloudEntry(
                name=name,
                path=f"{norm}/{name}" if norm else name,
                is_dir=is_dir,
                size=int(size_el.text) if (size_el is not None and size_el.text and size_el.text.isdigit()) else 0,
                mtime=mtime_el.text if mtime_el is not None else None,
            ))
        return entries

    def delete_path(self, remote_path: str) -> None:
        status, _, _ = http_request(self._url(remote_path), method="DELETE", headers=self._headers())
        if status not in (200, 204, 404):
            raise CloudFSError(f"WebDAV DELETE failed (HTTP {status})")

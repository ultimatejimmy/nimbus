"""Shared CloudFS interface and HTTP helpers using Python stdlib."""

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


class CloudFSError(Exception):
    """Raised when a cloud storage operation fails."""


class CloudNotFoundError(CloudFSError):
    """Raised when a remote file or directory does not exist."""


@dataclass
class CloudEntry:
    name: str
    path: str
    is_dir: bool
    size: int = 0
    mtime: Optional[str] = None
    file_id: Optional[str] = None


def http_request(
    url: str,
    method: str = "GET",
    headers: Optional[Dict[str, str]] = None,
    data: Optional[bytes] = None,
    timeout: int = 60,
) -> Tuple[int, Dict[str, str], bytes]:
    """Perform an HTTP request and return (status_code, headers_lower, body_bytes)."""
    req_headers = {"User-Agent": "Nimbus-Calibre/0.1.0"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, resp_headers, resp.read()
    except urllib.error.HTTPError as e:
        resp_headers = {k.lower(): v for k, v in (e.headers.items() if e.headers else [])}
        return e.code, resp_headers, e.read()
    except urllib.error.URLError as e:
        raise CloudFSError(f"Network error: {e.reason}") from e


def normalize_path(path: str) -> str:
    p = (path or "").replace("\\", "/").strip("/")
    while "//" in p:
        p = p.replace("//", "/")
    return p


class BaseCloudDriver:
    """Abstract CloudFS driver contract."""

    def test_connection(self) -> str:
        raise NotImplementedError

    def ensure_path(self, remote_dir: str) -> str:
        raise NotImplementedError

    def upload_bytes(self, remote_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        raise NotImplementedError

    def upload_file(self, remote_path: str, local_path: str) -> None:
        with open(local_path, "rb") as f:
            self.upload_bytes(remote_path, f.read(), "application/octet-stream")

    def download_bytes(self, remote_path: str) -> bytes:
        raise NotImplementedError

    def download_string(self, remote_path: str) -> str:
        return self.download_bytes(remote_path).decode("utf-8")

    def download_json(self, remote_path: str) -> Any:
        return json.loads(self.download_string(remote_path))

    def upload_json(self, remote_path: str, obj: Any) -> None:
        raw = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.upload_bytes(remote_path, raw, "application/json; charset=utf-8")

    def list_dir(self, remote_dir: str) -> List[CloudEntry]:
        raise NotImplementedError

    def delete_path(self, remote_path: str) -> None:
        raise NotImplementedError

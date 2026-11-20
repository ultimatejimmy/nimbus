"""Nimbus Calibre CloudFS factory & root-prefixed wrapper."""

from typing import Any, Callable, Dict, List, Optional

from .base import BaseCloudDriver, CloudEntry, CloudFSError, normalize_path
from .dropbox import DropboxDriver
from .gdrive import GDriveDriver
from .oauth import TokenManager
from .onedrive import OneDriveDriver
from .webdav import WebDAVDriver


class RootPrefixedFS:
    """Wraps a BaseCloudDriver so all relative paths sit under remote_root (e.g. 'Nimbus')."""

    def __init__(self, driver: BaseCloudDriver, remote_root: str = "Nimbus"):
        self.driver = driver
        self.remote_root = normalize_path(remote_root)

    def _full(self, rel_path: str) -> str:
        rel = normalize_path(rel_path)
        if not self.remote_root:
            return rel
        return f"{self.remote_root}/{rel}" if rel else self.remote_root

    def test_connection(self) -> str:
        return self.driver.test_connection()

    def upload_bytes(self, rel_path: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        self.driver.upload_bytes(self._full(rel_path), data, content_type)

    def upload_file(self, rel_path: str, local_path: str) -> None:
        self.driver.upload_file(self._full(rel_path), local_path)

    def download_bytes(self, rel_path: str) -> bytes:
        return self.driver.download_bytes(self._full(rel_path))

    def download_json(self, rel_path: str) -> Any:
        return self.driver.download_json(self._full(rel_path))

    def upload_json(self, rel_path: str, obj: Any) -> None:
        self.driver.upload_json(self._full(rel_path), obj)

    def list_dir(self, rel_dir: str) -> List[CloudEntry]:
        return self.driver.list_dir(self._full(rel_dir))

    def delete_path(self, rel_path: str) -> None:
        self.driver.delete_path(self._full(rel_path))


def build_cloud_fs(
    config: Dict[str, Any],
    on_save_tokens: Optional[Callable[[str, Dict[str, Any]], None]] = None,
) -> RootPrefixedFS:
    provider = (config or {}).get("provider", "none")
    root = (config or {}).get("remote_root", "Nimbus")

    if provider == "webdav":
        wd = (config or {}).get("webdav") or {}
        driver: BaseCloudDriver = WebDAVDriver(wd.get("url", ""), wd.get("username", ""), wd.get("password", ""))
        return RootPrefixedFS(driver, root)

    if provider in ("gdrive", "onedrive", "dropbox"):
        raw_toks = (config or {}).get("oauth_tokens") or {}
        if "access_token" in raw_toks or "refresh_token" in raw_toks:
            tokens = raw_toks
        else:
            tokens = raw_toks.get(provider) or {}
        tm = TokenManager(
            provider,
            tokens,
            on_save=(lambda new_tok: on_save_tokens(provider, new_tok)) if on_save_tokens else None,
        )
        if provider == "gdrive":
            driver = GDriveDriver(tm)
        elif provider == "onedrive":
            driver = OneDriveDriver(tm)
        else:
            driver = DropboxDriver(tm)
        return RootPrefixedFS(driver, root)

    raise CloudFSError(f"Cloud provider '{provider}' is not configured.")

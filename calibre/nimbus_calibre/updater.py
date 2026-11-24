"""Built-in GitHub Releases updater for the Nimbus Cloud Calibre plugin."""

import json
import os
import re
import tempfile
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

GITHUB_RELEASES_API = "https://api.github.com/repos/ultimatejimmy/nimbus/releases?per_page=15"
ASSET_NAME = "NimbusCalibre.zip"


def normalize_version_tuple(ver: Tuple[int, ...]) -> Tuple[int, int, int]:
    """Normalize (2026, 11, 24) or (26, 11, 24) to 2-digit year tuple for comparison."""
    nums = list(ver) + [0, 0, 0]
    y, m, d = int(nums[0]), int(nums[1]), int(nums[2])
    if y >= 2000:
        y = y % 100
    return (y, m, d)


def parse_release_version(tag: str) -> Optional[Tuple[int, int, int]]:
    s = str(tag or "").strip()
    s = re.sub(r"^(calibre[-_]?|v)", "", s, flags=re.IGNORECASE)
    base = s.split("-", 1)[0]
    parts = [int(p) for p in base.split(".") if p.isdigit()]
    if len(parts) < 2:
        return None
    while len(parts) < 3:
        parts.append(0)
    return normalize_version_tuple((parts[0], parts[1], parts[2]))


def format_version(ver: Tuple[int, ...]) -> str:
    n = normalize_version_tuple(ver)
    return f"{n[0]}.{n[1]}.{n[2]}"


def find_latest_calibre_release(releases: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    best = None
    best_ver = None
    for rel in releases or []:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        assets = rel.get("assets") or []
        zip_asset = next((a for a in assets if a.get("name") == ASSET_NAME and a.get("browser_download_url")), None)
        if not zip_asset:
            continue
        ver = parse_release_version(rel.get("tag_name") or rel.get("name") or "")
        if not ver:
            continue
        if best_ver is None or ver > best_ver:
            best_ver = ver
            best = {
                "tag": rel.get("tag_name") or "",
                "version": ver,
                "version_str": format_version(ver),
                "download_url": zip_asset["browser_download_url"],
                "notes": (rel.get("body") or "").strip(),
            }
    return best


def check_for_update(current_version: Tuple[int, ...], timeout: int = 15) -> Dict[str, Any]:
    req = urllib.request.Request(
        GITHUB_RELEASES_API,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "NimbusCalibre-Updater",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        releases = json.loads(resp.read().decode("utf-8"))

    cur_norm = normalize_version_tuple(current_version)
    latest = find_latest_calibre_release(releases)
    if not latest:
        return {
            "has_update": False,
            "current": format_version(cur_norm),
            "latest": format_version(cur_norm),
            "download_url": "",
            "notes": "",
            "tag": "",
        }
    return {
        "has_update": latest["version"] > cur_norm,
        "current": format_version(cur_norm),
        "latest": latest["version_str"],
        "download_url": latest["download_url"],
        "notes": latest["notes"],
        "tag": latest["tag"],
    }


def download_and_install_update(download_url: str, timeout: int = 60) -> None:
    from calibre.customize.ui import add_plugin

    req = urllib.request.Request(
        download_url,
        headers={"User-Agent": "NimbusCalibre-Updater"},
    )
    fd, tmp_path = tempfile.mkstemp(prefix="nimbus_update_", suffix=".zip")
    os.close(fd)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp, open(tmp_path, "wb") as out:
            out.write(resp.read())
        add_plugin(tmp_path)
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass

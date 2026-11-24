#!/usr/bin/env python3
"""Build installable Calibre plugin bundle dist/NimbusCalibre.zip."""

import argparse
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Optional

CALIBRE_DIR = Path(__file__).resolve().parent
PLUGIN_SRC = CALIBRE_DIR / "nimbus_calibre"
DIST_DIR = CALIBRE_DIR / "dist"
OUT_ZIP = DIST_DIR / "NimbusCalibre.zip"


def find_calibre_customize(explicit: Optional[str] = None) -> Optional[str]:
    if explicit and Path(explicit).exists():
        return explicit
    env_exe = os.environ.get("CALIBRE_CUSTOMIZE")
    if env_exe and Path(env_exe).exists():
        return env_exe
    found = shutil.which("calibre-customize")
    if found:
        return found
    home = Path.home()
    candidates = [
        Path(r"C:\Program Files\Calibre2\calibre-customize.exe"),
        Path(r"C:\Program Files (x86)\Calibre2\calibre-customize.exe"),
        Path("/Applications/calibre.app/Contents/MacOS/calibre-customize"),
        Path("/usr/bin/calibre-customize"),
    ]
    for root in (home, home / "OneDrive", home / "OneDrive" / "Portable Apps", home / "Portable Apps"):
        candidates.append(root / "Calibre Portable" / "Calibre" / "calibre-customize.exe")
    for c in candidates:
        if c.exists():
            return str(c)
    return None


def build() -> Path:
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(PLUGIN_SRC):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for fname in sorted(files):
                if fname.endswith((".pyc", ".pyo")):
                    continue
                full = Path(root) / fname
                rel = full.relative_to(PLUGIN_SRC)
                zf.write(full, arcname=str(rel).replace("\\", "/"))
    print(f"Built {OUT_ZIP} ({OUT_ZIP.stat().st_size} bytes)")
    return OUT_ZIP


def install_plugin(zip_path: Path, explicit_exe: Optional[str] = None) -> int:
    exe = find_calibre_customize(explicit_exe)
    if not exe:
        print(
            "Error: calibre-customize not found on PATH or standard/portable install directories.\n"
            f"Pass --calibre-exe <path> or install manually via Calibre -> Preferences -> Plugins -> Load plugin from file: {zip_path}",
            file=sys.stderr,
        )
        return 1
    env = os.environ.copy()
    portable_settings = Path(exe).resolve().parent.parent / "Calibre Settings"
    if portable_settings.is_dir() and "CALIBRE_CONFIG_DIRECTORY" not in env:
        env["CALIBRE_CONFIG_DIRECTORY"] = str(portable_settings)
        print(f"Detected Calibre Portable settings: {portable_settings}")
    print(f"Installing {zip_path} via {exe} ...")
    res = subprocess.run([exe, "-a", str(zip_path)], env=env, check=False)
    if res.returncode == 0:
        print("Installed! Restart Calibre if it is currently running.")
    return res.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build (and optionally install) NimbusCalibre.zip")
    parser.add_argument("--install", action="store_true", help="Install into Calibre via calibre-customize -a")
    parser.add_argument("--calibre-exe", help="Explicit path to calibre-customize executable")
    args = parser.parse_args()
    out = build()
    if args.install:
        sys.exit(install_plugin(out, args.calibre_exe))

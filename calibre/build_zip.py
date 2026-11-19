#!/usr/bin/env python3
"""Build installable Calibre plugin bundle dist/NimbusCalibre.zip."""

import os
import zipfile
from pathlib import Path

CALIBRE_DIR = Path(__file__).resolve().parent
PLUGIN_SRC = CALIBRE_DIR / "nimbus_calibre"
DIST_DIR = CALIBRE_DIR / "dist"
OUT_ZIP = DIST_DIR / "NimbusCalibre.zip"


def build():
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


if __name__ == "__main__":
    build()

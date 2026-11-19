#!/usr/bin/env python3
"""Bump version across nimbus.koplugin, nimbus-calibre, and nimbus-web, then commit, tag, and push."""

import json
import re
import subprocess
import sys
from pathlib import Path


def run_cmd(cmd, cwd=None):
    print(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, check=True, cwd=cwd)


def main():
    if len(sys.argv) != 2:
        print("Usage: python release.py <new_version>")
        sys.exit(1)

    new_version = sys.argv[1].strip().lstrip("v")
    tag_name = f"v{new_version}"
    repo_root = Path(__file__).resolve().parents[1]

    changed_files = []

    # 1. koreader/nimbus.koplugin/_meta.lua
    meta_path = repo_root / "koreader" / "nimbus.koplugin" / "_meta.lua"
    if meta_path.exists():
        content = meta_path.read_text(encoding="utf-8")
        new_content, count = re.subn(r'version\s*=\s*"[^"]+"', f'version = "{new_version}"', content)
        if count > 0 and new_content != content:
            meta_path.write_text(new_content, encoding="utf-8")
            changed_files.append(str(meta_path))

    # 2. koreader/nimbus.koplugin/nimbus_constants.lua
    const_path = repo_root / "koreader" / "nimbus.koplugin" / "nimbus_constants.lua"
    if const_path.exists():
        content = const_path.read_text(encoding="utf-8")
        new_content, count = re.subn(r'Constants\.VERSION\s*=\s*"[^"]+"', f'Constants.VERSION = "{new_version}"', content)
        if count > 0 and new_content != content:
            const_path.write_text(new_content, encoding="utf-8")
            changed_files.append(str(const_path))

    # 3. calibre/nimbus_calibre/__init__.py
    cal_init = repo_root / "calibre" / "nimbus_calibre" / "__init__.py"
    if cal_init.exists():
        parts = [p for p in new_version.split("-")[0].split(".") if p.isdigit()]
        while len(parts) < 3:
            parts.append("0")
        ver_tuple = f"({parts[0]}, {parts[1]}, {parts[2]})"
        content = cal_init.read_text(encoding="utf-8")
        new_content, count = re.subn(r"version\s*=\s*\(\d+,\s*\d+,\s*\d+\)", f"version = {ver_tuple}", content)
        if count > 0 and new_content != content:
            cal_init.write_text(new_content, encoding="utf-8")
            changed_files.append(str(cal_init))

    # 4. web/package.json
    pkg_path = repo_root / "web" / "package.json"
    if pkg_path.exists():
        pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
        if pkg.get("version") != new_version:
            pkg["version"] = new_version
            pkg_path.write_text(json.dumps(pkg, indent=2) + "\n", encoding="utf-8")
            changed_files.append(str(pkg_path))

    try:
        if changed_files:
            run_cmd(["git", "add", *changed_files], cwd=repo_root)
            run_cmd(["git", "commit", "-m", f"Release {tag_name}"], cwd=repo_root)

        tag_check = subprocess.run(["git", "tag", "-l", tag_name], capture_output=True, text=True, cwd=repo_root)
        if tag_name not in tag_check.stdout.splitlines():
            run_cmd(["git", "tag", tag_name], cwd=repo_root)

        push_cmd = ["git", "push", "origin"]
        if changed_files:
            push_cmd.extend(["HEAD", tag_name])
        else:
            push_cmd.append(tag_name)
        run_cmd(push_cmd, cwd=repo_root)
        print(f"\nRelease {tag_name} completed and pushed successfully!")
    except subprocess.CalledProcessError as e:
        print(f"Error during git operations: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

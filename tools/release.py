#!/usr/bin/env python3
"""
Release script for Nimbus (date-based versioning, e.g. 2026.11.19 or 2026.11.19-beta).

Usage:
  python tools/release.py 2026.11.19             # Releases KOReader plugin (tag: 2026.11.19)
  python tools/release.py koreader 2026.11.19    # Releases KOReader plugin (tag: 2026.11.19)
  python tools/release.py calibre 2026.11.19     # Releases Calibre plugin  (tag: calibre-2026.11.19)
  python tools/release.py all 2026.11.19         # Releases both as separate tags (2026.11.19 + calibre-2026.11.19)
"""

import json
import re
import subprocess
import sys
from pathlib import Path

VALID_TARGETS = ("koreader", "calibre", "all")


def run_cmd(cmd, cwd=None):
    print(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, check=True, cwd=cwd)


def parse_version_tuple(ver_str: str):
    base = ver_str.split("-")[0]
    nums = [int(p) for p in base.split(".") if p.isdigit()]
    while len(nums) < 3:
        nums.append(0)
    return nums[0], nums[1], nums[2]


def update_koreader_version(repo_root: Path, new_version: str):
    changed = []
    meta_path = repo_root / "koreader" / "nimbus.koplugin" / "_meta.lua"
    if meta_path.exists():
        content = meta_path.read_text(encoding="utf-8")
        new_content, count = re.subn(
            r'^([ \t]*version\s*=\s*)"[^"]+"',
            rf'\g<1>"{new_version}"',
            content,
            flags=re.MULTILINE,
        )
        if count != 1:
            print(f"Error: Expected 1 version string in _meta.lua, found {count}")
            sys.exit(1)
        if new_content != content:
            meta_path.write_text(new_content, encoding="utf-8")
            changed.append(str(meta_path.resolve()))

    const_path = repo_root / "koreader" / "nimbus.koplugin" / "nimbus_constants.lua"
    if const_path.exists():
        content = const_path.read_text(encoding="utf-8")
        new_content, count = re.subn(
            r'Constants\.VERSION\s*=\s*"[^"]+"',
            f'Constants.VERSION = "{new_version}"',
            content,
        )
        if count > 0 and new_content != content:
            const_path.write_text(new_content, encoding="utf-8")
            changed.append(str(const_path.resolve()))
    return changed


def update_calibre_version(repo_root: Path, new_version: str):
    changed = []
    cal_init = repo_root / "calibre" / "nimbus_calibre" / "__init__.py"
    if cal_init.exists():
        v0, v1, v2 = parse_version_tuple(new_version)
        ver_tuple = f"({v0}, {v1}, {v2})"
        content = cal_init.read_text(encoding="utf-8")
        new_content, count = re.subn(
            r"^([ \t]*version\s*=\s*)\(\d+,\s*\d+,\s*\d+\)",
            rf"\g<1>{ver_tuple}",
            content,
            flags=re.MULTILINE,
        )
        if count != 1:
            print(f"Error: Expected 1 version tuple in calibre/nimbus_calibre/__init__.py, found {count}")
            sys.exit(1)
        if new_content != content:
            cal_init.write_text(new_content, encoding="utf-8")
            changed.append(str(cal_init.resolve()))
    return changed


def update_web_version(repo_root: Path, new_version: str):
    changed = []
    pkg_path = repo_root / "web" / "package.json"
    if pkg_path.exists():
        v0, v1, v2 = parse_version_tuple(new_version)
        suffix = f"-{new_version.split('-', 1)[1]}" if "-" in new_version else ""
        semver_str = f"{v0}.{v1}.{v2}{suffix}"
        pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
        if pkg.get("version") != semver_str:
            pkg["version"] = semver_str
            pkg_path.write_text(json.dumps(pkg, indent=2) + "\n", encoding="utf-8")
            changed.append(str(pkg_path.resolve()))
    return changed


def parse_args(argv):
    if len(argv) == 2 and argv[1] not in ("-h", "--help") and argv[1] not in VALID_TARGETS:
        return "koreader", argv[1].strip()
    if len(argv) == 3 and argv[1].lower() in VALID_TARGETS:
        return argv[1].lower(), argv[2].strip()
    print(__doc__.strip())
    sys.exit(1)


def main():
    target, raw_version = parse_args(sys.argv)
    # Strip accidental leading 'v' or 'calibre-' so tags are always normalized
    if raw_version.lower().startswith("calibre-"):
        raw_version = raw_version[len("calibre-") :]
    if raw_version.lower().startswith("v") and len(raw_version) > 1 and raw_version[1].isdigit():
        raw_version = raw_version[1:]

    repo_root = Path(__file__).resolve().parents[1]
    changed_files = []
    tags_to_push = []

    if target in ("koreader", "all"):
        print(f"Updating KOReader plugin version to {raw_version}...")
        changed_files.extend(update_koreader_version(repo_root, raw_version))
        tags_to_push.append(raw_version)

    if target in ("calibre", "all"):
        print(f"Updating Calibre plugin version to {raw_version}...")
        changed_files.extend(update_calibre_version(repo_root, raw_version))
        tags_to_push.append(f"calibre-{raw_version}")

    if target == "all":
        changed_files.extend(update_web_version(repo_root, raw_version))

    print(f"Executing git commands in {repo_root}...")
    try:
        if changed_files:
            run_cmd(["git", "add", *changed_files], cwd=repo_root)
            commit_label = f"Release {raw_version}" if target != "calibre" else f"Release calibre-{raw_version}"
            run_cmd(["git", "commit", "-m", commit_label], cwd=repo_root)
        else:
            print("Version files already match target version.")

        existing_tags = subprocess.run(
            ["git", "tag", "-l"],
            capture_output=True,
            text=True,
            cwd=repo_root,
        ).stdout.splitlines()

        for t in tags_to_push:
            if t not in existing_tags:
                run_cmd(["git", "tag", t], cwd=repo_root)
            else:
                print(f"Tag {t} already exists locally. Skipping local tag creation.")

        push_cmd = ["git", "push", "origin"]
        if changed_files:
            push_cmd.append("HEAD")
        push_cmd.extend(tags_to_push)

        run_cmd(push_cmd, cwd=repo_root)
        print(f"\n✅ Release ({', '.join(tags_to_push)}) completed and pushed successfully!")
    except subprocess.CalledProcessError as e:
        print(f"Error during git operations: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

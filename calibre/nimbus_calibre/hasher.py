"""Exact KOReader partial_md5, SHA-256, and deterministic annotation ID helpers."""

import hashlib
import re
import uuid

PARTIAL_MD5_OFFSETS = (
    0,
    1024,
    4096,
    16384,
    65536,
    262144,
    1048576,
    4194304,
    16777216,
    67108864,
    268435456,
    1073741824,
)


def partial_md5(filepath: str) -> str:
    """Compute KOReader-compatible partial_md5 (1024-byte geometric offsets)."""
    h = hashlib.md5()
    with open(filepath, "rb") as f:
        for offset in PARTIAL_MD5_OFFSETS:
            f.seek(offset)
            chunk = f.read(1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def sha256_file(filepath: str) -> str:
    """Compute lowercase hex SHA-256 of a file."""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def annotation_id(book_id: str, text: str, anchor: str = "") -> str:
    """Generate deterministic annotation ID matching spec/SCHEMA.md."""
    norm_text = re.sub(r"\s+", " ", (text or "").strip())
    payload = f"{book_id}|{norm_text}|{anchor or ''}".encode("utf-8")
    return "ann_" + hashlib.sha256(payload).hexdigest()[:10]


def generate_book_id() -> str:
    """Generate an 8-char lowercase alphanumeric book ID."""
    return uuid.uuid4().hex[:8]

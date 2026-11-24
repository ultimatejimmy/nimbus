"""Nimbus Calibre sync engine (push books/covers/metadata & pull progress/highlights)."""

import datetime
import hashlib
import html
import os
import re
from typing import Any, Dict, List, Optional, Tuple

from .cloud import RootPrefixedFS
from .cloud.base import CloudNotFoundError
from .hasher import generate_book_id, partial_md5, sha256_file
from .merge import merge_annotations, merge_progress
from .templates import format_book_path

SCHEMA_VERSION = 1
PREFERRED_FORMATS = ("epub", "pdf", "cbz", "mobi", "azw3", "fb2")


def utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sanitize_folder_part(val: str, fallback: str = "Unknown") -> str:
    s = re.sub(r'[\\/:*?"<>|]', "_", str(val or fallback))
    s = re.sub(r"\s+", " ", s).strip()
    return (s or fallback)[:60]


def load_or_init_catalog(fs: RootPrefixedFS, device_id: str) -> Dict[str, Any]:
    try:
        cat = fs.download_json("_sync/catalog.json")
        if isinstance(cat, dict) and isinstance(cat.get("books"), dict):
            return cat
    except CloudNotFoundError:
        pass
    return {
        "version": SCHEMA_VERSION,
        "updated_at": utc_now_iso(),
        "updated_by": device_id,
        "books": {},
    }


def save_catalog(fs: RootPrefixedFS, catalog: Dict[str, Any], device_id: str) -> None:
    catalog["version"] = SCHEMA_VERSION
    catalog["updated_at"] = utc_now_iso()
    catalog["updated_by"] = device_id
    fs.upload_json("_sync/catalog.json", catalog)


def _norm_key(val: Optional[str]) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(val or "").lower())


def resolve_book_id(
    catalog: Dict[str, Any],
    pmd5: str,
    sha: str,
    existing_id: Optional[str] = None,
    book_meta: Optional[Dict[str, Any]] = None,
) -> Optional[str]:
    books = catalog.get("books") or {}
    if existing_id and existing_id in books and not books[existing_id].get("deleted"):
        return existing_id
    for bid, entry in books.items():
        if entry.get("deleted"):
            continue
        hashes = entry.get("hashes") or {}
        if pmd5 and hashes.get("partial_md5") == pmd5:
            return bid
        if sha and hashes.get("sha256") == sha:
            return bid

    if book_meta:
        cuuid = str(book_meta.get("calibre_uuid") or "").strip()
        isbn = _norm_key(book_meta.get("isbn"))
        title_k = _norm_key(book_meta.get("title"))
        authors = book_meta.get("authors") or []
        if isinstance(authors, str):
            authors = [authors]
        author_k = _norm_key(authors[0] if authors else "")

        for bid, entry in books.items():
            if entry.get("deleted"):
                continue
            if cuuid and entry.get("calibre_uuid") == cuuid:
                return bid
            if isbn and len(isbn) >= 10 and _norm_key(entry.get("isbn")) == isbn:
                return bid
            if title_k and author_k:
                e_authors = entry.get("authors") or []
                if isinstance(e_authors, str):
                    e_authors = [e_authors]
                e_author_k = _norm_key(e_authors[0] if e_authors else "")
                if _norm_key(entry.get("title")) == title_k and e_author_k == author_k:
                    return bid
    return None


def compute_cover_etag(cover_bytes: Optional[bytes]) -> Optional[str]:
    """Return a deterministic Calibre v2 cover ETag from cover bytes, or None if empty."""
    if not cover_bytes:
        return None
    digest = hashlib.sha256(cover_bytes).hexdigest()[:12]
    return f"v2_cal_{digest}"


def push_book(
    fs: RootPrefixedFS,
    device_id: str,
    book_meta: Dict[str, Any],
    file_path: str,
    cover_bytes: Optional[bytes] = None,
    catalog: Optional[Dict[str, Any]] = None,
    folder_template: str = "",
    calibre_mi: Any = None,
) -> Tuple[str, Dict[str, Any], Dict[str, Any]]:
    """Upload a book, cover, and metadata.json to Nimbus Cloud and update catalog.json."""
    if catalog is None:
        catalog = load_or_init_catalog(fs, device_id)

    pmd5 = partial_md5(file_path)
    sha = sha256_file(file_path)
    book_id = resolve_book_id(catalog, pmd5, sha, existing_id=book_meta.get("nimbus_id"), book_meta=book_meta) or generate_book_id()

    title = book_meta.get("title") or "Untitled"
    authors = book_meta.get("authors") or ["Unknown Author"]
    if isinstance(authors, str):
        authors = [authors]
    primary_author = authors[0] if authors else "Unknown Author"

    fmt = (book_meta.get("format") or "epub").lower()
    rel_dir = ""
    tpl_filename = None
    if folder_template:
        rel_dir, tpl_filename = format_book_path(folder_template, book_meta, fmt, calibre_mi=calibre_mi)

    prev = catalog.get("books", {}).get(book_id, {})
    filename = book_meta.get("filename") or tpl_filename or f"{sanitize_folder_part(title, 'Book')}.{fmt}"
    folder = prev.get("folder") or f"Books/{sanitize_folder_part(primary_author, 'Unknown')} - {sanitize_folder_part(title, 'Untitled')} [{book_id}]"

    fs.upload_file(f"{folder}/{filename}", file_path)

    has_cover = False
    if cover_bytes:
        fs.upload_bytes(f"{folder}/cover.jpg", cover_bytes, "image/jpeg")
        has_cover = True

    now_iso = utc_now_iso()
    final_rel_dir = rel_dir if folder_template else (book_meta.get("relative_dir") or prev.get("relative_dir") or "")
    entry = {
        "id": book_id,
        "title": title,
        "authors": list(authors),
        "series": book_meta.get("series"),
        "series_index": book_meta.get("series_index"),
        "tags": list(book_meta.get("tags") or []),
        "language": book_meta.get("language"),
        "isbn": book_meta.get("isbn"),
        "calibre_uuid": book_meta.get("calibre_uuid"),
        "metadata_source": "calibre",
        "folder": folder,
        "filename": filename,
        "relative_dir": final_rel_dir,
        "format": fmt,
        "size_bytes": os.path.getsize(file_path),
        "has_cover": has_cover,
        "cover_etag": compute_cover_etag(cover_bytes) if has_cover else None,
        "hashes": {
            "partial_md5": pmd5,
            "sha256": sha,
        },
        "added_at": prev.get("added_at") or now_iso,
        "updated_at": now_iso,
        "deleted": False,
    }
    fs.upload_json(f"{folder}/metadata.json", entry)
    catalog.setdefault("books", {})[book_id] = entry
    save_catalog(fs, catalog, device_id)
    return book_id, entry, catalog


def _resolve_linked_book_id(
    catalog: Dict[str, Any],
    explicit_id: Optional[str] = None,
    calibre_uuid: Optional[str] = None,
    book_meta: Optional[Dict[str, Any]] = None,
) -> Optional[str]:
    return resolve_book_id(
        catalog,
        pmd5="",
        sha="",
        existing_id=explicit_id,
        book_meta={**(book_meta or {}), "calibre_uuid": calibre_uuid or (book_meta or {}).get("calibre_uuid")},
    )


def update_metadata_and_covers(
    fs: RootPrefixedFS,
    device_id: str,
    items: List[Dict[str, Any]],
    catalog: Optional[Dict[str, Any]] = None,
    folder_template: str = "",
) -> Tuple[List[Tuple[Any, str, str, str]], int, Dict[str, Any]]:
    """Update metadata.json, cover.jpg (if ETag changed), and catalog.json for already-linked books."""
    if catalog is None:
        catalog = load_or_init_catalog(fs, device_id)

    updated: List[Tuple[Any, str, str, str]] = []
    skipped = 0

    for item in items:
        cid = item["cid"]
        book_meta = item["meta"]
        cover_bytes = item.get("cover_bytes")
        identifiers = item.get("identifiers") or {}
        id_key = item.get("id_key") or "nimbus"
        acc_tag = (item.get("acc_tag") or "").strip()
        calibre_mi = item.get("calibre_mi")

        book_id = _resolve_linked_book_id(
            catalog,
            explicit_id=identifiers.get(id_key),
            calibre_uuid=book_meta.get("calibre_uuid"),
            book_meta=book_meta,
        )
        if not book_id:
            skipped += 1
            continue

        prev = catalog.get("books", {}).get(book_id, {})
        folder = prev.get("folder")
        if not folder:
            skipped += 1
            continue

        title = book_meta.get("title") or prev.get("title") or "Untitled"
        authors = book_meta.get("authors") or prev.get("authors") or ["Unknown Author"]
        if isinstance(authors, str):
            authors = [authors]
        fmt = (prev.get("format") or book_meta.get("format") or "epub").lower()

        if folder_template:
            rel_dir, _ = format_book_path(folder_template, book_meta, fmt, calibre_mi=calibre_mi)
        else:
            rel_dir = prev.get("relative_dir") or ""

        new_etag = compute_cover_etag(cover_bytes)
        has_cover = bool(cover_bytes)
        if has_cover and (new_etag != prev.get("cover_etag") or not prev.get("has_cover")):
            fs.upload_bytes(f"{folder}/cover.jpg", cover_bytes, "image/jpeg")

        now_iso = utc_now_iso()
        entry = {
            "id": book_id,
            "title": title,
            "authors": list(authors),
            "series": book_meta.get("series"),
            "series_index": book_meta.get("series_index"),
            "tags": list(book_meta.get("tags") or []),
            "language": book_meta.get("language"),
            "isbn": book_meta.get("isbn"),
            "calibre_uuid": book_meta.get("calibre_uuid") or prev.get("calibre_uuid"),
            "metadata_source": "calibre",
            "folder": folder,
            "filename": prev.get("filename"),
            "relative_dir": rel_dir,
            "format": fmt,
            "size_bytes": prev.get("size_bytes"),
            "has_cover": has_cover,
            "cover_etag": new_etag if has_cover else None,
            "hashes": dict(prev.get("hashes") or {}),
            "added_at": prev.get("added_at") or now_iso,
            "updated_at": now_iso,
            "deleted": False,
        }
        fs.upload_json(f"{folder}/metadata.json", entry)
        catalog.setdefault("books", {})[book_id] = entry
        updated.append((cid, id_key, book_id, acc_tag))

    if updated:
        save_catalog(fs, catalog, device_id)
    return updated, skipped, catalog


def pull_merged_state(fs: RootPrefixedFS, device_id: str) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any]]:
    """Fetch catalog + all device shards and return (catalog, merged_progress, merged_annotations)."""
    catalog = load_or_init_catalog(fs, device_id)
    device_entries = [e for e in fs.list_dir("_sync/devices") if e.is_dir]

    prog_shards: List[Dict[str, Any]] = []
    ann_shards: List[Dict[str, Any]] = []

    for dev in device_entries:
        try:
            p = fs.download_json(f"_sync/devices/{dev.name}/progress.json")
            if isinstance(p, dict):
                p.setdefault("device_id", dev.name)
                prog_shards.append(p)
        except CloudNotFoundError:
            pass
        try:
            a = fs.download_json(f"_sync/devices/{dev.name}/annotations.json")
            if isinstance(a, dict):
                a.setdefault("device_id", dev.name)
                ann_shards.append(a)
        except CloudNotFoundError:
            pass

    return catalog, merge_progress(prog_shards), merge_annotations(ann_shards)


def format_highlights_html(annotations: List[Dict[str, Any]]) -> str:
    """Format active annotations as clean HTML for Calibre comments/HTML custom columns."""
    if not annotations:
        return ""
    parts = ["<div class='nimbus-highlights'>"]
    for ann in annotations:
        chapter = html.escape(str(ann.get("chapter") or ""))
        pct = ann.get("percent")
        pct_str = f" ({pct * 100:.1f}%)" if pct is not None else ""
        text = html.escape(str(ann.get("text") or ""))
        note = ann.get("note")
        parts.append("<blockquote>")
        if chapter or pct_str:
            parts.append(f"<p><strong>{chapter}{pct_str}</strong></p>")
        parts.append(f"<p>{text}</p>")
        if note:
            parts.append(f"<p><em>Note: {html.escape(str(note))}</em></p>")
        parts.append("</blockquote>")
    parts.append("</div>")
    return "\n".join(parts)

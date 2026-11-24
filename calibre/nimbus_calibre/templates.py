"""Calibre-style folder and filename template evaluation for Nimbus destinations."""

import re
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_SERIES_TEMPLATE = '{series:\'ifempty($, "")\'}/{series_index:\'ifempty($, "")\'} {title} - {authors}'

FOLDER_TEMPLATE_PRESETS: List[Tuple[str, str]] = [
    ("Series (KOReader Default)", DEFAULT_SERIES_TEMPLATE),
    ("Series / 01 - Title", "{series}/{series_index:0>2s|| - }{title}"),
    ("Author / Series / 01 - Title", "{author_sort}/{series}/{series_index:0>2s|| - }{title}"),
    ("Series Folder Only", "{series}/"),
    ("Author / Series Folder Only", "{author_sort}/{series}/"),
    ("Root / Flat (No Folders)", ""),
]

_TOKEN_RE = re.compile(r"\{([^{}]+)\}")


def sanitize_path_part(val: str, fallback: str = "", max_len: int = 80) -> str:
    s = re.sub(r'[\\/:*?"<>|]', "_", str(val or ""))
    s = re.sub(r"\s+", " ", s).strip().strip(".")
    if not s:
        return fallback
    return s[:max_len].strip()


def _format_series_index(val: Any) -> str:
    if val is None or val == "":
        return ""
    try:
        num = float(val)
    except (TypeError, ValueError):
        return str(val).strip()
    if num.is_integer():
        return str(int(num))
    return f"{num:g}"


def _apply_calibre_spec(raw_val: str, spec: str) -> str:
    """Apply simplified Calibre template format specifier or ifempty($, ...) expression."""
    val = str(raw_val or "").strip()
    m_ifempty = re.match(r"""^'ifempty\(\$\s*,\s*(["'])(.*?)\1\)'$""", spec.strip())
    if m_ifempty:
        return val if val else m_ifempty.group(2)

    fmt_part = spec
    prefix = ""
    suffix = ""
    if "|" in spec:
        parts = spec.split("|")
        fmt_part = parts[0]
        if len(parts) >= 2:
            prefix = parts[1]
        if len(parts) >= 3:
            suffix = parts[2]

    if not val:
        return ""

    fmt_part = fmt_part.strip()
    if fmt_part:
        # Handle common numeric/string zero-padding specs like 0>2s, 0>2d, 05.2f
        m_pad = re.match(r"^(0?)([<>]?)(\d+)([sd])$", fmt_part)
        if m_pad:
            fill_char = m_pad.group(1) or " "
            align = m_pad.group(2) or ">"
            width = int(m_pad.group(3))
            if "." in val and m_pad.group(4) in ("s", "d"):
                # Pad integer part for fractional series indices like 1.5 -> 01.5
                head, tail = val.split(".", 1)
                head = head.rjust(width, fill_char) if align == ">" else head.ljust(width, fill_char)
                val = f"{head}.{tail}"
            else:
                val = val.rjust(width, fill_char) if align == ">" else val.ljust(width, fill_char)
        elif fmt_part.endswith("f"):
            try:
                val = format(float(val), fmt_part)
            except (TypeError, ValueError):
                pass

    return f"{prefix}{val}{suffix}"


def _resolve_field_value(field: str, book_meta: Dict[str, Any]) -> str:
    key = field.strip().lower()
    authors = book_meta.get("authors") or []
    if isinstance(authors, str):
        authors = [a.strip() for a in authors.split(",") if a.strip()]
    primary_author = authors[0] if authors else ""

    if key == "title":
        return str(book_meta.get("title") or "").strip()
    if key in ("author", "primary_author"):
        return str(primary_author).strip()
    if key == "authors":
        return ", ".join(str(a).strip() for a in authors if str(a).strip())
    if key == "author_sort":
        explicit = str(book_meta.get("author_sort") or "").strip()
        if explicit:
            return explicit
        return str(primary_author).strip()
    if key == "series":
        return str(book_meta.get("series") or "").strip()
    if key == "series_index":
        # Only emit series_index if book actually belongs to a series
        if not str(book_meta.get("series") or "").strip():
            return ""
        return _format_series_index(book_meta.get("series_index"))
    if key == "tags":
        tags = book_meta.get("tags") or []
        if isinstance(tags, str):
            return tags.strip()
        return ", ".join(str(t).strip() for t in tags if str(t).strip())
    if key == "language":
        return str(book_meta.get("language") or "").strip()
    if key == "isbn":
        return str(book_meta.get("isbn") or "").strip()
    if key in ("pubyear", "year"):
        pub = str(book_meta.get("pubdate") or book_meta.get("year") or "").strip()
        m_y = re.match(r"(\d{4})", pub)
        return m_y.group(1) if m_y else ""
    return ""


def _eval_with_calibre_formatter(template: str, calibre_mi: Any) -> Optional[str]:
    if calibre_mi is None:
        return None
    try:
        from calibre.ebooks.metadata.book.formatter import SafeFormat
        return SafeFormat().safe_format(template, calibre_mi, "", calibre_mi)
    except Exception:
        return None


def evaluate_template_raw(template: str, book_meta: Dict[str, Any], calibre_mi: Any = None) -> str:
    tpl = str(template or "").strip()
    if not tpl:
        return ""

    # Use Calibre's native SafeFormat when inside Calibre (supports custom columns like {#mycol} and GPM)
    if calibre_mi is not None and ("{#" in tpl or "program:" in tpl):
        native = _eval_with_calibre_formatter(tpl, calibre_mi)
        if native is not None:
            return native

    def _replace(match: re.Match) -> str:
        expr = match.group(1)
        if ":" in expr:
            field, spec = expr.split(":", 1)
        else:
            field, spec = expr, ""
        val = _resolve_field_value(field, book_meta)
        val = sanitize_path_part(val, "") if val else ""
        if spec:
            return _apply_calibre_spec(val, spec)
        return val

    return _TOKEN_RE.sub(_replace, tpl)


def format_book_path(
    template: str,
    book_meta: Dict[str, Any],
    fmt: str,
    calibre_mi: Any = None,
) -> Tuple[str, Optional[str]]:
    """Evaluate a per-destination folder template into (relative_dir, filename_or_none)."""
    tpl = str(template or "").strip().replace("\\", "/")
    if not tpl:
        return "", None

    folder_only = tpl.endswith("/")
    evaluated = evaluate_template_raw(tpl, book_meta, calibre_mi=calibre_mi).replace("\\", "/")

    raw_parts = [p for p in evaluated.split("/") if p.strip()]
    clean_parts = [sanitize_path_part(p, "") for p in raw_parts]
    clean_parts = [p for p in clean_parts if p]

    if folder_only:
        return "/".join(clean_parts), None

    if not clean_parts:
        return "", None

    rel_dir = "/".join(clean_parts[:-1])
    stem = clean_parts[-1]
    ext = (fmt or book_meta.get("format") or "epub").lower().lstrip(".")
    return rel_dir, f"{stem}.{ext}"

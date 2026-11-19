"""Deterministic cross-client merge engine matching spec/SCHEMA.md."""

from typing import Any, Dict, List


def _progress_sort_key(rec: Dict[str, Any], dev_id: str):
    return (
        int(rec.get("updated_at") or 0),
        float(rec.get("percent") or 0.0),
        str(dev_id or ""),
    )


def merge_progress(device_shards: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """Merge progress.json shards across all devices."""
    merged: Dict[str, Dict[str, Any]] = {}
    for shard in device_shards or []:
        dev_id = str(shard.get("device_id") or "")
        for book_id, rec in (shard.get("books") or {}).items():
            if not isinstance(rec, dict):
                continue
            cur = merged.get(book_id)
            if cur is None or _progress_sort_key(rec, dev_id) > _progress_sort_key(cur, cur.get("device_id", "")):
                copy = dict(rec)
                copy.setdefault("book_id", book_id)
                copy["device_id"] = dev_id
                merged[book_id] = copy
    return merged


def _annotation_sort_key(ann: Dict[str, Any], dev_id: str):
    return (
        int(ann.get("updated_at") or 0),
        1 if ann.get("deleted") is True else 0,
        1 if (ann.get("note") or "") != "" else 0,
        str(dev_id or ""),
    )


def merge_annotations(device_shards: List[Dict[str, Any]]) -> Dict[str, Dict[str, List[Dict[str, Any]]]]:
    """Merge annotations.json shards across all devices with tombstone support."""
    by_book: Dict[str, Dict[str, Dict[str, Any]]] = {}
    for shard in device_shards or []:
        dev_id = str(shard.get("device_id") or "")
        for book_id, items in (shard.get("books") or {}).items():
            if not isinstance(items, list):
                continue
            book_map = by_book.setdefault(book_id, {})
            for ann in items:
                if not isinstance(ann, dict) or not ann.get("id"):
                    continue
                ann_id = ann["id"]
                cur = book_map.get(ann_id)
                if cur is None or _annotation_sort_key(ann, dev_id) > _annotation_sort_key(cur, cur.get("_device_id", "")):
                    copy = dict(ann)
                    copy["_device_id"] = dev_id
                    book_map[ann_id] = copy

    result: Dict[str, Dict[str, List[Dict[str, Any]]]] = {}
    for book_id, book_map in by_book.items():
        all_list = []
        active_list = []
        for ann in book_map.values():
            ann.pop("_device_id", None)
            all_list.append(ann)
            if not ann.get("deleted"):
                active_list.append(ann)

        def order_key(a: Dict[str, Any]):
            return (
                float(a.get("percent") or 0.0),
                int(a.get("created_at") or 0),
                str(a.get("id") or ""),
            )

        all_list.sort(key=order_key)
        active_list.sort(key=order_key)
        result[book_id] = {"all": all_list, "active": active_list}
    return result


def merge_sessions(session_shards: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Merge and deduplicate monthly reading session shards."""
    dedup: Dict[tuple, Dict[str, Any]] = {}
    for shard in session_shards or []:
        dev_id = str(shard.get("device_id") or "")
        for s in shard.get("sessions") or []:
            if not isinstance(s, dict) or not s.get("book_id") or s.get("start_time") is None:
                continue
            key = (dev_id, str(s["book_id"]), int(s["start_time"]))
            cur = dedup.get(key)
            s_rank = (int(s.get("duration_sec") or 0), int(s.get("pages_read") or 0))
            c_rank = (int(cur.get("duration_sec") or 0), int(cur.get("pages_read") or 0)) if cur else (-1, -1)
            if cur is None or s_rank > c_rank:
                copy = dict(s)
                copy["device_id"] = dev_id
                dedup[key] = copy

    merged = list(dedup.values())
    merged.sort(key=lambda s: (int(s["start_time"]), str(s["book_id"]), str(s["device_id"])))
    return merged

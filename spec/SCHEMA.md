# Nimbus Cloud Storage & Sync Specification (Schema v1)

This document defines the canonical cloud folder layout, hashing algorithms, JSON schemas, and deterministic cross-client merge rules for **Nimbus** across:
- **KOReader** (`nimbus.koplugin` — Lua)
- **Calibre** (`nimbus-calibre` — Python)
- **Web App / PWA** (`nimbus-web` — TypeScript)

All three clients **must** produce bit-identical hashes and identical merge outputs against the golden test vectors in `spec/fixtures/`.

---

## 1. Cloud Folder Layout

Under the user-configured root directory (default: `/Nimbus`):

```text
/Nimbus/
├── Books/
│   └── <Author> - <Title> [<book_id>]/
│       ├── <Filename>.<ext>                  # Supported: epub, pdf, cbz, mobi, azw3, fb2
│       ├── cover.jpg                         # Optional JPEG thumbnail (max 400px wide)
│       └── metadata.json                     # Per-book metadata snapshot
└── _sync/
    ├── schema_version.json                   # { "version": 1, "min_client": "0.1.0" }
    ├── catalog.json                          # Single-file library index of all books
    └── devices/
        └── <device_slug>/                    # e.g., "Kobo-Libra-2_9f2a"
            ├── device.json                   # Device identity, platform, last_sync_at
            ├── progress.json                 # Map: book_id -> latest position & status
            ├── annotations.json              # Map: book_id -> array of highlights/notes/tombstones
            └── sessions/
                └── YYYY-MM.json              # Monthly reading sessions shard
```

### Write-Ownership Invariant (Zero Write-Write Collisions)
- **Device Shards (`_sync/devices/<device_slug>/...`)**: A client **only** writes to its own `<device_slug>` directory and **reads** from all sibling device directories. Offline devices can never overwrite each other's progress, annotations, or reading sessions.
- **Book Folders (`Books/...`)**: Created/updated when a book is uploaded or its metadata/cover is updated.
- **Catalog (`_sync/catalog.json`)**: Updated via read-merge-write whenever a book is added, edited, or soft-deleted (`deleted: true`).

---

## 2. Book Identity & Hashing (`partial_md5`)

### `book_id`
- An immutable 8-character lowercase alphanumeric identifier (e.g. `a1b2c3d4`, derived from random UUID prefix or content hash prefix).
- Once assigned, `book_id` **never changes**, even if the book's title, author, or folder name is edited in Calibre or the Web App.

### `partial_md5` (KOReader `util.partialMD5` Parity)
To match KOReader's `util.partialMD5` (`frontend/util.lua`) bit-for-bit across Lua, Python, and TypeScript:
1. Open the ebook file in binary read mode.
2. Initialize an MD5 hasher.
3. Read up to `1024` bytes at each of the following byte offsets (in order), feeding any non-empty read into the MD5 hasher and stopping as soon as a seek/read yields EOF (`0` bytes):
   - `0`
   - `1024` (`1024 << 0`)
   - `4096` (`1024 << 2`)
   - `16384` (`1024 << 4`)
   - `65536` (`1024 << 6`)
   - `262144` (`1024 << 8`)
   - `1048576` (`1024 << 10`)
   - `4194304` (`1024 << 12`)
   - `16777216` (`1024 << 14`)
   - `67108864` (`1024 << 16`)
   - `268435456` (`1024 << 18`)
   - `1073741824` (`1024 << 20`)
4. Output lowercase 32-character hexadecimal MD5 digest.

*(Note: In KOReader's LuaJIT `for i = -1, 10`, `bit.lshift(1024, 2 * -1)` wraps 5-bit shift count `-2` to `30`, evaluating `1024 << 30` in 32-bit as `0`. Explicitly starting at offset `0` followed by `1024 << (2 * i)` for `i = 0..10` produces identical behavior in Python, TypeScript, and Lua.)*

### `sha256`
Standard lowercase 64-character hexadecimal SHA-256 digest of the entire ebook file.

### Book Matching Priority Order
1. Local linked `book_id` (stored in client's local link map / Calibre `nimbus:<book_id>` identifier / IndexedDB).
2. Exact match on `hashes.partial_md5`.
3. Exact match on `hashes.sha256`.
4. Fallback candidate match on normalized `(title, primary_author)` or `isbn` (prompting user to confirm link).

---

## 3. Deterministic Merge Rules

### A. Reading Progress (`progress.json`)
Given all device progress maps `{ device_id -> { books: { book_id -> ProgressRecord } } }`:
- For each `book_id`, collect all non-null `ProgressRecord` entries across all devices.
- Select the winner by:
  1. Highest `updated_at` (Unix epoch seconds, integer).
  2. Tie-breaker: highest `percent` (float `0.0 .. 1.0`).
  3. Tie-breaker: lexicographically greatest `device_id`.

#### Cross-Engine Position Resolution
- **KOReader → KOReader**: Prefer exact `xpointer` (reflowable) or `page` (fixed-layout PDF/CBZ).
- **Web → Web**: Prefer exact `cfi` (EPUB) or `page` (PDF/CBZ).
- **KOReader ↔ Web**: Use `percent` to seek to the approximate location, then search nearby text for `text_anchor` (a normalized ~40-character snippet around the reading position) to snap to the exact paragraph.

### B. Annotations & Highlights (`annotations.json`)
Each annotation has a stable `id` (e.g. `ann_<10hex>`). If an annotation is imported without an `id`, compute a deterministic ID:
`ann_` + first 10 hex chars of `sha256(book_id + "|" + normalized_text + "|" + (pos0 || cfi_range || round(percent, 4)))`.

Given all device annotation maps `{ device_id -> { books: { book_id -> Annotation[] } } }`:
- For each `book_id`, group all annotation records across all devices by `annotation.id`.
- For each `id`, select the record with:
  1. Highest `updated_at` (Unix epoch seconds).
  2. Tie-breaker: `deleted == true` wins if `updated_at` is equal (safe tombstone propagation).
  3. Tie-breaker: record with non-empty `note`, then lexicographically greatest `device_id`.
- Tombstone records (`"deleted": true`) are retained in the merged state so deletions propagate to offline devices, and filtered out when displaying active highlights in the UI.
- Sort active annotations for a book by `percent` ascending, then `created_at` ascending, then `id` ascending.

### C. Reading Sessions (`sessions/YYYY-MM.json`)
Given all session records across all devices and months:
- Deduplicate by composite key `(device_id, book_id, start_time)`.
  - If an identical key appears more than once, keep the record with the largest `duration_sec` (then `pages_read`).
- Sort merged sessions by `start_time` ascending, then `book_id` ascending, then `device_id` ascending.

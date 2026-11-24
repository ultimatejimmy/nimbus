import { NimbusWebConfig, RootPrefixedCloudFS } from '../cloud';
import {
  AnnotationRecord,
  AnnotationsShard,
  BookCatalogEntry,
  CatalogFile,
  CloudNotFoundError,
  ProgressRecord,
  ProgressShard,
  ReadingSession,
  SessionsShard,
} from '../cloud/types';
import { db, enqueueSyncOp } from './db';
import { generateBookId, partialMd5Bytes, sha256Hex } from './hasher';
import { MergedBookAnnotations, mergeAnnotations, mergeProgress, mergeSessions } from './merge';

export interface SyncSnapshot {
  catalog: CatalogFile;
  devices: string[];
  progress: Record<string, ProgressRecord>;
  annotations: Record<string, MergedBookAnnotations>;
  sessions: ReadingSession[];
}

export async function loadOrInitCatalog(fs: RootPrefixedCloudFS, deviceId: string): Promise<CatalogFile> {
  try {
    const cat = await fs.downloadJson<CatalogFile>('_sync/catalog.json');
    if (cat && typeof cat.books === 'object') return cat;
  } catch (err) {
    if (!(err instanceof CloudNotFoundError)) throw err;
  }
  return {
    version: 1,
    updated_at: new Date().toISOString(),
    updated_by: deviceId,
    books: {},
  };
}

export async function syncAllFromCloud(fs: RootPrefixedCloudFS, cfg: NimbusWebConfig): Promise<SyncSnapshot> {
  await flushPendingQueue(fs);
  const catalog = await loadOrInitCatalog(fs, cfg.deviceId);
  const devEntries = await fs.listDir('_sync/devices');
  const devices = Array.from(new Set(devEntries.filter((e) => e.is_dir).map((e) => e.name)));

  const progShards: ProgressShard[] = [];
  const annShards: AnnotationsShard[] = [];
  const sessShards: SessionsShard[] = [];

  await Promise.all(
    devices.map(async (dev) => {
      try {
        const p = await fs.downloadJson<ProgressShard>(`_sync/devices/${dev}/progress.json`);
        progShards.push({ ...p, device_id: p.device_id || dev });
      } catch (e) {
        if (!(e instanceof CloudNotFoundError)) console.warn('Progress fetch failed for', dev, e);
      }
      try {
        const a = await fs.downloadJson<AnnotationsShard>(`_sync/devices/${dev}/annotations.json`);
        annShards.push({ ...a, device_id: a.device_id || dev });
      } catch (e) {
        if (!(e instanceof CloudNotFoundError)) console.warn('Annotations fetch failed for', dev, e);
      }
      try {
        const monthFiles = await fs.listDir(`_sync/devices/${dev}/sessions`);
        for (const mf of monthFiles.filter((f) => !f.is_dir && f.name.endsWith('.json'))) {
          try {
            const s = await fs.downloadJson<SessionsShard>(`_sync/devices/${dev}/sessions/${mf.name}`);
            sessShards.push({ ...s, device_id: s.device_id || dev });
          } catch {
            // ignore missing
          }
        }
      } catch {
        // ignore missing sessions dir
      }
    }),
  );

  const progress = mergeProgress(progShards);
  const annotations = mergeAnnotations(annShards);
  const sessions = mergeSessions(sessShards);

  // Persist to IndexedDB
  await db.transaction('rw', [db.catalog, db.progress, db.annotations, db.sessions], async () => {
    await db.catalog.clear();
    await db.catalog.bulkPut(Object.values(catalog.books || {}).filter((b) => !b.deleted));
    await db.progress.clear();
    await db.progress.bulkPut(Object.values(progress));
    await db.annotations.clear();
    await db.annotations.bulkPut(
      Object.entries(annotations).map(([book_id, val]) => ({ book_id, items: val.active })),
    );
    await db.sessions.clear();
    await db.sessions.bulkPut(
      sessions.map((s) => ({ id: `${s.device_id}|${s.book_id}|${s.start_time}`, session: s })),
    );
  });

  return { catalog, devices, progress, annotations, sessions };
}

export async function flushPendingQueue(fs: RootPrefixedCloudFS): Promise<number> {
  const ops = await db.pendingQueue.orderBy('id').toArray();
  let flushed = 0;
  for (const op of ops) {
    try {
      await fs.uploadBytes(op.rel_path, new TextEncoder().encode(op.payload_json), 'application/json; charset=utf-8');
      if (op.id !== undefined) await db.pendingQueue.delete(op.id);
      flushed++;
    } catch {
      break;
    }
  }
  return flushed;
}

export async function pushDeviceProgress(
  fs: RootPrefixedCloudFS | null,
  deviceId: string,
  booksMap: Record<string, ProgressRecord>,
): Promise<void> {
  const relPath = `_sync/devices/${deviceId}/progress.json`;
  const shard: ProgressShard = {
    version: 1,
    device_id: deviceId,
    updated_at: new Date().toISOString(),
    books: booksMap,
  };
  if (!fs) {
    await enqueueSyncOp(db, 'progress', relPath, shard);
    return;
  }
  try {
    await fs.uploadJson(relPath, shard);
  } catch {
    await enqueueSyncOp(db, 'progress', relPath, shard);
  }
}

export async function pushDeviceAnnotations(
  fs: RootPrefixedCloudFS | null,
  deviceId: string,
  booksMap: Record<string, any[]>,
): Promise<void> {
  const relPath = `_sync/devices/${deviceId}/annotations.json`;
  const shard: AnnotationsShard = {
    version: 1,
    device_id: deviceId,
    updated_at: new Date().toISOString(),
    books: booksMap,
  };
  if (!fs) {
    await enqueueSyncOp(db, 'annotations', relPath, shard);
    return;
  }
  try {
    await fs.uploadJson(relPath, shard);
  } catch {
    await enqueueSyncOp(db, 'annotations', relPath, shard);
  }
}

export async function pushDeviceSession(
  fs: RootPrefixedCloudFS | null,
  deviceId: string,
  session: ReadingSession,
): Promise<void> {
  const d = new Date(session.start_time * 1000);
  const month = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
  const relPath = `_sync/devices/${deviceId}/sessions/${month}.json`;

  let existing: SessionsShard = {
    version: 1,
    device_id: deviceId,
    month,
    sessions: [],
  };
  if (fs) {
    try {
      existing = await fs.downloadJson<SessionsShard>(relPath);
    } catch {
      // new month shard
    }
  }
  existing.sessions.push(session);
  if (!fs) {
    await enqueueSyncOp(db, 'sessions', relPath, existing);
    return;
  }
  try {
    await fs.uploadJson(relPath, existing);
  } catch {
    await enqueueSyncOp(db, 'sessions', relPath, existing);
  }
}

function sanitizePart(s: string, fallback: string): string {
  const clean = (s || fallback).replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim();
  return (clean || fallback).slice(0, 60);
}

export async function uploadBookToCloud(
  fs: RootPrefixedCloudFS,
  deviceId: string,
  file: File,
  meta: { title?: string; authors?: string[]; series?: string; coverBlob?: Blob },
): Promise<BookCatalogEntry> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pmd5 = partialMd5Bytes(bytes);
  const sha = await sha256Hex(bytes);
  const ext = (file.name.split('.').pop() || 'epub').toLowerCase() as BookCatalogEntry['format'];
  const bookId = generateBookId();
  const title = meta.title || file.name.replace(/\.[^.]+$/, '');
  const authors = meta.authors?.length ? meta.authors : ['Unknown Author'];
  const folder = `Books/${sanitizePart(authors[0], 'Unknown')} - ${sanitizePart(title, 'Untitled')} [${bookId}]`;

  await fs.uploadBytes(`${folder}/${file.name}`, bytes, file.type || 'application/octet-stream');
  let hasCover = false;
  if (meta.coverBlob) {
    await fs.uploadBytes(`${folder}/cover.jpg`, meta.coverBlob, 'image/jpeg');
    hasCover = true;
  }

  const now = new Date().toISOString();
  const entry: BookCatalogEntry = {
    id: bookId,
    title,
    authors,
    series: meta.series || null,
    tags: [],
    folder,
    filename: file.name,
    format: ['epub', 'pdf', 'cbz', 'mobi', 'azw3', 'fb2'].includes(ext) ? ext : 'epub',
    size_bytes: bytes.byteLength,
    has_cover: hasCover,
    cover_etag: hasCover ? String(Date.now()) : null,
    hashes: { partial_md5: pmd5, sha256: sha },
    added_at: now,
    updated_at: now,
    deleted: false,
  };

  await fs.uploadJson(`${folder}/metadata.json`, entry);
  const catalog = await loadOrInitCatalog(fs, deviceId);
  catalog.books[bookId] = entry;
  catalog.updated_at = now;
  catalog.updated_by = deviceId;
  await fs.uploadJson('_sync/catalog.json', catalog);
  await db.catalog.put(entry);
  return entry;
}

export async function deleteBookFromCloud(
  fs: RootPrefixedCloudFS,
  book: BookCatalogEntry,
  deviceId: string,
): Promise<void> {
  const now = new Date().toISOString();
  const catalog = await loadOrInitCatalog(fs, deviceId);
  const existing = catalog.books[book.id];
  const folder = existing?.folder || book.folder;
  if (existing) {
    existing.deleted = true;
    existing.updated_at = now;
  }
  catalog.updated_at = now;
  catalog.updated_by = deviceId;
  await fs.uploadJson('_sync/catalog.json', catalog);

  if (folder) {
    try {
      await fs.deletePath(folder);
    } catch (err) {
      if (!(err instanceof CloudNotFoundError)) {
        console.warn('Cloud folder delete failed for', book.title, err);
      }
    }
  }

  await db.transaction('rw', [db.catalog, db.books, db.covers], async () => {
    await db.catalog.delete(book.id);
    await db.books.delete(book.id);
    await db.covers.delete(book.id);
  });
}

export async function syncCoversFromCloud(
  fs: RootPrefixedCloudFS,
  books: BookCatalogEntry[],
  onCoverReady?: (bookId: string, blob: Blob) => void,
  concurrency = 4,
): Promise<void> {
  const queue = books.filter((b) => b.has_cover && !b.deleted);
  if (queue.length === 0) return;

  let idx = 0;
  const worker = async () => {
    while (idx < queue.length) {
      const book = queue[idx++];
      try {
        const cached = await db.covers.get(book.id);
        const targetEtag = book.cover_etag || '';
        if (cached && (!targetEtag || cached.etag === targetEtag)) {
          onCoverReady?.(book.id, cached.data);
          continue;
        }
        const bytes = await fs.downloadBytes(`${book.folder}/cover.jpg`);
        const blob = new Blob([bytes.slice().buffer], { type: 'image/jpeg' });
        await db.covers.put({ book_id: book.id, etag: targetEtag, data: blob });
        onCoverReady?.(book.id, blob);
      } catch (err) {
        if (!(err instanceof CloudNotFoundError)) {
          console.warn('Cover download failed for', book.title, err);
        }
      }
    }
  };

  await Promise.all(Array.from({ length: Math.min(concurrency, queue.length) }, () => worker()));
}

function normKey(val?: string | null): string {
  return String(val || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

function normalizeTitleKey(raw?: string | null): string {
  let s = String(raw || '')
    .replace(/\([^)]*\)/g, ' ')
    .replace(/\[[^\]]*\]/g, ' ')
    .replace(/:.*$/, '')
    .trim()
    .toLowerCase();
  s = s.replace(/,\s*(the|a|an)\s*$/i, '').replace(/^(the|a|an)\s+/i, '');
  return s.replace(/[^a-z0-9]+/g, '');
}

function normalizeAuthorKey(raw?: string | null): string {
  const s = String(raw || '').trim().toLowerCase();
  if (!s || s === 'unknown' || s === 'unknown author') return '';
  const tokens = s
    .replace(/[^a-z0-9\s]+/g, ' ')
    .split(/\s+/)
    .filter((w) => w && w !== 'sir' && w !== 'dr' && w !== 'mr' && w !== 'mrs' && w !== 'ms');
  if (tokens.length === 0) return '';
  tokens.sort();
  return tokens.join('');
}

function primaryAuthor(book: BookCatalogEntry): string {
  let raw = '';
  if (Array.isArray(book.authors) && book.authors.length > 0) raw = String(book.authors[0] || '');
  else if (typeof (book as any).authors === 'string') raw = String((book as any).authors);
  return raw.split(/\s*(?:&|;|\band\b)\s*/i)[0].trim();
}

export function findDuplicateGroups(books: BookCatalogEntry[]): BookCatalogEntry[][] {
  const active = books.filter((b) => !b.deleted);
  if (active.length < 2) return [];

  const parent = active.map((_, i) => i);
  const find = (i: number): number => {
    while (parent[i] !== i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  };
  const union = (a: number, b: number) => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  const seen = new Map<string, number>();
  const register = (key: string, idx: number) => {
    if (!key) return;
    const prev = seen.get(key);
    if (prev !== undefined) union(prev, idx);
    else seen.set(key, idx);
  };

  const byTitle = new Map<string, number[]>();

  active.forEach((b, i) => {
    if (b.hashes?.sha256) register(`sha:${b.hashes.sha256}`, i);
    if (b.hashes?.partial_md5) register(`pmd5:${b.hashes.partial_md5}`, i);
    const isbn = normKey(b.isbn);
    if (isbn.length >= 10) register(`isbn:${isbn}`, i);
    if (b.calibre_uuid) register(`cuuid:${b.calibre_uuid}`, i);

    const t = normalizeTitleKey(b.title);
    const a = normalizeAuthorKey(primaryAuthor(b));
    if (t && a) {
      register(`ta:${t}|${a}`, i);
    }
    if (t && t.length >= 10) {
      const list = byTitle.get(t) || [];
      list.push(i);
      byTitle.set(t, list);
    }
  });

  // Match an unknown-author entry against another entry with the exact same normalized title
  for (const indices of byTitle.values()) {
    if (indices.length < 2) continue;
    const hasUnknown = indices.some((idx) => !normalizeAuthorKey(primaryAuthor(active[idx])));
    if (hasUnknown) {
      for (let k = 1; k < indices.length; k++) {
        union(indices[0], indices[k]);
      }
    }
  }

  const buckets = new Map<number, BookCatalogEntry[]>();
  active.forEach((b, i) => {
    const root = find(i);
    const list = buckets.get(root) || [];
    list.push(b);
    buckets.set(root, list);
  });

  return Array.from(buckets.values()).filter((g) => g.length >= 2);
}

function scoreBookForKeep(book: BookCatalogEntry): number {
  let score = 0;
  const etag = String(book.cover_etag || '');
  if (etag.startsWith('v2_cal_')) score += 1000;
  else if (etag.startsWith('v2_')) score += 500;
  if (book.has_cover) score += 200;
  if ((book as any).metadata_source === 'calibre') score += 100;
  if (book.hashes?.sha256) score += 20;
  if (book.series) score += 10;
  return score;
}

export async function mergeDuplicateGroups(
  fs: RootPrefixedCloudFS,
  cfg: NimbusWebConfig,
  groups: BookCatalogEntry[][],
  preferredKeepIds?: Record<string, string>,
): Promise<{ mergedGroups: number; removedBooks: number }> {
  if (!groups.length) return { mergedGroups: 0, removedBooks: 0 };

  const now = new Date().toISOString();
  const catalog = await loadOrInitCatalog(fs, cfg.deviceId);
  const remap = new Map<string, string>();
  const dupFoldersToDelete: string[] = [];
  const dupIds: string[] = [];

  for (const group of groups) {
    const live = group
      .map((g) => catalog.books[g.id] || g)
      .filter((b) => b && !b.deleted);
    if (live.length < 2) continue;

    const explicitKeepId = preferredKeepIds?.[group[0].id];
    live.sort((a, b) => {
      if (explicitKeepId) {
        if (a.id === explicitKeepId) return -1;
        if (b.id === explicitKeepId) return 1;
      }
      const sa = scoreBookForKeep(a);
      const sb = scoreBookForKeep(b);
      if (sa !== sb) return sb - sa;
      return String(a.added_at || '9999').localeCompare(String(b.added_at || '9999'));
    });

    const keep = live[0];
    const dups = live.slice(1);
    for (const dup of dups) {
      remap.set(dup.id, keep.id);
      dupIds.push(dup.id);
      if (!keep.hashes) keep.hashes = { partial_md5: '', sha256: '' };
      if (!keep.hashes.sha256 && dup.hashes?.sha256) keep.hashes.sha256 = dup.hashes.sha256;
      if (!keep.hashes.partial_md5 && dup.hashes?.partial_md5) keep.hashes.partial_md5 = dup.hashes.partial_md5;
      if (!keep.isbn && dup.isbn) keep.isbn = dup.isbn;
      if (!keep.calibre_uuid && dup.calibre_uuid) keep.calibre_uuid = dup.calibre_uuid;
      if (!keep.series && dup.series) {
        keep.series = dup.series;
        keep.series_index = keep.series_index ?? dup.series_index;
      }
      if (!keep.relative_dir && dup.relative_dir) keep.relative_dir = dup.relative_dir;
      if (!keep.has_cover && dup.has_cover) {
        keep.has_cover = true;
        keep.cover_etag = dup.cover_etag;
      }
      if (dup.added_at && (!keep.added_at || dup.added_at < keep.added_at)) {
        keep.added_at = dup.added_at;
      }
      dup.deleted = true;
      dup.updated_at = now;
      catalog.books[dup.id] = dup;
      if (dup.folder && dup.folder !== keep.folder) {
        dupFoldersToDelete.push(dup.folder);
      }
    }
    keep.updated_at = now;
    catalog.books[keep.id] = keep;
    if (keep.folder) {
      try {
        await fs.uploadJson(`${keep.folder}/metadata.json`, keep);
      } catch {
        // non-fatal
      }
    }
  }

  if (remap.size === 0) return { mergedGroups: 0, removedBooks: 0 };

  // Migrate progress, annotations, and sessions across all device shards
  try {
    const devEntries = await fs.listDir('_sync/devices');
    const devices = Array.from(new Set(devEntries.filter((e) => e.is_dir).map((e) => e.name)));
    for (const dev of devices) {
      try {
        const p = await fs.downloadJson<ProgressShard>(`_sync/devices/${dev}/progress.json`);
        if (p?.books) {
          let changed = false;
          for (const [dupId, keepId] of remap.entries()) {
            const dupRec = p.books[dupId];
            if (!dupRec) continue;
            const keepRec = p.books[keepId];
            const dupTs = dupRec.updated_at || 0;
            const keepTs = keepRec?.updated_at || 0;
            if (!keepRec || dupTs > keepTs || (dupTs === keepTs && (dupRec.percent || 0) > (keepRec.percent || 0))) {
              p.books[keepId] = { ...dupRec, book_id: keepId };
            }
            delete p.books[dupId];
            changed = true;
          }
          if (changed) {
            p.updated_at = now;
            await fs.uploadJson(`_sync/devices/${dev}/progress.json`, p);
          }
        }
      } catch {
        // ignore missing shard
      }

      try {
        const a = await fs.downloadJson<AnnotationsShard>(`_sync/devices/${dev}/annotations.json`);
        if (a?.books) {
          let changed = false;
          for (const [dupId, keepId] of remap.entries()) {
            const dupAnns = a.books[dupId];
            if (!dupAnns) continue;
            const existing = a.books[keepId] || [];
            const byId = new Map<string, AnnotationRecord>();
            for (const item of existing) byId.set(item.id, item);
            for (const item of dupAnns) {
              const moved = { ...item, book_id: keepId };
              const prev = byId.get(moved.id);
              if (!prev || (moved.updated_at || 0) > (prev.updated_at || 0)) {
                byId.set(moved.id, moved);
              }
            }
            a.books[keepId] = Array.from(byId.values());
            delete a.books[dupId];
            changed = true;
          }
          if (changed) {
            a.updated_at = now;
            await fs.uploadJson(`_sync/devices/${dev}/annotations.json`, a);
          }
        }
      } catch {
        // ignore missing shard
      }

      try {
        const monthFiles = await fs.listDir(`_sync/devices/${dev}/sessions`);
        for (const mf of monthFiles.filter((f) => !f.is_dir && f.name.endsWith('.json'))) {
          try {
            const s = await fs.downloadJson<SessionsShard>(`_sync/devices/${dev}/sessions/${mf.name}`);
            if (Array.isArray(s?.sessions)) {
              let changed = false;
              for (const rec of s.sessions) {
                const keepId = remap.get(rec.book_id);
                if (keepId) {
                  rec.book_id = keepId;
                  changed = true;
                }
              }
              if (changed) {
                await fs.uploadJson(`_sync/devices/${dev}/sessions/${mf.name}`, s);
              }
            }
          } catch {
            // ignore
          }
        }
      } catch {
        // ignore
      }
    }
  } catch {
    // ignore if _sync/devices missing
  }

  catalog.updated_at = now;
  catalog.updated_by = cfg.deviceId;
  await fs.uploadJson('_sync/catalog.json', catalog);

  for (const folder of dupFoldersToDelete) {
    try {
      await fs.deletePath(folder);
    } catch {
      // non-fatal
    }
  }

  await db.transaction('rw', [db.catalog, db.books, db.covers, db.progress, db.annotations], async () => {
    for (const id of dupIds) {
      await db.catalog.delete(id);
      await db.books.delete(id);
      await db.covers.delete(id);
      await db.progress.delete(id);
      await db.annotations.delete(id);
    }
  });

  return { mergedGroups: groups.length, removedBooks: dupIds.length };
}

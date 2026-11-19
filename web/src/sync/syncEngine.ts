import { NimbusWebConfig, RootPrefixedCloudFS } from '../cloud';
import {
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
  const devices = devEntries.filter((e) => e.is_dir).map((e) => e.name);

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

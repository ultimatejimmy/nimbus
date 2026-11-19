import Dexie, { Table } from 'dexie';
import {
  AnnotationRecord,
  BookCatalogEntry,
  ProgressRecord,
  ReadingSession,
} from '../cloud/types';

export interface OfflineBookBlob {
  book_id: string;
  filename: string;
  format: string;
  data: Blob;
  cached_at: number;
}

export interface OfflineCoverBlob {
  book_id: string;
  etag: string;
  data: Blob;
}

export interface PendingSyncOp {
  id?: number;
  kind: 'progress' | 'annotations' | 'sessions';
  rel_path: string;
  payload_json: string;
  created_at: number;
}

export class NimbusDB extends Dexie {
  catalog!: Table<BookCatalogEntry, string>;
  books!: Table<OfflineBookBlob, string>;
  covers!: Table<OfflineCoverBlob, string>;
  progress!: Table<ProgressRecord, string>;
  annotations!: Table<{ book_id: string; items: AnnotationRecord[] }, string>;
  sessions!: Table<{ id: string; session: ReadingSession }, string>;
  pendingQueue!: Table<PendingSyncOp, number>;

  constructor() {
    super('NimbusLibraryDB');
    this.version(1).stores({
      catalog: 'id, title, updated_at',
      books: 'book_id, cached_at',
      covers: 'book_id',
      progress: 'book_id, updated_at',
      annotations: 'book_id',
      sessions: 'id',
      pendingQueue: '++id, kind, created_at',
    });
  }
}

export const db = new NimbusDB();

export async function enqueueSyncOp(
  targetDb: NimbusDB,
  kind: PendingSyncOp['kind'],
  relPath: string,
  payload: unknown,
): Promise<number> {
  return targetDb.pendingQueue.add({
    kind,
    rel_path: relPath,
    payload_json: JSON.stringify(payload),
    created_at: Date.now(),
  });
}

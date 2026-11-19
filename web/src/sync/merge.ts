import {
  AnnotationRecord,
  AnnotationsShard,
  ProgressRecord,
  ProgressShard,
  ReadingSession,
  SessionsShard,
} from '../cloud/types';

function isBetterProgress(cand: ProgressRecord, cur: ProgressRecord | undefined, candDev: string): boolean {
  if (!cur) return true;
  const cTs = Number(cand.updated_at || 0);
  const curTs = Number(cur.updated_at || 0);
  if (cTs !== curTs) return cTs > curTs;
  const cPct = Number(cand.percent || 0);
  const curPct = Number(cur.percent || 0);
  if (cPct !== curPct) return cPct > curPct;
  return candDev > (cur.device_id || '');
}

export function mergeProgress(shards: ProgressShard[]): Record<string, ProgressRecord> {
  const merged: Record<string, ProgressRecord> = {};
  for (const shard of shards || []) {
    const devId = shard.device_id || '';
    for (const [bookId, rec] of Object.entries(shard.books || {})) {
      if (!rec) continue;
      if (isBetterProgress(rec, merged[bookId], devId)) {
        merged[bookId] = {
          ...rec,
          book_id: rec.book_id || bookId,
          device_id: devId,
        };
      }
    }
  }
  return merged;
}

type AnnotatedWithDev = AnnotationRecord & { _device_id?: string };

function isBetterAnnotation(cand: AnnotationRecord, cur: AnnotatedWithDev | undefined, candDev: string): boolean {
  if (!cur) return true;
  const cTs = Number(cand.updated_at || 0);
  const curTs = Number(cur.updated_at || 0);
  if (cTs !== curTs) return cTs > curTs;
  const cDel = cand.deleted === true ? 1 : 0;
  const curDel = cur.deleted === true ? 1 : 0;
  if (cDel !== curDel) return cDel > curDel;
  const cNote = cand.note ? 1 : 0;
  const curNote = cur.note ? 1 : 0;
  if (cNote !== curNote) return cNote > curNote;
  return candDev > (cur._device_id || '');
}

export interface MergedBookAnnotations {
  all: AnnotationRecord[];
  active: AnnotationRecord[];
}

export function mergeAnnotations(shards: AnnotationsShard[]): Record<string, MergedBookAnnotations> {
  const byBook = new Map<string, Map<string, AnnotatedWithDev>>();
  for (const shard of shards || []) {
    const devId = shard.device_id || '';
    for (const [bookId, list] of Object.entries(shard.books || {})) {
      if (!Array.isArray(list)) continue;
      let bookMap = byBook.get(bookId);
      if (!bookMap) {
        bookMap = new Map();
        byBook.set(bookId, bookMap);
      }
      for (const ann of list) {
        if (!ann?.id) continue;
        const cur = bookMap.get(ann.id);
        if (isBetterAnnotation(ann, cur, devId)) {
          bookMap.set(ann.id, { ...ann, _device_id: devId });
        }
      }
    }
  }

  const out: Record<string, MergedBookAnnotations> = {};
  for (const [bookId, bookMap] of byBook.entries()) {
    const all: AnnotationRecord[] = [];
    const active: AnnotationRecord[] = [];
    for (const item of bookMap.values()) {
      const { _device_id: _, ...clean } = item;
      all.push(clean);
      if (!clean.deleted) active.push(clean);
    }
    const sortFn = (a: AnnotationRecord, b: AnnotationRecord) => {
      const pa = Number(a.percent || 0);
      const pb = Number(b.percent || 0);
      if (pa !== pb) return pa - pb;
      if (a.created_at !== b.created_at) return a.created_at - b.created_at;
      return a.id.localeCompare(b.id);
    };
    all.sort(sortFn);
    active.sort(sortFn);
    out[bookId] = { all, active };
  }
  return out;
}

export function mergeSessions(shards: SessionsShard[]): ReadingSession[] {
  const dedup = new Map<string, ReadingSession>();
  for (const shard of shards || []) {
    const devId = shard.device_id || '';
    for (const s of shard.sessions || []) {
      if (!s?.book_id || s.start_time == null) continue;
      const key = `${devId}|${s.book_id}|${s.start_time}`;
      const cur = dedup.get(key);
      const replace =
        !cur ||
        Number(s.duration_sec || 0) > Number(cur.duration_sec || 0) ||
        (Number(s.duration_sec || 0) === Number(cur.duration_sec || 0) &&
          Number(s.pages_read || 0) > Number(cur.pages_read || 0));
      if (replace) {
        dedup.set(key, { ...s, device_id: devId });
      }
    }
  }
  return Array.from(dedup.values()).sort((a, b) => {
    if (a.start_time !== b.start_time) return a.start_time - b.start_time;
    const bc = a.book_id.localeCompare(b.book_id);
    if (bc !== 0) return bc;
    return (a.device_id || '').localeCompare(b.device_id || '');
  });
}

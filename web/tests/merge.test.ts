import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { mergeAnnotations, mergeProgress, mergeSessions } from '../src/sync/merge';

const FIXTURES = path.resolve(__dirname, '../../spec/fixtures');
const readJson = (name: string) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), 'utf-8'));

describe('merge engine against spec/fixtures', () => {
  const expected = readJson('expected_merged.json');

  it('merges progress deterministically', () => {
    const a = readJson('device_a_progress.json');
    const b = readJson('device_b_progress.json');
    const merged = mergeProgress([a, b]);
    for (const [bookId, exp] of Object.entries<any>(expected.progress)) {
      expect(merged[bookId]).toBeDefined();
      expect(merged[bookId].device_id).toBe(exp.device_id);
      expect(merged[bookId].percent).toBe(exp.percent);
      expect(merged[bookId].updated_at).toBe(exp.updated_at);
    }
  });

  it('merges annotations with edits and tombstones', () => {
    const a = readJson('device_a_annotations.json');
    const b = readJson('device_b_annotations.json');
    const merged = mergeAnnotations([a, b]);
    const res = merged['a1b2c3d4'];
    expect(res).toBeDefined();
    expect(res.active.map((x) => x.id).sort()).toEqual(expected.annotations.a1b2c3d4.active_ids);
    expect(res.all.filter((x) => x.deleted).map((x) => x.id).sort()).toEqual(
      expected.annotations.a1b2c3d4.tombstone_ids,
    );
    const ann2 = res.active.find((x) => x.id === 'ann_002');
    expect(ann2?.note).toBe(expected.annotations.a1b2c3d4.ann_002_note);
    expect(ann2?.color).toBe(expected.annotations.a1b2c3d4.ann_002_color);
  });

  it('merges and deduplicates reading sessions', () => {
    const a = readJson('device_a_sessions.json');
    const b = readJson('device_b_sessions.json');
    const merged = mergeSessions([a, b]);
    expect(merged).toHaveLength(expected.sessions.length);
    expected.sessions.forEach((exp: any, idx: number) => {
      expect(merged[idx].device_id).toBe(exp.device_id);
      expect(merged[idx].book_id).toBe(exp.book_id);
      expect(merged[idx].start_time).toBe(exp.start_time);
      expect(merged[idx].duration_sec).toBe(exp.duration_sec);
    });
  });

  it('ignores non-array sessions such as Lua empty object {}', () => {
    const merged = mergeSessions([
      { version: 1, device_id: 'Kobo', updated_at: '', sessions: {} as any },
    ]);
    expect(merged).toEqual([]);
  });
});

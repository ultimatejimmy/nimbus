import 'fake-indexeddb/auto';
import { describe, expect, it } from 'vitest';
import { enqueueSyncOp, NimbusDB } from '../src/sync/db';

describe('Dexie offline sync queue', () => {
  it('queues pending sync ops in IndexedDB', async () => {
    const testDb = new NimbusDB();
    await testDb.pendingQueue.clear();
    await enqueueSyncOp(testDb, 'progress', '_sync/devices/Web_1234/progress.json', { version: 1 });
    const ops = await testDb.pendingQueue.toArray();
    expect(ops).toHaveLength(1);
    expect(ops[0].kind).toBe('progress');
    expect(JSON.parse(ops[0].payload_json)).toEqual({ version: 1 });
    await testDb.close();
  });
});

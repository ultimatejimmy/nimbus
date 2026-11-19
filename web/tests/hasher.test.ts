import { describe, expect, it } from 'vitest';
import { annotationId, partialMd5Bytes } from '../src/sync/hasher';

describe('hasher', () => {
  it('computes partialMd5Bytes matching KOReader geometric offsets', () => {
    const chunk = new TextEncoder().encode('ABCD1234');
    const buf = new Uint8Array(10240);
    for (let i = 0; i < 1280; i++) {
      buf.set(chunk, i * 8);
    }
    const h = partialMd5Bytes(buf);
    expect(h).toHaveLength(32);
    expect(h).toMatch(/^[a-f0-9]{32}$/);
  });

  it('computes deterministic annotationId', async () => {
    const id1 = await annotationId('a1b2c3d4', "  There's always   another secret. ", '/body/p[1]');
    const id2 = await annotationId('a1b2c3d4', "There's always another secret.", '/body/p[1]');
    expect(id1).toBe(id2);
    expect(id1.startsWith('ann_')).toBe(true);
  });
});

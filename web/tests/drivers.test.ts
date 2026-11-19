import { afterEach, describe, expect, it, vi } from 'vitest';
import { DropboxWebDriver } from '../src/cloud/dropbox';
import { GDriveWebDriver } from '../src/cloud/gdrive';
import { WebTokenManager } from '../src/cloud/oauth';
import { OneDriveWebDriver } from '../src/cloud/onedrive';
import { WebDAVWebDriver } from '../src/cloud/webdav';

describe('CloudFS web drivers (mocked fetch)', () => {
  const tm = new WebTokenManager('gdrive', {
    access_token: 'tok_123',
    expires_at: Math.floor(Date.now() / 1000) + 3600,
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('GDriveWebDriver testConnection and downloadBytes', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (url.includes('/about')) {
          return new Response(JSON.stringify({ user: { emailAddress: 'web@example.com' } }), { status: 200 });
        }
        if (url.includes('files?')) {
          return new Response(JSON.stringify({ files: [{ id: 'f1', name: 'catalog.json' }] }), { status: 200 });
        }
        return new Response('{"version":1}', { status: 200 });
      }),
    );

    const drv = new GDriveWebDriver(tm);
    expect(await drv.testConnection()).toBe('web@example.com');
    const bytes = await drv.downloadBytes('Nimbus/_sync/catalog.json');
    expect(new TextDecoder().decode(bytes)).toBe('{"version":1}');
  });

  it('OneDriveWebDriver listDir', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            value: [
              { id: 'd1', name: 'Books', folder: { childCount: 1 } },
              { id: 'f1', name: 'catalog.json', size: 12 },
            ],
          }),
          { status: 200 },
        ),
      ),
    );
    const drv = new OneDriveWebDriver(tm);
    const entries = await drv.listDir('Nimbus/_sync');
    expect(entries).toHaveLength(2);
    expect(entries[0].is_dir).toBe(true);
    expect(entries[1].is_dir).toBe(false);
  });

  it('DropboxWebDriver uploadBytes and downloadBytes', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"ok":true}', { status: 200 })));
    const drv = new DropboxWebDriver(tm);
    await drv.uploadBytes('Nimbus/_sync/progress.json', new TextEncoder().encode('{"ok":true}'));
    const bytes = await drv.downloadBytes('Nimbus/_sync/progress.json');
    expect(new TextDecoder().decode(bytes)).toBe('{"ok":true}');
  });

  it('WebDAVWebDriver testConnection', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('', { status: 207 })));
    const drv = new WebDAVWebDriver({ url: 'https://example.com/dav', username: 'u', password: 'p' });
    expect(await drv.testConnection()).toBe('https://example.com/dav');
  });
});

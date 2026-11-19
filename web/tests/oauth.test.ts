import { afterEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_RELAY_URL, pollTokenOnce, requestDeviceCode } from '../src/cloud/oauth';

describe('Web OAuth client', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('requests Google Drive device code directly from Google with form-urlencoded', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          device_code: 'dev-123',
          user_code: 'ABCD-EFGH',
          verification_url: 'https://www.google.com/device',
          interval: 5,
          expires_in: 1800,
        }),
        { status: 200 },
      ),
    );
    vi.stubGlobal('fetch', fetchMock);

    const info = await requestDeviceCode('gdrive');
    expect(info.device_code).toBe('dev-123');
    expect(info.user_code).toBe('ABCD-EFGH');
    expect(info.verification_url).toBe('https://www.google.com/device');

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://oauth2.googleapis.com/device/code');
    expect(init.headers['Content-Type']).toBe('application/x-www-form-urlencoded');
    expect(init.body).toContain('client_id=');
    expect(init.body).toContain('scope=');
  });

  it('polls Google Drive tokens via relay worker', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: 'authorization_pending' }), { status: 400 }),
    );
    vi.stubGlobal('fetch', fetchMock);

    const res = await pollTokenOnce('gdrive', 'dev-123');
    expect(res).toBeNull();
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(`${DEFAULT_RELAY_URL}/api/oauth/gdrive/poll`);
    expect(init.headers['Content-Type']).toBe('application/json');
  });

  it('requests and polls OneDrive directly against Microsoft consumer endpoint', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            device_code: 'ms-dev',
            user_code: 'MS1234',
            verification_uri: 'https://microsoft.com/devicelogin',
            interval: 5,
            expires_in: 900,
          }),
          { status: 200 },
        ),
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            access_token: 'tok-abc',
            refresh_token: 'ref-xyz',
            expires_in: 3600,
          }),
          { status: 200 },
        ),
      );
    vi.stubGlobal('fetch', fetchMock);

    const info = await requestDeviceCode('onedrive');
    expect(info.user_code).toBe('MS1234');
    expect(fetchMock.mock.calls[0][0]).toBe(
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode',
    );

    const tok = await pollTokenOnce('onedrive', 'ms-dev');
    expect(tok?.access_token).toBe('tok-abc');
    expect(fetchMock.mock.calls[1][0]).toBe(
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/token',
    );
  });
});

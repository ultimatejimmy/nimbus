import { OAuthTokens } from './types';

export const DEFAULT_RELAY_URL = 'https://backup.ultimatejimmy.workers.dev';

export const OAUTH_CONFIG = {
  gdrive: {
    name: 'Google Drive',
    clientId: '444320595925-2mlkslggov1f25qv45th2tq3dl466f9u.apps.googleusercontent.com',
    scope: 'https://www.googleapis.com/auth/drive.file',
    initUrl: `${DEFAULT_RELAY_URL}/api/oauth/gdrive/init`,
    pollUrl: `${DEFAULT_RELAY_URL}/api/oauth/gdrive/poll`,
    refreshUrl: `${DEFAULT_RELAY_URL}/api/oauth/gdrive/refresh`,
  },
  onedrive: {
    name: 'Microsoft OneDrive',
    clientId: '982359c5-d74b-408c-8ff0-7d43c678195e',
    scope: 'Files.ReadWrite offline_access',
    initUrl: `${DEFAULT_RELAY_URL}/api/oauth/onedrive/init`,
    pollUrl: `${DEFAULT_RELAY_URL}/api/oauth/onedrive/poll`,
    refreshUrl: `${DEFAULT_RELAY_URL}/api/oauth/onedrive/refresh`,
  },
  dropbox: {
    name: 'Dropbox',
    clientId: 'khboin1ohr74q7y',
    scope: '',
    initUrl: `${DEFAULT_RELAY_URL}/api/oauth/dropbox/init`,
    pollUrl: `${DEFAULT_RELAY_URL}/api/oauth/dropbox/poll`,
    refreshUrl: `${DEFAULT_RELAY_URL}/api/oauth/dropbox/refresh`,
  },
} as const;

export type OAuthProvider = keyof typeof OAUTH_CONFIG;

export interface DeviceCodeInfo {
  device_code: string;
  user_code: string;
  verification_url: string;
  interval: number;
  expires_in: number;
}

export async function requestDeviceCode(provider: OAuthProvider): Promise<DeviceCodeInfo> {
  const cfg = OAUTH_CONFIG[provider];
  const resp = await fetch(cfg.initUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: cfg.clientId, scope: cfg.scope }),
  });
  const data = await resp.json();
  if (!resp.ok || !data.device_code) {
    throw new Error(data.error_description || data.error || `OAuth init failed (${resp.status})`);
  }
  const verifyUrl =
    data.verification_uri_complete ||
    data.verification_url ||
    data.verification_uri ||
    (provider === 'dropbox' ? `${DEFAULT_RELAY_URL}/link?session=${encodeURIComponent(data.user_code)}` : '');
  return {
    device_code: data.device_code,
    user_code: data.user_code,
    verification_url: verifyUrl,
    interval: Number(data.interval) || 5,
    expires_in: Number(data.expires_in) || 600,
  };
}

export async function pollTokenOnce(provider: OAuthProvider, deviceCode: string): Promise<OAuthTokens | null> {
  const cfg = OAUTH_CONFIG[provider];
  const resp = await fetch(cfg.pollUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device_code: deviceCode, client_id: cfg.clientId }),
  });
  const data = await resp.json();
  if (resp.ok && data.access_token) {
    return {
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      token_type: data.token_type || 'Bearer',
      expires_at: Math.floor(Date.now() / 1000) + (Number(data.expires_in) || 3600),
    };
  }
  if (data.error === 'authorization_pending' || data.error === 'slow_down') {
    return null;
  }
  throw new Error(data.error_description || data.error || `OAuth poll failed (${resp.status})`);
}

export async function refreshAccessToken(provider: OAuthProvider, tokens: OAuthTokens): Promise<OAuthTokens> {
  const cfg = OAUTH_CONFIG[provider];
  if (!tokens.refresh_token) {
    throw new Error('Missing refresh_token; please sign in again.');
  }
  const resp = await fetch(cfg.refreshUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: tokens.refresh_token, client_id: cfg.clientId }),
  });
  const data = await resp.json();
  if (!resp.ok || !data.access_token) {
    throw new Error(data.error_description || data.error || `Token refresh failed (${resp.status})`);
  }
  return {
    ...tokens,
    access_token: data.access_token,
    refresh_token: data.refresh_token || tokens.refresh_token,
    expires_at: Math.floor(Date.now() / 1000) + (Number(data.expires_in) || 3600),
  };
}

export class WebTokenManager {
  constructor(
    private provider: OAuthProvider,
    private tokens: OAuthTokens,
    private onSave?: (tokens: OAuthTokens) => void,
  ) {}

  async getAccessToken(): Promise<string> {
    if (!this.tokens?.access_token) {
      throw new Error(`Not signed in to ${this.provider}`);
    }
    const now = Math.floor(Date.now() / 1000);
    if (this.tokens.expires_at && now >= this.tokens.expires_at - 120) {
      this.tokens = await refreshAccessToken(this.provider, this.tokens);
      this.onSave?.(this.tokens);
    }
    return this.tokens.access_token;
  }
}

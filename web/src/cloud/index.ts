import { DropboxWebDriver } from './dropbox';
import { GDriveWebDriver } from './gdrive';
import { OAuthProvider, WebTokenManager } from './oauth';
import { OneDriveWebDriver } from './onedrive';
import { CloudDriver, CloudEntry, CloudProviderId, OAuthTokens, WebDAVCreds } from './types';
import { WebDAVWebDriver } from './webdav';

function normPath(p: string): string {
  return (p || '').replace(/\\/g, '/').replace(/^\/+|\/+$/g, '').replace(/\/+/g, '/');
}

export class RootPrefixedCloudFS {
  private root: string;

  constructor(private driver: CloudDriver, remoteRoot = 'Nimbus') {
    this.root = normPath(remoteRoot);
  }

  private full(relPath: string): string {
    const rel = normPath(relPath);
    if (!this.root) return rel;
    return rel ? `${this.root}/${rel}` : this.root;
  }

  testConnection(): Promise<string> {
    return this.driver.testConnection();
  }

  uploadBytes(relPath: string, data: Uint8Array | Blob, contentType?: string): Promise<void> {
    return this.driver.uploadBytes(this.full(relPath), data, contentType);
  }

  async uploadJson(relPath: string, obj: unknown): Promise<void> {
    const json = JSON.stringify(obj, null, 2);
    await this.uploadBytes(relPath, new TextEncoder().encode(json), 'application/json; charset=utf-8');
  }

  downloadBytes(relPath: string): Promise<Uint8Array> {
    return this.driver.downloadBytes(this.full(relPath));
  }

  async downloadJson<T>(relPath: string): Promise<T> {
    const bytes = await this.downloadBytes(relPath);
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  }

  listDir(relDir: string): Promise<CloudEntry[]> {
    return this.driver.listDir(this.full(relDir));
  }

  deletePath(relPath: string): Promise<void> {
    return this.driver.deletePath(this.full(relPath));
  }
}

export interface NimbusWebConfig {
  provider: CloudProviderId;
  remoteRoot: string;
  deviceId: string;
  webdav?: WebDAVCreds;
  oauthTokens?: Partial<Record<OAuthProvider, OAuthTokens>>;
}

export function buildWebCloudFS(
  config: NimbusWebConfig,
  onSaveTokens?: (provider: OAuthProvider, tokens: OAuthTokens) => void,
): RootPrefixedCloudFS {
  if (config.provider === 'webdav' && config.webdav) {
    return new RootPrefixedCloudFS(new WebDAVWebDriver(config.webdav), config.remoteRoot);
  }
  if (config.provider === 'gdrive' || config.provider === 'onedrive' || config.provider === 'dropbox') {
    const tokens = config.oauthTokens?.[config.provider];
    if (!tokens) throw new Error(`Not signed in to ${config.provider}`);
    const tm = new WebTokenManager(config.provider, tokens, (t) => onSaveTokens?.(config.provider as OAuthProvider, t));
    const drv =
      config.provider === 'gdrive'
        ? new GDriveWebDriver(tm)
        : config.provider === 'onedrive'
          ? new OneDriveWebDriver(tm)
          : new DropboxWebDriver(tm);
    return new RootPrefixedCloudFS(drv, config.remoteRoot);
  }
  throw new Error('Cloud provider is not configured.');
}

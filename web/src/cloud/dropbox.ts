import { WebTokenManager } from './oauth';
import { CloudDriver, CloudEntry, CloudNotFoundError } from './types';

const RPC_API = 'https://api.dropboxapi.com/2';
const CONTENT_API = 'https://content.dropboxapi.com/2';

function dbxPath(p: string): string {
  const norm = (p || '').replace(/\\/g, '/').replace(/^\/+|\/+$/g, '').replace(/\/+/g, '/');
  return norm ? `/${norm}` : '';
}

export class DropboxWebDriver implements CloudDriver {
  constructor(private tm: WebTokenManager) {}

  private async headers(extra?: Record<string, string>): Promise<Record<string, string>> {
    const token = await this.tm.getAccessToken();
    return { Authorization: `Bearer ${token}`, ...extra };
  }

  async testConnection(): Promise<string> {
    const resp = await fetch(`${RPC_API}/users/get_current_account`, {
      method: 'POST',
      headers: await this.headers(),
    });
    if (!resp.ok) throw new Error(`Dropbox connection failed (${resp.status})`);
    const data = await resp.json();
    return data.email || data.name?.display_name || 'Dropbox';
  }

  async ensurePath(remoteDir: string): Promise<string> {
    const p = dbxPath(remoteDir);
    if (!p) return '';
    const resp = await fetch(`${RPC_API}/files/create_folder_v2`, {
      method: 'POST',
      headers: await this.headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ path: p, autorename: false }),
    });
    if (!resp.ok && resp.status !== 409) throw new Error(`Dropbox folder create failed (${resp.status})`);
    return p;
  }

  async uploadBytes(remotePath: string, data: Uint8Array | Blob): Promise<void> {
    const p = dbxPath(remotePath);
    const bodyData = data instanceof Blob ? data : data.slice().buffer;
    const resp = await fetch(`${CONTENT_API}/files/upload`, {
      method: 'POST',
      headers: await this.headers({
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': JSON.stringify({ path: p, mode: 'overwrite', mute: true }),
      }),
      body: bodyData,
    });
    if (!resp.ok) throw new Error(`Dropbox upload failed (${resp.status})`);
  }

  async downloadBytes(remotePath: string): Promise<Uint8Array> {
    const p = dbxPath(remotePath);
    const resp = await fetch(`${CONTENT_API}/files/download`, {
      method: 'POST',
      headers: await this.headers({
        'Dropbox-API-Arg': JSON.stringify({ path: p }),
      }),
    });
    if (resp.status === 409) throw new CloudNotFoundError(remotePath);
    if (!resp.ok) throw new Error(`Dropbox download failed (${resp.status})`);
    return new Uint8Array(await resp.arrayBuffer());
  }

  async listDir(remoteDir: string): Promise<CloudEntry[]> {
    const p = dbxPath(remoteDir);
    let url = `${RPC_API}/files/list_folder`;
    let payload: Record<string, unknown> = { path: p, recursive: false };
    const entries: CloudEntry[] = [];

    while (true) {
      const resp = await fetch(url, {
        method: 'POST',
        headers: await this.headers({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(payload),
      });
      if (resp.status === 409) return [];
      if (!resp.ok) throw new Error(`Dropbox list failed (${resp.status})`);
      const data = await resp.json();
      for (const item of data.entries || []) {
        entries.push({
          name: item.name,
          path: String(item.path_display || item.path_lower || '').replace(/^\/+/, ''),
          is_dir: item['.tag'] === 'folder',
          size: Number(item.size || 0),
          mtime: item.server_modified,
          file_id: item.id,
        });
      }
      if (!data.has_more) break;
      url = `${RPC_API}/files/list_folder/continue`;
      payload = { cursor: data.cursor };
    }
    return entries;
  }

  async deletePath(remotePath: string): Promise<void> {
    const p = dbxPath(remotePath);
    const resp = await fetch(`${RPC_API}/files/delete_v2`, {
      method: 'POST',
      headers: await this.headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ path: p }),
    });
    if (!resp.ok && resp.status !== 409) throw new Error(`Dropbox delete failed (${resp.status})`);
  }
}

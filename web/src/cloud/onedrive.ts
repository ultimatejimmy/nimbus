import { WebTokenManager } from './oauth';
import { CloudDriver, CloudEntry, CloudNotFoundError } from './types';

const GRAPH_API = 'https://graph.microsoft.com/v1.0/me/drive';

function normalizePath(p: string): string {
  return (p || '').replace(/\\/g, '/').replace(/^\/+|\/+$/g, '').replace(/\/+/g, '/');
}

function encodePath(p: string): string {
  return normalizePath(p)
    .split('/')
    .map((seg) => encodeURIComponent(seg))
    .join('/');
}

export class OneDriveWebDriver implements CloudDriver {
  constructor(private tm: WebTokenManager) {}

  private async headers(extra?: Record<string, string>): Promise<Record<string, string>> {
    const token = await this.tm.getAccessToken();
    return { Authorization: `Bearer ${token}`, ...extra };
  }

  async testConnection(): Promise<string> {
    const resp = await fetch(GRAPH_API, { headers: await this.headers() });
    if (!resp.ok) throw new Error(`OneDrive connection failed (${resp.status})`);
    const data = await resp.json();
    return data.owner?.user?.displayName || 'OneDrive';
  }

  async ensurePath(remoteDir: string): Promise<string> {
    const norm = normalizePath(remoteDir);
    if (!norm) return '';
    let acc = '';
    for (const part of norm.split('/')) {
      const parentUrl = acc ? `${GRAPH_API}/root:/${encodePath(acc)}:/children` : `${GRAPH_API}/root/children`;
      acc = acc ? `${acc}/${part}` : part;
      const chk = await fetch(`${GRAPH_API}/root:/${encodePath(acc)}`, { headers: await this.headers() });
      if (!chk.ok) {
        const mk = await fetch(parentUrl, {
          method: 'POST',
          headers: await this.headers({ 'Content-Type': 'application/json' }),
          body: JSON.stringify({
            name: part,
            folder: {},
            '@microsoft.graph.conflictBehavior': 'replace',
          }),
        });
        if (!mk.ok && mk.status !== 409) throw new Error(`OneDrive folder create failed (${mk.status})`);
      }
    }
    return norm;
  }

  async uploadBytes(remotePath: string, data: Uint8Array | Blob, contentType = 'application/octet-stream'): Promise<void> {
    const norm = normalizePath(remotePath);
    const idx = norm.lastIndexOf('/');
    if (idx >= 0) await this.ensurePath(norm.slice(0, idx));
    const bodyData = data instanceof Blob ? data : data.slice().buffer;
    const resp = await fetch(`${GRAPH_API}/root:/${encodePath(norm)}:/content`, {
      method: 'PUT',
      headers: await this.headers({ 'Content-Type': contentType }),
      body: bodyData,
    });
    if (!resp.ok) throw new Error(`OneDrive upload failed (${resp.status})`);
  }

  async downloadBytes(remotePath: string): Promise<Uint8Array> {
    const norm = normalizePath(remotePath);
    const resp = await fetch(`${GRAPH_API}/root:/${encodePath(norm)}:/content`, {
      headers: await this.headers(),
    });
    if (resp.status === 404) throw new CloudNotFoundError(remotePath);
    if (!resp.ok) throw new Error(`OneDrive download failed (${resp.status})`);
    return new Uint8Array(await resp.arrayBuffer());
  }

  async listDir(remoteDir: string): Promise<CloudEntry[]> {
    const norm = normalizePath(remoteDir);
    let url: string | null = norm ? `${GRAPH_API}/root:/${encodePath(norm)}:/children` : `${GRAPH_API}/root/children`;
    const entries: CloudEntry[] = [];
    while (url) {
      const resp = await fetch(url, { headers: await this.headers() });
      if (resp.status === 404) return [];
      if (!resp.ok) throw new Error(`OneDrive list failed (${resp.status})`);
      const data = await resp.json();
      for (const item of data.value || []) {
        entries.push({
          name: item.name,
          path: norm ? `${norm}/${item.name}` : item.name,
          is_dir: Boolean(item.folder),
          size: Number(item.size || 0),
          mtime: item.lastModifiedDateTime,
          file_id: item.id,
        });
      }
      url = data['@odata.nextLink'] || null;
    }
    return entries;
  }

  async deletePath(remotePath: string): Promise<void> {
    const norm = normalizePath(remotePath);
    const resp = await fetch(`${GRAPH_API}/root:/${encodePath(norm)}`, {
      method: 'DELETE',
      headers: await this.headers(),
    });
    if (!resp.ok && resp.status !== 404) throw new Error(`OneDrive delete failed (${resp.status})`);
  }
}

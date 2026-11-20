import { WebTokenManager } from './oauth';
import { CloudDriver, CloudEntry, CloudNotFoundError } from './types';

const DRIVE_API = 'https://www.googleapis.com/drive/v3';
const DRIVE_UPLOAD = 'https://www.googleapis.com/upload/drive/v3';

function normalizePath(p: string): string {
  return (p || '').replace(/\\/g, '/').replace(/^\/+|\/+$/g, '').replace(/\/+/g, '/');
}

function escapeQuery(s: string): string {
  return s.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

export class GDriveWebDriver implements CloudDriver {
  private folderCache = new Map<string, string>();
  private dirLocks = new Map<string, Promise<string | null>>();

  constructor(private tm: WebTokenManager) {}

  private async headers(extra?: Record<string, string>): Promise<Record<string, string>> {
    const token = await this.tm.getAccessToken();
    return { Authorization: `Bearer ${token}`, ...extra };
  }

  private async findInParent(parentId: string, name: string, isDir?: boolean): Promise<any | null> {
    let mimeClause = '';
    if (isDir === true) mimeClause = " and mimeType = 'application/vnd.google-apps.folder'";
    if (isDir === false) mimeClause = " and mimeType != 'application/vnd.google-apps.folder'";
    const q = `name = '${escapeQuery(name)}' and '${escapeQuery(parentId)}' in parents and trashed = false${mimeClause}`;
    const url = `${DRIVE_API}/files?q=${encodeURIComponent(q)}&fields=files(id,name,mimeType,size,modifiedTime)&orderBy=createdTime asc&pageSize=5`;
    const resp = await fetch(url, { headers: await this.headers() });
    if (!resp.ok) throw new Error(`Google Drive query failed (${resp.status})`);
    const data = await resp.json();
    return data.files?.[0] || null;
  }

  private resolveDirId(remoteDir: string, create: boolean): Promise<string | null> {
    const norm = normalizePath(remoteDir);
    if (!norm) return Promise.resolve('root');
    if (this.folderCache.has(norm)) return Promise.resolve(this.folderCache.get(norm)!);

    const lockKey = `${create ? '1' : '0'}:${norm}`;
    const pending = this.dirLocks.get(lockKey);
    if (pending) return pending;

    const task = (async () => {
      let parentId = 'root';
      let acc = '';
      for (const part of norm.split('/')) {
        acc = acc ? `${acc}/${part}` : part;
        if (this.folderCache.has(acc)) {
          parentId = this.folderCache.get(acc)!;
          continue;
        }
        const existing = await this.findInParent(parentId, part, true);
        if (existing?.id) {
          parentId = existing.id;
          this.folderCache.set(acc, parentId);
        } else if (create) {
          const resp = await fetch(`${DRIVE_API}/files?fields=id`, {
            method: 'POST',
            headers: await this.headers({ 'Content-Type': 'application/json; charset=UTF-8' }),
            body: JSON.stringify({
              name: part,
              mimeType: 'application/vnd.google-apps.folder',
              parents: [parentId],
            }),
          });
          if (!resp.ok) throw new Error(`Failed to create folder '${acc}' (${resp.status})`);
          const created = await resp.json();
          parentId = created.id;
          this.folderCache.set(acc, parentId);
        } else {
          return null;
        }
      }
      return parentId;
    })().finally(() => {
      this.dirLocks.delete(lockKey);
    });

    this.dirLocks.set(lockKey, task);
    return task;
  }

  private async resolveItem(remotePath: string): Promise<any | null> {
    const norm = normalizePath(remotePath);
    const idx = norm.lastIndexOf('/');
    const dir = idx >= 0 ? norm.slice(0, idx) : '';
    const name = idx >= 0 ? norm.slice(idx + 1) : norm;
    const parentId = await this.resolveDirId(dir, false);
    if (!parentId) return null;
    return this.findInParent(parentId, name);
  }

  async testConnection(): Promise<string> {
    const resp = await fetch(`${DRIVE_API}/about?fields=user(displayName,emailAddress)`, {
      headers: await this.headers(),
    });
    if (!resp.ok) throw new Error(`Google Drive connection failed (${resp.status})`);
    const data = await resp.json();
    return data.user?.emailAddress || data.user?.displayName || 'Google Drive';
  }

  async ensurePath(remoteDir: string): Promise<string> {
    const id = await this.resolveDirId(remoteDir, true);
    if (!id) throw new Error(`Could not ensure directory: ${remoteDir}`);
    return id;
  }

  async uploadBytes(remotePath: string, data: Uint8Array | Blob, contentType = 'application/octet-stream'): Promise<void> {
    const norm = normalizePath(remotePath);
    const idx = norm.lastIndexOf('/');
    const dir = idx >= 0 ? norm.slice(0, idx) : '';
    const name = idx >= 0 ? norm.slice(idx + 1) : norm;
    const parentId = await this.ensurePath(dir);
    const existing = await this.findInParent(parentId, name, false);
    const bodyBlob = data instanceof Blob ? data : new Blob([data.slice().buffer], { type: contentType });

    if (existing?.id) {
      const resp = await fetch(`${DRIVE_UPLOAD}/files/${existing.id}?uploadType=media`, {
        method: 'PATCH',
        headers: await this.headers({ 'Content-Type': contentType }),
        body: bodyBlob,
      });
      if (!resp.ok) throw new Error(`Google Drive upload failed (${resp.status})`);
      return;
    }

    const form = new FormData();
    form.append('metadata', new Blob([JSON.stringify({ name, parents: [parentId] })], { type: 'application/json' }));
    form.append('file', bodyBlob);
    const resp = await fetch(`${DRIVE_UPLOAD}/files?uploadType=multipart`, {
      method: 'POST',
      headers: await this.headers(),
      body: form,
    });
    if (!resp.ok) throw new Error(`Google Drive upload failed (${resp.status})`);
  }

  async downloadBytes(remotePath: string): Promise<Uint8Array> {
    const item = await this.resolveItem(remotePath);
    if (!item?.id) throw new CloudNotFoundError(remotePath);
    const resp = await fetch(`${DRIVE_API}/files/${item.id}?alt=media`, {
      headers: await this.headers(),
    });
    if (resp.status === 404) throw new CloudNotFoundError(remotePath);
    if (!resp.ok) throw new Error(`Google Drive download failed (${resp.status})`);
    return new Uint8Array(await resp.arrayBuffer());
  }

  async listDir(remoteDir: string): Promise<CloudEntry[]> {
    const norm = normalizePath(remoteDir);
    const parentId = await this.resolveDirId(norm, false);
    if (!parentId) return [];

    const entries: CloudEntry[] = [];
    const seen = new Set<string>();
    let pageToken: string | undefined;
    do {
      const q = `'${escapeQuery(parentId)}' in parents and trashed = false`;
      let url = `${DRIVE_API}/files?q=${encodeURIComponent(q)}&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime)&orderBy=modifiedTime desc&pageSize=200`;
      if (pageToken) url += `&pageToken=${encodeURIComponent(pageToken)}`;
      const resp = await fetch(url, { headers: await this.headers() });
      if (!resp.ok) throw new Error(`Google Drive list failed (${resp.status})`);
      const data = await resp.json();
      for (const f of data.files || []) {
        const isDir = f.mimeType === 'application/vnd.google-apps.folder';
        const dedupeKey = `${isDir ? 'd' : 'f'}:${f.name}`;
        if (seen.has(dedupeKey)) continue;
        seen.add(dedupeKey);
        entries.push({
          name: f.name,
          path: norm ? `${norm}/${f.name}` : f.name,
          is_dir: isDir,
          size: Number(f.size || 0),
          mtime: f.modifiedTime,
          file_id: f.id,
        });
      }
      pageToken = data.nextPageToken;
    } while (pageToken);

    return entries;
  }

  async deletePath(remotePath: string): Promise<void> {
    const item = await this.resolveItem(remotePath);
    if (!item?.id) return;
    const resp = await fetch(`${DRIVE_API}/files/${item.id}`, {
      method: 'DELETE',
      headers: await this.headers(),
    });
    if (!resp.ok && resp.status !== 404) throw new Error(`Google Drive delete failed (${resp.status})`);
    this.folderCache.clear();
  }
}

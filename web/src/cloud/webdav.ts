import { CloudDriver, CloudEntry, CloudNotFoundError, WebDAVCreds } from './types';

function normalizePath(p: string): string {
  return (p || '').replace(/\\/g, '/').replace(/^\/+|\/+$/g, '').replace(/\/+/g, '/');
}

export class WebDAVWebDriver implements CloudDriver {
  private baseUrl: string;

  constructor(private creds: WebDAVCreds) {
    this.baseUrl = (creds.url || '').replace(/\/+$/, '');
  }

  private buildUrl(remotePath: string): string {
    const norm = normalizePath(remotePath);
    const encoded = norm
      ? norm
          .split('/')
          .map((s) => encodeURIComponent(s))
          .join('/')
      : '';
    const target = encoded ? `${this.baseUrl}/${encoded}` : `${this.baseUrl}/`;
    if (this.creds.corsProxy && this.creds.corsProxy.trim()) {
      const proxy = this.creds.corsProxy.trim();
      return proxy.includes('{url}') ? proxy.replace('{url}', encodeURIComponent(target)) : `${proxy.replace(/\/+$/, '')}/${target}`;
    }
    return target;
  }

  private headers(extra?: Record<string, string>): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.creds.username) {
      h['Authorization'] = `Basic ${btoa(`${this.creds.username}:${this.creds.password || ''}`)}`;
    }
    return { ...h, ...extra };
  }

  async testConnection(): Promise<string> {
    if (!this.baseUrl) throw new Error('WebDAV URL is not configured.');
    const resp = await fetch(this.buildUrl(''), {
      method: 'PROPFIND',
      headers: this.headers({ Depth: '0' }),
    });
    if (resp.status !== 207 && resp.status !== 200) {
      throw new Error(`WebDAV connection failed (${resp.status})`);
    }
    return this.baseUrl;
  }

  async ensurePath(remoteDir: string): Promise<string> {
    const norm = normalizePath(remoteDir);
    if (!norm) return '';
    let acc = '';
    for (const part of norm.split('/')) {
      acc = acc ? `${acc}/${part}` : part;
      const url = `${this.buildUrl(acc)}/`;
      const resp = await fetch(url, { method: 'MKCOL', headers: this.headers() });
      if (!resp.ok && resp.status !== 405) {
        const p = await fetch(url, { method: 'PROPFIND', headers: this.headers({ Depth: '0' }) });
        if (p.status !== 207 && p.status !== 200) {
          throw new Error(`WebDAV MKCOL failed for '${acc}' (${resp.status})`);
        }
      }
    }
    return norm;
  }

  async uploadBytes(remotePath: string, data: Uint8Array | Blob, contentType = 'application/octet-stream'): Promise<void> {
    const norm = normalizePath(remotePath);
    const idx = norm.lastIndexOf('/');
    if (idx >= 0) await this.ensurePath(norm.slice(0, idx));
    const bodyData = data instanceof Blob ? data : data.slice().buffer;
    const resp = await fetch(this.buildUrl(norm), {
      method: 'PUT',
      headers: this.headers({ 'Content-Type': contentType }),
      body: bodyData,
    });
    if (!resp.ok) throw new Error(`WebDAV PUT failed (${resp.status})`);
  }

  async downloadBytes(remotePath: string): Promise<Uint8Array> {
    const resp = await fetch(this.buildUrl(remotePath), { headers: this.headers() });
    if (resp.status === 404) throw new CloudNotFoundError(remotePath);
    if (!resp.ok) throw new Error(`WebDAV GET failed (${resp.status})`);
    return new Uint8Array(await resp.arrayBuffer());
  }

  async listDir(remoteDir: string): Promise<CloudEntry[]> {
    const norm = normalizePath(remoteDir);
    let url = this.buildUrl(norm);
    if (!url.endsWith('/')) url += '/';
    const resp = await fetch(url, {
      method: 'PROPFIND',
      headers: this.headers({ Depth: '1', 'Content-Type': 'application/xml; charset=utf-8' }),
      body: '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>',
    });
    if (resp.status === 404) return [];
    if (resp.status !== 207 && resp.status !== 200) throw new Error(`WebDAV PROPFIND failed (${resp.status})`);

    const xmlText = await resp.text();
    const doc = new DOMParser().parseFromString(xmlText, 'application/xml');
    const responses = Array.from(doc.getElementsByTagNameNS('*', 'response'));
    const reqPath = new URL(url).pathname.replace(/\/+$/, '');
    const entries: CloudEntry[] = [];

    for (const r of responses) {
      const hrefRaw = r.getElementsByTagNameNS('*', 'href')[0]?.textContent || '';
      if (!hrefRaw) continue;
      const hrefPath = decodeURIComponent(hrefRaw.replace(/^https?:\/\/[^/]+/, '')).replace(/\/+$/, '');
      if (hrefPath === decodeURIComponent(reqPath)) continue;
      const name = hrefPath.split('/').pop() || '';
      if (!name) continue;
      const isDir = r.getElementsByTagNameNS('*', 'collection').length > 0 || hrefRaw.endsWith('/');
      const sizeText = r.getElementsByTagNameNS('*', 'getcontentlength')[0]?.textContent;
      const mtime = r.getElementsByTagNameNS('*', 'getlastmodified')[0]?.textContent || undefined;
      entries.push({
        name,
        path: norm ? `${norm}/${name}` : name,
        is_dir: isDir,
        size: sizeText ? Number(sizeText) : 0,
        mtime,
      });
    }
    return entries;
  }

  async deletePath(remotePath: string): Promise<void> {
    const resp = await fetch(this.buildUrl(remotePath), {
      method: 'DELETE',
      headers: this.headers(),
    });
    if (!resp.ok && resp.status !== 404) throw new Error(`WebDAV DELETE failed (${resp.status})`);
  }
}

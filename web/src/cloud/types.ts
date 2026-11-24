export type CloudProviderId = 'none' | 'gdrive' | 'onedrive' | 'dropbox' | 'webdav';

export interface CloudEntry {
  name: string;
  path: string;
  is_dir: boolean;
  size: number;
  mtime?: string | null;
  file_id?: string;
}

export class CloudNotFoundError extends Error {
  constructor(path: string) {
    super(`Remote path not found: ${path}`);
    this.name = 'CloudNotFoundError';
  }
}

export interface CloudDriver {
  testConnection(): Promise<string>;
  ensurePath(remoteDir: string): Promise<string>;
  uploadBytes(remotePath: string, data: Uint8Array | Blob, contentType?: string): Promise<void>;
  downloadBytes(remotePath: string): Promise<Uint8Array>;
  listDir(remoteDir: string): Promise<CloudEntry[]>;
  deletePath(remotePath: string): Promise<void>;
}

export interface OAuthTokens {
  access_token: string;
  refresh_token?: string;
  expires_at: number;
  token_type?: string;
}

export interface WebDAVCreds {
  url: string;
  username?: string;
  password?: string;
  corsProxy?: string;
}

export interface BookCatalogEntry {
  id: string;
  title: string;
  authors: string[];
  series?: string | null;
  series_index?: number | null;
  tags?: string[];
  language?: string | null;
  isbn?: string | null;
  calibre_uuid?: string | null;
  folder: string;
  filename: string;
  relative_dir?: string;
  metadata_source?: string;
  format: 'epub' | 'pdf' | 'cbz' | 'mobi' | 'azw3' | 'fb2';
  size_bytes: number;
  has_cover: boolean;
  cover_etag?: string | null;
  hashes: {
    partial_md5: string;
    sha256?: string;
  };
  added_at: string;
  updated_at: string;
  deleted?: boolean;
}

export interface CatalogFile {
  version: number;
  updated_at: string;
  updated_by?: string;
  books: Record<string, BookCatalogEntry>;
}

export interface ProgressRecord {
  book_id: string;
  partial_md5?: string;
  percent: number;
  page?: number | null;
  total_pages?: number | null;
  chapter?: string | null;
  xpointer?: string | null;
  cfi?: string | null;
  text_anchor?: string | null;
  status?: 'unread' | 'reading' | 'finished' | 'abandoned';
  rating?: number | null;
  updated_at: number;
  device_id?: string;
}

export interface ProgressShard {
  version: number;
  device_id: string;
  updated_at: string;
  books: Record<string, ProgressRecord>;
}

export interface AnnotationRecord {
  id: string;
  book_id: string;
  type: 'highlight' | 'note' | 'bookmark';
  chapter?: string | null;
  page?: number | null;
  percent?: number | null;
  pos0?: string | null;
  pos1?: string | null;
  cfi_range?: string | null;
  text: string;
  note?: string | null;
  color?: string | null;
  created_at: number;
  updated_at: number;
  deleted: boolean;
}

export interface AnnotationsShard {
  version: number;
  device_id: string;
  updated_at: string;
  books: Record<string, AnnotationRecord[]>;
}

export interface ReadingSession {
  book_id: string;
  partial_md5?: string;
  start_time: number;
  duration_sec: number;
  pages_read?: number;
  start_percent?: number;
  end_percent?: number;
  device_id?: string;
}

export interface SessionsShard {
  version: number;
  device_id: string;
  month: string;
  sessions: ReadingSession[];
}

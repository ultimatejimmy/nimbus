import React, { useEffect, useMemo, useState } from 'react';
import { BarChart3, BookOpen, Cloud, Highlighter, RefreshCw, Settings } from 'lucide-react';
import { buildWebCloudFS, NimbusWebConfig } from './cloud';
import { OAuthProvider } from './cloud/oauth';
import {
  AnnotationRecord,
  BookCatalogEntry,
  OAuthTokens,
  ProgressRecord,
  ReadingSession,
} from './cloud/types';
import { ConnectModal } from './features/auth/ConnectModal';
import { HighlightsView } from './features/highlights/HighlightsView';
import { LibraryView } from './features/library/LibraryView';
import { ReaderView } from './features/reader/ReaderView';
import { SettingsView } from './features/settings/SettingsView';
import { StatsView } from './features/stats/StatsView';
import { db } from './sync/db';
import {
  pushDeviceAnnotations,
  pushDeviceProgress,
  pushDeviceSession,
  syncAllFromCloud,
  uploadBookToCloud,
} from './sync/syncEngine';

type TabId = 'library' | 'highlights' | 'stats' | 'settings';

const CONFIG_KEY = 'nimbus_web_config_v1';

function loadConfig(): NimbusWebConfig {
  try {
    const raw = localStorage.getItem(CONFIG_KEY);
    if (raw) return JSON.parse(raw);
  } catch {
    // ignore
  }
  const id = `Web-Browser_${Math.random().toString(16).slice(2, 6)}`;
  const initial: NimbusWebConfig = { provider: 'none', remoteRoot: 'Nimbus', deviceId: id, oauthTokens: {} };
  localStorage.setItem(CONFIG_KEY, JSON.stringify(initial));
  return initial;
}

export function App() {
  const [config, setConfig] = useState<NimbusWebConfig>(() => loadConfig());
  const [tab, setTab] = useState<TabId>('library');
  const [showConnect, setShowConnect] = useState(false);
  const [syncing, setSyncing] = useState(false);

  const [books, setBooks] = useState<BookCatalogEntry[]>([]);
  const [devices, setDevices] = useState<string[]>([]);
  const [progressByBook, setProgressByBook] = useState<Record<string, ProgressRecord>>({});
  const [annotationsByBook, setAnnotationsByBook] = useState<Record<string, AnnotationRecord[]>>({});
  const [sessions, setSessions] = useState<ReadingSession[]>([]);
  const [offlineIds, setOfflineIds] = useState<Set<string>>(new Set());
  const [coverUrls, setCoverUrls] = useState<Record<string, string>>({});

  const [activeBook, setActiveBook] = useState<{ book: BookCatalogEntry; blob: Blob } | null>(null);

  const saveConfig = (next: NimbusWebConfig) => {
    setConfig(next);
    localStorage.setItem(CONFIG_KEY, JSON.stringify(next));
  };

  const fs = useMemo(() => {
    if (config.provider === 'none') return null;
    try {
      return buildWebCloudFS(config, (prov: OAuthProvider, tok: OAuthTokens) => {
        saveConfig({ ...config, oauthTokens: { ...config.oauthTokens, [prov]: tok } });
      });
    } catch {
      return null;
    }
  }, [config]);

  const loadFromIndexedDB = async () => {
    const [cat, prog, anns, sess, offline] = await Promise.all([
      db.catalog.toArray(),
      db.progress.toArray(),
      db.annotations.toArray(),
      db.sessions.toArray(),
      db.books.toCollection().primaryKeys(),
    ]);
    setBooks(cat);
    setProgressByBook(Object.fromEntries(prog.map((p) => [p.book_id, p])));
    setAnnotationsByBook(Object.fromEntries(anns.map((a) => [a.book_id, a.items])));
    setSessions(sess.map((s) => s.session));
    setOfflineIds(new Set(offline));
  };

  const runSync = async () => {
    if (!fs) return;
    setSyncing(true);
    try {
      const snap = await syncAllFromCloud(fs, config);
      setDevices(snap.devices);
      await loadFromIndexedDB();
    } catch (e) {
      console.error('Sync failed:', e);
    } finally {
      setSyncing(false);
    }
  };

  useEffect(() => {
    loadFromIndexedDB();
  }, []);

  useEffect(() => {
    if (fs) runSync();
  }, [fs]);

  const downloadOffline = async (book: BookCatalogEntry): Promise<Blob> => {
    if (!fs) throw new Error('Cloud is not connected');
    const bytes = await fs.downloadBytes(`${book.folder}/${book.filename}`);
    const blob = new Blob([bytes.slice().buffer]);
    await db.books.put({
      book_id: book.id,
      filename: book.filename,
      format: book.format,
      data: blob,
      cached_at: Date.now(),
    });
    setOfflineIds((prev) => new Set(prev).add(book.id));
    return blob;
  };

  const openBook = async (book: BookCatalogEntry) => {
    const cached = await db.books.get(book.id);
    const blob = cached ? cached.data : await downloadOffline(book);
    setActiveBook({ book, blob });
  };

  const handleSaveProgress = async (prog: ProgressRecord) => {
    const next = { ...progressByBook, [prog.book_id]: { ...prog, device_id: config.deviceId } };
    setProgressByBook(next);
    await db.progress.put(next[prog.book_id]);
    await pushDeviceProgress(fs, config.deviceId, next);
  };

  const handleAddAnnotation = async (ann: AnnotationRecord) => {
    const cur = annotationsByBook[ann.book_id] || [];
    const nextList = [...cur.filter((a) => a.id !== ann.id), ann];
    const nextMap = { ...annotationsByBook, [ann.book_id]: nextList };
    setAnnotationsByBook(nextMap);
    await db.annotations.put({ book_id: ann.book_id, items: nextList });
    await pushDeviceAnnotations(fs, config.deviceId, nextMap);
  };

  const handleRecordSession = async (session: ReadingSession) => {
    const withDev = { ...session, device_id: config.deviceId };
    setSessions((prev) => [...prev, withDev]);
    await pushDeviceSession(fs, config.deviceId, withDev);
  };

  const handleUploadFiles = async (files: FileList) => {
    if (!fs) {
      setShowConnect(true);
      return;
    }
    setSyncing(true);
    try {
      for (const f of Array.from(files)) {
        await uploadBookToCloud(fs, config.deviceId, f, {});
      }
      await loadFromIndexedDB();
    } finally {
      setSyncing(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      <nav className="sticky top-0 z-30 border-b border-slate-800/80 bg-slate-950/90 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
          <div className="flex items-center gap-6">
            <div className="flex items-center gap-2 font-semibold tracking-tight text-sky-400">
              <Cloud className="h-5 w-5" />
              <span className="text-slate-100">Nimbus</span>
            </div>
            <div className="flex items-center gap-1">
              {(
                [
                  ['library', 'Library', BookOpen],
                  ['highlights', 'Highlights', Highlighter],
                  ['stats', 'Stats', BarChart3],
                  ['settings', 'Settings', Settings],
                ] as const
              ).map(([id, label, Icon]) => (
                <button
                  key={id}
                  onClick={() => setTab(id)}
                  className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition ${
                    tab === id ? 'bg-slate-800 text-sky-300' : 'text-slate-400 hover:text-slate-200'
                  }`}
                >
                  <Icon className="h-4 w-4" />
                  <span className="hidden sm:inline">{label}</span>
                </button>
              ))}
            </div>
          </div>

          <div className="flex items-center gap-2">
            {config.provider === 'none' ? (
              <button
                onClick={() => setShowConnect(true)}
                className="rounded-lg bg-sky-500 px-3.5 py-1.5 text-xs font-semibold text-slate-950 hover:bg-sky-400"
              >
                Connect Cloud
              </button>
            ) : (
              <button
                onClick={runSync}
                disabled={syncing}
                className="inline-flex items-center gap-1.5 rounded-lg border border-slate-800 bg-slate-900 px-3 py-1.5 text-xs font-medium text-slate-300 hover:border-slate-700"
              >
                <RefreshCw className={`h-3.5 w-3.5 ${syncing ? 'animate-spin text-sky-400' : ''}`} />
                {syncing ? 'Syncing…' : 'Synced'}
              </button>
            )}
          </div>
        </div>
      </nav>

      <main className="mx-auto max-w-6xl px-4 py-8">
        {tab === 'library' && (
          <LibraryView
            books={books}
            progressByBook={progressByBook}
            offlineBookIds={offlineIds}
            coverUrls={coverUrls}
            onOpenBook={openBook}
            onDownloadOffline={async (b) => {
              await downloadOffline(b);
            }}
            onRemoveOffline={async (b) => {
              await db.books.delete(b.id);
              setOfflineIds((prev) => {
                const n = new Set(prev);
                n.delete(b.id);
                return n;
              });
            }}
            onUploadFiles={handleUploadFiles}
          />
        )}
        {tab === 'highlights' && (
          <HighlightsView books={books} annotationsByBook={annotationsByBook} />
        )}
        {tab === 'stats' && (
          <StatsView sessions={sessions} books={books} progressByBook={progressByBook} />
        )}
        {tab === 'settings' && (
          <SettingsView
            config={config}
            devices={devices}
            onOpenConnect={() => setShowConnect(true)}
            onSyncNow={runSync}
            onClearCache={async () => {
              await db.books.clear();
              await db.covers.clear();
              setOfflineIds(new Set());
              setCoverUrls({});
            }}
          />
        )}
      </main>

      {showConnect && (
        <ConnectModal
          config={config}
          onSaveConfig={saveConfig}
          onClose={() => setShowConnect(false)}
        />
      )}

      {activeBook && (
        <ReaderView
          book={activeBook.book}
          fileBlob={activeBook.blob}
          initialProgress={progressByBook[activeBook.book.id]}
          annotations={annotationsByBook[activeBook.book.id] || []}
          onSaveProgress={handleSaveProgress}
          onAddAnnotation={handleAddAnnotation}
          onRecordSession={handleRecordSession}
          onClose={() => setActiveBook(null)}
        />
      )}
    </div>
  );
}

export default App;

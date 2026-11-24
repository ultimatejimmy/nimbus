import React, { useEffect, useMemo, useRef, useState } from 'react';
import { BarChart3, BookOpen, CloudLightning, Highlighter, Moon, RefreshCw, Settings, Sun } from 'lucide-react';
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
  deleteBookFromCloud,
  findDuplicateGroups,
  mergeDuplicateGroups,
  pushDeviceAnnotations,
  pushDeviceProgress,
  pushDeviceSession,
  syncAllFromCloud,
  syncCoversFromCloud,
  uploadBookToCloud,
} from './sync/syncEngine';

type TabId = 'library' | 'highlights' | 'stats' | 'settings';

const CONFIG_KEY = 'nimbus_web_config_v1';
const THEME_KEY = 'nimbus_web_theme_v1';

function loadTheme(): 'light' | 'dark' {
  try {
    const saved = localStorage.getItem(THEME_KEY);
    if (saved === 'light' || saved === 'dark') return saved;
  } catch {
    // ignore
  }
  return 'dark';
}

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
  const [theme, setTheme] = useState<'light' | 'dark'>(() => loadTheme());
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
  const [openingBookTitle, setOpeningBookTitle] = useState<string | null>(null);
  const [openError, setOpenError] = useState<string | null>(null);
  const [syncError, setSyncError] = useState<string | null>(null);
  const syncSeqRef = useRef(0);

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
    const [cat, prog, anns, sess, offline, covers] = await Promise.all([
      db.catalog.toArray(),
      db.progress.toArray(),
      db.annotations.toArray(),
      db.sessions.toArray(),
      db.books.toCollection().primaryKeys(),
      db.covers.toArray(),
    ]);
    setBooks(cat);
    setProgressByBook(Object.fromEntries(prog.map((p) => [p.book_id, p])));
    setAnnotationsByBook(Object.fromEntries(anns.map((a) => [a.book_id, a.items])));
    setSessions(sess.map((s) => s.session));
    setOfflineIds(new Set(offline));
    if (covers.length > 0) {
      setCoverUrls((prev) => {
        const next = { ...prev };
        for (const c of covers) {
          if (!next[c.book_id]) {
            next[c.book_id] = URL.createObjectURL(c.data);
          }
        }
        return next;
      });
    }
  };

  const runSync = async () => {
    if (!fs) return;
    const seq = ++syncSeqRef.current;
    setSyncError(null);
    setSyncing(true);
    try {
      const snap = await syncAllFromCloud(fs, config);
      if (seq !== syncSeqRef.current) return;
      setDevices(snap.devices);
      await loadFromIndexedDB();
      void syncCoversFromCloud(fs, Object.values(snap.catalog.books || {}), (bookId, blob) => {
        if (seq !== syncSeqRef.current) return;
        const url = URL.createObjectURL(blob);
        setCoverUrls((prev) => {
          if (prev[bookId]) URL.revokeObjectURL(prev[bookId]);
          return { ...prev, [bookId]: url };
        });
      });
    } catch (e: any) {
      if (seq === syncSeqRef.current) {
        console.error('Sync failed:', e);
        setSyncError(`Sync failed for "/${config.remoteRoot}": ${e?.message || String(e)}`);
      }
    } finally {
      if (seq === syncSeqRef.current) setSyncing(false);
    }
  };

  useEffect(() => {
    document.documentElement.classList.toggle('dark', theme === 'dark');
    try {
      localStorage.setItem(THEME_KEY, theme);
    } catch {
      // ignore
    }
  }, [theme]);

  useEffect(() => {
    loadFromIndexedDB();
  }, []);

  useEffect(() => {
    if (fs) runSync();
  }, [fs]);

  const downloadOffline = async (book: BookCatalogEntry): Promise<Blob> => {
    if (!fs) throw new Error('Cloud is not connected');
    let bytes: Uint8Array;
    try {
      bytes = await fs.downloadBytes(`${book.folder}/${book.filename}`);
    } catch (err: any) {
      if (err?.name !== 'CloudNotFoundError' || !book.folder) throw err;
      const entries = await fs.listDir(book.folder);
      const ext = `.${(book.format || 'epub').toLowerCase()}`;
      const match =
        entries.find((e) => !e.is_dir && e.name.toLowerCase().endsWith(ext)) ||
        entries.find((e) => !e.is_dir && e.name !== 'cover.jpg' && e.name !== 'metadata.json');
      if (!match) throw err;
      bytes = await fs.downloadBytes(`${book.folder}/${match.name}`);
    }
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
    setOpenError(null);
    setOpeningBookTitle(book.title);
    try {
      const cached = await db.books.get(book.id);
      const blob = cached ? cached.data : await downloadOffline(book);
      setActiveBook({ book, blob });
    } catch (e: any) {
      console.error('Failed to open book:', e);
      setOpenError(`Failed to open "${book.title}": ${e?.message || String(e)}`);
    } finally {
      setOpeningBookTitle(null);
    }
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
    <div className="min-h-screen bg-slate-50 text-slate-900 transition-colors dark:bg-slate-950 dark:text-slate-100">
      <nav className="sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur dark:border-slate-800/80 dark:bg-slate-950/90">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
          <div className="flex items-center gap-6">
            <div className="flex items-center gap-2 font-semibold tracking-tight text-emerald-600 dark:text-emerald-400">
              <CloudLightning className="h-5 w-5" />
              <span className="text-slate-900 dark:text-slate-100">Nimbus</span>
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
                    tab === id
                      ? 'bg-emerald-50 text-emerald-700 dark:bg-slate-800 dark:text-emerald-300'
                      : 'text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-200'
                  }`}
                >
                  <Icon className="h-4 w-4" />
                  <span className="hidden sm:inline">{label}</span>
                </button>
              ))}
            </div>
          </div>

          <div className="flex items-center gap-2">
            <button
              onClick={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}
              className="rounded-lg border border-slate-200 bg-white p-1.5 text-slate-600 transition hover:bg-slate-100 hover:text-slate-900 dark:border-slate-800 dark:bg-slate-900 dark:text-slate-300 dark:hover:border-slate-700 dark:hover:text-slate-100"
              title={theme === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode'}
              aria-label={theme === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode'}
            >
              {theme === 'dark' ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
            </button>

            {config.provider === 'none' ? (
              <button
                onClick={() => setShowConnect(true)}
                className="rounded-lg bg-emerald-600 px-3.5 py-1.5 text-xs font-semibold text-white transition hover:bg-emerald-500 dark:bg-emerald-500 dark:text-slate-950 dark:hover:bg-emerald-400"
              >
                Connect Cloud
              </button>
            ) : (
              <button
                onClick={runSync}
                disabled={syncing}
                className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 transition hover:border-slate-300 dark:border-slate-800 dark:bg-slate-900 dark:text-slate-300 dark:hover:border-slate-700"
              >
                <RefreshCw className={`h-3.5 w-3.5 ${syncing ? 'animate-spin text-emerald-500 dark:text-emerald-400' : ''}`} />
                {syncing ? 'Syncing…' : 'Synced'}
              </button>
            )}
          </div>
        </div>
      </nav>

      <main className="mx-auto max-w-6xl px-4 py-8">
        {openingBookTitle && (
          <div className="mb-4 flex items-center gap-2 rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-4 py-2.5 text-sm text-emerald-700 dark:text-emerald-300">
            <RefreshCw className="h-4 w-4 animate-spin" />
            <span>Downloading & opening “{openingBookTitle}”…</span>
          </div>
        )}
        {(openError || syncError) && (
          <div className="mb-4 flex items-center justify-between rounded-lg border border-rose-500/30 bg-rose-500/10 px-4 py-2.5 text-sm text-rose-700 dark:text-rose-300">
            <span>{openError || syncError}</span>
            <button
              onClick={() => {
                setOpenError(null);
                setSyncError(null);
              }}
              className="ml-4 text-xs underline"
            >
              Dismiss
            </button>
          </div>
        )}
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
            onDeleteFromCloud={async (b) => {
              if (!fs) {
                setShowConnect(true);
                return;
              }
              await deleteBookFromCloud(fs, b, config.deviceId);
              setOfflineIds((prev) => {
                const n = new Set(prev);
                n.delete(b.id);
                return n;
              });
              await loadFromIndexedDB();
            }}
            onMergeDuplicates={async (groups, preferredKeepIds) => {
              if (!fs) {
                setShowConnect(true);
                return;
              }
              setSyncing(true);
              try {
                await mergeDuplicateGroups(fs, config, groups, preferredKeepIds);
                await runSync();
              } finally {
                setSyncing(false);
              }
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
            onChangeRemoteRoot={async (nextRoot) => {
              await db.covers.clear();
              setCoverUrls({});
              saveConfig({ ...config, remoteRoot: nextRoot });
            }}
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

import React, { useMemo, useRef, useState } from 'react';
import { BookOpen, CheckCircle2, CloudDownload, HardDrive, Search, Trash2, Upload } from 'lucide-react';
import { BookCatalogEntry, ProgressRecord } from '../../cloud/types';

type FilterTab = 'all' | 'reading' | 'unread' | 'finished' | 'offline';

interface Props {
  books: BookCatalogEntry[];
  progressByBook: Record<string, ProgressRecord>;
  offlineBookIds: Set<string>;
  coverUrls: Record<string, string>;
  onOpenBook: (book: BookCatalogEntry) => void;
  onDownloadOffline: (book: BookCatalogEntry) => Promise<void>;
  onRemoveOffline: (book: BookCatalogEntry) => Promise<void>;
  onUploadFiles: (files: FileList) => Promise<void>;
}

export const LibraryView: React.FC<Props> = ({
  books,
  progressByBook,
  offlineBookIds,
  coverUrls,
  onOpenBook,
  onDownloadOffline,
  onRemoveOffline,
  onUploadFiles,
}) => {
  const [filter, setFilter] = useState<FilterTab>('all');
  const [query, setQuery] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return books
      .filter((b) => {
        if (b.deleted) return false;
        const prog = progressByBook[b.id];
        const status = prog?.status || 'unread';
        if (filter === 'reading' && status !== 'reading') return false;
        if (filter === 'unread' && status !== 'unread') return false;
        if (filter === 'finished' && status !== 'finished') return false;
        if (filter === 'offline' && !offlineBookIds.has(b.id)) return false;
        if (!q) return true;
        const hay = `${b.title} ${(b.authors || []).join(' ')} ${b.series || ''} ${(b.tags || []).join(' ')}`.toLowerCase();
        return hay.includes(q);
      })
      .sort((a, b) => {
        const ta = progressByBook[a.id]?.updated_at || 0;
        const tb = progressByBook[b.id]?.updated_at || 0;
        if (ta !== tb) return tb - ta;
        return a.title.localeCompare(b.title);
      });
  }, [books, progressByBook, offlineBookIds, filter, query]);

  return (
    <div
      className="space-y-6"
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => {
        e.preventDefault();
        if (e.dataTransfer.files?.length) onUploadFiles(e.dataTransfer.files);
      }}
    >
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight">Cloud Library</h2>
          <p className="text-sm text-slate-400">
            {books.length} book{books.length === 1 ? '' : 's'} synced across your cloud storage
          </p>
        </div>
        <div>
          <input
            ref={fileRef}
            type="file"
            multiple
            accept=".epub,.pdf,.cbz,.mobi,.azw3,.fb2"
            className="hidden"
            onChange={(e) => {
              if (e.target.files?.length) onUploadFiles(e.target.files);
              e.target.value = '';
            }}
          />
          <button
            onClick={() => fileRef.current?.click()}
            className="inline-flex items-center gap-2 rounded-lg bg-sky-500 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-sky-400"
          >
            <Upload className="h-4 w-4" />
            Upload Book
          </button>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <div className="relative flex-1 min-w-[220px]">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search title, author, series, or tag..."
            className="w-full rounded-lg border border-slate-800 bg-slate-900 py-2 pl-9 pr-3 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none"
          />
        </div>
        <div className="flex flex-wrap gap-1.5 rounded-lg border border-slate-800 bg-slate-900 p-1">
          {(
            [
              ['all', 'All'],
              ['reading', 'Reading'],
              ['unread', 'Unread'],
              ['finished', 'Finished'],
              ['offline', 'Offline'],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              onClick={() => setFilter(id)}
              className={`rounded-md px-3 py-1 text-xs font-medium transition ${
                filter === id ? 'bg-sky-500 text-slate-950' : 'text-slate-300 hover:bg-slate-800'
              }`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className="rounded-2xl border border-dashed border-slate-800 bg-slate-900/40 p-16 text-center text-slate-400">
          <BookOpen className="mx-auto mb-3 h-10 w-10 text-slate-600" />
          <p className="font-medium text-slate-300">No books match your filter</p>
          <p className="mt-1 text-xs">Drag & drop an EPUB, PDF, or CBZ here to upload to Nimbus Cloud.</p>
        </div>
      ) : (
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
          {filtered.map((book) => {
            const prog = progressByBook[book.id];
            const pct = prog ? Math.round((prog.percent || 0) * 100) : 0;
            const isOffline = offlineBookIds.has(book.id);
            const cover = coverUrls[book.id];

            return (
              <div
                key={book.id}
                className="group flex flex-col overflow-hidden rounded-xl border border-slate-800 bg-slate-900/70 transition hover:border-slate-700"
              >
                <div
                  onClick={() => onOpenBook(book)}
                  className="relative aspect-[2/3] cursor-pointer overflow-hidden bg-slate-800"
                >
                  {cover ? (
                    <img src={cover} alt={book.title} className="h-full w-full object-cover transition group-hover:scale-105" />
                  ) : (
                    <div className="flex h-full flex-col items-center justify-center p-4 text-center">
                      <BookOpen className="mb-2 h-8 w-8 text-slate-500" />
                      <span className="line-clamp-3 text-xs font-medium text-slate-300">{book.title}</span>
                    </div>
                  )}
                  <span className="absolute right-2 top-2 rounded bg-slate-950/80 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-slate-200">
                    {book.format}
                  </span>
                  {isOffline && (
                    <span className="absolute left-2 top-2 rounded bg-emerald-500/90 p-1 text-slate-950" title="Cached offline">
                      <HardDrive className="h-3 w-3" />
                    </span>
                  )}
                  {pct > 0 && (
                    <div className="absolute inset-x-0 bottom-0 h-1.5 bg-slate-950/80">
                      <div className="h-full bg-sky-400" style={{ width: `${pct}%` }} />
                    </div>
                  )}
                </div>

                <div className="flex flex-1 flex-col justify-between p-3">
                  <div>
                    <h3
                      onClick={() => onOpenBook(book)}
                      className="line-clamp-2 cursor-pointer text-sm font-medium text-slate-100 hover:text-sky-400"
                    >
                      {book.title}
                    </h3>
                    <p className="mt-0.5 line-clamp-1 text-xs text-slate-400">
                      {(book.authors || []).join(', ')}
                    </p>
                  </div>

                  <div className="mt-3 flex items-center justify-between text-xs text-slate-400">
                    <span className="inline-flex items-center gap-1">
                      {prog?.status === 'finished' ? (
                        <>
                          <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" /> Done
                        </>
                      ) : (
                        `${pct}%`
                      )}
                    </span>
                    <button
                      disabled={busyId === book.id}
                      onClick={async () => {
                        setBusyId(book.id);
                        try {
                          if (isOffline) await onRemoveOffline(book);
                          else await onDownloadOffline(book);
                        } finally {
                          setBusyId(null);
                        }
                      }}
                      className="rounded p-1 text-slate-400 hover:bg-slate-800 hover:text-slate-200"
                      title={isOffline ? 'Remove offline copy' : 'Download for offline reading'}
                    >
                      {isOffline ? <Trash2 className="h-3.5 w-3.5" /> : <CloudDownload className="h-3.5 w-3.5" />}
                    </button>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
};

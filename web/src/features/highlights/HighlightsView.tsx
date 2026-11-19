import React, { useMemo, useState } from 'react';
import { Download, Search, Highlighter } from 'lucide-react';
import { AnnotationRecord, BookCatalogEntry } from '../../cloud/types';
import { formatObsidianMarkdown } from './obsidianExport';

interface Props {
  books: BookCatalogEntry[];
  annotationsByBook: Record<string, AnnotationRecord[]>;
}

export const HighlightsView: React.FC<Props> = ({ books, annotationsByBook }) => {
  const [query, setQuery] = useState('');
  const [selectedBookId, setSelectedBookId] = useState<string>('all');

  const bookMap = useMemo(() => {
    const m = new Map<string, BookCatalogEntry>();
    for (const b of books) m.set(b.id, b);
    return m;
  }, [books]);

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    const out: { book: BookCatalogEntry; ann: AnnotationRecord }[] = [];
    for (const [bid, list] of Object.entries(annotationsByBook)) {
      if (selectedBookId !== 'all' && bid !== selectedBookId) continue;
      const book = bookMap.get(bid);
      if (!book) continue;
      for (const ann of list) {
        if (ann.deleted) continue;
        if (
          !q ||
          ann.text.toLowerCase().includes(q) ||
          (ann.note || '').toLowerCase().includes(q) ||
          book.title.toLowerCase().includes(q)
        ) {
          out.push({ book, ann });
        }
      }
    }
    return out.sort((a, b) => (b.ann.updated_at || 0) - (a.ann.updated_at || 0));
  }, [annotationsByBook, bookMap, query, selectedBookId]);

  const exportBook = (book: BookCatalogEntry) => {
    const md = formatObsidianMarkdown(book, annotationsByBook[book.id] || []);
    const blob = new Blob([md], { type: 'text/markdown;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${book.title.replace(/[\\/:*?"<>|]/g, '_')}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight">Highlights & Notes</h2>
          <p className="text-sm text-slate-500 dark:text-slate-400">
            Unified across KOReader & Web Reader with 1-click Obsidian Markdown export.
          </p>
        </div>
        {selectedBookId !== 'all' && bookMap.get(selectedBookId) && (
          <button
            onClick={() => exportBook(bookMap.get(selectedBookId)!)}
            className="inline-flex items-center gap-2 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-emerald-500 dark:bg-emerald-500 dark:text-slate-950 dark:hover:bg-emerald-400"
          >
            <Download className="h-4 w-4" />
            Export Book to Markdown
          </button>
        )}
      </div>

      <div className="flex flex-wrap gap-3">
        <div className="relative flex-1 min-w-[220px]">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search highlights, notes, or book titles..."
            className="w-full rounded-lg border border-slate-200 bg-white py-2 pl-9 pr-3 text-sm text-slate-900 placeholder-slate-400 focus:border-emerald-500 focus:outline-none dark:border-slate-800 dark:bg-slate-900 dark:text-slate-100 dark:placeholder-slate-500"
          />
        </div>
        <select
          value={selectedBookId}
          onChange={(e) => setSelectedBookId(e.target.value)}
          className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-emerald-500 focus:outline-none dark:border-slate-800 dark:bg-slate-900 dark:text-slate-100"
        >
          <option value="all">All Books</option>
          {books
            .filter((b) => (annotationsByBook[b.id] || []).some((a) => !a.deleted))
            .map((b) => (
              <option key={b.id} value={b.id}>
                {b.title}
              </option>
            ))}
        </select>
      </div>

      {rows.length === 0 ? (
        <div className="rounded-xl border border-slate-200 bg-white p-12 text-center text-slate-500 dark:border-slate-800 dark:bg-slate-900/50 dark:text-slate-400">
          <Highlighter className="mx-auto mb-3 h-8 w-8 text-slate-400 dark:text-slate-600" />
          No highlights found. Create highlights in KOReader or the Nimbus Web Reader.
        </div>
      ) : (
        <div className="space-y-3">
          {rows.map(({ book, ann }) => (
            <div
              key={`${book.id}-${ann.id}`}
              className="rounded-xl border border-slate-200 bg-white p-4 transition hover:border-slate-300 dark:border-slate-800 dark:bg-slate-900/70 dark:hover:border-slate-700"
            >
              <div className="mb-2 flex items-center justify-between gap-2 text-xs text-slate-500 dark:text-slate-400">
                <span className="font-medium text-emerald-600 dark:text-emerald-400">
                  {book.title} {ann.chapter ? `· ${ann.chapter}` : ''}
                </span>
                <div className="flex items-center gap-3">
                  {ann.percent != null && <span>{(ann.percent * 100).toFixed(1)}%</span>}
                  <button
                    onClick={() => exportBook(book)}
                    className="text-slate-400 hover:text-slate-700 dark:hover:text-slate-200"
                    title="Export book highlights as Markdown"
                  >
                    <Download className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>
              <blockquote className="border-l-2 border-emerald-500/80 pl-3 text-sm leading-relaxed text-slate-800 dark:text-slate-100">
                {ann.text}
              </blockquote>
              {ann.note && (
                <p className="mt-2 rounded bg-slate-100 px-3 py-1.5 text-xs text-slate-700 dark:bg-slate-800/70 dark:text-slate-300">
                  <strong className="text-slate-900 dark:text-slate-200">Note:</strong> {ann.note}
                </p>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

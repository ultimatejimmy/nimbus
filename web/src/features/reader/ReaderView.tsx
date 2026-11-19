import React, { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ChevronLeft, ChevronRight, Highlighter, List, Moon, Sun } from 'lucide-react';
import { AnnotationRecord, BookCatalogEntry, ProgressRecord, ReadingSession } from '../../cloud/types';
import { annotationId } from '../../sync/hasher';

interface Props {
  book: BookCatalogEntry;
  fileBlob: Blob;
  initialProgress?: ProgressRecord;
  annotations: AnnotationRecord[];
  onSaveProgress: (prog: ProgressRecord) => void;
  onAddAnnotation: (ann: AnnotationRecord) => void;
  onRecordSession: (session: ReadingSession) => void;
  onClose: () => void;
}

export const ReaderView: React.FC<Props> = ({
  book,
  fileBlob,
  initialProgress,
  annotations,
  onSaveProgress,
  onAddAnnotation,
  onRecordSession,
  onClose,
}) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const viewRef = useRef<any>(null);

  const [theme, setTheme] = useState<'dark' | 'light' | 'sepia'>('dark');
  const [percent, setPercent] = useState<number>(initialProgress?.percent || 0);
  const [chapter, setChapter] = useState<string>(initialProgress?.chapter || '');
  const [toc, setToc] = useState<{ label: string; href: string }[]>([]);
  const [showToc, setShowToc] = useState(false);
  const [pdfPage, setPdfPage] = useState<number>(initialProgress?.page || 1);
  const [pdfTotal, setPdfTotal] = useState<number>(initialProgress?.total_pages || 1);
  const pdfDocRef = useRef<any>(null);

  const sessionStartRef = useRef<number>(Math.floor(Date.now() / 1000));
  const startPercentRef = useRef<number>(initialProgress?.percent || 0);
  const pagesTurnedRef = useRef<number>(0);

  // Record reading session on unmount
  useEffect(() => {
    return () => {
      const now = Math.floor(Date.now() / 1000);
      const dur = now - sessionStartRef.current;
      if (dur >= 10) {
        onRecordSession({
          book_id: book.id,
          partial_md5: book.hashes.partial_md5,
          start_time: sessionStartRef.current,
          duration_sec: dur,
          pages_read: Math.max(1, pagesTurnedRef.current),
          start_percent: startPercentRef.current,
          end_percent: percent,
        });
      }
    };
  }, []);

  // Initialize foliate-js for EPUB/CBZ/MOBI/FB2 or pdf.js for PDF
  useEffect(() => {
    let disposed = false;

    if (book.format === 'pdf') {
      (async () => {
        const pdfjs = await import('pdfjs-dist');
        pdfjs.GlobalWorkerOptions.workerSrc = new URL(
          'pdfjs-dist/build/pdf.worker.min.mjs',
          import.meta.url,
        ).toString();
        const data = await fileBlob.arrayBuffer();
        const doc = await pdfjs.getDocument({ data }).promise;
        if (disposed) return;
        pdfDocRef.current = doc;
        setPdfTotal(doc.numPages);
        const startPage = Math.min(doc.numPages, Math.max(1, initialProgress?.page || 1));
        setPdfPage(startPage);
        renderPdfPage(doc, startPage);
      })();
      return () => {
        disposed = true;
      };
    }

    (async () => {
      await import('foliate-js/view.js');
      if (disposed || !containerRef.current) return;
      const view = document.createElement('foliate-view') as any;
      view.style.width = '100%';
      view.style.height = '100%';
      containerRef.current.innerHTML = '';
      containerRef.current.appendChild(view);
      viewRef.current = view;

      const file = new File([fileBlob], book.filename, { type: 'application/epub+zip' });
      await view.open(file);

      if (view.book?.toc) {
        setToc(view.book.toc.map((t: any) => ({ label: t.label, href: t.href })));
      }

      view.addEventListener('relocate', (e: any) => {
        const detail = e.detail || {};
        const frac = Number(detail.fraction ?? 0);
        pagesTurnedRef.current += 1;
        setPercent(frac);
        if (detail.tocItem?.label) setChapter(detail.tocItem.label);
        onSaveProgress({
          book_id: book.id,
          partial_md5: book.hashes.partial_md5,
          percent: frac,
          chapter: detail.tocItem?.label || chapter || null,
          cfi: detail.cfi || null,
          status: frac >= 0.99 ? 'finished' : 'reading',
          updated_at: Math.floor(Date.now() / 1000),
        });
      });

      if (initialProgress?.cfi) {
        await view.init({ lastLocation: initialProgress.cfi });
      } else if (initialProgress?.percent) {
        await view.init({ lastLocation: initialProgress.percent });
      } else {
        await view.init({});
      }
    })();

    return () => {
      disposed = true;
      if (viewRef.current?.close) viewRef.current.close();
    };
  }, [book.id]);

  const renderPdfPage = async (doc: any, pageNum: number) => {
    if (!canvasRef.current) return;
    const page = await doc.getPage(pageNum);
    const viewport = page.getViewport({ scale: 1.5 });
    const canvas = canvasRef.current;
    canvas.height = viewport.height;
    canvas.width = viewport.width;
    const ctx = canvas.getContext('2d');
    if (ctx) {
      await page.render({ canvasContext: ctx, viewport }).promise;
    }
    const frac = doc.numPages > 0 ? pageNum / doc.numPages : 0;
    setPercent(frac);
    onSaveProgress({
      book_id: book.id,
      partial_md5: book.hashes.partial_md5,
      percent: frac,
      page: pageNum,
      total_pages: doc.numPages,
      status: frac >= 0.99 ? 'finished' : 'reading',
      updated_at: Math.floor(Date.now() / 1000),
    });
  };

  const goPrev = () => {
    if (book.format === 'pdf' && pdfDocRef.current && pdfPage > 1) {
      const next = pdfPage - 1;
      pagesTurnedRef.current += 1;
      setPdfPage(next);
      renderPdfPage(pdfDocRef.current, next);
    } else {
      viewRef.current?.prev();
    }
  };

  const goNext = () => {
    if (book.format === 'pdf' && pdfDocRef.current && pdfPage < pdfTotal) {
      const next = pdfPage + 1;
      pagesTurnedRef.current += 1;
      setPdfPage(next);
      renderPdfPage(pdfDocRef.current, next);
    } else {
      viewRef.current?.next();
    }
  };

  const quickHighlight = async () => {
    const sel = window.getSelection()?.toString().trim();
    const text = sel || prompt('Enter highlight or note text:');
    if (!text) return;
    const now = Math.floor(Date.now() / 1000);
    const id = await annotationId(book.id, text, `${percent.toFixed(4)}`);
    onAddAnnotation({
      id,
      book_id: book.id,
      type: 'highlight',
      chapter: chapter || null,
      percent,
      text,
      note: null,
      color: 'yellow',
      created_at: now,
      updated_at: now,
      deleted: false,
    });
  };

  const themeBg =
    theme === 'light'
      ? 'bg-white text-slate-900'
      : theme === 'sepia'
        ? 'bg-[#f4ecd8] text-[#433422]'
        : 'bg-slate-950 text-slate-100';

  return (
    <div className={`fixed inset-0 z-40 flex flex-col ${themeBg}`}>
      <header className="flex items-center justify-between border-b border-slate-800/40 px-4 py-2.5">
        <div className="flex items-center gap-3">
          <button onClick={onClose} className="rounded-lg p-1.5 hover:bg-slate-800/30">
            <ArrowLeft className="h-5 w-5" />
          </button>
          <div>
            <h2 className="text-sm font-semibold line-clamp-1">{book.title}</h2>
            <p className="text-xs opacity-70">
              {chapter ? `${chapter} · ` : ''}
              {(percent * 100).toFixed(1)}%
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {toc.length > 0 && (
            <button onClick={() => setShowToc((s) => !s)} className="rounded-lg p-2 hover:bg-slate-800/30" title="Table of Contents">
              <List className="h-4 w-4" />
            </button>
          )}
          <button onClick={quickHighlight} className="rounded-lg p-2 hover:bg-slate-800/30" title="Save Highlight">
            <Highlighter className="h-4 w-4" />
          </button>
          <button
            onClick={() => setTheme((t) => (t === 'dark' ? 'sepia' : t === 'sepia' ? 'light' : 'dark'))}
            className="rounded-lg p-2 hover:bg-slate-800/30"
            title="Switch Reader Theme"
          >
            {theme === 'dark' ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
          </button>
        </div>
      </header>

      <div className="relative flex flex-1 overflow-hidden">
        {showToc && (
          <aside className="w-72 overflow-y-auto border-r border-slate-800/40 bg-slate-900/95 p-4 text-slate-100">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wider text-slate-400">Contents</h3>
            <ul className="space-y-1.5">
              {toc.map((item, idx) => (
                <li key={idx}>
                  <button
                    onClick={() => {
                      viewRef.current?.goTo(item.href);
                      setShowToc(false);
                    }}
                    className="w-full rounded px-2 py-1 text-left text-xs hover:bg-slate-800"
                  >
                    {item.label}
                  </button>
                </li>
              ))}
            </ul>
            {annotations.length > 0 && (
              <div className="mt-6">
                <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-slate-400">
                  Highlights ({annotations.length})
                </h4>
                <ul className="space-y-2 text-xs text-slate-300">
                  {annotations.map((a) => (
                    <li key={a.id} className="border-l-2 border-amber-400 pl-2">
                      {a.text}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </aside>
        )}

        <div className="relative flex-1 overflow-auto">
          {book.format === 'pdf' ? (
            <div className="flex justify-center p-4">
              <canvas ref={canvasRef} className="max-w-full shadow-lg" />
            </div>
          ) : (
            <div ref={containerRef} className="h-full w-full" />
          )}

          <button
            onClick={goPrev}
            className="fixed bottom-6 left-6 rounded-full bg-slate-900/80 p-3 text-slate-100 shadow-lg hover:bg-slate-800"
            title="Previous Page"
          >
            <ChevronLeft className="h-5 w-5" />
          </button>
          <button
            onClick={goNext}
            className="fixed bottom-6 right-6 rounded-full bg-slate-900/80 p-3 text-slate-100 shadow-lg hover:bg-slate-800"
            title="Next Page"
          >
            <ChevronRight className="h-5 w-5" />
          </button>
        </div>
      </div>
    </div>
  );
};

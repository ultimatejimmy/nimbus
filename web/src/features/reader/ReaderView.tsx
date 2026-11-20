import React, { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ChevronLeft, ChevronRight, Highlighter, List, Moon, Sun, Type } from 'lucide-react';
import { AnnotationRecord, BookCatalogEntry, ProgressRecord, ReadingSession } from '../../cloud/types';
import { annotationId } from '../../sync/hasher';

interface ReaderPrefs {
  theme: 'dark' | 'light' | 'sepia';
  fontFamily: 'serif' | 'sans' | 'mono' | 'publisher';
  fontSize: number;
  lineHeight: number;
  margin: 'narrow' | 'medium' | 'wide';
  flow: 'paginated' | 'scrolled';
  columns: '1' | '2' | '3';
}

const READER_PREFS_KEY = 'nimbus_reader_prefs_v1';

const DEFAULT_PREFS: ReaderPrefs = {
  theme: 'dark',
  fontFamily: 'serif',
  fontSize: 18,
  lineHeight: 1.6,
  margin: 'medium',
  flow: 'paginated',
  columns: '2',
};

function loadReaderPrefs(): ReaderPrefs {
  try {
    const raw = localStorage.getItem(READER_PREFS_KEY);
    if (raw) return { ...DEFAULT_PREFS, ...JSON.parse(raw) };
  } catch {
    // ignore
  }
  return DEFAULT_PREFS;
}

function buildReaderCss(prefs: ReaderPrefs): string {
  const palette =
    prefs.theme === 'dark'
      ? { bg: '#090d16', fg: '#e2e8f0', link: '#34d399', scheme: 'dark' }
      : prefs.theme === 'sepia'
        ? { bg: '#f4ecd8', fg: '#433422', link: '#047857', scheme: 'light' }
        : { bg: '#ffffff', fg: '#0f172a', link: '#059669', scheme: 'light' };

  const fontStack =
    prefs.fontFamily === 'serif'
      ? 'Literata, Georgia, "Times New Roman", serif'
      : prefs.fontFamily === 'sans'
        ? 'Inter, system-ui, -apple-system, sans-serif'
        : prefs.fontFamily === 'mono'
          ? 'ui-monospace, SFMono-Regular, Menlo, monospace'
          : 'inherit';

  const fontRule = prefs.fontFamily === 'publisher' ? '' : `font-family: ${fontStack} !important;`;

  return `
    :root {
      color-scheme: ${palette.scheme};
    }
    html, body {
      background-color: ${palette.bg} !important;
      color: ${palette.fg} !important;
      ${fontRule}
      font-size: ${prefs.fontSize}px !important;
      line-height: ${prefs.lineHeight} !important;
    }
    body, p, div, span, li, blockquote, h1, h2, h3, h4, h5, h6 {
      color: ${palette.fg} !important;
      background-color: transparent !important;
      ${fontRule}
      line-height: ${prefs.lineHeight} !important;
    }
    p, li, blockquote {
      font-size: ${prefs.fontSize}px !important;
    }
    a, a * {
      color: ${palette.link} !important;
    }
  `;
}

function applyRendererPrefs(view: any, prefs: ReaderPrefs) {
  const renderer = view?.renderer;
  if (!renderer) return;
  const marginMap = {
    narrow: { gap: '3%', margin: '24px', maxInline: '920px' },
    medium: { gap: '7%', margin: '48px', maxInline: '720px' },
    wide: { gap: '12%', margin: '72px', maxInline: '580px' },
  }[prefs.margin];

  renderer.setAttribute('flow', prefs.flow);
  renderer.setAttribute('gap', marginMap.gap);
  renderer.setAttribute('margin', marginMap.margin);
  renderer.setAttribute('max-inline-size', marginMap.maxInline);
  renderer.setAttribute('max-column-count', prefs.columns);
  if (typeof renderer.setStyles === 'function') {
    renderer.setStyles(buildReaderCss(prefs));
  }
}

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

  const [prefs, setPrefs] = useState<ReaderPrefs>(() => loadReaderPrefs());
  const [showAppearance, setShowAppearance] = useState(false);
  const [percent, setPercent] = useState<number>(initialProgress?.percent || 0);
  const [chapter, setChapter] = useState<string>(initialProgress?.chapter || '');
  const [toc, setToc] = useState<{ label: string; href: string }[]>([]);
  const [showToc, setShowToc] = useState(false);
  const [pdfPage, setPdfPage] = useState<number>(initialProgress?.page || 1);
  const [pdfTotal, setPdfTotal] = useState<number>(initialProgress?.total_pages || 1);
  const [loading, setLoading] = useState<boolean>(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
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
    setLoading(true);
    setErrorMsg(null);

    if (book.format === 'pdf') {
      (async () => {
        try {
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
          await renderPdfPage(doc, startPage);
        } catch (err: any) {
          if (!disposed) setErrorMsg(err?.message || 'Failed to open PDF.');
        } finally {
          if (!disposed) setLoading(false);
        }
      })();
      return () => {
        disposed = true;
      };
    }

    (async () => {
      try {
        await import('foliate-js/view.js');
        if (disposed || !containerRef.current) return;
        const view = document.createElement('foliate-view') as any;
        view.style.width = '100%';
        view.style.height = '100%';
        containerRef.current.innerHTML = '';
        containerRef.current.appendChild(view);
        viewRef.current = view;

        const file = new File([fileBlob], book.filename);
        await view.open(file);
        if (disposed) return;

        if (view.book?.toc) {
          setToc(view.book.toc.map((t: any) => ({ label: t.label, href: t.href })));
        }

        view.addEventListener('load', (e: any) => {
          const doc = e.detail?.doc as Document | undefined;
          if (doc) doc.addEventListener('keydown', handleKeyDownRef.current);
        });

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
        } else if (initialProgress?.percent && initialProgress.percent > 0) {
          await view.init({ lastLocation: { fraction: initialProgress.percent } });
        } else {
          await view.init({});
        }
        applyRendererPrefs(view, prefs);
      } catch (err: any) {
        console.error('Reader open error:', err);
        if (!disposed) setErrorMsg(err?.message || `Failed to open ${book.filename}.`);
      } finally {
        if (!disposed) setLoading(false);
      }
    })();

    return () => {
      disposed = true;
      if (viewRef.current?.close) viewRef.current.close();
    };
  }, [book.id]);

  useEffect(() => {
    try {
      localStorage.setItem(READER_PREFS_KEY, JSON.stringify(prefs));
    } catch {
      // ignore
    }
    if (viewRef.current) {
      applyRendererPrefs(viewRef.current, prefs);
    }
  }, [prefs]);

  const updatePref = <K extends keyof ReaderPrefs>(key: K, value: ReaderPrefs[K]) => {
    setPrefs((prev) => ({ ...prev, [key]: value }));
  };

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

  const goPrevRef = useRef(goPrev);
  const goNextRef = useRef(goNext);
  goPrevRef.current = goPrev;
  goNextRef.current = goNext;

  const handleKeyDownRef = useRef<(e: KeyboardEvent) => void>(() => {});
  handleKeyDownRef.current = (e: KeyboardEvent) => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    const target = e.target as HTMLElement | null;
    const tag = target?.tagName?.toLowerCase();
    if (tag === 'input' || tag === 'textarea' || target?.isContentEditable) return;

    if (e.key === 'ArrowRight') {
      e.preventDefault();
      goNextRef.current();
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      goPrevRef.current();
    } else if (e.key === ' ' || e.code === 'Space') {
      e.preventDefault();
      if (e.shiftKey) goPrevRef.current();
      else goNextRef.current();
    }
  };

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => handleKeyDownRef.current(e);
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

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
    prefs.theme === 'light'
      ? 'bg-white text-slate-900'
      : prefs.theme === 'sepia'
        ? 'bg-[#f4ecd8] text-[#433422]'
        : 'bg-[#090d16] text-slate-100';

  const pdfFilter =
    prefs.theme === 'dark'
      ? 'invert(0.92) hue-rotate(180deg)'
      : prefs.theme === 'sepia'
        ? 'sepia(0.35)'
        : 'none';

  return (
    <div className={`fixed inset-0 z-40 flex flex-col ${themeBg}`}>
      <header className="relative flex items-center justify-between border-b border-slate-500/20 px-4 py-2.5">
        <div className="flex items-center gap-3">
          <button onClick={onClose} className="rounded-lg p-1.5 hover:bg-slate-500/15">
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

        <div className="flex items-center gap-1.5">
          {toc.length > 0 && (
            <button onClick={() => setShowToc((s) => !s)} className="rounded-lg p-2 hover:bg-slate-500/15" title="Table of Contents">
              <List className="h-4 w-4" />
            </button>
          )}
          <button onClick={quickHighlight} className="rounded-lg p-2 hover:bg-slate-500/15" title="Save Highlight">
            <Highlighter className="h-4 w-4" />
          </button>
          <button
            onClick={() => setShowAppearance((s) => !s)}
            className={`rounded-lg p-2 hover:bg-slate-500/15 ${showAppearance ? 'bg-emerald-500/20 text-emerald-500' : ''}`}
            title="Reader Appearance & Typography"
          >
            <Type className="h-4 w-4" />
          </button>
          <button
            onClick={() =>
              updatePref('theme', prefs.theme === 'dark' ? 'sepia' : prefs.theme === 'sepia' ? 'light' : 'dark')
            }
            className="rounded-lg p-2 hover:bg-slate-500/15"
            title={`Theme: ${prefs.theme} (click to cycle)`}
          >
            {prefs.theme === 'dark' ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
          </button>
        </div>

        {showAppearance && (
          <div className="absolute right-4 top-14 z-30 w-72 space-y-4 rounded-xl border border-slate-700/60 bg-slate-900 p-4 text-slate-100 shadow-2xl">
            <div>
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-400">Theme</p>
              <div className="grid grid-cols-3 gap-1.5">
                {(
                  [
                    ['light', 'Light'],
                    ['sepia', 'Sepia'],
                    ['dark', 'Dark'],
                  ] as const
                ).map(([t, label]) => (
                  <button
                    key={t}
                    onClick={() => updatePref('theme', t)}
                    className={`rounded-lg border px-2 py-1.5 text-xs font-medium transition ${
                      prefs.theme === t
                        ? 'border-emerald-500 bg-emerald-500/20 text-emerald-300'
                        : 'border-slate-700 bg-slate-800/60 text-slate-300 hover:border-slate-600'
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>

            <div>
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-400">Font Style</p>
              <div className="grid grid-cols-2 gap-1.5">
                {(
                  [
                    ['serif', 'Serif'],
                    ['sans', 'Sans'],
                    ['mono', 'Mono'],
                    ['publisher', 'Publisher'],
                  ] as const
                ).map(([f, label]) => (
                  <button
                    key={f}
                    onClick={() => updatePref('fontFamily', f)}
                    className={`rounded-lg border px-2 py-1.5 text-xs font-medium transition ${
                      prefs.fontFamily === f
                        ? 'border-emerald-500 bg-emerald-500/20 text-emerald-300'
                        : 'border-slate-700 bg-slate-800/60 text-slate-300 hover:border-slate-600'
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>

            <div className="flex items-center justify-between">
              <span className="text-xs text-slate-300">Font Size</span>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => updatePref('fontSize', Math.max(12, prefs.fontSize - 2))}
                  className="rounded border border-slate-700 px-2.5 py-0.5 text-xs hover:bg-slate-800"
                >
                  A-
                </button>
                <span className="w-10 text-center text-xs font-medium">{prefs.fontSize}px</span>
                <button
                  onClick={() => updatePref('fontSize', Math.min(32, prefs.fontSize + 2))}
                  className="rounded border border-slate-700 px-2.5 py-0.5 text-xs hover:bg-slate-800"
                >
                  A+
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between">
              <span className="text-xs text-slate-300">Line Spacing</span>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => updatePref('lineHeight', Math.max(1.1, Number((prefs.lineHeight - 0.1).toFixed(1))))}
                  className="rounded border border-slate-700 px-2.5 py-0.5 text-xs hover:bg-slate-800"
                >
                  -
                </button>
                <span className="w-10 text-center text-xs font-medium">{prefs.lineHeight.toFixed(1)}</span>
                <button
                  onClick={() => updatePref('lineHeight', Math.min(2.4, Number((prefs.lineHeight + 0.1).toFixed(1))))}
                  className="rounded border border-slate-700 px-2.5 py-0.5 text-xs hover:bg-slate-800"
                >
                  +
                </button>
              </div>
            </div>

            <div>
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-400">Margins</p>
              <div className="grid grid-cols-3 gap-1.5">
                {(
                  [
                    ['narrow', 'Narrow'],
                    ['medium', 'Medium'],
                    ['wide', 'Wide'],
                  ] as const
                ).map(([m, label]) => (
                  <button
                    key={m}
                    onClick={() => updatePref('margin', m)}
                    className={`rounded-lg border px-2 py-1.5 text-xs font-medium transition ${
                      prefs.margin === m
                        ? 'border-emerald-500 bg-emerald-500/20 text-emerald-300'
                        : 'border-slate-700 bg-slate-800/60 text-slate-300 hover:border-slate-600'
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>

            <div>
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-400">Layout</p>
              <div className="grid grid-cols-2 gap-1.5">
                {(
                  [
                    ['paginated', 'Paginated'],
                    ['scrolled', 'Scrolled'],
                  ] as const
                ).map(([fl, label]) => (
                  <button
                    key={fl}
                    onClick={() => updatePref('flow', fl)}
                    className={`rounded-lg border px-2 py-1.5 text-xs font-medium transition ${
                      prefs.flow === fl
                        ? 'border-emerald-500 bg-emerald-500/20 text-emerald-300'
                        : 'border-slate-700 bg-slate-800/60 text-slate-300 hover:border-slate-600'
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>

            {prefs.flow === 'paginated' && (
              <div>
                <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-400">Columns</p>
                <div className="grid grid-cols-3 gap-1.5">
                  {(
                    [
                      ['1', '1 Col'],
                      ['2', '2 Cols'],
                      ['3', '3 Cols'],
                    ] as const
                  ).map(([col, label]) => (
                    <button
                      key={col}
                      onClick={() => updatePref('columns', col)}
                      className={`rounded-lg border px-2 py-1.5 text-xs font-medium transition ${
                        prefs.columns === col
                          ? 'border-emerald-500 bg-emerald-500/20 text-emerald-300'
                          : 'border-slate-700 bg-slate-800/60 text-slate-300 hover:border-slate-600'
                      }`}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
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
          {loading && (
            <div className="absolute inset-0 z-10 flex items-center justify-center bg-inherit/80">
              <p className="text-sm font-medium opacity-80">Opening “{book.title}”…</p>
            </div>
          )}
          {errorMsg && (
            <div className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-3 p-6 text-center">
              <p className="text-sm font-medium text-rose-500">{errorMsg}</p>
              <button
                onClick={onClose}
                className="rounded-lg bg-emerald-600 px-4 py-2 text-xs font-semibold text-white hover:bg-emerald-500"
              >
                Back to Library
              </button>
            </div>
          )}
          {book.format === 'pdf' ? (
            <div className="flex justify-center p-4">
              <canvas ref={canvasRef} style={{ filter: pdfFilter }} className="max-w-full shadow-lg" />
            </div>
          ) : (
            <div ref={containerRef} className="absolute inset-0" />
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

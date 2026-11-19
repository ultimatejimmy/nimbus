import { AnnotationRecord, BookCatalogEntry } from '../../cloud/types';

export function formatObsidianMarkdown(
  book: BookCatalogEntry,
  annotations: AnnotationRecord[],
): string {
  const active = (annotations || []).filter((a) => !a.deleted);
  const authors = (book.authors || []).map((a) => `"${a.replace(/"/g, '\\"')}"`).join(', ');
  const tags = (book.tags || []).map((t) => `"${t.replace(/"/g, '\\"')}"`).join(', ');

  const lines: string[] = [
    '---',
    `title: "${book.title.replace(/"/g, '\\"')}"`,
    `authors: [${authors}]`,
    ...(book.series ? [`series: "${book.series.replace(/"/g, '\\"')}"`] : []),
    `tags: [${tags}]`,
    `nimbus_id: "${book.id}"`,
    `exported_at: "${new Date().toISOString()}"`,
    '---',
    '',
    `# ${book.title}`,
    `*by ${(book.authors || ['Unknown']).join(', ')}*`,
    '',
  ];

  let lastChapter: string | null = null;
  for (const ann of active) {
    const ch = ann.chapter || 'Highlights';
    if (ch !== lastChapter) {
      lines.push(`## ${ch}`, '');
      lastChapter = ch;
    }
    const pct = ann.percent != null ? ` *(${(ann.percent * 100).toFixed(1)}%)*` : '';
    lines.push(`> ${ann.text.replace(/\n/g, '\n> ')}${pct}`);
    if (ann.note) {
      lines.push('', `**Note:** ${ann.note}`);
    }
    lines.push('');
  }

  return lines.join('\n');
}

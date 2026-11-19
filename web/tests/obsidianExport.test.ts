import { describe, expect, it } from 'vitest';
import { formatObsidianMarkdown } from '../src/features/highlights/obsidianExport';

describe('Obsidian Markdown exporter', () => {
  it('renders YAML frontmatter, chapter headings, blockquotes, and notes', () => {
    const md = formatObsidianMarkdown(
      {
        id: 'a1b2c3d4',
        title: 'Mistborn',
        authors: ['Brandon Sanderson'],
        series: 'Mistborn',
        tags: ['Fantasy'],
        folder: 'Books/Mistborn',
        filename: 'Mistborn.epub',
        format: 'epub',
        size_bytes: 1000,
        has_cover: false,
        hashes: { partial_md5: 'd41d8cd98f00b204e9800998ecf8427e' },
        added_at: '2026-11-19T00:00:00Z',
        updated_at: '2026-11-19T00:00:00Z',
      },
      [
        {
          id: 'ann_1',
          book_id: 'a1b2c3d4',
          type: 'highlight',
          chapter: 'Chapter 1',
          percent: 0.1,
          text: "There's always another secret.",
          note: 'Classic quote',
          created_at: 1,
          updated_at: 1,
          deleted: false,
        },
        {
          id: 'ann_2',
          book_id: 'a1b2c3d4',
          type: 'highlight',
          text: 'Deleted highlight',
          created_at: 2,
          updated_at: 3,
          deleted: true,
        },
      ],
    );

    expect(md).toContain('title: "Mistborn"');
    expect(md).toContain('## Chapter 1');
    expect(md).toContain("> There's always another secret.");
    expect(md).toContain('**Note:** Classic quote');
    expect(md).not.toContain('Deleted highlight');
  });
});

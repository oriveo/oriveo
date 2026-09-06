import { describe, expect, it } from 'vitest';
import {
  assertArchiveWithinBudget,
  ATTACHMENT_ARCHIVE_BUDGET,
  BoundedArchiveReader,
} from '../zip-budget';
import { ExtractionError } from '../../core/attachments/file-text-extractor';

/** A JSZip-shaped entry: `_data.uncompressedSize` is what the central directory declares. */
function entry(name: string, options: { declared?: number; text?: string; dir?: boolean } = {}) {
  return {
    name,
    dir: options.dir ?? false,
    _data: options.declared === undefined ? undefined : { uncompressedSize: options.declared },
    async: async () => options.text ?? '',
  };
}

function filesOf(...entries: ReturnType<typeof entry>[]) {
  return Object.fromEntries(entries.map((item) => [item.name, item]));
}

describe('assertArchiveWithinBudget', () => {
  it('accepts an ordinary document', () => {
    expect(() => assertArchiveWithinBudget(filesOf(
      entry('word/', { dir: true }),
      entry('word/document.xml', { declared: 40_000 }),
    ))).not.toThrow();
  });

  // The classic zip bomb: a few kilobytes on disk declaring gigabytes of output. Refusing it from
  // the central directory alone means not a byte is decompressed.
  it('refuses an entry that declares more than the entry budget', () => {
    expect(() => assertArchiveWithinBudget(filesOf(
      entry('word/document.xml', { declared: ATTACHMENT_ARCHIVE_BUDGET.maxEntryBytes + 1 }),
    ))).toThrow(ExtractionError);
  });

  it('refuses many entries that only exceed the budget in total', () => {
    const each = ATTACHMENT_ARCHIVE_BUDGET.maxEntryBytes;
    const count = Math.ceil(ATTACHMENT_ARCHIVE_BUDGET.maxTotalBytes / each) + 1;
    const entries = Array.from({ length: count }, (_, index) => entry(`ppt/slides/slide${index}.xml`, { declared: each }));
    expect(() => assertArchiveWithinBudget(filesOf(...entries))).toThrow(ExtractionError);
  });

  it('refuses an archive with more entries than the budget allows', () => {
    const entries = Array.from(
      { length: ATTACHMENT_ARCHIVE_BUDGET.maxEntries + 1 },
      (_, index) => entry(`chapter-${index}.xhtml`, { declared: 1 }),
    );
    expect(() => assertArchiveWithinBudget(filesOf(...entries))).toThrow(ExtractionError);
  });

  it('reports an oversized archive as too large rather than as corrupted', () => {
    try {
      assertArchiveWithinBudget(filesOf(entry('content.xml', { declared: 1024 ** 4 })));
      expect.unreachable('expected the archive to be refused');
    } catch (error) {
      expect(error).toBeInstanceOf(ExtractionError);
      expect((error as ExtractionError).code).toBe('file_too_large');
    }
  });
});

describe('BoundedArchiveReader', () => {
  const budget = { maxEntryBytes: 100, maxTotalBytes: 150, maxEntries: 8 };

  it('reads entries that stay inside the budget', async () => {
    const reader = new BoundedArchiveReader(budget);
    await expect(reader.readText(entry('a.xml', { declared: 10, text: 'a'.repeat(10) }))).resolves.toBe('a'.repeat(10));
  });

  // A declared size is part of the archive, so it can understate the truth. Whatever actually comes
  // out has to be measured too, or the up-front check is trivially bypassed.
  it('refuses an entry that expands past the budget while declaring that it will not', async () => {
    const reader = new BoundedArchiveReader(budget);
    await expect(reader.readText(entry('a.xml', { declared: 1, text: 'a'.repeat(101) })))
      .rejects.toThrow(ExtractionError);
  });

  it('holds one running total across the whole archive', async () => {
    const reader = new BoundedArchiveReader(budget);
    await reader.readText(entry('a.xml', { declared: 90, text: 'a'.repeat(90) }));
    await expect(reader.readText(entry('b.xml', { declared: 90, text: 'b'.repeat(90) })))
      .rejects.toThrow(ExtractionError);
  });
});

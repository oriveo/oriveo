import { describe, it, expect } from 'vitest';
import { FileTextExtractor, resolveFileExtractionLimits, DEFAULT_LIMITS, type FileExtractionLimits } from '../file-text-extractor';

describe('FileTextExtractor.truncate', () => {
  it('does not truncate small input', () => {
    const lines = Array.from({ length: 100 }, (_, i) => `line ${i + 1}`);
    const raw = lines.join('\n');
    const r = FileTextExtractor.truncate(raw, raw.length);
    expect(r.truncated).toBe(false);
    expect(r.totalLines).toBe(100);
    expect(r.content).toBe(raw);
  });

  it('truncates by lines (500 cap)', () => {
    const raw = Array.from({ length: 700 }, (_, i) => `L${i + 1}`).join('\n');
    const r = FileTextExtractor.truncate(raw, raw.length);
    expect(r.truncated).toBe(true);
    expect(r.truncationReason).toBe('lines');
    expect(r.totalLines).toBe(700);
    expect(r.content.split('\n').length).toBe(500);
  });

  // Bisecting by whole lines yields empty content when not even one line fits; it cuts inside the line at a UTF-8 character boundary instead.
  it('a single line over the byte cap: keeps the start instead of truncating to empty content', () => {
    const raw = 'a'.repeat(DEFAULT_LIMITS.maxBytes + 100);
    const r = FileTextExtractor.truncate(raw, raw.length);
    expect(r.truncated).toBe(true);
    expect(r.truncationReason).toBe('bytes');
    expect(r.totalLines).toBe(1);
    expect(r.content).toBe('a'.repeat(DEFAULT_LIMITS.maxBytes));
  });

  it('the in-line hard cut never splits a multi-byte character', () => {
    const limits: FileExtractionLimits = { ...DEFAULT_LIMITS, maxBytes: 10 };
    // Each CJK character is 3 bytes: 10 bytes hold 3 whole characters (9 bytes), and the 4th cannot be cut in half
    const r = FileTextExtractor.truncate('\u4e2d\u6587\u5b57\u7b26\u622a\u65ad', 18, limits);
    expect(r.content).toBe('\u4e2d\u6587\u5b57');
    expect(r.truncated).toBe(true);
    // A 4-byte emoji works the same way
    expect(FileTextExtractor.truncate('ab😀😀😀', 14, { ...DEFAULT_LIMITS, maxBytes: 7 }).content).toBe('ab😀');
  });

  it('the first line does not fit and more lines follow: the start of the first line is kept as well', () => {
    const limits: FileExtractionLimits = { ...DEFAULT_LIMITS, maxBytes: 8 };
    const r = FileTextExtractor.truncate('0123456789\nsecond', 17, limits);
    expect(r.content).toBe('01234567');
    expect(r.totalLines).toBe(2);
    expect(r.truncated).toBe(true);
  });

  it('truncates by bytes (100KB cap)', () => {
    const big = 'a'.repeat(5000);
    const raw = Array.from({ length: 50 }, () => big).join('\n');
    const r = FileTextExtractor.truncate(raw, raw.length);
    expect(r.truncated).toBe(true);
    const bytes = new TextEncoder().encode(r.content).byteLength;
    expect(bytes).toBeLessThanOrEqual(DEFAULT_LIMITS.maxBytes);
  });

  it('respects custom limits', () => {
    const customLimits: FileExtractionLimits = { ...DEFAULT_LIMITS, maxLines: 10 };
    const raw = Array.from({ length: 20 }, (_, i) => `L${i + 1}`).join('\n');
    const r = FileTextExtractor.truncate(raw, raw.length, customLimits);
    expect(r.truncated).toBe(true);
    expect(r.content.split('\n').length).toBe(10);
  });
});

describe('resolveFileExtractionLimits', () => {
  it('returns DEFAULT_LIMITS for null model', () => {
    const r = resolveFileExtractionLimits(null);
    expect(r).toEqual(DEFAULT_LIMITS);
  });

  it('returns DEFAULT_LIMITS for model without attachmentExtraction', () => {
    const r = resolveFileExtractionLimits({ capabilities: ['text'] });
    expect(r).toEqual(DEFAULT_LIMITS);
  });

  it('overrides specific fields from model.attachmentExtraction', () => {
    const r = resolveFileExtractionLimits({
      attachmentExtraction: { maxLines: 2000, maxBytes: 400_000 },
    });
    expect(r.maxLines).toBe(2000);
    expect(r.maxBytes).toBe(400_000);
    expect(r.totalCap).toBe(DEFAULT_LIMITS.totalCap); // not overridden
    expect(r.maxFiles).toBe(3); // maxAttachments not delivered
  });

  // The count cap accepts the model's maxAttachments; a missing or invalid value gives 3.
  it('maxFiles accepts the maxAttachments delivered by the model and is 3 when absent', () => {
    expect(resolveFileExtractionLimits({ attachmentExtraction: { maxAttachments: 5 } }).maxFiles).toBe(5);
    expect(resolveFileExtractionLimits({ attachmentExtraction: { maxAttachments: 2 } }).maxFiles).toBe(2);
    expect(resolveFileExtractionLimits({ attachmentExtraction: { totalCap: 1 } }).maxFiles).toBe(3);
    expect(resolveFileExtractionLimits(undefined).maxFiles).toBe(3);
    for (const bad of [0, -1, 2.5, Number.NaN]) {
      expect(resolveFileExtractionLimits({ attachmentExtraction: { maxAttachments: bad } }).maxFiles).toBe(3);
    }
  });
});

describe('FileTextExtractor.textExtensions', () => {
  it('includes code file extensions', () => {
    expect(FileTextExtractor.textExtensions.has('ts')).toBe(true);
    expect(FileTextExtractor.textExtensions.has('py')).toBe(true);
    expect(FileTextExtractor.textExtensions.has('go')).toBe(true);
  });
});

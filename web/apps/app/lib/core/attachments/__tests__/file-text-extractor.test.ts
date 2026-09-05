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
    expect(r.maxFiles).toBe(3); // always DEFAULT
  });

  it('maxFiles is always 3 regardless of model override', () => {
    // maxFiles is a business invariant, not overrideable
    const r = resolveFileExtractionLimits({ attachmentExtraction: { maxLines: 5000 } });
    expect(r.maxFiles).toBe(3);
  });
});

describe('FileTextExtractor.textExtensions', () => {
  it('includes code file extensions', () => {
    expect(FileTextExtractor.textExtensions.has('ts')).toBe(true);
    expect(FileTextExtractor.textExtensions.has('py')).toBe(true);
    expect(FileTextExtractor.textExtensions.has('go')).toBe(true);
  });
});

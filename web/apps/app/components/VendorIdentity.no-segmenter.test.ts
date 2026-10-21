// @vitest-environment jsdom
/**
 * Regression: Mobile Safari 16.6 has no Intl.Segmenter, and a top-level `new` in VendorIdentity made the chat chunk throw on evaluation.
 * The result with a Segmenter (including hi / th combining marks) is locked by the RL2-MONOGRAM-01 case in relay-r8-web-b.test.tsx.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Mimic real old Safari: Intl has no Segmenter key at all (`'Segmenter' in Intl` is false); other members stay.
const intlWithoutSegmenter = Object.fromEntries(
  Object.getOwnPropertyNames(Intl)
    .filter((key) => key !== 'Segmenter')
    .map((key) => [key, (Intl as unknown as Record<string, unknown>)[key]]),
) as typeof Intl;

describe('VendorIdentity without Intl.Segmenter', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.stubGlobal('Intl', intlWithoutSegmenter);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  it('imports without throwing and the monogram falls back to code points', async () => {
    const mod = await import('./VendorIdentity');
    expect(mod.vendorMonogram('Other')).toBe('OT');
    expect(mod.vendorMonogram('\u305d\u306e\u4ed6')).toBe('\u305d\u306e');
    expect(mod.vendorMonogram('Totally Unknown')).toBe('TU');
    expect(mod.vendorMonogram('')).toBe('AI');
  });

  it('summary quote tail truncation still works in the fallback', async () => {
    const { buildSummaryQuote } = await import('../lib/core/chat/context-compaction/context-compaction-actions');
    const row = { summary: `HEAD${'s'.repeat(9000)}`, userMessageIds: [], coversTo: 'm-1' } as unknown as Parameters<typeof buildSummaryQuote>[0];
    const quote = buildSummaryQuote(row, 'Label', []);
    expect(quote?.selectedText.startsWith('HEAD')).toBe(true);
    expect(quote?.contextTruncated).toBe(true);
    expect(Array.from(`Label${quote?.selectedText}`).length).toBe(8000);
  });
});

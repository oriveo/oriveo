import { describe, expect, it } from 'vitest';
import { selectionAskElapsedBucket, selectionAskTelemetryProperties } from './quote-telemetry';

const quoteContext = {
  schemaVersion: 1 as const,
  sourceMessageId: 'must-not-leak',
  sourceRole: 'assistant' as const,
  contentKind: 'formula-that-falls-back' as never,
  leadingText: 'private before',
  selectedText: 'private selected',
  trailingText: 'private after',
  contextTruncated: false,
};

describe('selection Ask telemetry privacy', () => {
  it('includes only structural role/kind properties and no body, id, length, or exact time', () => {
    const properties = selectionAskTelemetryProperties(quoteContext);
    expect(properties).toEqual({ source_role: 'assistant', content_kind: 'formula-that-falls-back' });
    expect(JSON.stringify(properties)).not.toMatch(/private|must-not-leak|length|elapsed_ms/);
  });

  it.each([
    [0, 'under_5s'],
    [4_999, 'under_5s'],
    [5_000, '5_to_29s'],
    [30_000, '30_to_119s'],
    [120_000, '120s_or_more'],
  ])('buckets %i ms without exposing exact elapsed time', (elapsed, expected) => {
    expect(selectionAskElapsedBucket(elapsed)).toBe(expected);
  });
});

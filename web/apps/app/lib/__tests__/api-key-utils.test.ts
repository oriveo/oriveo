import { describe, it, expect } from 'vitest';
import { formatApiKeyPreview } from '@oriveo/shared';

describe('formatApiKeyPreview', () => {
  it('formats a standard-length key as 4 characters, an ellipsis, then 4 characters', () => {
    expect(formatApiKeyPreview('sk-abc123def456xyz7890')).toBe('sk-a...7890');
  });

  it('does the same for a long key', () => {
    expect(formatApiKeyPreview('sk-ant-api03-abcdefghijklmnopqrstuvwxyz')).toBe('sk-a...wxyz');
  });

  it('fully masks a key of 12 characters or fewer', () => {
    expect(formatApiKeyPreview('short')).toBe('••••••••');
    expect(formatApiKeyPreview('exactly12chr')).toBe('••••••••');
  });

  it('uses the 4 plus 4 form at exactly 13 characters', () => {
    expect(formatApiKeyPreview('1234567890abc')).toBe('1234...0abc');
  });

  it('trims leading and trailing whitespace', () => {
    expect(formatApiKeyPreview('  sk-abc123def456xyz7890  ')).toBe('sk-a...7890');
  });

  // The absence of a key must not render as a masked preview: that would draw dots for a key that
  // does not exist. Only the credential state machine expresses "not set" or "no key required".
  it('returns an empty string for an empty or all-whitespace input', () => {
    expect(formatApiKeyPreview('')).toBe('');
    expect(formatApiKeyPreview('   ')).toBe('');
  });

  it('never reveals more than 8 characters after masking', () => {
    const key = 'sk-proj-0123456789abcdefghij';
    const preview = formatApiKeyPreview(key);
    const revealed = preview.replace('...', '');
    expect(revealed.length).toBe(8);
    expect(key).toContain(revealed.slice(0, 4));
  });
});

import { describe, expect, it } from 'vitest';

import { matchModelById } from './model-matching';

describe('matchModelById', () => {
  it('matches by id (case-insensitive)', () => {
    expect(matchModelById({ id: 'gpt-4o' }, 'GPT-4o')).toBe(true);
    expect(matchModelById({ id: 'GPT-4o' }, 'gpt-4o')).toBe(true);
  });

  it('matches by canonicalModelId when id differs', () => {
    expect(
      matchModelById({ id: 'custom-alias', canonicalModelId: 'gpt-4o' }, 'GPT-4o'),
    ).toBe(true);
  });

  it('falls back to false when neither matches', () => {
    expect(matchModelById({ id: 'gpt-4o' }, 'claude-3-opus')).toBe(false);
    expect(
      matchModelById({ id: 'a', canonicalModelId: 'b' }, 'c'),
    ).toBe(false);
  });

  it('trims target whitespace', () => {
    expect(matchModelById({ id: 'gpt-4o' }, '   gpt-4o  ')).toBe(true);
  });

  it('returns false on empty / null / undefined target', () => {
    expect(matchModelById({ id: 'gpt-4o' }, '')).toBe(false);
    expect(matchModelById({ id: 'gpt-4o' }, null)).toBe(false);
    expect(matchModelById({ id: 'gpt-4o' }, undefined)).toBe(false);
    expect(matchModelById({ id: 'gpt-4o' }, '   ')).toBe(false);
  });
});

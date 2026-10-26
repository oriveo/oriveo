import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { consumeModelRetiredHint } from '../model-retired-hint';

const STORAGE_KEY = 'oriveo.model-retired-hint-seen.v1';

describe('consumeModelRetiredHint', () => {
  beforeEach(() => localStorage.removeItem(STORAGE_KEY));
  afterEach(() => localStorage.removeItem(STORAGE_KEY));

  it('the same provider + model is hinted only once per device', () => {
    expect(consumeModelRetiredHint('openai', 'gpt-4o', 'last_used_retired')).toBe(true);
    expect(consumeModelRetiredHint('openai', 'gpt-4o', 'last_used_retired')).toBe(false);
    expect(JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]')).toEqual(['openai|gpt-4o']);
  });

  it('hints again after switching model or connection', () => {
    expect(consumeModelRetiredHint('openai', 'gpt-4o', 'last_used_retired')).toBe(true);
    expect(consumeModelRetiredHint('openai', 'gpt-4.1', 'last_used_retired')).toBe(true);
    expect(consumeModelRetiredHint('anthropic', 'gpt-4o', 'last_used_retired')).toBe(true);
  });

  it('with no fallback marker or a missing id, nothing is hinted or recorded', () => {
    expect(consumeModelRetiredHint('openai', 'gpt-4o', null)).toBe(false);
    expect(consumeModelRetiredHint(null, 'gpt-4o', 'last_used_retired')).toBe(false);
    expect(consumeModelRetiredHint('openai', undefined, 'last_used_retired')).toBe(false);
    expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
  });
});

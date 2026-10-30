import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  FEATURE_BADGES_SEEN_KEY,
  FEATURE_BADGE_IDS,
  REGISTERED_FEATURE_BADGE_IDS,
  isUnseen,
  markSeen,
} from '../feature-badges';
import { safeLocalStorage } from '../../infra/storage/web-storage';

const repositoryRoot = resolve(process.cwd(), '../../..');
const registry = JSON.parse(
  readFileSync(resolve(repositoryRoot, 'shared/ui-contracts/feature-badges.v1.json'), 'utf8'),
) as { badges: Array<{ id: string }> };

const memoryId = FEATURE_BADGE_IDS.settingsMemory;

describe('feature-badges', () => {
  beforeEach(() => {
    window.localStorage.clear();
    safeLocalStorage.resetForTest();
  });

  it('constants match the shared registry ids one by one', () => {
    expect([...REGISTERED_FEATURE_BADGE_IDS]).toEqual(registry.badges.map((badge) => badge.id));
  });

  it('shows the red dot by default (new user)', () => {
    expect(isUnseen(memoryId)).toBe(true);
  });

  it('hides the dot after markSeen, and still hides it after reading the storage again', () => {
    markSeen(memoryId);
    expect(isUnseen(memoryId)).toBe(false);
    expect(JSON.parse(window.localStorage.getItem(FEATURE_BADGES_SEEN_KEY) ?? '[]')).toEqual([memoryId]);
    safeLocalStorage.resetForTest();
    expect(isUnseen(memoryId)).toBe(false);
  });

  it('the web search entry dot is independent of memory: each is marked seen on its own', () => {
    const webSearchId = FEATURE_BADGE_IDS.settingsWebSearch;
    expect(webSearchId).toBe('settings.webSearch.2026-10');
    markSeen(webSearchId);
    expect(isUnseen(webSearchId)).toBe(false);
    expect(isUnseen(memoryId)).toBe(true);
  });

  it('drops unregistered ids on read and write', () => {
    window.localStorage.setItem(FEATURE_BADGES_SEEN_KEY, JSON.stringify(['settings.memory.2025-01', memoryId]));
    expect(isUnseen(memoryId)).toBe(false);
    expect(JSON.parse(window.localStorage.getItem(FEATURE_BADGES_SEEN_KEY) ?? '[]')).toEqual([memoryId]);
  });

  describe('storage unavailable', () => {
    let original: PropertyDescriptor | undefined;
    beforeEach(() => {
      original = Object.getOwnPropertyDescriptor(window, 'localStorage');
      Object.defineProperty(window, 'localStorage', {
        configurable: true,
        get() {
          const error = new Error('denied');
          error.name = 'SecurityError';
          throw error;
        },
      });
      safeLocalStorage.resetForTest();
    });
    afterEach(() => {
      if (original) Object.defineProperty(window, 'localStorage', original);
      safeLocalStorage.resetForTest();
    });

    it('shows no red dot and does not throw', () => {
      expect(() => markSeen(memoryId)).not.toThrow();
      expect(isUnseen(memoryId)).toBe(false);
    });
  });
});

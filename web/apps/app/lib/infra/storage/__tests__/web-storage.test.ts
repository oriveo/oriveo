/**
 * @vitest-environment jsdom
 *
 * Tests for the secure storage facade.
 *
 * The core fact under test: when the browser has site data disabled, the `window.localStorage`
 * property getter itself throws SecurityError, not getItem. That is what makes guards such as
 * `typeof localStorage` useless and what blew up the first step of bootstrap in production.
 * The mocks here therefore patch the getter rather than swapping in a fake object with throwing
 * methods.
 */

import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  safeLocalStorage,
  estimateLocalStorageUsage,
  LOCAL_STORAGE_MAX_ITEM_CHARS,
} from '../web-storage';

// The @sentry/nextjs exports cannot be redefined, so the whole module is mocked, matching the existing convention in this repo
const { mockCaptureMessage } = vi.hoisted(() => ({ mockCaptureMessage: vi.fn() }));
vi.mock('@sentry/nextjs', () => ({
  captureMessage: (...args: unknown[]) => mockCaptureMessage(...args),
  withScope: (fn: (scope: unknown) => void) => fn({
    setTag: () => {}, setContext: () => {}, setLevel: () => {},
  }),
}));

const realDescriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');

/** Makes the `window.localStorage` getter throw a given error, reproducing the real browser refusal. */
function denyLocalStorage(error: Error) {
  Object.defineProperty(window, 'localStorage', {
    configurable: true,
    get() {
      throw error;
    },
  });
}

function restore() {
  if (realDescriptor) Object.defineProperty(window, 'localStorage', realDescriptor);
  safeLocalStorage.resetForTest();
}

afterEach(() => {
  restore();
  try {
    window.localStorage.clear();
  } catch {
    /* Ignore if it was already restored */
  }
});

describe('safeLocalStorage', () => {
  it('reads and writes match native storage in a normal environment', () => {
    expect(safeLocalStorage.setItem('k', 'v')).toBe(true);
    expect(safeLocalStorage.getItem('k')).toBe('v');
    expect(safeLocalStorage.keys()).toContain('k');
    expect(safeLocalStorage.removeItem('k')).toBe(true);
    expect(safeLocalStorage.getItem('k')).toBeNull();
    expect(safeLocalStorage.availability()).toBe('available');
  });

  it('degrades every operation without throwing when the getter raises SecurityError', () => {
    const error = new Error('Failed to read the \'localStorage\' property from \'Window\'');
    error.name = 'SecurityError';
    denyLocalStorage(error);
    safeLocalStorage.resetForTest();

    // Each of these four calls used to blow the call stack
    expect(() => safeLocalStorage.getItem('k')).not.toThrow();
    expect(safeLocalStorage.getItem('k')).toBeNull();
    expect(safeLocalStorage.setItem('k', 'v')).toBe(false);
    expect(safeLocalStorage.removeItem('k')).toBe(false);
    expect(safeLocalStorage.keys()).toEqual([]);

    expect(safeLocalStorage.availability()).toBe('denied');
    expect(safeLocalStorage.lastWriteFailure()).toBe('denied');
    expect(estimateLocalStorageUsage()).toBeNull();
  });

  it('a full quota still counts as available, because reads are fine and the fallback differs from a denial', () => {
    const quota = new Error('exceeded the quota');
    quota.name = 'QuotaExceededError';
    Object.defineProperty(window, 'localStorage', {
      configurable: true,
      value: {
        getItem: () => 'existing',
        setItem: () => { throw quota; },
        removeItem: () => {},
        key: () => null,
        length: 0,
        clear: () => {},
      } as unknown as Storage,
    });
    safeLocalStorage.resetForTest();

    expect(safeLocalStorage.availability()).toBe('available');
    expect(safeLocalStorage.setItem('k', 'v')).toBe(false);
    expect(safeLocalStorage.lastWriteFailure()).toBe('quota');
    // The key difference: reads still work, so cached data stays usable and no site-wide degraded banner is warranted
    expect(safeLocalStorage.getItem('k')).toBe('existing');
  });

  it('usage is estimated in UTF-16 code units, matching the Chrome quota accounting', () => {
    window.localStorage.clear();
    safeLocalStorage.resetForTest();
    safeLocalStorage.setItem('ab', 'cde');
    // key 2 + value 3
    expect(estimateLocalStorageUsage()).toBe(5);
  });

  it('rejects a single key above the 64KB limit without touching the underlying storage and reports once to Sentry', () => {
    mockCaptureMessage.mockReset();
    const oversized = 'x'.repeat(LOCAL_STORAGE_MAX_ITEM_CHARS);
    expect(safeLocalStorage.setItem('big', oversized)).toBe(false);
    expect(safeLocalStorage.lastWriteFailure()).toBe('oversize');
    // The rejection has to happen before the underlying storage is touched; the whole point of the limit is to keep this data out of the shared 5MB pool
    expect(window.localStorage.getItem('big')).toBeNull();
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.oversize_write_rejected');
  });

  it('reports an over-limit write once per session for the same key family, since callers usually retry unchanged', () => {
    mockCaptureMessage.mockReset();
    const oversized = 'x'.repeat(LOCAL_STORAGE_MAX_ITEM_CHARS);
    safeLocalStorage.setItem('dup', oversized);
    safeLocalStorage.setItem('dup', oversized);
    expect(mockCaptureMessage).toHaveBeenCalledTimes(1);
  });

  it('a write exactly at the limit still succeeds', () => {
    const key = 'edge';
    const fitting = 'x'.repeat(LOCAL_STORAGE_MAX_ITEM_CHARS - key.length);
    expect(safeLocalStorage.setItem(key, fitting)).toBe(true);
    expect(safeLocalStorage.lastWriteFailure()).toBeNull();
    safeLocalStorage.removeItem(key);
  });

  it('a successful write clears the previous failure reason', () => {
    const quota = new Error('quota');
    quota.name = 'QuotaExceededError';
    let failNext = true;
    const real = new Map<string, string>();
    Object.defineProperty(window, 'localStorage', {
      configurable: true,
      value: {
        getItem: (k: string) => real.get(k) ?? null,
        setItem: (k: string, v: string) => {
          if (failNext) throw quota;
          real.set(k, v);
        },
        removeItem: (k: string) => { real.delete(k); },
        key: () => null,
        length: 0,
        clear: () => real.clear(),
      } as unknown as Storage,
    });
    safeLocalStorage.resetForTest();

    expect(safeLocalStorage.setItem('k', 'v')).toBe(false);
    expect(safeLocalStorage.lastWriteFailure()).toBe('quota');
    failNext = false;
    expect(safeLocalStorage.setItem('k', 'v')).toBe(true);
    expect(safeLocalStorage.lastWriteFailure()).toBeNull();
  });
});

import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Storage health probing and reporting.
 *
 * This path exists for visibility: blocked storage used to be completely silent in
 * production, with a single console.error and nothing in Sentry, and the failed startup was
 * only noticed through an unhandledrejection escaping from an unrelated SDK. So these
 * assertions are not about probing accurately, but about always raising a correctly graded
 * signal once something is detected.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  detectStorageHealth,
  reportStorageHealth,
  __resetStorageHealthForTest,
} from '../storage-health';
import { safeLocalStorage, LOCAL_STORAGE_QUOTA_CHARS } from '../../infra/storage/web-storage';

// The @sentry/nextjs exports cannot be redefined, so the whole module is mocked, matching the existing convention in this repo
const { mockCaptureMessage, mockSetContext } = vi.hoisted(() => ({
  mockCaptureMessage: vi.fn(),
  mockSetContext: vi.fn(),
}));
vi.mock('@sentry/nextjs', () => ({
  captureMessage: (...args: unknown[]) => mockCaptureMessage(...args),
  withScope: (fn: (scope: unknown) => void) => fn({
    setTag: () => {}, setContext: (...args: unknown[]) => mockSetContext(...args), setLevel: () => {},
  }),
}));

/** Read the `storage` context this report wrote into the scope. */
function reportedStorageContext(): Record<string, unknown> {
  const call = mockSetContext.mock.calls.find(([name]) => name === 'storage');
  if (!call) throw new Error('storage context was never set');
  return call[1] as Record<string, unknown>;
}

const realIDB = globalThis.indexedDB;

beforeEach(() => {
  __resetStorageHealthForTest();
  safeLocalStorage.resetForTest();
  mockCaptureMessage.mockReset();
  mockSetContext.mockReset();
  localStorage.clear();
});

afterEach(() => {
  Object.defineProperty(globalThis, 'indexedDB', { configurable: true, value: realIDB });
  __resetStorageHealthForTest();
  safeLocalStorage.resetForTest();
  vi.restoreAllMocks();
  localStorage.clear();
});

function denyIndexedDB() {
  Object.defineProperty(globalThis, 'indexedDB', {
    configurable: true,
    value: {
      open() {
        throw new DOMException('The user denied permission to access the database.', 'UnknownError');
      },
    },
  });
}

describe('detectStorageHealth', () => {
  it('reports both media available and persistent true in a healthy environment', async () => {
    const health = await detectStorageHealth();
    expect(health.local).toBe('available');
    expect(health.indexedDB).toBe('available');
    expect(health.persistent).toBe(true);
  });

  it('reports persistent false when IndexedDB is denied, which is the test for nothing being storable locally', async () => {
    denyIndexedDB();
    const health = await detectStorageHealth();
    expect(health.indexedDB).toBe('denied');
    expect(health.persistent).toBe(false);
  });

  it('reports timeout rather than denied on a probe timeout, so a busy IDB is not passed off as a rejection', async () => {
    vi.useFakeTimers();
    try {
      Object.defineProperty(globalThis, 'indexedDB', {
        configurable: true,
        // open returns a request that never fires any callback, simulating an IDB overwhelmed by a write storm
        value: { open: () => ({}) },
      });
      const pending = detectStorageHealth();
      await vi.advanceTimersByTimeAsync(3000);
      const health = await pending;
      expect(health.indexedDB).toBe('timeout');
      expect(health.persistent).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it('probes only once per session, since storage permission does not change mid-session', async () => {
    const first = await detectStorageHealth();
    denyIndexedDB();
    const second = await detectStorageHealth();
    expect(second).toBe(first);
  });
});

describe('reportStorageHealth', () => {
  it('sends an error-level captureMessage when persistence is unavailable', () => {
    reportStorageHealth({
      local: 'denied', indexedDB: 'denied', localUsage: 0, persistent: false,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.persistence_unavailable');
  });

  it('sends a probe timeout as its own warning signal rather than as a denied error', () => {
    reportStorageHealth({
      local: 'available', indexedDB: 'timeout', localUsage: 0, persistent: false,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.persistence_probe_timeout');
    expect(mockCaptureMessage).not.toHaveBeenCalledWith('storage.persistence_unavailable');
  });

  it('sends a warning when IDB still works and only localStorage is gone, without inflating it into an incident', () => {
    reportStorageHealth({
      local: 'denied', indexedDB: 'available', localUsage: null, persistent: true,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.local_unavailable');
  });

  it('reports pressure once localStorage passes 60% of its quota, which precedes the sync queue filling up', () => {
    reportStorageHealth({
      local: 'available',
      indexedDB: 'available',
      // This is the order of magnitude seen in production: a 3.3MB metadata snapshot taking 66%
      localUsage: Math.floor(LOCAL_STORAGE_QUOTA_CHARS * 0.66),
      persistent: true,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.local_pressure');
  });

  it('stays quiet when everything is fine', () => {
    reportStorageHealth({
      local: 'available', indexedDB: 'available', localUsage: 1024, persistent: true,
    });
    expect(mockCaptureMessage).not.toHaveBeenCalled();
  });

  it('reports at most once per session instead of flooding', () => {
    const bad = { local: 'denied', indexedDB: 'denied', localUsage: 0, persistent: false } as const;
    reportStorageHealth(bad);
    reportStorageHealth(bad);
    reportStorageHealth(bad);
    expect(mockCaptureMessage).toHaveBeenCalledTimes(1);
  });
});

/**
 * Regression: the alert has to say who ate the quota.
 *
 * Observed in production (2026-08-29, 10 events): `localUsageRatio 0.657` with
 * `topGroups: ["[Object]", "[Object]", "[Object]", "[Object]", "[Object]"]`. The only field
 * that identifies the culprit was swallowed whole by Sentry's `normalizeDepth` (default 3),
 * since `contexts.storage.topGroups[i]` sits exactly at level 4.
 */
describe('actionable context on storage.local_pressure', () => {
  it('keeps topGroups an array of strings, not flattened to "[Object]" by normalizeDepth, carrying group name, character count and key count', async () => {
    localStorage.setItem('vendor_mutations_pfx_37289_uid', 'x'.repeat(3_400_000));
    await detectStorageHealth();
    reportStorageHealth({
      local: 'available',
      indexedDB: 'available',
      localUsage: Math.round(LOCAL_STORAGE_QUOTA_CHARS * 0.66),
      persistent: true,
    });

    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.local_pressure');
    const topGroups = reportedStorageContext()['topGroups'] as unknown[];
    expect(topGroups.every((entry) => typeof entry === 'string')).toBe(true);
    expect(topGroups.join('|')).not.toContain('[Object]');
    // batchId is already normalized (`\d{3,}` becomes <n>) and the group name is still recognizable
    expect(topGroups[0]).toContain('vendor_mutations_pfx_<n>_uid');
    expect(topGroups[0]).toMatch(/\d+ chars/);
    expect(topGroups[0]).toMatch(/\d+ keys/);
  });

  it('never puts a user e-mail address in a key group: the providersUsageSummary suffix is a real e-mail key', async () => {
    localStorage.setItem('oriveo.providersUsageSummary.someone@example.com', 'y'.repeat(4_000_000));
    await detectStorageHealth();
    reportStorageHealth({
      local: 'available',
      indexedDB: 'available',
      localUsage: Math.round(LOCAL_STORAGE_QUOTA_CHARS * 0.8),
      persistent: true,
    });

    const serialized = JSON.stringify(reportedStorageContext()['topGroups']);
    expect(serialized).not.toContain('someone@example.com');
    expect(serialized).not.toContain('someone');
    expect(serialized).not.toContain('example.com');
    // The local part of an e-mail address may contain dots and is literally
    // indistinguishable from a key name prefix, so the whole segment is wiped: better to
    // lose a group name than to send a user's e-mail address into monitoring. The real fix
    // is not to use e-mail addresses as storage keys.
    expect(serialized).toContain('<email>');
  });

  it('reads detail and usage at the same moment, so keys added after the probe do not appear in topGroups', async () => {
    localStorage.setItem('oriveo.before.detect', 'z'.repeat(3_500_000));
    await detectStorageHealth();
    // The probe runs at bootstrap step 0 while reporting waits for auth to settle, and actions in between such as quota reclaim change the picture.
    localStorage.setItem('oriveo.after.detect', 'w'.repeat(100_000));
    reportStorageHealth({
      local: 'available',
      indexedDB: 'available',
      localUsage: Math.round(LOCAL_STORAGE_QUOTA_CHARS * 0.7),
      persistent: true,
    });

    const serialized = JSON.stringify(reportedStorageContext()['topGroups']);
    expect(serialized).toContain('oriveo.before.detect');
    expect(serialized).not.toContain('oriveo.after.detect');
  });
});

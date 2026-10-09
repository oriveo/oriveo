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
  isPersistenceBroken,
  reportStorageHealth,
  __resetStorageHealthForTest,
} from '../storage-health';
import { safeLocalStorage, LOCAL_STORAGE_QUOTA_CHARS } from '../../infra/storage/web-storage';

// The @sentry/nextjs exports cannot be redefined, so the whole module is mocked, matching the existing convention in this repo
const { mockCaptureMessage, mockSetContext, mockAddBreadcrumb } = vi.hoisted(() => ({
  mockCaptureMessage: vi.fn(),
  mockSetContext: vi.fn(),
  mockAddBreadcrumb: vi.fn(),
}));
vi.mock('@sentry/nextjs', () => ({
  addBreadcrumb: (...args: unknown[]) => mockAddBreadcrumb(...args),
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
  mockAddBreadcrumb.mockReset();
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

  /**
   * No callback within 3s only means the result has not settled. A later callback of the same
   * open() decides it, and only a confirmation window without any callback is a timeout.
   */
  describe('no callback within 3s yields slow, revised by what the same open() does next', () => {
    type FakeRequest = { onsuccess?: () => void; onerror?: () => void; result: { close: () => void } };

    function stallIndexedDB(): FakeRequest {
      const request: FakeRequest = { result: { close: () => {} } };
      Object.defineProperty(globalThis, 'indexedDB', { configurable: true, value: { open: () => request } });
      return request;
    }

    async function detectUntilSlow(onRevised = vi.fn()) {
      const pending = detectStorageHealth({ onRevised });
      await vi.advanceTimersByTimeAsync(3000);
      return { health: await pending, onRevised };
    }

    beforeEach(() => { vi.useFakeTimers(); });
    afterEach(() => { vi.useRealTimers(); });

    it('hands back slow at the deadline: not broken, not reported, and startup stops waiting', async () => {
      stallIndexedDB();
      const { health, onRevised } = await detectUntilSlow();

      expect(health.indexedDB).toBe('slow');
      expect(health.persistent).toBe(false);
      expect(health.probeStarved).toBe(false);
      expect(health.probeElapsedMs).toBe(3000);
      expect(isPersistenceBroken(health)).toBe(false);

      reportStorageHealth(health);
      expect(mockCaptureMessage).not.toHaveBeenCalled();
      expect(onRevised).not.toHaveBeenCalled();
    });

    it('revises to available when the callback arrives late, leaving a breadcrumb and no issue', async () => {
      const request = stallIndexedDB();
      const { health, onRevised } = await detectUntilSlow();
      reportStorageHealth(health);

      await vi.advanceTimersByTimeAsync(185);
      request.onsuccess?.();
      await vi.advanceTimersByTimeAsync(0);

      expect(onRevised).toHaveBeenCalledExactlyOnceWith(
        expect.objectContaining({ indexedDB: 'available', persistent: true, probeElapsedMs: 3185, probeStarved: false }),
      );
      expect(await detectStorageHealth()).toMatchObject({ indexedDB: 'available', persistent: true });
      expect(mockAddBreadcrumb).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
        message: 'storage.persistence_probe_slow',
        data: { probeElapsedMs: 3185 },
      }));

      // The confirmation deadline does not flip a verdict that has already settled.
      await vi.advanceTimersByTimeAsync(15000);
      expect(onRevised).toHaveBeenCalledTimes(1);
      expect(mockCaptureMessage).not.toHaveBeenCalled();
    });

    it('revises to denied when the late callback is a failure, and then reports persistence_unavailable', async () => {
      const request = stallIndexedDB();
      const { health, onRevised } = await detectUntilSlow();
      reportStorageHealth(health);

      await vi.advanceTimersByTimeAsync(2000);
      request.onerror?.();
      await vi.advanceTimersByTimeAsync(0);

      const revised = onRevised.mock.calls[0]?.[0];
      expect(revised).toMatchObject({ indexedDB: 'denied', persistent: false });
      expect(isPersistenceBroken(revised)).toBe(true);
      expect(mockCaptureMessage).toHaveBeenCalledExactlyOnceWith('storage.persistence_unavailable');
    });

    it('becomes timeout, not denied, only when the confirmation window passes without a callback', async () => {
      stallIndexedDB();
      const { health, onRevised } = await detectUntilSlow();
      reportStorageHealth(health);

      await vi.advanceTimersByTimeAsync(11999);
      expect(onRevised).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1);

      const revised = onRevised.mock.calls[0]?.[0];
      expect(revised).toMatchObject({ indexedDB: 'timeout', persistent: false, probeElapsedMs: 15000, probeStarved: false });
      expect(isPersistenceBroken(revised)).toBe(true);
      expect(mockCaptureMessage).toHaveBeenCalledExactlyOnceWith('storage.persistence_probe_timeout');
      expect(reportedStorageContext()).toMatchObject({ indexedDB: 'timeout', probeElapsedMs: 15000 });
    });

    it('reports the latest verdict when the revision landed before the report was requested with a stale slow snapshot', async () => {
      stallIndexedDB();
      const { health } = await detectUntilSlow();
      await vi.advanceTimersByTimeAsync(12000);

      reportStorageHealth(health);

      expect(mockCaptureMessage).toHaveBeenCalledExactlyOnceWith('storage.persistence_probe_timeout');
    });

    it('becomes unknown when the page goes to the background while waiting, since throttled timers cannot measure the confirmation window either', async () => {
      stallIndexedDB();
      const { health, onRevised } = await detectUntilSlow();
      reportStorageHealth(health);

      const visibility = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden');
      document.dispatchEvent(new Event('visibilitychange'));
      visibility.mockRestore();
      await vi.advanceTimersByTimeAsync(12000);

      const revised = onRevised.mock.calls[0]?.[0];
      expect(revised).toMatchObject({ indexedDB: 'unknown', probeStarved: true });
      expect(isPersistenceBroken(revised)).toBe(false);
      expect(mockCaptureMessage).toHaveBeenCalledExactlyOnceWith('storage.persistence_probe_starved');
    });
  });

  /**
   * The probe deadline is measured with the host's timer queue, and when that queue is starved
   * the ruler itself is broken. A load whose 8s startup timer runs after 23s has its 3s probe
   * fallback running many seconds late as well. That proves the main thread stalled, not that
   * IDB is broken, and must never be judged a timeout that raises the storage banner.
   */
  it('reports unknown with probeStarved, not timeout, when the fallback callback is starved (a 3s timer running after 23s)', async () => {
    vi.useFakeTimers();
    // Fake timers only fire a callback at the instant it is due, so they cannot model a late
    // callback. Lateness is host behaviour: the wall clock has to run ahead by 23s before the
    // callback is scheduled, hence Date.now is controlled separately here.
    const base = Date.now();
    let wallClock = base;
    const nowSpy = vi.spyOn(Date, 'now').mockImplementation(() => wallClock);
    try {
      Object.defineProperty(globalThis, 'indexedDB', {
        configurable: true,
        value: { open: () => ({}) },
      });
      const pending = detectStorageHealth();
      wallClock = base + 23_276;
      await vi.advanceTimersByTimeAsync(3000);
      const health = await pending;
      expect(health.indexedDB).toBe('unknown');
      expect(health.probeStarved).toBe(true);
      expect(health.probeElapsedMs).toBe(23_276);
      // Not measured is not the same as measured broken: the banner criterion must be false.
      expect(isPersistenceBroken(health)).toBe(false);
    } finally {
      nowSpy.mockRestore();
      vi.useRealTimers();
    }
  });

  it('reports unknown when the page went hidden during the probe, since no deadline holds under background throttling', async () => {
    vi.useFakeTimers();
    try {
      Object.defineProperty(globalThis, 'indexedDB', {
        configurable: true,
        value: { open: () => ({}) },
      });
      const pending = detectStorageHealth();
      // jsdom defines visibilityState on Document.prototype; an own property on the instance shadows it.
      Object.defineProperty(document, 'visibilityState', {
        configurable: true,
        get: () => 'hidden',
      });
      document.dispatchEvent(new Event('visibilitychange'));
      await vi.advanceTimersByTimeAsync(3000);
      const health = await pending;
      // The timer fired on time (elapsed = 3000) but the page was backgrounded, so the criterion still fails.
      expect(health.indexedDB).toBe('unknown');
      expect(health.probeStarved).toBe(true);
    } finally {
      delete (document as unknown as Record<string, unknown>).visibilityState;
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
      local: 'denied', indexedDB: 'denied', localUsage: 0, persistent: false, probeElapsedMs: 12, probeStarved: false,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.persistence_unavailable');
  });

  it('sends a probe timeout as its own warning signal rather than as a denied error', () => {
    reportStorageHealth({
      local: 'available', indexedDB: 'timeout', localUsage: 0, persistent: false, probeElapsedMs: 12, probeStarved: false,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.persistence_probe_timeout');
    expect(mockCaptureMessage).not.toHaveBeenCalledWith('storage.persistence_unavailable');
  });

  /**
   * The two edges left once "worth reporting" and "worth interrupting the user" are separate:
   * unknown must still be reported (it is the only place main-thread stalls are observed), but
   * under its own message rather than posing as a storage fault.
   */
  it('sends a starved probe as its own probe_starved signal, carrying the elapsed time and the starved flag', () => {
    reportStorageHealth({
      local: 'available',
      indexedDB: 'unknown',
      localUsage: 0,
      persistent: false,
      probeElapsedMs: 23_276,
      probeStarved: true,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.persistence_probe_starved');
    expect(mockCaptureMessage).not.toHaveBeenCalledWith('storage.persistence_probe_timeout');
    expect(mockCaptureMessage).not.toHaveBeenCalledWith('storage.persistence_unavailable');
    const context = reportedStorageContext();
    expect(context['probeElapsedMs']).toBe(23_276);
    expect(context['probeStarved']).toBe(true);
  });

  it('sends a warning when IDB still works and only localStorage is gone, without inflating it into an incident', () => {
    reportStorageHealth({
      local: 'denied', indexedDB: 'available', localUsage: null, persistent: true, probeElapsedMs: 12, probeStarved: false,
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
      probeElapsedMs: 12,
      probeStarved: false,
    });
    expect(mockCaptureMessage).toHaveBeenCalledWith('storage.local_pressure');
  });

  it('stays quiet when everything is fine', () => {
    reportStorageHealth({
      local: 'available', indexedDB: 'available', localUsage: 1024, persistent: true, probeElapsedMs: 12, probeStarved: false,
    });
    expect(mockCaptureMessage).not.toHaveBeenCalled();
  });

  it('reports at most once per session instead of flooding', () => {
    const bad = {
      local: 'denied', indexedDB: 'denied', localUsage: 0, persistent: false,
      probeElapsedMs: 12, probeStarved: false,
    } as const;
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
      probeElapsedMs: 12,
      probeStarved: false,
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
      probeElapsedMs: 12,
      probeStarved: false,
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
      probeElapsedMs: 12,
      probeStarved: false,
    });

    const serialized = JSON.stringify(reportedStorageContext()['topGroups']);
    expect(serialized).toContain('oriveo.before.detect');
    expect(serialized).not.toContain('oriveo.after.detect');
  });
});

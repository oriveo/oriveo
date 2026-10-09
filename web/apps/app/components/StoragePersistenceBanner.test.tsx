/**
 * When the "browser has disabled site data" banner is shown.
 *
 * These assertions are not about what the banner looks like but about when it is entitled to
 * interrupt the user. A probe can be starved by the host's timer queue (a 3s fallback callback
 * running after 23s) while storage is perfectly fine and localStorage writes succeed; showing a
 * red alert to someone in the middle of adding a key would be wrong. So "nothing was measured"
 * and "measured broken" have to be two different paths.
 */

import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { StoragePersistenceBanner } from './StoragePersistenceBanner';
import type { StorageHealth } from '../lib/core/storage-health';

interface MockState {
  storageHealth: StorageHealth | null;
}

let mockState: MockState = { storageHealth: null };

vi.mock('../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

function health(overrides: Partial<StorageHealth>): StorageHealth {
  return {
    local: 'available',
    indexedDB: 'available',
    localUsage: 1024,
    persistent: true,
    probeElapsedMs: 12,
    probeStarved: false,
    ...overrides,
  };
}

beforeEach(() => {
  mockState = { storageHealth: null };
});

describe('StoragePersistenceBanner', () => {
  it('renders nothing before detection finishes (null), so an uncertain answer never alarms the user', () => {
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('renders nothing when persistence is confirmed available', () => {
    mockState.storageHealth = health({});
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('renders the red alert when IDB is explicitly denied, which is when nothing can really be stored', () => {
    mockState.storageHealth = health({ indexedDB: 'denied', persistent: false });
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).not.toBeNull();
    expect(screen.queryByText('blockedTitle')).not.toBeNull();
  });

  it('renders nothing while the probe is still waiting after 3s without a callback (slow): slow is not broken', () => {
    mockState.storageHealth = health({ indexedDB: 'slow', persistent: false, probeElapsedMs: 3000 });
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('still renders on a probe timeout: that state did measure a database that cannot be opened', () => {
    mockState.storageHealth = health({ indexedDB: 'timeout', persistent: false });
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).not.toBeNull();
  });

  it('renders when the browser does not support IDB', () => {
    mockState.storageHealth = health({ indexedDB: 'unsupported', persistent: false });
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).not.toBeNull();
  });

  /** Regression: persistent is false here as well, but this time nothing was measured. */
  it('renders nothing when the probe was starved by the host (unknown), even though persistent is false too', () => {
    mockState.storageHealth = health({
      indexedDB: 'unknown',
      persistent: false,
      probeElapsedMs: 23_276,
      probeStarved: true,
    });
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('does not interrupt the user when only localStorage is gone and IDB still works (data is still stored)', () => {
    mockState.storageHealth = health({ local: 'denied' });
    render(<StoragePersistenceBanner />);
    expect(screen.queryByRole('alert')).toBeNull();
  });
});

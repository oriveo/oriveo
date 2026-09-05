// @vitest-environment jsdom
//
// Registration tests for the module-level lifecycle listeners (visibilitychange / pagehide).
// Key checks:
//   1. loading the module registers nothing, so nothing can react to a lifecycle event before
//      StoreProvider is initialized
//   2. the install function is idempotent
//   3. visibilitychange=hidden triggers flushAllStreamsForLifecycle
//   4. pagehide triggers flushAllStreamsForLifecycle + backupAllStreamsToSessionStorage

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  flushAllStreamsForLifecycle: vi.fn(),
  backupAllStreamsToSessionStorage: vi.fn(),
}));

vi.mock('../active-streams', () => ({
  flushAllStreamsForLifecycle: mocks.flushAllStreamsForLifecycle,
  backupAllStreamsToSessionStorage: mocks.backupAllStreamsToSessionStorage,
}));

import {
  installStreamLifecycleListeners,
  __resetStreamLifecycleListenersForTests,
} from '../lifecycle-listeners';

beforeEach(() => {
  __resetStreamLifecycleListenersForTests();
  mocks.flushAllStreamsForLifecycle.mockReset();
  mocks.backupAllStreamsToSessionStorage.mockReset();
});

afterEach(() => {
  __resetStreamLifecycleListenersForTests();
});

describe('installStreamLifecycleListeners', () => {
  it('module evaluation does not install listeners before bootstrap', async () => {
    const documentAddSpy = vi.spyOn(document, 'addEventListener');
    const windowAddSpy = vi.spyOn(window, 'addEventListener');
    vi.stubEnv('NODE_ENV', 'production');
    try {
      vi.resetModules();
      const freshModule = await import('../lifecycle-listeners');

      expect(documentAddSpy).not.toHaveBeenCalledWith('visibilitychange', expect.any(Function));
      expect(windowAddSpy).not.toHaveBeenCalledWith('pagehide', expect.any(Function));
      freshModule.__resetStreamLifecycleListenersForTests();
    } finally {
      vi.unstubAllEnvs();
      documentAddSpy.mockRestore();
      windowAddSpy.mockRestore();
    }
  });

  it('visibilitychange=hidden triggers flushAllStreamsForLifecycle', () => {
    installStreamLifecycleListeners();

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'hidden',
    });
    document.dispatchEvent(new Event('visibilitychange'));

    expect(mocks.flushAllStreamsForLifecycle).toHaveBeenCalledTimes(1);
    expect(mocks.backupAllStreamsToSessionStorage).not.toHaveBeenCalled();
  });

  it('visibilitychange=visible does NOT trigger flush', () => {
    installStreamLifecycleListeners();

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    });
    document.dispatchEvent(new Event('visibilitychange'));

    expect(mocks.flushAllStreamsForLifecycle).not.toHaveBeenCalled();
  });

  it('pagehide triggers flushAllStreamsForLifecycle + backupAllStreamsToSessionStorage', () => {
    installStreamLifecycleListeners();

    window.dispatchEvent(new Event('pagehide'));

    expect(mocks.flushAllStreamsForLifecycle).toHaveBeenCalledTimes(1);
    expect(mocks.backupAllStreamsToSessionStorage).toHaveBeenCalledTimes(1);
  });

  it('idempotent: multiple installs only register once', () => {
    installStreamLifecycleListeners();
    installStreamLifecycleListeners();
    installStreamLifecycleListeners();

    window.dispatchEvent(new Event('pagehide'));

    // A duplicate registration would call the mocks below more than once
    expect(mocks.flushAllStreamsForLifecycle).toHaveBeenCalledTimes(1);
    expect(mocks.backupAllStreamsToSessionStorage).toHaveBeenCalledTimes(1);
  });
});

// @vitest-environment jsdom

import React from 'react';
import { act, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  subscribeToChanges: vi.fn(() => () => {}),
  bootstrapApp: vi.fn(() => new Promise(() => {})),
  trackEvent: vi.fn(),
}));

vi.mock('../lib/core/store/persistence', () => ({
  subscribeToChanges: mocks.subscribeToChanges,
}));

vi.mock('../lib/core/bootstrap', () => ({
  bootstrapApp: mocks.bootstrapApp,
}));

vi.mock('../lib/core/telemetry', () => ({
  trackEvent: mocks.trackEvent,
}));

vi.mock('../lib/hooks/useTheme', () => ({
  useTheme: vi.fn(),
}));

vi.mock('../components/Skeleton', () => ({
  Skeleton: () => <div data-testid="skeleton" />,
}));

import { StoreProvider, getVanillaStore } from './StoreProvider';

describe('StoreProvider', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
    mocks.bootstrapApp.mockImplementation(() => new Promise(() => {}));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('timeout path still installs persistence subscription', async () => {
    render(
      <StoreProvider>
        <div data-testid="app-ready" />
      </StoreProvider>,
    );

    expect(screen.getByTestId('skeleton')).toBeTruthy();

    await act(async () => {
      vi.advanceTimersByTime(8000);
    });

    expect(mocks.subscribeToChanges).toHaveBeenCalledTimes(1);
    expect(screen.getByTestId('app-ready')).toBeTruthy();
    expect(getVanillaStore().getState().hydrationPhase).toBe('ready');
  });

  it('timeout path triggers bootstrap_timed_out telemetry', async () => {
    render(
      <StoreProvider>
        <div data-testid="app-ready" />
      </StoreProvider>,
    );

    await act(async () => {
      vi.advanceTimersByTime(8000);
    });

    expect(mocks.trackEvent).toHaveBeenCalledWith(
      'bootstrap_timed_out',
      expect.objectContaining({ timeout_ms: 8000 }),
    );
  });

  it('renders children after bootstrap resolves', async () => {
    vi.useRealTimers();
    mocks.bootstrapApp.mockResolvedValueOnce({ initialUser: null, authResolution: 'observed' });

    render(
      <StoreProvider>
        <div data-testid="app-ready" />
      </StoreProvider>,
    );

    await waitFor(() => expect(screen.getByTestId('app-ready')).toBeTruthy());
  });
});

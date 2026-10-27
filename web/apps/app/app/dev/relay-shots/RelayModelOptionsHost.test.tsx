import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({ providers: [] as Provider[] }));

vi.mock('next-intl', () => ({
  useTranslations: (namespace: string) => (key: string, values?: Record<string, unknown>) => (
    values ? `${namespace}.${key}:${Object.values(values).join(',')}` : `${namespace}.${key}`
  ),
  useLocale: () => 'en',
}));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: () => null,
  useAppStore: <T,>(selector: (state: { providers: Provider[] }) => T) => selector({ providers: mocks.providers }),
}));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: vi.fn() }));

/** Shared shot manifest (found by walking up from this directory to the repo root). */
function loadManifest() {
  for (let dir = resolve(import.meta.dirname); ; dir = dirname(dir)) {
    try {
      return JSON.parse(readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'relay.v1.json'), 'utf8'));
    } catch (error) {
      if (dirname(dir) === dir) throw error;
    }
  }
}

const fakeStore = () => ({ getState: () => ({ setProviders: vi.fn() }), setState: vi.fn() }) as never;

describe('relay shots model options host (production ModelOptionsPopover)', () => {
  let uninstall: (() => void) | null = null;
  // Cold transpile of the host plus the production ModelOptionsPopover takes 6-7s under full-suite concurrency: load once first (timed separately) so it does not eat the 5s case budget;
  // otherwise a timed-out case keeps rendering in the background and leaks into the next case's DOM.
  beforeAll(async () => {
    await import('./relay-shots-fence');
    await import('./relay-shots-data');
    await import('../../../lib/infra/storage/web-storage');
    await import('./RelayModelOptionsHost');
  }, 60_000);
  afterEach(() => {
    cleanup();
    uninstall?.();
    uninstall = null;
  });

  /** In entry order: build the plan -> write the in-memory store -> apply (preferences written through the production store) -> render the host. */
  async function renderShot(page: 'relayModelOptionsWeb' | 'relayModelOptionsWebRejected') {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const { safeLocalStorage } = await import('../../../lib/infra/storage/web-storage');
    const { RelayModelOptionsHost } = await import('./RelayModelOptionsHost');
    const plan = data.relayShotPlan(page, loadManifest());
    for (const [key, value] of Object.entries(plan.localStorage)) safeLocalStorage.setItem(key, value);
    data.applyRelayShotPlan(plan, fakeStore());
    mocks.providers = plan.providers;
    if (plan.target.kind !== 'modelOptions') throw new Error(`unexpected target ${plan.target.kind}`);
    render(<RelayModelOptionsHost providerId={plan.target.providerId} modelId={plan.target.modelId} />);
  }

  it('relayModelOptionsWeb: web switch on, status Search confirmed', async () => {
    await renderShot('relayModelOptionsWeb');
    const toggle = screen.getByRole('switch', { name: /capabilityControlWebSearch/ }) as HTMLInputElement;
    expect(toggle.checked).toBe(true);
    expect(toggle.disabled).toBe(false);
    expect(screen.getByText('common.modelOptionsRelayWebSearchConfirmed')).toBeTruthy();
  });

  it('relayModelOptionsWebRejected: switch off but tappable, rejection copy, Test capabilities link', async () => {
    await renderShot('relayModelOptionsWebRejected');
    const toggle = screen.getByRole('switch', { name: /capabilityControlWebSearch/ }) as HTMLInputElement;
    expect(toggle.checked).toBe(false);
    expect(toggle.disabled).toBe(false);
    expect(screen.getByText('common.modelOptionsRelayWebRejected')).toBeTruthy();
    expect(screen.getByRole('button', { name: /pages\.relayDetail\.capabilityTest\.action$/ })).toBeTruthy();
  });
});

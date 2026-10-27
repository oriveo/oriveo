import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  notFound: vi.fn(() => {
    throw new Error('NEXT_HTTP_ERROR_FALLBACK;404');
  }),
  bootstrapApp: vi.fn(() => new Promise(() => {})),
  subscribeToChanges: vi.fn(() => () => {}),
}));

vi.mock('next/navigation', () => ({ notFound: mocks.notFound }));
vi.mock('../../../lib/core/bootstrap', () => ({
  bootstrapApp: mocks.bootstrapApp,
}));
vi.mock('../../../lib/core/store/persistence', () => ({ subscribeToChanges: mocks.subscribeToChanges }));
vi.mock('../../../lib/hooks/useTheme', () => ({ useTheme: vi.fn(), useDarkPalette: vi.fn() }));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: vi.fn() }));

/** Shared screenshot manifest (walk up from this directory to the repository root). */
function loadManifest() {
  for (let dir = resolve(import.meta.dirname); ; dir = dirname(dir)) {
    try {
      return JSON.parse(readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'relay.v1.json'), 'utf8'));
    } catch (error) {
      if (dirname(dir) === dir) throw error;
    }
  }
}

describe('relay shots direct entry', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    window.history.replaceState(null, '', '/');
  });

  // Expectations read pages[].name from the shared manifest (iOS `RelayFamilyDebugShots` is aligned with it) instead of hard-coding a page count.
  it('page name table matches the shared screenshot manifest (order and case)', async () => {
    const { RELAY_SHOT_PAGES } = await import('./relay-shots-pages');
    const manifestPages = (loadManifest().pages as Array<{ name: string }>).map((page) => page.name);
    expect(manifestPages.length).toBeGreaterThan(0);
    expect([...RELAY_SHOT_PAGES]).toEqual(manifestPages);
  });

  it('production build returns notFound and the entry does not statically import the fake data or client module', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    const { default: RelayShotsPage } = await import('./[page]/page');
    await expect(RelayShotsPage({ params: Promise.resolve({ page: 'relayDetail' }) })).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
    expect(mocks.notFound).toHaveBeenCalled();
    const source = readFileSync(resolve(import.meta.dirname, '[page]/page.tsx'), 'utf8');
    expect(source).not.toMatch(/^import .*relay-shots-(data|fence)|^import .*RelayShotsClient/m);
  });

  it('dev build returns notFound for an unknown page name', async () => {
    mocks.notFound.mockClear();
    const { default: RelayShotsPage } = await import('./[page]/page');
    await expect(RelayShotsPage({ params: Promise.resolve({ page: 'nope' }) })).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
  });

  describe('screenshot mode isolation', () => {
    let uninstall: (() => void) | null = null;
    beforeEach(() => {
      vi.clearAllMocks();
    });
    afterEach(async () => {
      const fence = await import('./relay-shots-fence');
      if (fence.relayShotsFenceInstalled()) fence.installRelayShotsFence()();
      uninstall = null;
    });

    it('on a screenshot route bootstrap, persistence subscription and cloud sync do not run, and storage and network go into the fence', async () => {
      window.history.replaceState(null, '', '/dev/relay-shots/relayEditFailure');
      const realIndexedDB = globalThis.indexedDB;
      window.localStorage.setItem('relay-shots-probe', 'real');
      const { StoreProvider } = await import('../../../providers/StoreProvider');
      render(<StoreProvider><p>shot-child</p></StoreProvider>);
      await screen.findByText('shot-child');

      expect(mocks.bootstrapApp).not.toHaveBeenCalled();
      expect(mocks.subscribeToChanges).not.toHaveBeenCalled();
      const { getSyncAdapter } = await import('../../../lib/core/sync-port');
      expect(getSyncAdapter()).toBeNull();

      const fence = await import('./relay-shots-fence');
      expect(fence.relayShotsFenceInstalled()).toBe(true);
      expect(globalThis.indexedDB).not.toBe(realIndexedDB);
      // In-memory stand-in: real values cannot be read and nothing is written to real storage.
      expect(window.localStorage.getItem('relay-shots-probe')).toBeNull();
      window.localStorage.setItem('relay-shots-probe', 'shot');
      uninstall = fence.installRelayShotsFence();
      uninstall();
      expect(window.localStorage.getItem('relay-shots-probe')).toBe('real');
      expect(globalThis.indexedDB).toBe(realIndexedDB);
      window.localStorage.removeItem('relay-shots-probe');
    });

    it('fake data: long name carries no transport; times are offsets from now; unverified lastError; setup flow catalog has 9 ids; the screenshot connection is seeded with a capability evidence identity', async () => {
      const fence = await import('./relay-shots-fence');
      uninstall = fence.installRelayShotsFence();
      const data = await import('./relay-shots-data');
      const manifest = loadManifest();
      const secret = (ref: string) => (manifest.relay.keys as Array<{ ref: string; secret: string }>).find((key) => key.ref === ref)!.secret;
      const { getActiveUIDSync } = await import('../../../lib/infra/storage/partition');
      const { readCapabilityEvidenceIdentity } = await import('../../../lib/core/providers/capability-evidence-identity');
      const now = Date.now();
      const agoSeconds = (iso: string | undefined) => Math.round((now - Date.parse(iso ?? '')) / 1000);

      const relay = data.demoRelayProvider('relayLibrary', manifest);
      const long = relay.models.find((model) => model.id.startsWith('claude-sonnet-5-extended'))!;
      expect(long.relayTransport).toBeUndefined();
      expect(long.relayTransportSource).toBeUndefined();
      expect(Math.abs(agoSeconds(relay.lastCheckedAt) - 180)).toBeLessThanOrEqual(5);
      for (const key of relay.relayKeys ?? []) expect(Math.abs(agoSeconds(key.status?.checkedAt) - 240)).toBeLessThanOrEqual(5);
      expect(Math.abs(agoSeconds(data.studioOllamaProvider(manifest).lastCheckedAt) - 60)).toBeLessThanOrEqual(5);
      expect(data.demoRelayProvider('relayDetailIssue', manifest).lastError).toBe('Connection has not been verified.');

      const store = { getState: () => ({ setProviders: vi.fn() }), setState: vi.fn() };
      const mainModels = async () => {
        const response = await fetch(`${manifest.relay.apiRoot}/models`, { headers: { Authorization: `Bearer ${secret('main')}` } });
        return ((await response.json()) as { data: Array<{ id: string }> }).data.map((model) => model.id);
      };
      data.applyRelayShotPlan(data.relayShotPlan('relaySetupModels', manifest), store as never);
      expect(await mainModels()).toEqual([
        'gpt-5.6-sol', 'gpt-5.6-mini', 'gpt-image-1', 'claude-sonnet-5', 'claude-opus-5', 'claude-haiku-5',
        'deepseek-chat', 'relay-chat-large', 'claude-sonnet-5-extended-thinking-preview-20261001',
      ]);
      data.applyRelayShotPlan(data.relayShotPlan('relayLibrary', manifest), store as never);
      expect(await mainModels()).toEqual(['gpt-5.6-sol', 'gpt-5.6-mini', 'gpt-image-1', 'relay-chat-large']);
      // The production beginCapabilityEvidenceIdentityIfAbsent writes into the fence memory.
      expect(readCapabilityEvidenceIdentity(getActiveUIDSync(), manifest.relay.id)).not.toBeNull();
      expect(readCapabilityEvidenceIdentity(getActiveUIDSync(), manifest.local.id)).not.toBeNull();
    });

    it('the fake relay answers through the production proxy arguments: Backup 401, Main catalog; the edit-failure preset is the 401 from the production error constructor', async () => {
      const fence = await import('./relay-shots-fence');
      uninstall = fence.installRelayShotsFence();
      const { buildBrowserRelayFetchArgs } = await import('../../../lib/core/providers/relay-browser-direct');
      const { applyRelayShotPlan, demoRelayProvider, relayShotPlan } = await import('./relay-shots-data');
      const manifest = loadManifest();
      const DEMO_RELAY_API_ROOT: string = manifest.relay.apiRoot;
      const DEMO_KEYS = Object.fromEntries(
        (manifest.relay.keys as Array<{ ref: string; secret: string }>).map((key) => [key.ref, key.secret]),
      ) as Record<'main' | 'backup' | 'team', string>;
      // The fence's fake upstream only answers once the plan has been applied.
      applyRelayShotPlan(relayShotPlan('relayDetail', manifest), { getState: () => ({ setProviders: vi.fn() }), setState: vi.fn() } as never);
      const request = (apiKey: string, path: string, method: 'GET' | 'POST') => {
        const args = buildBrowserRelayFetchArgs(`${DEMO_RELAY_API_ROOT}${path}`, {}, {
          transport: 'openai_chat_completions', authMode: 'bearer', apiKey, method,
        });
        return fetch(args.url, { method: 'POST', headers: args.headers });
      };
      expect((await request(DEMO_KEYS.backup, '/chat/completions', 'POST')).status).toBe(401);
      const models = await (await request(DEMO_KEYS.main, '/models', 'GET')).json() as { data: Array<{ id: string }> };
      expect(models.data.map((model) => model.id)).toEqual(['gpt-5.6-sol', 'gpt-5.6-mini', 'gpt-image-1', 'relay-chat-large']);
      expect((await fetch('/api/providers/models', { method: 'POST' })).status).toBe(503);

      const { extractRelayPingFailureDetails } = await import('../../../lib/core/providers/ping-relay');
      const failure = relayShotPlan('relayEditFailure', manifest).seed.detail?.settingsFailure;
      expect(failure?.delayMs).toBe(600);
      expect(extractRelayPingFailureDetails(failure?.failure.error, {
        apiKey: DEMO_KEYS.main,
        relayRequested: demoRelayProvider('relayEditFailure', manifest).relayRequested!,
      })).toMatchObject({
        statusCode: 401,
        requestURL: `${DEMO_RELAY_API_ROOT}/responses`,
      });
    });
  });
});

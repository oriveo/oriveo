import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  notFound: vi.fn(() => {
    throw new Error('NEXT_HTTP_ERROR_FALLBACK;404');
  }),
  /** When non-null, the manifest text read by the entry is replaced with it (tests reading the file are unaffected). */
  manifestText: null as string | null,
}));

vi.mock('next/navigation', () => ({ notFound: mocks.notFound }));
vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>();
  const readFileSync = ((path: Parameters<typeof actual.readFileSync>[0], ...rest: unknown[]) => {
    if (mocks.manifestText !== null && String(path).endsWith('relay.v1.json')) return mocks.manifestText;
    return (actual.readFileSync as (...args: unknown[]) => unknown)(path, ...rest);
  }) as typeof actual.readFileSync;
  return { ...actual, default: { ...actual, readFileSync }, readFileSync };
});

function manifestPath(): string {
  let dir = resolve(import.meta.dirname);
  for (;;) {
    const candidate = join(dir, 'shared', 'test-fixtures', 'shots', 'relay.v1.json');
    try {
      readFileSync(candidate, 'utf8');
      return candidate;
    } catch {
      const parent = dirname(dir);
      if (parent === dir) throw new Error('relay.v1.json not found');
      dir = parent;
    }
  }
}

/** Hands out a fresh copy each time, so changing it does not affect other cases. */
function loadManifest() {
  return JSON.parse(readFileSync(manifestPath(), 'utf8'));
}

const fakeStore = () => ({ getState: () => ({ setProviders: vi.fn() }), setState: vi.fn() }) as never;

describe('relay shots shared sample manifest', () => {
  let uninstall: (() => void) | null = null;
  // The page and the client components it loads on demand take seconds to cold-transpile under full-suite concurrency: load once first (timed separately) so it does not eat the 5s case budget.
  beforeAll(async () => {
    await import('./[page]/page');
    await import('./RelayShotsClient');
    await import('./relay-shots-pages');
  }, 60_000);
  afterEach(() => {
    uninstall?.();
    uninstall = null;
    mocks.manifestText = null;
    vi.restoreAllMocks();
  });

  it('shotsManifestPagesMatchImplemented', async () => {
    const { RELAY_SHOT_PAGES } = await import('./relay-shots-pages');
    const manifest = loadManifest();
    const names = (manifest.pages as Array<{ name: string }>).map((page) => page.name);
    expect(new Set(names)).toEqual(new Set(RELAY_SHOT_PAGES));
    expect(names).toHaveLength(RELAY_SHOT_PAGES.length);
  });

  it('shotsManifestBuildsDemoRelay', async () => {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const manifest = loadManifest();

    const relay = data.relayShotPlan('relayDetail', manifest).providers[0]!;
    expect(relay.id).toBe('5E1A7000-0000-4000-8000-000000000001');
    expect(relay.customName).toBe('Demo Relay');
    expect(relay.baseURLText).toBe('https://api.relay-demo.example');
    expect(relay.relayResolvedBaseURLText).toBe('https://api.relay-demo.example/v1');
    expect(relay.apiKey).toBe('sk-relay-demo-main-7Q4f');
    expect(relay.relayRequested?.transport).toBe('auto');
    expect(relay.relayRequested?.authMode).toBe('bearer');
    expect(relay.relayRequested?.securityMode).toBe('remote_https');
    expect(relay.relayRequested?.resolvedAPIBaseURLs).toEqual({
      openai_chat_completions: 'https://api.relay-demo.example/v1',
      openai_responses: 'https://api.relay-demo.example/v1',
    });
    expect(relay.relayKeys?.map(({ status, ...key }) => ({ ...key, state: status?.state, httpStatus: status?.httpStatus }))).toEqual([
      // Manifest httpStatus null: RelayKeyStatus.httpStatus is an optional number, treated as absent.
      { id: 'initial', name: 'Main', apiKey: '', state: 'ok', httpStatus: undefined },
      { id: 'k-demo-backup', name: 'Backup', apiKey: 'sk-relay-demo-backup-9Zc2', state: 'invalid', httpStatus: 401 },
      { id: 'k-demo-team', apiKey: 'sk-relay-demo-team-51Lx', state: 'limited', httpStatus: 429 },
    ]);
    expect(relay.catalogModels?.map((model) => [model.id, model.relayListedByKeyIDs])).toEqual([
      ['gpt-5.6-sol', ['initial', 'k-demo-team']],
      ['gpt-5.6-mini', ['initial', 'k-demo-team']],
      ['gpt-image-1', ['initial']],
      ['claude-sonnet-5', ['k-demo-backup']],
      ['claude-opus-5', ['k-demo-backup']],
      ['claude-haiku-5', ['k-demo-backup']],
      ['relay-chat-large', ['initial']],
      ['claude-sonnet-5-extended-thinking-preview-20261001', ['k-demo-backup']],
      ['deepseek-chat', ['k-demo-team']],
    ]);
    expect(relay.models.map((model) => ({
      id: model.id,
      key: model.relayKeyID,
      overrides: model.relayCapabilityOverrides,
      transport: model.relayTransport,
      transportSource: model.relayTransportSource,
    }))).toEqual([
      {
        id: 'gpt-5.6-sol', key: 'initial',
        overrides: { image: { value: true, source: 'tested' }, toolCall: { value: true, source: 'tested' } },
        transport: 'openai_responses', transportSource: 'observed',
      },
      {
        id: 'claude-sonnet-5', key: 'k-demo-backup',
        overrides: { image: { value: true, source: 'user' }, file: { value: false, source: 'user' } },
        transport: 'openai_chat_completions', transportSource: 'reachable',
      },
      { id: 'relay-chat-large', key: 'initial', overrides: undefined, transport: undefined, transportSource: undefined },
      {
        id: 'claude-sonnet-5-extended-thinking-preview-20261001', key: 'k-demo-backup',
        overrides: undefined, transport: undefined, transportSource: undefined,
      },
    ]);

    expect(data.relayShotPlan('relayLibraryLast', manifest).providers[0]!.models.map((model) => model.id)).toEqual(['gpt-5.6-sol']);
    for (const page of ['relayDetailIssue', 'relayAdvancedFixed'] as const) {
      const provider = data.relayShotPlan(page, manifest).providers[0]!;
      expect(provider.relayRequested?.transport).toBe('openai_responses');
      expect(provider.models.some((model) => model.relayTransport !== undefined || model.relayTransportSource !== undefined)).toBe(false);
    }

    const local = data.relayShotPlan('localDetail', manifest).providers[1]!;
    expect(local.customName).toBe('Studio Ollama');
    expect(local.catalogModels?.map((model) => [model.id, model.localLoadState, model.engineDeclaration])).toEqual([
      ['qwen3:8b', 'loaded', { image: false, toolCall: true, thinking: true }],
      ['llama3.3:70b', 'unloaded', { toolCall: true, thinking: false }],
      ['gemma3:12b', 'unloaded', { image: true }],
    ]);
    expect(local.models.map((model) => model.id)).toEqual(['qwen3:8b', 'llama3.3:70b']);

    data.applyRelayShotPlan(data.relayShotPlan('relaySetup', manifest), fakeStore());
    expect(data.demoUpstreamCatalog('main')).toEqual([
      'gpt-5.6-sol', 'gpt-5.6-mini', 'gpt-image-1', 'claude-sonnet-5', 'claude-opus-5', 'claude-haiku-5',
      'deepseek-chat', 'relay-chat-large', 'claude-sonnet-5-extended-thinking-preview-20261001',
    ]);
    expect(data.relayShotPlan('relayManualSetupFailure', manifest).seed.setup?.apiKey).toBe('sk-relay-demo-main-7Q4f');
  });

  it('two failure cards: the 401 body comes from the manifest unauthorizedError, production still classifies it as an invalid key and still allows saving unverified', async () => {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const { verifyRelayManualSetup } = await import('../../providers/relay/new/relay-setup-two-step-run');
    const { initialManualSetupDraft, manualSetupProvider } = await import('../../providers/relay/new/manual-setup-board');
    const manifest = loadManifest();
    const body: string = manifest.relay.unauthorizedError.body;

    // Edit page save failure: the preset error is built by the production error constructor from the manifest 401 body.
    const failure = data.relayShotPlan('relayEditFailure', manifest).seed.detail?.settingsFailure?.failure;
    expect(failure?.canSaveUnverified).toBe(true);
    expect(failure?.error).toMatchObject({ kind: 'invalidKey', status: 401 });

    // Other pages: the Backup key gets the manifest 401, and the reply body is the manifest text verbatim.
    data.applyRelayShotPlan(data.relayShotPlan('relayDetail', manifest), fakeStore());
    const backup = await fetch(`${manifest.relay.apiRoot}/chat/completions`, {
      method: 'POST', headers: { Authorization: 'Bearer sk-relay-demo-backup-9Zc2' },
    });
    expect(backup.status).toBe(401);
    expect(await backup.text()).toBe(body);

    // Manual setup failure page: fill in the primary key; the fence answers every verification request on this page with 401; production verification fails (not a persistence failure, so the failure card offers "Save anyway") and classifies it as an invalid key.
    const plan = data.relayShotPlan('relayManualSetupFailure', manifest);
    data.applyRelayShotPlan(plan, fakeStore());
    const seed = plan.seed.setup!;
    const provider = manualSetupProvider({
      id: 'shots-manual',
      endpoint: seed.endpoint!,
      keys: [{ id: 'initial', apiKey: seed.apiKey!, name: '' }],
      draft: { ...initialManualSetupDraft(), ...seed.manualDraft },
      providers: [],
      now: new Date().toISOString(),
    });
    const outcome = await verifyRelayManualSetup({ provider, modelID: seed.manualDraft!.model! });
    expect(outcome.ok).toBe(false);
    expect(outcome.ok ? null : outcome.error).toMatchObject({ kind: 'invalidKey', status: 401 });
  });

  it('shotsManifestKeyAddedNotice: team is set to ok on this page, and the production notice computes added(N=3, M=1)', async () => {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const manifest = loadManifest();
    const plan = data.relayShotPlan('relayKeysAdded', manifest);
    const team = plan.providers[0]!.relayKeys?.find((key) => key.id === 'k-demo-team');
    expect(team?.status?.state).toBe('ok');
    expect(plan.seed.detail?.keysNotices).toEqual([{ kind: 'added', keyID: 'k-demo-team', listed: 3, new: 1 }]);
    // Other pages: team keeps the manifest status.
    expect(data.relayShotPlan('relayKeys', manifest).providers[0]!.relayKeys?.find((key) => key.id === 'k-demo-team')?.status?.state)
      .toBe('limited');
  });

  it('shotsManifestWebSearchRejected: a stored Chat fragment + a rejected record for the claude-sonnet-5 current fragment, with key and hash identical to production first-launch protocol', async () => {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const { RELAY_WEB_PROBE_RECORDS_STORAGE_KEY } = await import('../../../lib/core/chat/relay-web-probe-records');
    const { relayWebFragmentHash } = await import('@oriveo/core/providers/relay-web-probe');
    const { relayWebProbeTransport } = await import('../../../lib/core/relay-web-probe-ops');
    const manifest = loadManifest();
    const plan = data.relayShotPlan('relayWebSearchRejected', manifest);
    expect(plan.target).toMatchObject({ kind: 'detail', providerId: manifest.relay.id });
    const relay = plan.providers[0]!;
    const sonnet = relay.models.find((model) => model.id === 'claude-sonnet-5')!;
    expect(relayWebProbeTransport(relay, sonnet)).toBe('openai_chat_completions');
    const stored = JSON.parse(plan.localStorage[RELAY_WEB_PROBE_RECORDS_STORAGE_KEY]!);
    expect(stored.version).toBe(1);
    expect(stored.entries).toEqual([expect.objectContaining({
      connectionId: manifest.relay.id,
      modelId: 'claude-sonnet-5',
      transport: 'openai_chat_completions',
      result: 'rejected',
      source: 'tested',
      fragmentHash: relayWebFragmentHash({ web_search_options: {} }),
    })]);
    expect(Number.isFinite(Date.parse(stored.entries[0].at))).toBe(true);
  });

  /** Builds the plan, writes it into the in-memory store and applies it; returns the web facts and presentation that production functions compute for the shot connection x page model. */
  async function relayWebShot(page: string) {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const { safeLocalStorage } = await import('../../../lib/infra/storage/web-storage');
    const records = await import('../../../lib/core/chat/relay-web-probe-records');
    const prefs = await import('../../../lib/core/chat/capability-preference-settings');
    const manifest = loadManifest();
    const plan = data.relayShotPlan(page as never, manifest);
    for (const [key, value] of Object.entries(plan.localStorage)) safeLocalStorage.setItem(key, value);
    data.applyRelayShotPlan(plan, fakeStore());
    const relay = plan.providers[0]!;
    const model = relay.models.find((item) => item.id === 'gpt-5.6-sol')!;
    const facts = records.relayWebModelOptionFacts(relay, model);
    const identity = prefs.capabilityPreferenceIdentity(relay, model)!;
    const defaultWeb = records.relayWebPreferenceDefaultFor(relay, model);
    const preference = prefs.displayRelayWebPreference({ ...(prefs.relayWebPreferenceIdentity(relay, model) ?? identity), ...(defaultWeb ? { defaultWeb } : {}) });
    return { plan, manifest, model, facts, preference, presentation: records.resolveRelayWebPresentation(facts, preference) };
  }

  it('shotsManifestModelOptionsWeb: production panel host, a searched record under the template hash + preference on -> switch on, Search confirmed', async () => {
    const { plan, manifest, facts, preference, presentation } = await relayWebShot('relayModelOptionsWeb');
    expect(plan.target).toEqual({ kind: 'modelOptions', providerId: manifest.relay.id, modelId: 'gpt-5.6-sol' });
    expect(facts).toMatchObject({ hasFragment: false, probe: 'searched' });
    expect(preference).toBe('automatic');
    expect(presentation).toMatchObject({ row: 'toggle', isOn: true, statusId: 'web_probe_searched' });
  });

  it('shotsManifestModelOptionsWebRejected: rejected under the template hash, preference unset -> switch is tappable and off, rejection copy, Test capabilities', async () => {
    const { plan, facts, presentation } = await relayWebShot('relayModelOptionsWebRejected');
    expect(plan.webPreferences).toEqual([]);
    expect(facts).toMatchObject({ hasFragment: false, probe: 'rejected' });
    expect(presentation).toMatchObject({ row: 'toggle', isOn: false, statusId: 'web_probe_rejected', retestLink: 'testCapabilities', replyNotice: null });
  });

  it('shotsManifestAdvancedWeb: relayAdvanced under the template hash with searched + tested override -> Search confirmed · Tested', async () => {
    const { plan, model, presentation } = await relayWebShot('relayAdvanced');
    expect(plan.target).toMatchObject({ kind: 'detail', query: '?view=advanced&model=gpt-5.6-sol' });
    expect(model.relayCapabilityOverrides?.web).toEqual({ value: true, source: 'tested' });
    expect(model.relayCapabilityOverrides?.image).toEqual({ value: true, source: 'tested' });
    expect(presentation.advanced).toEqual({ statusId: 'web_probe_searched', source: 'tested' });
  });

  it('shotsManifestValuesFollowManifest', async () => {
    const fence = await import('./relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./relay-shots-data');
    const manifest = loadManifest();
    manifest.relay.name = 'Changed Relay';
    manifest.setupCatalog = manifest.setupCatalog.slice(0, 2);
    const capabilityPage = manifest.pages.find((page: { name: string }) => page.name === 'relayCapabilityTest');
    capabilityPage.preset.capabilityTest.results.text.elapsedMs = 999;

    expect(data.relayShotPlan('relayDetail', manifest).providers[0]!.customName).toBe('Changed Relay');
    expect(data.relayShotPlan('relayCapabilityTest', manifest).seed.detail?.capabilityTest?.results.text?.elapsedMs).toBe(999);
    data.applyRelayShotPlan(data.relayShotPlan('relaySetupModels', manifest), fakeStore());
    expect(data.demoUpstreamCatalog('main')).toEqual(['gpt-5.6-sol', 'gpt-5.6-mini']);
  });

  it('shotsManifestUnreadableRefuses', async () => {
    const { default: RelayShotsPage } = await import('./[page]/page');
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const open = () => RelayShotsPage({ params: Promise.resolve({ page: 'relayDetail' }) });
    // Read the variant first, then replace the text the entry reads (this file's readFileSync goes through the same mock).
    const withoutRelay = loadManifest();
    delete withoutRelay.relay;
    const withoutPage = loadManifest();
    withoutPage.pages = withoutPage.pages.filter((page: { name: string }) => page.name !== 'relayDetail');

    mocks.manifestText = '{ not json';
    await expect(open()).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
    expect(errors.mock.calls.some((call) => String(call[0]).includes('shots manifest'))).toBe(true);

    errors.mockClear();
    mocks.manifestText = JSON.stringify(withoutRelay);
    await expect(open()).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
    expect(errors.mock.calls.some((call) => String(call[0]).includes('shots manifest'))).toBe(true);

    // The page name is in the implementation table but not in the manifest: also rejected, with a log line.
    errors.mockClear();
    mocks.manifestText = JSON.stringify(withoutPage);
    await expect(open()).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
    expect(errors.mock.calls.some((call) => String(call[0]).includes('shots manifest'))).toBe(true);
  });
});

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { makeRelayRequested } from '@oriveo/shared';
import { SENTINEL_PROBE_MODEL_ID, type RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import { RelaySetup } from './RelaySetup';
import { withRelayModelProbePass } from '../../../../lib/core/providers/relay-model-probe';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../../../lib/core/chat/stream-options';
import { sendStream } from '../../../../lib/core/providers/service';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  routerBack: vi.fn(),
  addProvider: vi.fn(),
  probeRelayEndpoint: vi.fn(),
  setHasCompletedOnboarding: vi.fn(),
  setLastUsedModelRef: vi.fn(),
  getVanillaStore: vi.fn(),
}));

type MockStore = {
  setHasCompletedOnboarding: (value: boolean) => void;
  setLastUsedModelRef: (ref: unknown) => void;
  providers: unknown[];
};

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: mocks.routerBack }),
  useSearchParams: () => new URLSearchParams(window.location.search),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('@oriveo/shared', async () => {
  const actual = await vi.importActual<typeof import('@oriveo/shared')>('@oriveo/shared');
  return { ...actual, formatApiKeyPreview: (key: string) => `preview-${key}` };
});

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockStore) => unknown) => selector({
    setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    setLastUsedModelRef: mocks.setLastUsedModelRef,
    providers: [],
  }),
  getVanillaStore: () => mocks.getVanillaStore(),
}));

vi.mock('../../../../lib/core/provider-ops', () => ({
  addProvider: (...args: unknown[]) => mocks.addProvider(...args),
}));

vi.mock('../../../../lib/core/providers/probe/probe-runner', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../../lib/core/providers/probe/probe-runner')>();
  return {
    ...actual,
    probeRelayEndpoint: (...args: unknown[]) => mocks.probeRelayEndpoint(...args),
  };
});

vi.mock('../../../../lib/utils/id-utils', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/utils/id-utils')>()),
  createCanonicalUUID: () => 'relay-provider-id',
}));

vi.mock('@oriveo/ui', () => ({
  Dialog: ({ open, children, ariaLabelledBy }: { open: boolean; children: React.ReactNode; ariaLabelledBy?: string }) =>
    open ? <div role="dialog" aria-labelledby={ariaLabelledBy}>{children}</div> : null,
  BackButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
  CloseButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
  Button: ({
    children,
    onClick,
    disabled,
    className,
    ...rest
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    className?: string;
    'data-testid'?: string;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled} className={className} data-testid={rest['data-testid']}>
      {children}
    </button>
  ),
}));

function catalogModel(id: string): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
  };
}

function detectedResult(
  state: 'verified' | 'needs_manual_model',
  options: {
    modelIDs?: string[];
    generationVerified?: boolean;
    evidence?: 'catalog' | 'generation_probe';
    diagnostic?: string;
  } = {},
): RelayDiscoveryResult {
  const modelIDs = options.modelIDs ?? ['gpt-5.4', 'gpt-5.4-mini'];
  return {
    state,
    attempts: [],
    diagnostic: options.diagnostic,
    retriedRequestCount: 0,
    detection: {
      transport: 'openai_responses',
      authMode: 'bearer',
      apiBaseURL: 'https://relay.example.com/codex',
      modelIDs,
      catalogModels: modelIDs.map(catalogModel),
      generationVerified: options.generationVerified ?? state === 'verified',
      catalogEvidenceSucceeded: (options.evidence ?? 'catalog') === 'catalog',
      detectionEvidence: options.evidence ?? 'catalog',
    },
  };
}

/** The request the production send chain (stream-options -> service.sendStream('relay') -> adapter) actually sends to the relay. */
async function captureRelaySend(provider: Provider, model: AIModel): Promise<{ url: string; headers: Headers }> {
  const calls: Array<{ url: string; headers: Headers }> = [];
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
    if (url.includes('/api/metadata')) throw new Error('metadata unavailable');
    calls.push({ url, headers });
    return new Response('data: [DONE]\n\n', { status: 200, headers: { 'content-type': 'text/event-stream' } });
  }));
  try {
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, undefined, false), model);
    const handle = sendStream('relay', provider.apiKey, model.id, [{ role: 'user', content: 'hi' }], provider.baseURLText, options);
    const reader = handle.stream.getReader();
    for (let i = 0; i < 20 && calls.length === 0; i += 1) {
      const { done } = await reader.read();
      if (done) break;
    }
    await reader.cancel().catch(() => undefined);
  } finally {
    vi.unstubAllGlobals();
  }
  if (!calls[0]) throw new Error('relay send issued no request');
  return calls[0];
}

function fillConnection(endpoint = 'https://relay.example.com/codex') {
  fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: endpoint } });
  fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: ' sk-test ' } });
}

/** Step 2: expand all groups and check these models (relay groups by family, so the catalog may be split across several groups). */
async function selectInStepTwo(...modelIDs: string[]) {
  await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
  for (const toggle of document.querySelectorAll('[data-testid="relay-setup-group"] button[aria-expanded="false"]')) {
    fireEvent.click(toggle);
  }
  for (const modelID of modelIDs) fireEvent.click(screen.getByRole('checkbox', { name: modelID }));
}

/** Step 2: when the catalog cannot be obtained, manually add models (adding checks them). */
async function addManuallyInStepTwo(modelID: string) {
  await screen.findByRole('heading', { name: 'twoStep.modelsTitle' });
  fireEvent.click(screen.getByTestId('relay_setup_models_add_manual_button'));
  fireEvent.change(screen.getByLabelText('twoStep.addModelManually', { selector: 'input' }), { target: { value: modelID } });
  fireEvent.click(screen.getByRole('button', { name: 'add' }));
}

/** The 1-token verification at save time goes through a real ping: generation requests always return 200, metadata unavailable. Returns the generation request URL. */
function stubGenerationOk(): string[] {
  const posts: string[] = [];
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
    if (url.includes('/api/metadata')) return new Response('{}', { status: 404 });
    posts.push(url);
    return new Response(JSON.stringify({ id: 'ok' }), { status: 200, headers: { 'content-type': 'application/json' } });
  }));
  return posts;
}

describe('RelaySetup', () => {
  beforeEach(() => {
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: false });
    window.history.replaceState({}, '', '/');
    sessionStorage.clear();
    for (const mock of Object.values(mocks)) mock.mockReset();
    mocks.getVanillaStore.mockReturnValue({ store: 'relay-store' });
    mocks.addProvider.mockResolvedValue(undefined);
  });

  it('shows only the baseline connection fields in relay quick setup, with the name belonging to manual setup', () => {
    render(<RelaySetup />);

    expect(screen.getByRole('heading', { name: 'heroTitle' })).toBeTruthy();
    expect(screen.queryByRole('tablist')).toBeNull();
    expect(screen.queryByLabelText('localCompute')).toBeNull();
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('button', { name: 'manualProtocol' })).toBeTruthy();
    expect(screen.queryByLabelText('relayType')).toBeNull();
    expect(screen.queryByLabelText('nameLabel')).toBeNull();
    expect(screen.getByLabelText('requestURLLabel')).toBeTruthy();
    expect(screen.getByLabelText('apiKeyLabel')).toBeTruthy();
    // The quick path has no default-model slot; the model input remains only on the manual setup path.
    expect(screen.queryByLabelText('defaultModelLabel')).toBeNull();
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });

  it('does not repeat the relay or local scenario choice inside the setup page', () => {
    render(<RelaySetup />);

    expect(screen.queryByRole('tab')).toBeNull();
    expect(screen.queryByText('connectionMethod')).toBeNull();
    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect(screen.getByRole('heading', { name: 'heroTitle' })).toBeTruthy();
  });

  it('opens Local compute directly from ?mode=local without inferring cleartext authorization', () => {
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: true });
    window.history.pushState({}, '', '/providers/relay/new?mode=local');
    render(<RelaySetup />);

    expect(screen.getByRole('heading', { name: 'localHeroTitle' })).toBeTruthy();
    expect(screen.queryByRole('tablist')).toBeNull();
    expect(window.location.search).toBe('?mode=local');
    // The local page no longer has a plaintext confirmation toggle; the address itself decides whether it can connect; with an empty address the primary button is unavailable.
    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(true);
    window.history.replaceState({}, '', '/');
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: false });
  });

  it('detects through the production probe, persists the exact API root and only enables the default model', async () => {
    mocks.probeRelayEndpoint.mockResolvedValueOnce(detectedResult('verified'));
    const posts = stubGenerationOk();
    try {
      render(<RelaySetup />);
      fillConnection('relay.example.com/codex');

      fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));

      // Step 1 only discovers the catalog, carries no model hint and makes no 1-token request.
      await waitFor(() => expect(mocks.probeRelayEndpoint).toHaveBeenCalledWith(expect.objectContaining({
        endpoint: 'https://relay.example.com/codex',
        deferModelVerification: true,
      })));
      expect(mocks.probeRelayEndpoint.mock.calls[0]![0]).not.toHaveProperty('modelHint', expect.anything());
      expect(posts).toEqual([]);
      await selectInStepTwo('gpt-5.4-mini');
      fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));

      await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
      expect(posts).toHaveLength(1);
      expect(mocks.addProvider).toHaveBeenCalledWith(
        { store: 'relay-store' },
        expect.objectContaining({
          id: 'relay-provider-id',
          kind: 'relay',
          customName: 'example.com',
          status: { kind: 'connected' },
          baseURLText: 'https://relay.example.com/codex',
          relayResolvedBaseURLText: 'https://relay.example.com/codex',
          apiKey: 'sk-test',
          apiKeyPreview: 'preview-sk-test',
          // A relay has no default model: the selected models are only enabled, not marked default.
          models: [expect.objectContaining({ id: 'gpt-5.4-mini', isDefault: false })],
          catalogModels: [
            expect.objectContaining({ id: 'gpt-5.4', isDefault: false }),
            expect.objectContaining({ id: 'gpt-5.4-mini', isDefault: false }),
          ],
          // The quick-mode user chose no protocol: the connection stays auto, and the protocol found by probing is no longer written into the connection;
          // auth is auto, Responses storage is off, and when the discovered protocol is not the connection's actual default (Chat) the root goes into the address table.
          relayRequested: expect.objectContaining({
            transport: 'auto',
            authMode: 'auto',
            disableResponseStorage: true,
            resolvedAPIBaseURLs: expect.objectContaining({ openai_responses: 'https://relay.example.com/codex' }),
          }),
        }),
        expect.objectContaining({ shouldCommit: expect.any(Function) }),
      );
      const saved = mocks.addProvider.mock.calls[0][1] as Provider;
      expect(saved.relayRequested?.resolvedAPIBaseURL).toBeUndefined();
      expect(saved.relayRequested).not.toHaveProperty('codexCompatIdentity');
      expect(saved.relayRequested?.modelID).toBeUndefined();
      expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledWith(true);
      expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('RD1-WRITE-01 after register-and-save: no model isDefault, relayRequested.modelID is empty, the selected models are enabled and selected', async () => {
    mocks.probeRelayEndpoint.mockResolvedValueOnce(detectedResult('verified'));
    stubGenerationOk();
    try {
      render(<RelaySetup />);
      fillConnection('relay.example.com/codex');
      fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
      await selectInStepTwo('gpt-5.4');
      fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));

      await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
      const saved = mocks.addProvider.mock.calls[0][1] as Provider;
      expect([...saved.models, ...saved.catalogModels].some((model) => model.isDefault)).toBe(false);
      expect(saved.relayRequested?.modelID ?? '').toBe('');
      expect(saved.models.map((model) => model.id)).toEqual(['gpt-5.4']);
      expect(mocks.setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'relay-provider-id', modelID: 'gpt-5.4' });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('empty catalog stays on step 1 with the upstream detail, then step 2 starts in the manual-add state and nothing is saved unverified', async () => {
    mocks.probeRelayEndpoint.mockResolvedValueOnce(detectedResult('needs_manual_model', {
      modelIDs: [],
      generationVerified: false,
      evidence: 'generation_probe',
      diagnostic: 'upstream unknown model detail',
    }));
    render(<RelaySetup />);
    fillConnection('https://relay.example.com');

    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByText('twoStep.modelsEmpty')).toBeTruthy();
    expect(screen.getByText('upstream unknown model detail')).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'twoStep.modelsTitle' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(await screen.findByRole('heading', { name: 'twoStep.modelsTitle' })).toBeTruthy();
    expect((screen.getByTestId('relay_setup_models_save_button') as HTMLButtonElement).disabled).toBe(true);
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });

  it('maps a rejected production probe into the unified failed result and redacts the current credential from its visible diagnostic', async () => {
    const currentKey = 'sk-current-secret-12345';
    mocks.probeRelayEndpoint.mockRejectedValueOnce(new Error(`upstream rejected ${currentKey}`));
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: currentKey } });

    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));

    expect(await screen.findByText('twoStep.failNetwork')).toBeTruthy();
    expect(screen.getByText(`upstream rejected [redacted]`)).toBeTruthy();
    expect(screen.queryByText(currentKey)).toBeNull();
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled).toBe(false);
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });

  it('still completes connected onboarding with the user model when the production probe catalog is all 404 but generation returns 200', async () => {
    const production = await vi.importActual<typeof import('../../../../lib/core/providers/probe/probe-runner')>(
      '../../../../lib/core/providers/probe/probe-runner',
    );
    vi.stubGlobal('fetch', vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'POST') {
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      }
      return new Response(JSON.stringify({ error: 'route missing' }), {
        status: 404,
        headers: { 'content-type': 'application/json' },
      });
    }));
    const productionResult = await production.probeRelayEndpoint({
      endpoint: 'https://relay.example.com/v1',
      apiKey: 'sk-test',
      modelHint: 'user-model',
      forcedTransport: 'openai_chat_completions',
      securityMode: 'remote_https',
      retryBackoffMs: [],
    });
    expect(productionResult).toMatchObject({
      state: 'verified',
      detection: {
        generationVerified: true,
        catalogEvidenceSucceeded: false,
        detectionEvidence: 'generation_probe',
      },
    });
    mocks.probeRelayEndpoint.mockResolvedValueOnce(productionResult);
    const posts = stubGenerationOk();
    try {
      render(<RelaySetup />);
      fillConnection('https://relay.example.com/v1');

      // Catalog unavailable: step 1 stays; tapping Next goes to step 2 to add the user model manually, and the single verification at save passes.
      fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
      expect(await screen.findByText('twoStep.modelsEmpty')).toBeTruthy();
      fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
      await addManuallyInStepTwo('user-model');
      fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));

      await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
      expect(posts).toHaveLength(1);
      expect(mocks.addProvider.mock.calls[0][1]).toEqual(expect.objectContaining({
        status: { kind: 'connected' },
        lastError: undefined,
        models: [expect.objectContaining({ id: 'user-model' })],
        relayCapabilityBitmap: {
          modelsList: false,
          responses: false,
          chatCompletions: true,
          messages: false,
          geminiGenerateContent: false,
        },
      }));
      expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledWith(true);
      expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('discards an in-flight result when the request URL changes', async () => {
    let resolveProbe!: (result: RelayDiscoveryResult) => void;
    mocks.probeRelayEndpoint.mockImplementationOnce(() => new Promise((resolve) => {
      resolveProbe = resolve;
    }));
    render(<RelaySetup />);
    fillConnection('https://old.example.com');

    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), {
      target: { value: 'https://new.example.com' },
    });
    resolveProbe(detectedResult('verified'));

    await waitFor(() => {
      expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled)
        .toBe(false);
    });
    expect(screen.queryByTestId('relay-setup-detection')).toBeNull();
    expect(screen.queryByRole('heading', { name: 'twoStep.modelsTitle' })).toBeNull();
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });

  it('manual setup verifies the chosen protocol with one request and never runs discovery', async () => {
    const posts = stubGenerationOk();
    try {
      render(<RelaySetup />);
      fillConnection();

      fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
      // The kind-card page has been removed: the protocol is chosen in the default protocol row.
      expect(screen.queryByRole('button', { name: /kind\./ })).toBeNull();
      fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol'), { target: { value: 'openai_responses' } });
      fireEvent.change(screen.getByLabelText('pages.relaySetup.defaultModelLabel'), { target: { value: 'gpt-5.4' } });
      fireEvent.change(screen.getByLabelText('pages.relaySetup.manual.connectionName'), { target: { value: ' Work Relay ' } });
      fireEvent.click(screen.getByTestId('relay_manual_setup_primary_button'));

      await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
      expect(mocks.probeRelayEndpoint).not.toHaveBeenCalled();
      expect(posts).toEqual(['https://relay.example.com/codex/v1/responses']);
      const saved = mocks.addProvider.mock.calls[0][1] as Provider;
      expect(saved.customName).toBe('Work Relay');
      expect(saved.relayRequested?.transport).toBe('openai_responses');
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('rejects invalid request URLs and non-ASCII API keys before probing', () => {
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), {
      target: { value: 'http://192.168.1.20:8080/v1' },
    });
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), {
      target: { value: 'sk-test\u3000key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));

    // The hint copy comes from the shared issue-to-key mapping, and keys carry a namespace (next-intl is mocked here to echo the key).
    expect(screen.getByText('common.relayHttpsRequired')).toBeTruthy();
    expect(screen.getByText('common.apiKeyInvalidChars')).toBeTruthy();
    expect(mocks.probeRelayEndpoint).not.toHaveBeenCalled();
  });

  it('decides whether the key is required from authMode, not from whether the input is empty', () => {
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), {
      target: { value: 'https://relay.example.com/v1' },
    });

    // None of the four preset protocols use authMode none (openai_compatible defaults to bearer),
    // so the field stays required: what changed is where the condition comes from, not that
    // validation was loosened.
    expect(makeRelayRequested('openai_compatible').authMode).toBe('bearer');
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled)
      .toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(mocks.probeRelayEndpoint).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: 'sk-test' } });
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled)
      .toBe(false);
  });

  it('exposes no security toggle on the relay creation page and rejects plaintext addresses under public HTTPS', () => {
    render(<RelaySetup />);
    fillConnection('http://192.168.1.20:8080/v1');

    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect((screen.getByRole('button', { name: 'twoStep.next' }) as HTMLButtonElement).disabled)
      .toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
    expect(mocks.probeRelayEndpoint).not.toHaveBeenCalled();
  });

  it('uses a real model ID as the default model placeholder', () => {
    render(<RelaySetup />);
    // The model input exists only on the manual setup path.
    expect(screen.queryByLabelText('pages.relaySetup.defaultModelLabel')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
    expect(screen.getByLabelText('pages.relaySetup.defaultModelLabel').getAttribute('placeholder')).toBe('gpt-5.6-sol');
  });

  describe('RL2-PROBE-03 adding a relay probes only the default model', () => {
    type Short = 'chat' | 'responses' | 'messages' | 'gemini';
    interface AddScenario {
      caseId: string;
      test: string;
      step: string;
      connection: { baseURL: string; transport: string };
      models: Array<{ id: string; supportedEndpointTypes?: string[] }>;
      defaultModel: string;
      ping: Record<string, string>;
      expect: {
        pings: Array<[string, Short]>;
        verified: boolean;
        connectionTransport: string;
        resolvedAPIBaseURLs: Record<string, string>;
        models: Record<string, { relayTransport?: string; relayTransportSource?: string }>;
      };
    }

    function loadOrchestration(): { transports: Record<Short, string>; scenarios: AddScenario[] } {
      let dir = process.cwd();
      for (let depth = 0; depth < 8; depth += 1) {
        const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'probe-orchestration.v1.json');
        if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8'));
        dir = path.dirname(dir);
      }
      throw new Error('probe-orchestration.v1.json not found');
    }

    const orchestration = loadOrchestration();

    const OUTCOME_STATUS: Readonly<Record<string, number>> = {
      http_400: 400, http_401: 401, http_403: 403, http_404: 404, http_405: 405,
      http_415: 415, http_422: 422, http_429: 429, http_5xx: 502,
    };

    /** Fake gateway: GET .../models returns the fixture catalog; POST looks up the ping table by `<model>@<protocol>`, anything unlisted is 404. */
    function installFakeRelay(scenario: AddScenario): Array<[string, Short]> {
      const pings: Array<[string, Short]> = [];
      vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        sentBodies.push(String(init?.body ?? ''));
        const headers = new Headers(init?.headers);
        const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
        const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
        if (url.includes('/api/metadata/')) return new Response('{}', { status: 404 });
        if (method === 'GET' && url.endsWith('/models')) {
          return new Response(JSON.stringify({
            object: 'list',
            data: scenario.models.map((model) => ({
              id: model.id,
              object: 'model',
              ...(model.supportedEndpointTypes ? { supported_endpoint_types: model.supportedEndpointTypes } : {}),
            })),
          }), { status: 200, headers: { 'content-type': 'application/json' } });
        }
        if (method !== 'POST') return new Response('{}', { status: 404 });
        const body = JSON.parse(String(init?.body ?? '{}')) as { model?: string };
        const gemini = /\/models\/([^/:]+):generateContent$/.exec(url);
        const transport: Short = gemini
          ? 'gemini'
          : url.endsWith('/messages')
            ? 'messages'
            : url.endsWith('/responses')
              ? 'responses'
              : 'chat';
        const modelID = gemini ? decodeURIComponent(gemini[1]!) : body.model ?? '';
        pings.push([modelID, transport]);
        const outcome = scenario.ping[`${modelID}@${transport}`] ?? 'http_404';
        if (outcome === 'ok') {
          return new Response(JSON.stringify({ id: 'ok' }), { status: 200, headers: { 'content-type': 'application/json' } });
        }
        if (outcome === 'network') throw new TypeError('Failed to fetch');
        // Throw directly on an unrecognized result name, so a new result is not silently treated as 404 and passing.
        const status = OUTCOME_STATUS[outcome];
        if (status === undefined) throw new Error(`unknown probe outcome in fixture: ${outcome}`);
        return new Response(JSON.stringify({ error: { message: outcome } }), {
          status,
          headers: { 'content-type': 'application/json' },
        });
      }));
      return pings;
    }

    const addScenarios = orchestration.scenarios.filter((item) => item.test === 'RL2-PROBE-03');

    /* RL2-PROBE-06: adding a relay sends no capability test request (neither the built-in image nor tool names appear in the request body). */
    const capabilityBuiltins = (() => {
      let dir = process.cwd();
      for (let depth = 0; depth < 8; depth += 1) {
        const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'capability-test.v1.json');
        if (existsSync(candidate)) {
          return (JSON.parse(readFileSync(candidate, 'utf8')) as { builtins: { imagePNGBase64: string; tool: { name: string } } }).builtins;
        }
        dir = path.dirname(dir);
      }
      throw new Error('capability-test.v1.json not found');
    })();
    let sentBodies: string[] = [];
    function expectNoCapabilityTestRequests() {
      expect(sentBodies.some((body) => body.includes(capabilityBuiltins.imagePNGBase64))).toBe(false);
      expect(sentBodies.some((body) => body.includes(capabilityBuiltins.tool.name))).toBe(false);
    }

    it('RL2-PROBE-03 no catalog, generation-route discovery: the model manually added in step 2 is verified only once at save, candidates lead with the protocol found via the generation route, recorded as passing once for that model, and the connection stays auto', async () => {
      const production = await vi.importActual<typeof import('../../../../lib/core/providers/probe/probe-runner')>(
        '../../../../lib/core/providers/probe/probe-runner',
      );
      mocks.probeRelayEndpoint.mockImplementation((input: Parameters<typeof production.probeRelayEndpoint>[0]) => (
        production.probeRelayEndpoint({ ...input, retryBackoffMs: [] })
      ));
      const posts: string[] = [];
      vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const headers = new Headers(init?.headers);
        const url = headers.get('X-Relay-Upstream-URL') ?? String(input);
        const method = headers.get('X-Relay-Upstream-Method') ?? init?.method ?? 'GET';
        if (method === 'POST') {
          posts.push(`${(JSON.parse(String(init?.body ?? '{}')) as { model?: string }).model}@${url}`);
          if (url === 'https://relay.example.com/v1/messages') {
            return new Response('{"id":"ok"}', { status: 200, headers: { 'content-type': 'application/json' } });
          }
        }
        return new Response('{"error":"route missing"}', { status: 404, headers: { 'content-type': 'application/json' } });
      }));
      try {
        render(<RelaySetup />);
        fillConnection('https://relay.example.com');
        fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
        expect(await screen.findByText('twoStep.modelsEmpty')).toBeTruthy();
        // Step 1 sent only generation-route discovery (a sentinel model), with no 1-token request to any real model.
        expect(posts.every((post) => post.startsWith(`${SENTINEL_PROBE_MODEL_ID}@`))).toBe(true);
        const discoveryPosts = posts.length;
        fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
        await addManuallyInStepTwo('claude-sonnet-4-5');
        fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
        await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));

        // The protocol evidence found is carried into the verification candidates: even if the family cannot be looked up, Messages is tried first and passes at once.
        expect(posts.slice(discoveryPosts)).toEqual(['claude-sonnet-4-5@https://relay.example.com/v1/messages']);
        const provider = mocks.addProvider.mock.calls[0][1] as Provider;
        expect(provider.status).toEqual({ kind: 'connected' });
        expect(provider.relayRequested?.transport).toBe('auto');
        expect(provider.relayResolvedTransport).toBeUndefined();
        expect(provider.relayRequested?.resolvedAPIBaseURLs).toEqual({
          anthropic_messages: 'https://relay.example.com/v1',
        });
        expect(provider.models).toEqual([expect.objectContaining({
          id: 'claude-sonnet-4-5',
          relayTransport: 'anthropic_messages',
          relayTransportSource: 'reachable',
        })]);
      } finally {
        vi.unstubAllGlobals();
      }
    });

    it('RL2-PROBE-03 claude hint + auto-detect connection: the connection does not store the auth / header profile of the discovered protocol, and a later enabled gpt-4o-mini sends with bearer and no Anthropic headers', async () => {
      const scenario = addScenarios.find((item) => item.caseId === 'add_moves_to_the_second_candidate_when_the_first_fails')!;
      const production = await vi.importActual<typeof import('../../../../lib/core/providers/probe/probe-runner')>(
        '../../../../lib/core/providers/probe/probe-runner',
      );
      mocks.probeRelayEndpoint.mockImplementation((input: Parameters<typeof production.probeRelayEndpoint>[0]) => (
        production.probeRelayEndpoint({ ...input, retryBackoffMs: [] })
      ));
      installFakeRelay(scenario);
      let saved: Provider;
      try {
        render(<RelaySetup />);
        fillConnection(scenario.connection.baseURL);
        fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
        await selectInStepTwo(scenario.defaultModel);
        fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
        await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
        saved = mocks.addProvider.mock.calls[0][1] as Provider;
      } finally {
        vi.unstubAllGlobals();
      }

      const gpt: AIModel = {
        id: 'gpt-4o-mini', name: 'gpt-4o-mini', capabilities: ['text'],
        reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '',
      };
      const following = { ...saved, models: [...saved.models, gpt] };
      const probed = withRelayModelProbePass(following, gpt.id, {
        transport: 'openai_chat_completions',
        apiBaseURL: 'https://relay.example.com/v1',
      });
      for (const [label, provider] of [['follows connection', following], ['lazily verified as chat', probed]] as const) {
        const model = provider.models.find((item) => item.id === gpt.id)!;
        const sent = await captureRelaySend(provider, model);
        expect(sent.url, label).toBe('https://relay.example.com/v1/chat/completions');
        // The browser forwards via /api/relay/forward: the upstream auth header is decided only by X-Relay-Proxy-Config.authMode
        // (bearer -> Authorization; x_api_key -> x-api-key + anthropic-version).
        const proxy = JSON.parse(sent.headers.get('x-relay-proxy-config') ?? '{}') as { authMode?: string; transport?: string };
        expect(proxy, label).toMatchObject({ transport: 'openai_chat_completions', authMode: 'bearer' });
        expect(sent.headers.get('x-api-key'), label).toBeNull();
        expect(sent.headers.get('anthropic-version'), label).toBeNull();
      }
      expect(saved.relayRequested?.transport).toBe('auto');
      expect(saved.relayResolvedAuthMode).toBeUndefined();
      expect(saved.relayResolvedHeaderProfile).toBeUndefined();
      expect(saved.relayResolvedFamilyHint).toBeUndefined();
    });

    it('RL2-PROBE-03 the fixture has an add scenario', () => {
      expect(addScenarios.length).toBeGreaterThan(0);
      // A scenario that stops when nothing is detected must actually be executed.
      expect(addScenarios.map((item) => item.caseId))
        .toContain('add_stops_at_an_inconclusive_first_candidate_and_is_not_verified');
    });

    for (const scenario of addScenarios) {
      it(`RL2-PROBE-03 ${scenario.caseId}`, async () => {
        const production = await vi.importActual<typeof import('../../../../lib/core/providers/probe/probe-runner')>(
          '../../../../lib/core/providers/probe/probe-runner',
        );
        mocks.probeRelayEndpoint.mockImplementation((input: Parameters<typeof production.probeRelayEndpoint>[0]) => (
          production.probeRelayEndpoint({ ...input, retryBackoffMs: [] })
        ));
        sentBodies = [];
        const pings = installFakeRelay(scenario);
        try {
          render(<RelaySetup />);
          fillConnection(scenario.connection.baseURL);
          const manual = scenario.connection.transport !== 'auto';
          if (manual) {
            // The user picks a protocol and goes through manual setup: the selected protocol sends 1 request for this model only, no probing, and the model gets no protocol.
            fireEvent.click(screen.getByRole('button', { name: 'manualProtocol' }));
            fireEvent.change(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol'), {
              target: { value: scenario.connection.transport },
            });
            fireEvent.change(screen.getByLabelText('pages.relaySetup.defaultModelLabel'), { target: { value: scenario.defaultModel } });
            fireEvent.click(screen.getByTestId('relay_manual_setup_primary_button'));
          } else {
            // Auto-detect goes through two steps: step 2 checks the model and save verifies only it.
            fireEvent.click(screen.getByRole('button', { name: 'twoStep.next' }));
            await selectInStepTwo(scenario.defaultModel);
            fireEvent.click(screen.getByTestId('relay_setup_models_save_button'));
          }

          if (!scenario.expect.verified) {
            // The failure card no longer carries a "detection failed" title; judged as a failure-state result card.
            await waitFor(() => expect(document.querySelector('[role="status"][data-state="error"]')).toBeTruthy());
            expect(pings).toEqual(scenario.expect.pings);
            expect(mocks.addProvider).not.toHaveBeenCalled();
            expectNoCapabilityTestRequests();
            return;
          }

          await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
          expect(pings).toEqual(scenario.expect.pings);
          const provider = mocks.addProvider.mock.calls[0][1] as Provider;
          expect(provider.status).toEqual({ kind: 'connected' });
          expect(provider.relayRequested?.transport).toBe(scenario.expect.connectionTransport);
          // The fixture compares only the items written by the probe step itself (= the protocols of reachable models); the root written by catalog discovery is asserted separately.
          const probedTransports = new Set(provider.models
            .filter((model) => model.relayTransportSource === 'reachable')
            .map((model) => model.relayTransport!));
          const written = provider.relayRequested?.resolvedAPIBaseURLs ?? {};
          expect(Object.fromEntries(Object.entries(written).filter(([key]) => probedTransports.has(key as never))))
            .toEqual(scenario.expect.resolvedAPIBaseURLs);
          if (scenario.caseId === 'add_moves_to_the_second_candidate_when_the_first_fails') {
            // Step 1 no longer carries a model hint: the catalog is discovered over Chat in default order = auto's actual default, the root is written to the single-value field and not into the address table.
            expect(written.anthropic_messages).toBeUndefined();
            expect(provider.relayRequested?.resolvedAPIBaseURL).toBe('https://relay.example.com/v1');
          }
          // The probe result lands only on the model; the connection-level legacy dispatch fields are no longer written.
          expect(provider.relayResolvedTransport).toBeUndefined();
          for (const [modelID, expected] of Object.entries(scenario.expect.models)) {
            const model = provider.models.find((item) => item.id === modelID)
              ?? provider.catalogModels.find((item) => item.id === modelID);
            expect(model, modelID).toBeDefined();
            expect({
              relayTransport: model!.relayTransport,
              relayTransportSource: model!.relayTransportSource,
            }, modelID).toEqual({
              relayTransport: expected.relayTransport,
              relayTransportSource: expected.relayTransportSource,
            });
          }
          // The other models get 0 requests: probing only hit the default model.
          expect(new Set(pings.map(([modelID]) => modelID))).toEqual(new Set([scenario.defaultModel]));
          expectNoCapabilityTestRequests();
        } finally {
          vi.unstubAllGlobals();
        }
      });
    }
  });
});

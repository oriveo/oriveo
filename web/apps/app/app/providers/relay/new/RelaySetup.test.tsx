import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { makeRelayRequested } from '@oriveo/shared';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import { RelaySetup } from './RelaySetup';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  routerBack: vi.fn(),
  addProvider: vi.fn(),
  probeRelayEndpoint: vi.fn(),
  setHasCompletedOnboarding: vi.fn(),
  getVanillaStore: vi.fn(),
}));

type MockStore = {
  setHasCompletedOnboarding: (value: boolean) => void;
  providers: unknown[];
};

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: mocks.routerBack }),
  useSearchParams: () => new URLSearchParams(window.location.search),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('@oriveo/shared', async () => {
  const actual = await vi.importActual<typeof import('@oriveo/shared')>('@oriveo/shared');
  return { ...actual, formatApiKeyPreview: (key: string) => `preview-${key}` };
});

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockStore) => unknown) => selector({
    setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
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

vi.mock('../../../../lib/utils/id-utils', () => ({
  createCanonicalUUID: () => 'relay-provider-id',
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    className,
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    className?: string;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled} className={className}>
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

function fillConnection(endpoint = 'https://relay.example.com/codex') {
  fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: endpoint } });
  fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: ' sk-test ' } });
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

    expect(screen.getByRole('heading', { name: 'customEndpoint' })).toBeTruthy();
    expect(screen.queryByRole('tablist')).toBeNull();
    expect(screen.queryByLabelText('localCompute')).toBeNull();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('button', { name: /manualSetup/ })).toBeTruthy();
    expect(screen.queryByLabelText('relayType')).toBeNull();
    expect(screen.queryByLabelText('nameLabel')).toBeNull();
    expect(screen.getByLabelText('requestURLLabel')).toBeTruthy();
    expect(screen.getByLabelText('apiKeyLabel')).toBeTruthy();
    expect(screen.getByLabelText('defaultModelLabel')).toBeTruthy();
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });

  it('does not repeat the relay or local scenario choice inside the setup page', () => {
    render(<RelaySetup />);

    expect(screen.queryByRole('tab')).toBeNull();
    expect(screen.queryByText('connectionMethod')).toBeNull();
    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect(screen.getByRole('heading', { name: 'customEndpoint' })).toBeTruthy();
  });

  it('opens Local compute directly from ?mode=local without inferring cleartext authorization', () => {
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: true });
    window.history.pushState({}, '', '/providers/relay/new?mode=local');
    render(<RelaySetup />);

    expect(screen.getByRole('heading', { name: 'localCompute' })).toBeTruthy();
    expect(screen.queryByRole('tablist')).toBeNull();
    expect(window.location.search).toBe('?mode=local');
    expect(screen.getByRole('button', { name: 'changeConnectionType' }).textContent)
      .toContain('connectionTypeRemoteHttps');
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(true);
    window.history.replaceState({}, '', '/');
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: false });
  });

  it('detects through the production probe, persists the exact API root and only enables the default model', async () => {
    mocks.probeRelayEndpoint.mockResolvedValueOnce(detectedResult('verified'));
    render(<RelaySetup />);
    fillConnection('relay.example.com/codex');

    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

    await waitFor(() => expect(mocks.probeRelayEndpoint).toHaveBeenCalledWith(expect.objectContaining({
      endpoint: 'https://relay.example.com/codex',
    })));
    const endpoint = screen.getByLabelText('requestURLLabel') as HTMLInputElement;
    await waitFor(() => {
      expect(endpoint.value).toBe('https://relay.example.com/codex');
      expect(document.activeElement).toBe(endpoint);
      expect(endpoint.selectionStart).toBe(0);
      expect(endpoint.selectionEnd).toBe(endpoint.value.length);
    });

    expect(await screen.findByRole('button', { name: 'connectAndSave' })).toBeTruthy();
    expect((screen.getByRole('combobox', { name: 'defaultModelLabel' }) as HTMLSelectElement).value)
      .toBe('gpt-5.4');
    fireEvent.change(screen.getByRole('combobox', { name: 'defaultModelLabel' }), {
      target: { value: 'gpt-5.4-mini' },
    });
    expect(screen.getByRole('button', { name: 'connectAndSave' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSave' }));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
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
        models: [expect.objectContaining({ id: 'gpt-5.4-mini', isDefault: true })],
        catalogModels: [
          expect.objectContaining({ id: 'gpt-5.4', isDefault: false }),
          expect.objectContaining({ id: 'gpt-5.4-mini', isDefault: true }),
        ],
        relayRequested: expect.objectContaining({
          transport: 'openai_responses',
          modelID: 'gpt-5.4-mini',
          resolvedAPIBaseURL: 'https://relay.example.com/codex',
        }),
      }),
      expect.objectContaining({ shouldCommit: expect.any(Function) }),
    );
    expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledWith(true);
    expect(mocks.routerPush).toHaveBeenCalledWith('/providers/relay-provider-id');
  });

  it('saves an empty catalog as issue and preserves onboarding context for manual model entry', async () => {
    mocks.probeRelayEndpoint.mockResolvedValueOnce(detectedResult('needs_manual_model', {
      modelIDs: [],
      generationVerified: false,
      evidence: 'generation_probe',
      diagnostic: 'upstream unknown model detail',
    }));
    render(<RelaySetup />);
    fillConnection('https://relay.example.com');

    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    expect(await screen.findByRole('button', { name: 'saveAndContinue' })).toBeTruthy();
    expect(screen.getByText('probeProtocol')).toBeTruthy();
    expect(screen.getByText('upstream unknown model detail')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'saveAndContinue' }));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(mocks.addProvider.mock.calls[0][1]).toEqual(expect.objectContaining({
      status: { kind: 'issue', message: 'connectionUnverified' },
      models: [],
      catalogModels: [],
      lastError: 'connectionUnverified',
    }));
    expect(mocks.setHasCompletedOnboarding).not.toHaveBeenCalled();
    expect(mocks.routerPush).toHaveBeenCalledWith(
      '/providers/relay-provider-id/manual-model?context=onboarding',
    );
  });

  it('maps a rejected production probe into the unified failed result and redacts the current credential from its visible diagnostic', async () => {
    const currentKey = 'sk-current-secret-12345';
    mocks.probeRelayEndpoint.mockRejectedValueOnce(new Error(`upstream rejected ${currentKey}`));
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://relay.example.com' } });
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: currentKey } });

    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

    expect(await screen.findByText('relayDetectionFailed')).toBeTruthy();
    expect(screen.getByText(`upstream rejected [redacted]`)).toBeTruthy();
    expect(screen.queryByText(currentKey)).toBeNull();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(false);
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
    render(<RelaySetup />);
    fillConnection('https://relay.example.com/v1');

    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    expect(await screen.findByRole('button', { name: 'connectAndSave' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSave' }));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(mocks.addProvider.mock.calls[0][1]).toEqual(expect.objectContaining({
      status: { kind: 'connected' },
      lastError: undefined,
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
    vi.unstubAllGlobals();
  });

  it('discards an in-flight result when the request URL changes', async () => {
    let resolveProbe!: (result: RelayDiscoveryResult) => void;
    mocks.probeRelayEndpoint.mockImplementationOnce(() => new Promise((resolve) => {
      resolveProbe = resolve;
    }));
    render(<RelaySetup />);
    fillConnection('https://old.example.com');

    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    expect((screen.getByRole('button', { name: 'testingRelay' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), {
      target: { value: 'https://new.example.com' },
    });
    resolveProbe(detectedResult('verified'));

    await waitFor(() => {
      expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled)
        .toBe(false);
    });
    expect(screen.queryByText('relayDetected')).toBeNull();
    expect(mocks.addProvider).not.toHaveBeenCalled();
  });

  it('manual protocol selection still runs discovery with the selected transport', async () => {
    mocks.probeRelayEndpoint.mockResolvedValueOnce(detectedResult('verified'));
    render(<RelaySetup />);
    fillConnection();

    fireEvent.click(screen.getByRole('button', { name: /manualSetup/ }));
    fireEvent.click(screen.getByRole('button', { name: /kind.codex.title/ }));
    expect(screen.getByLabelText('nameLabel')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('nameLabel'), { target: { value: ' Work Relay ' } });
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

    await waitFor(() => expect(mocks.probeRelayEndpoint).toHaveBeenCalledWith(expect.objectContaining({
      forcedTransport: 'openai_responses',
    })));
    expect(await screen.findByRole('button', { name: 'connectAndSave' })).toBeTruthy();
  });

  it('rejects invalid request URLs and non-ASCII API keys before probing', () => {
    render(<RelaySetup />);
    fireEvent.change(screen.getByLabelText('requestURLLabel'), {
      target: { value: 'http://192.168.1.20:8080/v1' },
    });
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), {
      target: { value: 'sk-test\u3000key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

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
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled)
      .toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    expect(mocks.probeRelayEndpoint).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: 'sk-test' } });
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled)
      .toBe(false);
  });

  it('exposes no security toggle on the relay creation page and rejects plaintext addresses under public HTTPS', () => {
    render(<RelaySetup />);
    fillConnection('http://192.168.1.20:8080/v1');

    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled)
      .toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    expect(mocks.probeRelayEndpoint).not.toHaveBeenCalled();
  });

  it('uses a real model ID as the default model placeholder', () => {
    render(<RelaySetup />);
    expect(screen.getByLabelText('defaultModelLabel').getAttribute('placeholder')).toBe('gpt-5.6-sol');
  });
});

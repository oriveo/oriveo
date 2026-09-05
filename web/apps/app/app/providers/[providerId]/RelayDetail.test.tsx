import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import { RelayDetail } from './RelayDetail';

const routerPush = vi.fn();
const routerBack = vi.fn();
const mockDeleteProvider = vi.fn();
const mockSaveRelaySettings = vi.fn();
const mockSaveName = vi.fn();
const mockSaveBaseURL = vi.fn();
const mockWriteBackBaseURL = vi.fn();
const mockSaveKey = vi.fn();
const mockRemoveKey = vi.fn();
const mockClearRelayCredentials = vi.fn();
const mockReconnectSecurityMode = vi.fn();
const mockAddModels = vi.fn();
const mockToggleModel = vi.fn();
const mockPingRelay = vi.fn();
const mockVerifyRelayConnection = vi.fn();
const mockSaveRelaySettingsUnverified = vi.fn();
const mockRetryRelaySettingsSave = vi.fn();
const mockClearRelaySettingsSaveFailure = vi.fn();
const mockRefreshRelayCatalog = vi.fn();
const mockRelaySettingsSavePlan = vi.fn(() => ({ needsVerification: false, needsCatalogRefresh: false }));
const mockActionState = vi.hoisted(() => ({
  isSyncing: false,
  catalogLoadState: 'idle' as 'idle' | 'loading' | 'loaded' | 'failed',
  relaySettingsSaveFailure: null as null | {
    error: unknown;
    phase: 'generation' | 'catalog';
    canSaveUnverified: boolean;
  },
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: routerPush,
    back: routerBack,
  }),
}));

vi.mock('next-intl', () => ({
  // Carry the ICU placeholders into the key so expansions like "testRelayConnected({endpoint:GET /models})" can be asserted
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
}));

// The ping request itself is mocked, but the error copy and the failure card projection go through the production sanitizer instead of a copy kept in the test.
vi.mock('../../../lib/core/providers/ping-relay', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/providers/ping-relay')>();
  return {
    ...actual,
    pingRelay: (...args: unknown[]) => mockPingRelay(...args),
  };
});

vi.mock('../../../lib/hooks/useProviderActions', () => ({
  useProviderActions: () => ({
    isSyncing: mockActionState.isSyncing,
    catalogLoadState: mockActionState.catalogLoadState,
    relaySettingsSaveFailure: mockActionState.relaySettingsSaveFailure,
    saveKey: mockSaveKey,
    removeKey: mockRemoveKey,
    clearRelayCredentials: mockClearRelayCredentials,
    reconnectRelaySecurityMode: mockReconnectSecurityMode,
    verifyRelayConnection: mockVerifyRelayConnection,
    saveBaseURL: mockSaveBaseURL,
    writeBackBaseURL: mockWriteBackBaseURL,
    saveName: mockSaveName,
    saveRelaySettings: mockSaveRelaySettings,
    relaySettingsSavePlan: mockRelaySettingsSavePlan,
    saveRelaySettingsUnverified: mockSaveRelaySettingsUnverified,
    retryRelaySettingsSave: mockRetryRelaySettingsSave,
    clearRelaySettingsSaveFailure: mockClearRelaySettingsSaveFailure,
    refreshRelayCatalog: mockRefreshRelayCatalog,
    addModels: mockAddModels,
    toggleModel: mockToggleModel,
    removeModel: vi.fn(),
    deleteProvider: mockDeleteProvider,
  }),
}));

const mockSetLastUsedModelRef = vi.fn();
const mockSetActiveConversationId = vi.fn();
vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: {
    setLastUsedModelRef: typeof mockSetLastUsedModelRef;
    setActiveConversationId: typeof mockSetActiveConversationId;
  }) => unknown) =>
    selector({
      setLastUsedModelRef: mockSetLastUsedModelRef,
      setActiveConversationId: mockSetActiveConversationId,
    }),
}));

vi.mock('./components/ConfirmDeleteDialog', () => ({
  ConfirmDeleteDialog: ({ onConfirm, onCancel }: { onConfirm: () => void; onCancel: () => void }) => (
    <div data-testid="confirm-delete-dialog">
      <button onClick={onConfirm}>confirmDelete</button>
      <button onClick={onCancel}>cancelDelete</button>
    </div>
  ),
}));

const STORED_KEY = 'sk-relay-secret-0123456789';

const provider: Provider = {
  id: 'relay-1',
  kind: 'relay',
  customName: 'Relay 1',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: STORED_KEY,
  // preview comes from the production masking function, the test does not write a lookalike string
  apiKeyPreview: formatApiKeyPreview(STORED_KEY),
  baseURLText: 'https://relay.example.com',
  relayKind: 'openai_compatible',
  relayRequested: {
    transport: 'openai_chat_completions',
    authMode: 'bearer',
    stream: true,
    reasoningEffort: 'automatic',
  },
};

const relayModel: AIModel = {
  id: 'gpt-image-1',
  name: 'gpt-image-1',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
};

describe('RelayDetail', () => {
  beforeEach(() => {
    routerPush.mockReset();
    routerBack.mockReset();
    mockDeleteProvider.mockReset();
    mockSaveRelaySettings.mockReset();
    mockSaveRelaySettings.mockResolvedValue(true);
    mockSaveName.mockReset();
    mockSaveBaseURL.mockReset();
    mockWriteBackBaseURL.mockReset();
    mockActionState.isSyncing = false;
    mockActionState.catalogLoadState = 'idle';
    mockActionState.relaySettingsSaveFailure = null;
    mockRelaySettingsSavePlan.mockReset();
    mockRelaySettingsSavePlan.mockReturnValue({ needsVerification: false, needsCatalogRefresh: false });
    mockSaveRelaySettingsUnverified.mockReset();
    mockRetryRelaySettingsSave.mockReset();
    mockClearRelaySettingsSaveFailure.mockReset();
    mockRefreshRelayCatalog.mockReset();
    mockSaveKey.mockReset();
    mockSaveBaseURL.mockResolvedValue(true);
    mockRemoveKey.mockReset();
    mockClearRelayCredentials.mockReset();
    mockReconnectSecurityMode.mockReset();
    mockReconnectSecurityMode.mockResolvedValue({
      state: 'verified',
      attempts: [],
      retriedRequestCount: 0,
      detection: {
        transport: 'openai_chat_completions',
        authMode: 'none',
        apiBaseURL: 'http://192.168.1.20:8080/v1',
        modelIDs: ['local-model'],
        catalogModels: [],
        generationVerified: true,
        catalogEvidenceSucceeded: true,
        detectionEvidence: 'catalog',
      },
    });
    mockAddModels.mockReset();
    mockToggleModel.mockReset();
    mockPingRelay.mockReset();
    mockVerifyRelayConnection.mockReset();
    mockVerifyRelayConnection.mockResolvedValue({ modelCount: 0, probedEndpoint: 'POST /chat/completions' });
    mockSetLastUsedModelRef.mockReset();
    mockSetActiveConversationId.mockReset();
  });

  it('shows the relay privacy disclosure on the detail page', () => {
    render(<RelayDetail provider={provider} />);

    expect(screen.getByText('privacyNote')).toBeTruthy();
  });

  // ── The five credential states; the state is derived from the provider by the production relayProviderCredentialState ──

  it('S2 with a saved key shows only the masked string and never puts the plaintext in the DOM', () => {
    const { container } = render(<RelayDetail provider={provider} />);

    expect(screen.getByText(formatApiKeyPreview(STORED_KEY))).toBeTruthy();
    expect(screen.queryByText('apiKeyRequired')).toBeNull();
    expect(container.innerHTML).not.toContain(STORED_KEY);
  });

  it('S2 after clicking edit the field is an empty password input with no reveal toggle', () => {
    const { container } = render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'editKey' }));
    const input = screen.getByLabelText('apiKey') as HTMLInputElement;
    expect(input.type).toBe('password');
    expect(input.value).toBe('');
    expect(container.innerHTML).not.toContain(STORED_KEY);
    expect(screen.queryByRole('button', { name: 'showKey' })).toBeNull();
    expect(screen.getByText('rotateKeyNote')).toBeTruthy();
  });

  it('S1 a missing key is a warning state offering add key, and saving an empty value must show a visible reason rather than returning silently', () => {
    render(<RelayDetail provider={{ ...provider, apiKey: '', apiKeyPreview: '' }} />);

    expect(screen.getByText('apiKeyRequired')).toBeTruthy();
    expect(screen.getByText('addKey')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'apiKey' }));
    // Pressing enter on an empty field: this used to be `if (!trimmed) return;`, which gave the user no feedback at all
    fireEvent.keyDown(screen.getByLabelText('apiKey'), { key: 'Enter' });
    expect(screen.getByRole('alert').textContent).toBe('apiKeyRequired');
    expect(mockSaveKey).not.toHaveBeenCalled();
  });

  it('S0 a local connection with auth=none is a neutral no key required, not an orange failure state', () => {
    render(<RelayDetail provider={{
      ...provider,
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: {
        ...provider.relayRequested!,
        authMode: 'none',
        securityMode: 'local_http',
      },
      relayResolvedAuthMode: 'none',
    }} />);

    expect(screen.getByText('credentialNotRequired')).toBeTruthy();
    expect(screen.getByText('credentialNotSentNote')).toBeTruthy();
    expect(screen.queryByText('apiKeyRequired')).toBeNull();
    // S0 has no CTA: the user should not be steered back into that dead end
    expect(screen.queryByText('addKey')).toBeNull();
    expect(screen.queryByText('changeKey')).toBeNull();
  });

  it('with auth=none and a leftover key, only a standalone remove action is offered and the key is not carried into verification', () => {
    render(<RelayDetail provider={{
      ...provider,
      relayRequested: { ...provider.relayRequested!, authMode: 'none' },
      relayResolvedAuthMode: 'none',
    }} />);

    fireEvent.click(screen.getByRole('button', { name: 'removeKey' }));
    expect(mockRemoveKey).toHaveBeenCalledOnce();
  });

  it('saving a non-credential field does not require a key to be present', async () => {
    render(<RelayDetail provider={{
      ...provider,
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: { ...provider.relayRequested!, authMode: 'none' },
      relayResolvedAuthMode: 'none',
    }} />);

    fireEvent.click(screen.getByRole('button', { name: 'editName' }));
    fireEvent.change(screen.getByDisplayValue('Relay 1'), { target: { value: 'Local Engine' } });
    fireEvent.click(screen.getByRole('button', { name: 'saveName' }));
    expect(mockSaveName).toHaveBeenCalledWith('Local Engine');

    fireEvent.click(screen.getByRole('button', { name: 'saveRelaySettings' }));
    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledTimes(1));
  });

  it('removing the key does not change authMode', () => {
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'editKey' }));
    fireEvent.click(screen.getByRole('button', { name: 'removeKey' }));

    expect(mockRemoveKey).toHaveBeenCalledTimes(1);
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
  });

  it('S3 a plaintext connection carrying a key is blocked, and both ways out reuse the production actions', async () => {
    render(<RelayDetail provider={{
      ...provider,
      relayRequested: { ...provider.relayRequested!, securityMode: 'local_http' },
    }} />);

    expect(screen.getByText('cleartextCredentialsBlocked')).toBeTruthy();
    // The blocked state offers no entry point for editing the key
    expect(screen.queryByRole('button', { name: 'editKey' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'clearAndStay' }));
    expect(mockClearRelayCredentials).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'switchToHttpsConnection' }));
    await waitFor(() => expect(mockReconnectSecurityMode).toHaveBeenCalledWith(expect.objectContaining({
      securityMode: 'remote_https',
      normalizedEndpoint: 'https://relay.example.com',
    })));
    expect(mockReconnectSecurityMode.mock.calls[0]?.[0]).not.toHaveProperty('relayRequested');
  });

  it('downgrading the connection method does not write on the first click; only after confirmation does it run the production reconnect with the sanitized current draft', async () => {
    render(<RelayDetail provider={{
      ...provider,
      baseURLText: '192.168.1.20:8080/v1',
      relayRequested: {
        ...provider.relayRequested!,
        securityMode: 'remote_https',
      },
    }} />);

    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    expect(mockReconnectSecurityMode).not.toHaveBeenCalled();
    expect(screen.getByText('securityModeClearCredentialsWarning')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' }));
    await waitFor(() => expect(mockReconnectSecurityMode).toHaveBeenCalledWith(expect.objectContaining({
      securityMode: 'local_http',
      normalizedEndpoint: 'http://192.168.1.20:8080/v1',
    })));
    expect(mockReconnectSecurityMode.mock.calls[0]?.[0]).not.toHaveProperty('relayRequested');
  });

  it('T2 confirmation uses saved∪draft credential material and atomically clears an unsaved sensitive row', async () => {
    render(<RelayDetail provider={{
      ...provider,
      apiKey: '',
      apiKeyPreview: '',
      baseURLText: '192.168.1.20:8080/v1',
      relayKind: 'custom',
      relayRequested: {
        ...provider.relayRequested!,
        authMode: 'none',
        securityMode: 'remote_https',
        headers: undefined,
        queryParams: undefined,
      },
      relayResolvedAuthMode: 'none',
    }} />);

    fireEvent.change(screen.getByLabelText('headers.0.key'), { target: { value: 'X-Session-Token' } });
    fireEvent.change(screen.getByLabelText('headers.0.value'), { target: { value: 'tiny' } });
    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    expect(screen.getByText('securityModeClearCredentialsWarning')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' }));
    await waitFor(() => expect(mockReconnectSecurityMode).toHaveBeenCalledWith(expect.objectContaining({
      securityMode: 'local_http',
      requested: expect.objectContaining({
        authMode: 'none',
        headers: undefined,
        queryParams: undefined,
      }),
    })));
  });

  it('saveRelayConfig has to pass the shared form validation first, and S3 must not bypass the save', () => {
    render(<RelayDetail provider={{
      ...provider,
      baseURLText: 'http://192.168.1.20:8080/v1',
      relayRequested: {
        ...provider.relayRequested!,
        securityMode: 'local_http',
        authMode: 'bearer',
      },
    }} />);

    fireEvent.click(screen.getByRole('button', { name: 'saveRelaySettings' }));
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
    expect(screen.getAllByText('cleartextCredentialsBlocked').length).toBeGreaterThan(0);
  });

  it('opens confirm dialog and calls delete provider', () => {
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'deleteRelay' }));
    expect(screen.getByTestId('confirm-delete-dialog')).toBeTruthy();

    fireEvent.click(screen.getByText('confirmDelete'));
    expect(mockDeleteProvider).toHaveBeenCalledTimes(1);
  });

  it('lets users rename the relay from the logo-side title', () => {
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'editName' }));
    const input = screen.getByDisplayValue('Relay 1');
    fireEvent.change(input, { target: { value: 'Work Relay' } });
    fireEvent.click(screen.getByRole('button', { name: 'saveName' }));

    expect(mockSaveName).toHaveBeenCalledWith('Work Relay');
  });

  it('switches relay kind and saves matching requested defaults; advanced fields stay hidden for non-custom kinds', async () => {
    render(<RelayDetail provider={provider} />);

    // The edit page mirrors the create page: a non-custom kind hides the expert fields (protocol, behavior, headers, query)
    expect(screen.getByLabelText('relayType')).toBeTruthy();
    expect(screen.queryByLabelText('transport')).toBeNull();
    expect(screen.queryByLabelText('authMode')).toBeNull();
    expect(screen.queryByLabelText('codexCompatIdentity')).toBeNull();
    expect(screen.queryByLabelText('headers.0.key')).toBeNull();

    fireEvent.change(screen.getByLabelText('relayType'), {
      target: { value: 'codex_style' },
    });
    // Changing the type opens a confirmation first and only takes effect after clicking "Switch type", which preserves the user's fields
    fireEvent.click(screen.getByRole('button', { name: 'confirmKindChangeApply' }));

    // codex_style still does not expose the advanced fields; only custom expands them
    expect(screen.queryByLabelText('transport')).toBeNull();
    expect(screen.queryByLabelText('codexCompatIdentity')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'saveRelaySettings' }));

    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledWith(expect.objectContaining({
      relayKind: 'codex_style',
      relayRequested: expect.objectContaining({
        transport: 'openai_responses',
        authMode: 'bearer',
        stream: true,
        disableResponseStorage: true,
        codexCompatIdentity: true,
      }),
    })));
  });

  it('edits headers and query params through key-value rows after switching to custom', async () => {
    render(<RelayDetail provider={provider} />);

    // Default openai_compatible: headers and queryParams are hidden
    expect(screen.queryByLabelText('headers.0.key')).toBeNull();

    // Only switching to custom (expert mode) exposes the advanced fields
    fireEvent.change(screen.getByLabelText('relayType'), {
      target: { value: 'custom' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'confirmKindChangeApply' }));

    fireEvent.change(screen.getByLabelText('headers.0.key'), {
      target: { value: 'X-Test' },
    });
    fireEvent.change(screen.getByLabelText('headers.0.value'), {
      target: { value: '1' },
    });
    fireEvent.change(screen.getByLabelText('queryParams.0.key'), {
      target: { value: 'api-version' },
    });
    fireEvent.change(screen.getByLabelText('queryParams.0.value'), {
      target: { value: '2026-04-26' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'saveRelaySettings' }));

    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledWith(expect.objectContaining({
      relayRequested: expect.objectContaining({
        headers: [{ key: 'X-Test', value: '1' }],
        queryParams: [{ key: 'api-version', value: '2026-04-26' }],
      }),
    })));
  });

  it('does not show capabilities picker anywhere in the relay detail page', () => {
    // There is no entry point for editing capabilities: no edit capabilities button on a model row and no picker in the add model dialog
    render(<RelayDetail provider={{
      ...provider,
      models: [relayModel],
      catalogModels: [relayModel],
      relayRequested: {
        ...provider.relayRequested!,
        modelID: 'gpt-image-1',
      },
    }} />);

    // No edit capabilities button
    expect(screen.queryByRole('button', { name: 'editCapabilities' })).toBeNull();
    // Neither the relay settings nor the add model default state should show a capabilities heading
    expect(screen.queryByText('capabilities.title')).toBeNull();
  });

  it('edits the default model from the loaded catalog without triggering verification', async () => {
    mockActionState.catalogLoadState = 'loaded';
    render(<RelayDetail provider={{
      ...provider,
      models: [
        { ...relayModel, id: 'gpt-5.4', name: 'gpt-5.4', isDefault: true },
        { ...relayModel, id: 'gpt-5.5', name: 'gpt-5.5', isDefault: false },
      ],
      catalogModels: [
        { ...relayModel, id: 'gpt-5.4', name: 'gpt-5.4', isDefault: true },
        { ...relayModel, id: 'gpt-5.5', name: 'gpt-5.5', isDefault: false },
      ],
      relayRequested: {
        ...provider.relayRequested!,
        modelID: 'gpt-5.5',
      },
    }} />);

    const defaultModel = screen.getByLabelText('defaultModelLabel');
    expect((defaultModel as HTMLSelectElement).value).toBe('gpt-5.5');
    fireEvent.change(defaultModel, { target: { value: 'gpt-5.4' } });
    expect(screen.getByRole('button', { name: 'saveRelaySettings' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'verifyAndSave' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'saveRelaySettings' }));

    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledOnce());
    expect(mockSaveRelaySettings).toHaveBeenCalledWith(expect.objectContaining({
      relayRequested: expect.objectContaining({ modelID: 'gpt-5.4' }),
      models: expect.arrayContaining([
        expect.objectContaining({ id: 'gpt-5.4', isDefault: true }),
        expect.objectContaining({ id: 'gpt-5.5', isDefault: false }),
      ]),
    }));
  });

  it('keeps the current default selectable when it is absent from the loaded catalog', () => {
    mockActionState.catalogLoadState = 'loaded';
    render(<RelayDetail provider={{
      ...provider,
      models: [{ ...relayModel, id: 'outside-catalog', name: 'Outside catalog', isDefault: true }],
      catalogModels: [{ ...relayModel, id: 'catalog-model', name: 'Catalog model', isDefault: false }],
      relayRequested: { ...provider.relayRequested!, modelID: 'outside-catalog' },
    }} />);

    const defaultModel = screen.getByLabelText('defaultModelLabel') as HTMLSelectElement;
    expect(defaultModel.value).toBe('outside-catalog');
    expect([...defaultModel.options].map((option) => option.value)).toEqual([
      'outside-catalog',
      'catalog-model',
    ]);
  });

  it('renders catalog loading, failure recovery, and successful-empty as three distinct states', () => {
    const withModel = { ...provider, models: [relayModel], catalogModels: [] };
    mockActionState.catalogLoadState = 'loading';
    const view = render(<RelayDetail provider={withModel} />);
    expect(screen.getByRole('status').textContent).toContain('loading');

    mockActionState.catalogLoadState = 'failed';
    view.rerender(<RelayDetail provider={withModel} />);
    expect(screen.getByRole('alert').textContent).toContain('catalogFetchFailed');
    expect(screen.getByLabelText('defaultModelLabel')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'addModels' }));
    expect(screen.getByText('addModelsTitle')).toBeTruthy();

    fireEvent.click(screen.getByText('cancel'));
    mockActionState.catalogLoadState = 'loaded';
    view.rerender(<RelayDetail provider={withModel} />);
    expect(screen.queryByText('modelCatalog')).toBeNull();
    expect(screen.queryByText('catalogFetchFailed')).toBeNull();
    expect(screen.getByLabelText('defaultModelLabel').tagName).toBe('INPUT');
  });

  it('keeps the text fallback available while catalog state is still unknown', () => {
    mockActionState.catalogLoadState = 'idle';
    render(<RelayDetail provider={{ ...provider, catalogModels: [] }} />);

    const defaultModel = screen.getByLabelText('defaultModelLabel');
    expect(defaultModel.tagName).toBe('INPUT');
    expect(screen.queryByText('catalogFetchFailedHint')).toBeNull();
  });

  it('marks only catalog-backed enabled models that disappeared, not manual user assets', () => {
    mockActionState.catalogLoadState = 'loaded';
    render(<RelayDetail provider={{
      ...provider,
      models: [
        { ...relayModel, id: 'catalog-model', name: 'Catalog model', isManual: false },
        { ...relayModel, id: 'manual-model', name: 'Manual model', isManual: true, isDefault: false },
      ],
      catalogModels: [],
    }} />);

    expect(screen.getAllByText('modelMissingFromCatalog')).toHaveLength(1);
  });

  it('uses catalog metadata when a failed-catalog text field selects a known but disabled default', async () => {
    mockActionState.catalogLoadState = 'failed';
    const catalogModel = {
      ...relayModel,
      id: 'catalog-default',
      name: 'Catalog enriched name',
      isDefault: false,
      isManual: false,
      priceTier: 'premium',
    };
    render(<RelayDetail provider={{
      ...provider,
      models: [{ ...relayModel, id: 'old-default', isDefault: true }],
      catalogModels: [catalogModel],
      relayRequested: { ...provider.relayRequested!, modelID: undefined },
    }} />);

    fireEvent.change(screen.getByLabelText('defaultModelLabel'), { target: { value: 'catalog-default' } });
    fireEvent.click(screen.getByRole('button', { name: 'saveRelaySettings' }));

    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledOnce());
    const patch = mockSaveRelaySettings.mock.calls[0]?.[0] as { models: AIModel[] };
    expect(patch.models).toContainEqual(expect.objectContaining({
      id: 'catalog-default',
      name: 'Catalog enriched name',
      isDefault: true,
      isManual: false,
      priceTier: 'premium',
    }));
  });

  it('offers retry and explicit unverified save after generation verification fails', () => {
    mockActionState.relaySettingsSaveFailure = {
      error: {
        status: 401,
        upstreamURL: 'https://relay.example/v1/chat/completions',
        detail: 'invalid key',
        message: 'Connection failed',
      },
      phase: 'generation',
      canSaveUnverified: true,
    };
    render(<RelayDetail provider={provider} />);

    expect(screen.getByText('automaticRetries({"count":0})')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'verifyAndSave' }));
    fireEvent.click(screen.getByRole('button', { name: 'saveUnverified' }));
    expect(mockRetryRelaySettingsSave).toHaveBeenCalledOnce();
    expect(mockSaveRelaySettingsUnverified).toHaveBeenCalledOnce();
  });

  it('shows key-rotation generation failure with retry only and never renders echoed credentials or prompt', () => {
    const privatePrompt = 'private prompt must stay hidden';
    mockActionState.relaySettingsSaveFailure = {
      error: {
        status: 401,
        upstreamURL: 'https://relay.example/v1/chat/completions?api_key=leak',
        detail: `invalid ${STORED_KEY}; prompt=${privatePrompt}`,
        message: 'Connection failed',
      },
      phase: 'generation',
      canSaveUnverified: false,
    };
    const { container } = render(<RelayDetail provider={provider} />);

    expect(screen.getByText('automaticRetries({"count":0})')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'saveUnverified' })).toBeNull();
    expect(container.innerHTML).not.toContain(STORED_KEY);
    expect(container.innerHTML).not.toContain(privatePrompt);
    expect(container.innerHTML).not.toContain('api_key=leak');
    fireEvent.click(screen.getByRole('button', { name: 'verifyAndSave' }));
    expect(mockRetryRelaySettingsSave).toHaveBeenCalledOnce();
  });

  it('renders the test connection hint subtitle (iOS parity)', () => {
    render(<RelayDetail provider={provider} />);
    expect(screen.getByText('testRelayHint')).toBeTruthy();
  });

  it('shows ProviderError plain object message instead of "[object Object]" on failure', async () => {
    // Bug reproduction: a screenshot showed [object Object]. When pingRelay throws a plain object
    // rather than an Error instance, the message field has to be read through extractPingErrorMessage instead of a bare String(error).
    mockVerifyRelayConnection.mockRejectedValueOnce({
      kind: 'badRequest',
      title: 'Bad Request',
      message: 'Model gpt-5.5 not found.',
    });
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));

    await waitFor(() => {
      expect(screen.getByText('Model gpt-5.5 not found.')).toBeTruthy();
    });
    expect(screen.queryByText('[object Object]')).toBeNull();
  });

  it('shows endpointEmpty early-return without calling pingRelay when baseURLText is blank', () => {
    render(<RelayDetail provider={{ ...provider, baseURLText: '   ' }} />);

    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));

    expect(screen.getByText('endpointEmpty')).toBeTruthy();
    expect(mockVerifyRelayConnection).not.toHaveBeenCalled();
  });

  it('blocks stored and edited HTTP endpoints before save or ping', () => {
    render(<RelayDetail provider={{ ...provider, baseURLText: 'http://192.168.1.20:8080/v1' }} />);

    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));
    // The hint copy comes from the shared issue -> key mapping, and the key carries its namespace (next-intl is mocked here to echo the key back)
    expect(screen.getByText('common.relayHttpsRequired')).toBeTruthy();
    expect(mockVerifyRelayConnection).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'editBaseURL' }));
    fireEvent.change(screen.getByDisplayValue('http://192.168.1.20:8080/v1'), {
      target: { value: 'http://relay.local/v1' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'verifyAndSave' }));

    expect(screen.getByRole('alert').textContent).toContain('relayHttpsRequired');
    expect(mockSaveBaseURL).not.toHaveBeenCalled();
  });

  it('shows iOS-aligned success message with probedEndpoint and modelCount', async () => {
    mockVerifyRelayConnection.mockResolvedValueOnce({ modelCount: 0, probedEndpoint: 'POST /chat/completions' });
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));

    await waitFor(() => {
      expect(
        screen.getByText('testRelayConnected({"endpoint":"POST /chat/completions"})'),
      ).toBeTruthy();
    });
  });

  it('Test Connection uses only the persisted config, never the unsaved relay-settings draft', async () => {
    const saved = {
      ...provider,
      relayKind: 'custom' as const,
      relayRequested: { ...provider.relayRequested!, transport: 'openai_chat_completions' as const },
    };
    render(<RelayDetail provider={saved} />);

    const [, transport] = screen.getAllByRole('combobox') as HTMLSelectElement[];
    fireEvent.change(transport, { target: { value: 'anthropic_messages' } });
    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));

    await waitFor(() => expect(mockVerifyRelayConnection).toHaveBeenCalledOnce());
    const [candidate] = mockVerifyRelayConnection.mock.calls[0] as [Provider];
    expect(candidate.relayRequested?.transport).toBe('openai_chat_completions');
    expect(candidate.relayRequested).toEqual(saved.relayRequested);
  });

  it('test request writes back a missing HTTPS scheme before fetch and selects the normalized address', async () => {
    mockVerifyRelayConnection.mockResolvedValueOnce({ modelCount: 0, probedEndpoint: 'POST /chat/completions' });
    render(<RelayDetail provider={{ ...provider, baseURLText: 'relay.example.com/v1' }} />);

    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));

    await waitFor(() => expect(mockVerifyRelayConnection).toHaveBeenCalledTimes(1));
    expect(mockWriteBackBaseURL).toHaveBeenCalledWith('https://relay.example.com/v1');
    expect(mockWriteBackBaseURL.mock.invocationCallOrder[0])
      .toBeLessThan(mockVerifyRelayConnection.mock.invocationCallOrder[0]);
    const endpoint = await screen.findByDisplayValue('https://relay.example.com/v1') as HTMLInputElement;
    await waitFor(() => {
      expect(document.activeElement).toBe(endpoint);
      expect(endpoint.selectionStart).toBe(0);
      expect(endpoint.selectionEnd).toBe(endpoint.value.length);
    });
  });

  it('keeps every detail write entry disabled while a mode reconnect generation is pending', async () => {
    let resolveReconnect: ((value: unknown) => void) | undefined;
    mockReconnectSecurityMode.mockReturnValueOnce(new Promise((resolve) => { resolveReconnect = resolve; }));
    const customProvider: Provider = {
      ...provider,
      baseURLText: '192.168.1.20:8080/v1',
      relayKind: 'custom',
      relayRequested: {
        ...provider.relayRequested!,
        securityMode: 'remote_https',
        headers: [{ key: 'X-Tenant', value: 'alpha' }],
        queryParams: [{ key: 'region', value: 'local' }],
      },
    };
    const view = render(<RelayDetail provider={customProvider} />);

    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    fireEvent.click(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' }));
    await waitFor(() => expect(mockReconnectSecurityMode).toHaveBeenCalledTimes(1));

    mockActionState.isSyncing = true;
    view.rerender(<RelayDetail provider={customProvider} />);

    const disabled = (element: HTMLElement | null) => expect(element?.matches(':disabled')).toBe(true);
    disabled(screen.getByRole('button', { name: 'editName' }));
    disabled(screen.getByDisplayValue('http://192.168.1.20:8080/v1'));
    disabled(screen.getByRole('button', { name: 'editKey' }));
    disabled(screen.getByRole('button', { name: 'testRelay' }));
    disabled(screen.getByRole('button', { name: 'saveRelaySettings' }));
    disabled(screen.getByLabelText('relayType'));
    disabled(screen.getByLabelText('transport'));
    disabled(screen.getByLabelText('authMode'));
    disabled(screen.getByLabelText('headers.0.key'));
    disabled(screen.getByLabelText('queryParams.0.key'));
    disabled(screen.getByRole('button', { name: 'addModels' }));

    await act(async () => { resolveReconnect?.(null); });
  });

  it('clears stale ping result when user changes a relay field', async () => {
    mockVerifyRelayConnection.mockResolvedValueOnce({ modelCount: 0, probedEndpoint: 'POST /chat/completions' });
    render(<RelayDetail provider={{
      ...provider,
      relayKind: 'custom',
      relayRequested: {
        ...provider.relayRequested!,
        transport: 'openai_responses',
      },
    }} />);

    fireEvent.click(screen.getByRole('button', { name: 'testRelay' }));
    await waitFor(() => {
      expect(
        screen.getByText('testRelayConnected({"endpoint":"POST /chat/completions"})'),
      ).toBeTruthy();
    });

    // The user edited a transport field, so the previous test result is invalidated immediately rather than suggesting the new configuration still works
    fireEvent.change(screen.getByLabelText('transport'), {
      target: { value: 'anthropic_messages' },
    });

    expect(
      screen.queryByText('testRelayConnected({"endpoint":"POST /chat/completions"})'),
    ).toBeNull();
  });

  it('adds relay models without capability selection', () => {
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'addModels' }));
    fireEvent.change(screen.getByPlaceholderText('addModelsPlaceholder'), {
      target: { value: 'gpt-image-1' },
    });
    // The add model dialog has no capabilities picker
    expect(screen.queryByText('labels.imageGen')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /addModelsConfirm/ }));

    // The hook interface dropped the capabilities parameter and takes only an array of model ids
    expect(mockAddModels).toHaveBeenCalledWith(['gpt-image-1']);
  });

  it('renders discovered but disabled Relay catalog models and enables one through the model library', () => {
    const enabled = { ...relayModel, id: 'gpt-5.4', name: 'gpt-5.4' };
    const available = { ...relayModel, id: 'gpt-5.4-mini', name: 'gpt-5.4-mini', isDefault: false };
    render(<RelayDetail provider={{
      ...provider,
      models: [enabled],
      catalogModels: [enabled, available],
    }} />);

    expect(screen.getByText('modelCatalog')).toBeTruthy();
    expect(screen.getAllByText('catalogCount({"count":1})')).toHaveLength(2);
    fireEvent.click(screen.getByRole('button', { name: 'addModel: gpt-5.4-mini' }));

    expect(mockToggleModel).toHaveBeenCalledWith(available);
    expect(screen.queryByRole('button', { name: 'addModel: gpt-5.4' })).toBeNull();
  });

  // Wiring smoke test: the semantics are pinned by useProviderChatLauncher.test.tsx, this only checks
  // the button is really wired to the launcher. The relay chat button had no coverage before, and the bug where provider detail failed to open a new conversation slipped through exactly that gap.
  it('starts a chat with a relay model from the model row action', () => {
    render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);

    fireEvent.click(screen.getAllByRole('button', { name: /chatWithModel/ })[0]);

    expect(mockSetActiveConversationId).toHaveBeenCalledWith(null);
    expect(mockSetLastUsedModelRef).toHaveBeenCalledWith({
      providerID: 'relay-1',
      modelID: 'gpt-image-1',
    });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });
});

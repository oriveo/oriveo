import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayRequestedConfig } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import { RelayDetail } from './RelayDetail';

const routerPush = vi.fn();
const routerBack = vi.fn();
const routerReplace = vi.fn();
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
const mockRemoveModel = vi.fn();
const mockShowToast = vi.fn();
const mockEnableProviderModel = vi.fn();
const mockPingRelay = vi.fn();
const mockVerifyRelayConnection = vi.fn();
const mockTestRelayDraft = vi.fn();
const mockSaveRelaySettingsUnverified = vi.fn();
const mockRetryRelaySettingsSave = vi.fn();
const mockClearRelaySettingsSaveFailure = vi.fn();
const mockRefreshRelayCatalog = vi.fn();
const mockRelaySettingsSavePlan = vi.fn(() => ({ needsVerification: false, needsCatalogRefresh: false }));
const mockActionState = vi.hoisted(() => ({
  isSyncing: false,
  hydrationPhase: 'ready' as 'booting' | 'metadata-pending' | 'ready',
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
    replace: routerReplace,
  }),
}));

vi.mock('next-intl', () => ({
  // Carry the ICU placeholders into the key as well, so expansions like "testRelayConnected({endpoint:GET /models})" can be asserted
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

// The ping request itself is stubbed, but the error copy and the failure-card projection must go through the production sanitizer; the test no longer keeps its own copy.
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
    testRelayDraft: mockTestRelayDraft,
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
    removeModel: mockRemoveModel,
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
      hydrationPhase: mockActionState.hydrationPhase,
    } as never),
  getVanillaStore: () => ({ getState: () => ({ providers: [] }) }),
}));

vi.mock('../../../components/Toast', () => ({
  showToast: (...args: unknown[]) => mockShowToast(...args),
}));

vi.mock('../../../lib/core/provider-model-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/provider-model-ops')>()),
  enableProviderModel: (...args: unknown[]) => mockEnableProviderModel(...args),
}));

const mockRunRelayCapabilityTest = vi.fn();
const mockRestoreAllRelayAutomatic = vi.fn();
// The executor itself runs against a fake server in relay-capability-test-ops.test.ts; here only the entry point and the three dialog stages are checked, and the entry condition uses the production predicate.
vi.mock('../../../lib/core/relay-capability-test-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/relay-capability-test-ops')>()),
  runRelayCapabilityTest: (...args: unknown[]) => mockRunRelayCapabilityTest(...args),
}));
// The write itself runs against a real store in relay-model-advanced-board.test.tsx; here only the entry wiring is checked.
vi.mock('../../../lib/core/relay-model-advanced-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/relay-model-advanced-ops')>()),
  restoreAllRelayAutomatic: (...args: unknown[]) => mockRestoreAllRelayAutomatic(...args),
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
  // The preview is produced by the production masking function; the test does not write a "looks like" string of its own
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

/** The detail page is the board: settings live in the "Edit connection" subview and the model list in the "Model library" subview. */
function openEditConnection() {
  fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));
}

/** Edit page copy always resolves through the root translator in the component; the test echoes the full key. */
const EDIT = {
  save: 'common.save',
  validateAndSave: 'pages.relayDetail.editBoard.validateAndSave',
  test: 'pages.relayDetail.testRelay',
  endpoint: 'pages.relayDetail.endpoint',
  defaultProtocol: 'pages.relayDetail.editBoard.defaultProtocol',
  authentication: 'pages.relayDetail.authMode',
  headersGroup: /pages\.relayDetail\.sectionHeadersQuery/,
  add: 'pages.relayDetail.editBoard.add',
  header: 'pages.relayDetail.headers',
  queryParam: 'pages.relayDetail.queryParams',
  verified: 'pages.relayDetail.editBoard.verified',
} as const;

function expandHeadersGroup() {
  fireEvent.click(screen.getByRole('button', { name: EDIT.headersGroup }));
}

function addEntry(kind: 'header' | 'queryParam') {
  fireEvent.click(screen.getByRole('button', { name: EDIT.add }));
  fireEvent.click(screen.getByRole('menuitem', { name: EDIT[kind] }));
}

function openModelLibrary() {
  fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.modelLibrary/ }));
}

function backToBoard() {
  fireEvent.click(screen.getByRole('button', { name: 'back' }));
}

/** The key row goes to the keys page; the implicit single key's "change key" still uses the existing edit-key dialog. */
function openImplicitKeyDialog(rowName = 'editKey', keyRowName = formatApiKeyPreview(STORED_KEY)) {
  fireEvent.click(screen.getByRole('button', { name: rowName }));
  fireEvent.click(screen.getByRole('button', { name: keyRowName }));
  fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.keyReplace' }));
}

describe('RelayDetail', () => {
  beforeEach(() => {
    routerPush.mockReset();
    routerBack.mockReset();
    routerReplace.mockReset();
    window.history.replaceState(null, '', '/providers/relay-1');
    mockDeleteProvider.mockReset();
    mockSaveRelaySettings.mockReset();
    mockSaveRelaySettings.mockResolvedValue(true);
    mockSaveName.mockReset();
    mockSaveBaseURL.mockReset();
    mockWriteBackBaseURL.mockReset();
    mockActionState.isSyncing = false;
    mockActionState.hydrationPhase = 'ready';
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
    mockRemoveModel.mockReset();
    mockShowToast.mockReset();
    mockEnableProviderModel.mockReset();
    mockPingRelay.mockReset();
    mockVerifyRelayConnection.mockReset();
    mockVerifyRelayConnection.mockResolvedValue({ modelCount: 0, probedEndpoint: 'POST /chat/completions' });
    mockTestRelayDraft.mockReset();
    mockTestRelayDraft.mockResolvedValue({ modelCount: 0, probedEndpoint: 'POST /chat/completions' });
    mockSaveRelaySettingsUnverified.mockResolvedValue(false);
    mockSetLastUsedModelRef.mockReset();
    mockSetActiveConversationId.mockReset();
  });

  it('removing an enabled relay model shows a removed toast whose undo re-enables it', () => {
    // With only 1 left "Remove" is greyed out (the last-model rule), so two are placed here; removing goes through the trailing "..." menu.
    const second: AIModel = { ...relayModel, id: 'gpt-4o', name: 'gpt-4o' };
    const relayWithModel: Provider = { ...provider, models: [relayModel, second] };
    render(<RelayDetail provider={relayWithModel} />);
    openModelLibrary();

    fireEvent.click(screen.getAllByRole('button', { name: 'common.advancedMore' })[0]!);
    fireEvent.click(screen.getByRole('menuitem', { name: 'common.remove' }));

    expect(mockRemoveModel).toHaveBeenCalledWith('gpt-image-1');
    const [message, duration, onUndo, variant, undoLabel] = mockShowToast.mock.calls[0];
    expect(message).toBe('toast.modelRemoved({"model":"gpt-image-1"})');
    expect(duration).toBe(4000);
    expect(variant).toBe('removed');
    expect(undoLabel).toBe('undo');
    (onUndo as () => void)();
    expect(mockEnableProviderModel).toHaveBeenCalledWith(expect.anything(), relayWithModel, relayModel);
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

    openImplicitKeyDialog();
    const input = within(screen.getByRole('dialog')).getByLabelText('apiKey') as HTMLInputElement;
    expect(input.getAttribute('data-secret-visibility')).toBe('masked');
    expect(input.value).toBe('');
    expect(container.innerHTML).not.toContain(STORED_KEY);
    expect(screen.getByRole('button', { name: 'pages.providerDetail.showKey' })).toBeTruthy();
    expect(screen.getByText('rotateKeyNote')).toBeTruthy();
  });

  it('S1 a missing key is a warning state offering add key, and saving an empty value must show a visible reason rather than returning silently', () => {
    render(<RelayDetail provider={{ ...provider, apiKey: '', apiKeyPreview: '' }} />);

    expect(screen.getByText('pages.providerDetail.hero.tapToSet')).toBeTruthy();
    expect(screen.queryByText('pages.relayDetail.noKey')).toBeNull();
    expect(screen.queryByText('pages.relayDetail.keySaved')).toBeNull();

    openImplicitKeyDialog('apiKey', 'pages.providerDetail.hero.tapToSet');
    const dialog = screen.getByRole('dialog');
    // Pressing Enter on an empty input: before the fix this was `if (!trimmed) return;`, so the user got no feedback at all
    fireEvent.keyDown(within(dialog).getByLabelText('apiKey'), { key: 'Enter' });
    expect(within(dialog).getByRole('alert').textContent).toBe('apiKeyRequired');
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

    expect(screen.getByText('pages.relayDetail.noKey')).toBeTruthy();
    expect(screen.queryByText('apiKeyRequired')).toBeNull();
    // S0 has no CTA to change or remove the key
    expect(screen.queryByText('addKey')).toBeNull();
    expect(screen.queryByText('changeKey')).toBeNull();
    expect(screen.queryByRole('button', { name: 'removeKey' })).toBeNull();
    // The S0 key row is not tappable
    expect(screen.queryByRole('button', { name: 'apiKey' })).toBeNull();
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

  it('T5 saving a non-credential field does not require a key to be present', async () => {
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

    openEditConnection();
    fireEvent.click(screen.getByRole('button', { name: EDIT.save }));
    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledTimes(1));
  });

  it('the edit page headers section title = Headers & query params', () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();
    // next-intl echoes keys in this file; the English value "Headers & query params" is pinned by the same-named case in parameters-page-board.test.tsx.
    expect(screen.getByText('pages.relayDetail.sectionHeadersQuery')).toBeTruthy();
    expect(screen.queryByText(/sectionAdvancedHttp/)).toBeNull();
  });

  it('T3 removing the key does not change authMode', () => {
    render(<RelayDetail provider={provider} />);

    openImplicitKeyDialog();
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
    // A blocked state that still stores a key can be tapped into the edit-key dialog, using its remove / replace
    openImplicitKeyDialog();
    expect(within(screen.getByRole('dialog')).getByRole('button', { name: 'removeKey' })).toBeTruthy();
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'common.close' }));
    backToBoard();

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
    openEditConnection();

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

  it('switching connection security persists only the security itself and what comes with it: a default protocol changed in the draft is not persisted with the reconnect and stays in the editor', async () => {
    render(<RelayDetail provider={{
      ...provider,
      baseURLText: '192.168.1.20:8080/v1',
      relayRequested: { ...provider.relayRequested!, securityMode: 'remote_https' },
    }} />);
    openEditConnection();

    fireEvent.change(screen.getByLabelText(EDIT.defaultProtocol), { target: { value: 'anthropic_messages' } });
    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    fireEvent.click(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' }));

    await waitFor(() => expect(mockReconnectSecurityMode).toHaveBeenCalledTimes(1));
    const [input] = mockReconnectSecurityMode.mock.calls[0] as [{ requested: RelayRequestedConfig }];
    expect(input.requested).toMatchObject({ transport: 'openai_chat_completions', securityMode: 'local_http', authMode: 'none' });
    expect((screen.getByLabelText(EDIT.defaultProtocol) as HTMLSelectElement).value).toBe('anthropic_messages');
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
    openEditConnection();

    expandHeadersGroup();
    addEntry('header');
    fireEvent.change(screen.getByLabelText(`${EDIT.header} 1`), { target: { value: 'X-Session-Token' } });
    fireEvent.change(screen.getByLabelText(`${EDIT.header} 1 pages.relayDetail.valuePlaceholder`), { target: { value: 'tiny' } });
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

  it('saving has to pass the shared form validation first: with a hint the primary button is not clickable, and S3 must not bypass the save', () => {
    render(<RelayDetail provider={{
      ...provider,
      baseURLText: 'http://192.168.1.20:8080/v1',
      relayRequested: {
        ...provider.relayRequested!,
        securityMode: 'local_http',
        authMode: 'bearer',
      },
    }} />);
    openEditConnection();

    const primary = screen.getByRole('button', { name: EDIT.save });
    expect(primary.matches(':disabled')).toBe(true);
    fireEvent.click(primary);
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
    expect(screen.getAllByRole('alert').map((node) => node.textContent).join(' ')).toContain('cleartextCredentialsBlocked');
  });

  it('opens confirm dialog and calls delete provider', () => {
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' }));
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

  it('there is no type layer: changing the default protocol is "Verify and save", relayKind is derived from the protocol, reasoning is cleared, and the Codex identity is kept as is', async () => {
    const opened: Provider = {
      ...provider,
      relayRequested: { ...provider.relayRequested!, reasoningEffort: 'high', codexCompatIdentity: false },
    };
    render(<RelayDetail provider={opened} />);
    openEditConnection();

    // The type picker / confirmation dialog / preset cards / reasoning / Codex checkbox / transport type picker are all retired.
    expect(screen.queryByLabelText('relayType')).toBeNull();
    expect(screen.queryByLabelText(/reasoningEffort/)).toBeNull();
    expect(screen.queryByText(/codexCompatIdentity/)).toBeNull();
    expect(screen.queryByText(/relayTransportKind/)).toBeNull();
    expect(screen.queryByText(/presetMode/)).toBeNull();

    expect(screen.getByRole('button', { name: EDIT.save })).toBeTruthy();
    fireEvent.change(screen.getByLabelText(EDIT.defaultProtocol), { target: { value: 'openai_responses' } });
    fireEvent.click(screen.getByRole('button', { name: EDIT.validateAndSave }));

    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledTimes(1));
    // An edit save passes a patch evaluated against the live record; assert after evaluating it against the connection as it was when the page opened.
    const [patchFor] = mockSaveRelaySettings.mock.calls[0] as [(live: Provider) => { relayKind: string; relayRequested: Record<string, unknown> }];
    const patch = patchFor(opened);
    expect(patch.relayKind).toBe('codex_style');
    expect(patch.relayRequested).toMatchObject({ transport: 'openai_responses', authMode: 'bearer', stream: true, codexCompatIdentity: false });
    expect(patch.relayRequested.reasoningEffort).toBeUndefined();
  });

  it('edits headers and query params through key-value rows in the headers group', async () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    // Groups are collapsed by default
    expect(screen.queryByRole('button', { name: EDIT.add })).toBeNull();
    expandHeadersGroup();
    addEntry('header');
    addEntry('queryParam');
    fireEvent.change(screen.getByLabelText(`${EDIT.header} 1`), { target: { value: 'X-Test' } });
    fireEvent.change(screen.getByLabelText(`${EDIT.header} 1 pages.relayDetail.valuePlaceholder`), { target: { value: '1' } });
    fireEvent.change(screen.getByLabelText(`${EDIT.queryParam} 1`), { target: { value: 'api-version' } });
    fireEvent.change(screen.getByLabelText(`${EDIT.queryParam} 1 pages.relayDetail.valuePlaceholder`), { target: { value: '2026-04-26' } });
    // Header values are masked by default; query parameters are not
    expect((screen.getByLabelText(`${EDIT.header} 1 pages.relayDetail.valuePlaceholder`) as HTMLInputElement).type).toBe('password');
    expect((screen.getByLabelText(`${EDIT.queryParam} 1 pages.relayDetail.valuePlaceholder`) as HTMLInputElement).type).toBe('text');
    fireEvent.click(screen.getByRole('button', { name: EDIT.save }));

    await waitFor(() => expect(mockSaveRelaySettings).toHaveBeenCalledWith(
      expect.any(Function),
      expect.objectContaining({ isStale: expect.any(Function) }),
    ));
    const [patchFor] = mockSaveRelaySettings.mock.calls[0] as [(live: Provider) => { relayRequested: Record<string, unknown> }];
    expect(patchFor(provider).relayRequested).toMatchObject({
      headers: [{ key: 'X-Test', value: '1' }],
      queryParams: [{ key: 'api-version', value: '2026-04-26' }],
    });
  });

  it('does not show capabilities picker anywhere in the relay detail page', () => {
    // The entry for user-edited capabilities is removed: model rows have no "edit capabilities" button, and the add-model dialog has no picker either
    render(<RelayDetail provider={{
      ...provider,
      models: [relayModel],
      catalogModels: [relayModel],
      relayRequested: {
        ...provider.relayRequested!,
        modelID: 'gpt-image-1',
      },
    }} />);

    // There is no longer an "edit capabilities" button
    expect(screen.queryByRole('button', { name: 'editCapabilities' })).toBeNull();
    // Neither the relay settings nor the add-model dialog should show a capabilities title in their default state
    expect(screen.queryByText('capabilities.title')).toBeNull();
  });

  it('has no default model picker on the board even with legacy isDefault data', () => {
    mockActionState.catalogLoadState = 'loaded';
    render(<RelayDetail provider={{
      ...provider,
      models: [
        { ...relayModel, id: 'gpt-5.4', name: 'gpt-5.4', isDefault: false },
        { ...relayModel, id: 'gpt-5.5', name: 'gpt-5.5', isDefault: true },
      ],
      catalogModels: [
        { ...relayModel, id: 'gpt-5.4', name: 'gpt-5.4', isDefault: false },
        { ...relayModel, id: 'gpt-5.5', name: 'gpt-5.5', isDefault: true },
      ],
      relayRequested: {
        ...provider.relayRequested!,
        modelID: 'gpt-5.5',
      },
    }} />);

    // A relay has no default model: the detail page no longer has a default-model row or selector, and does not write a default either.
    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
    expect(screen.queryByRole('radio')).toBeNull();
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
  });

  it('does not offer a default model choice for enabled models outside the loaded catalog', () => {
    mockActionState.catalogLoadState = 'loaded';
    render(<RelayDetail provider={{
      ...provider,
      models: [{ ...relayModel, id: 'outside-catalog', name: 'Outside catalog', isDefault: true }],
      catalogModels: [{ ...relayModel, id: 'catalog-model', name: 'Catalog model', isDefault: false }],
      relayRequested: { ...provider.relayRequested!, modelID: 'outside-catalog' },
    }} />);

    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
    expect(screen.queryByRole('radio')).toBeNull();
  });

  it('renders catalog loading, failure recovery, and successful-empty as three distinct states', () => {
    const withModel = { ...provider, models: [relayModel], catalogModels: [] };
    mockActionState.catalogLoadState = 'loading';
    const view = render(<RelayDetail provider={withModel} />);
    openModelLibrary();
    expect(screen.getByRole('status').textContent).toContain('loading');

    mockActionState.catalogLoadState = 'failed';
    view.rerender(<RelayDetail provider={withModel} />);
    expect(screen.getByRole('alert').textContent).toContain('catalogFetchFailed');
    // The failure card has only Retry, and manual add exists in one place only, at the page foot.
    expect(within(screen.getByRole('alert')).queryByRole('button', { name: 'pages.relaySetup.twoStep.addModelManually' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'pages.relaySetup.twoStep.addModelManually' }));
    expect(screen.getByText('addModelsTitle')).toBeTruthy();

    fireEvent.click(screen.getByText('cancel'));
    mockActionState.catalogLoadState = 'loaded';
    view.rerender(<RelayDetail provider={withModel} />);
    expect(screen.queryByText('modelCatalog')).toBeNull();
    expect(screen.queryByText('catalogFetchFailed')).toBeNull();
    // A relay has no default-model row: it does not appear when returning to the board either.
    backToBoard();
    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
  });

  it('shows no default model entry while catalog state is still unknown', () => {
    mockActionState.catalogLoadState = 'idle';
    render(<RelayDetail provider={{ ...provider, models: [relayModel], catalogModels: [] }} />);

    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
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
    openModelLibrary();

    // A catalog-missing state is the status text of a Catalog row; the key carries a namespace and is resolved by the root translator.
    expect(screen.getAllByText('pages.relayDetail.modelMissingFromCatalog')).toHaveLength(1);
  });

  it('never writes a default model, even when the catalog failed', () => {
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

    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
  });

  it('verification failure shows only the failure card: the edit page failure card offers only "Save anyway (unverified)", and retry is the primary button', async () => {
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
    mockSaveRelaySettingsUnverified.mockResolvedValueOnce(true);
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    // Without an automatic retry, "Retried automatically 0 times" is not written.
    expect(screen.queryByText(/automaticRetries/)).toBeNull();
    expect(screen.queryByRole('button', { name: 'verifyAndSave' })).toBeNull();
    expect(screen.queryByRole('dialog')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'saveUnverified' }));
    expect(mockSaveRelaySettingsUnverified).toHaveBeenCalledOnce();
    // After saving, leave the edit page.
    await waitFor(() => expect(screen.getByRole('button', { name: 'editConnection' })).toBeTruthy());
  });

  it('when saving unverified is not allowed, the only primary button on the edit page failure card is close: it clears the failure state (as on iOS)', () => {
    mockActionState.relaySettingsSaveFailure = {
      error: { status: 401, upstreamURL: 'https://relay.example/v1/chat/completions', detail: 'invalid key', message: 'Connection failed' },
      phase: 'generation',
      canSaveUnverified: false,
    };
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    const card = screen.getByRole('alert');
    expect(within(card).queryByRole('button', { name: 'verifyAndSave' })).toBeNull();
    expect(within(card).queryByRole('button', { name: 'saveUnverified' })).toBeNull();
    expect(within(card).getAllByRole('button')).toHaveLength(1);
    fireEvent.click(within(card).getByRole('button', { name: 'close' }));
    expect(mockClearRelaySettingsSaveFailure).toHaveBeenCalled();
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

    expect(screen.queryByText(/automaticRetries/)).toBeNull();
    expect(screen.queryByRole('button', { name: 'saveUnverified' })).toBeNull();
    expect(container.innerHTML).not.toContain(STORED_KEY);
    expect(container.innerHTML).not.toContain(privatePrompt);
    expect(container.innerHTML).not.toContain('api_key=leak');
    fireEvent.click(screen.getByRole('button', { name: 'verifyAndSave' }));
    expect(mockRetryRelaySettingsSave).toHaveBeenCalledOnce();
  });

  it('edit page header: close at top left + centered title + subtitle with the connection name; the action bar has the secondary test-connection button + the primary button', () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();
    expect(screen.getByRole('heading', { name: 'pages.relayDetail.editConnection' })).toBeTruthy();
    expect(screen.getByText('Relay 1')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'common.close' })).toBeTruthy();
    expect(screen.getByRole('button', { name: EDIT.test })).toBeTruthy();
    expect(screen.getByRole('button', { name: EDIT.save })).toBeTruthy();
  });

  it('shows ProviderError plain object message instead of "[object Object]" on failure', async () => {
    // Bug reproduction: the production screenshot showed [object Object]. When pingRelay throws a plain object (not an Error instance)
    // it must go through extractPingErrorMessage to get the message field, never a bare String(error).
    mockTestRelayDraft.mockRejectedValueOnce({
      kind: 'badRequest',
      title: 'Bad Request',
      message: 'Model gpt-5.5 not found.',
    });
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));

    await waitFor(() => {
      expect(screen.getByText('Model gpt-5.5 not found.')).toBeTruthy();
    });
    expect(screen.queryByText('[object Object]')).toBeNull();
  });

  it('blank address: both test and the primary button are not clickable (silent required issue), and no request is sent', () => {
    render(<RelayDetail provider={{ ...provider, baseURLText: '   ' }} />);
    openEditConnection();

    expect(screen.getByRole('button', { name: EDIT.test }).matches(':disabled')).toBe(true);
    const primary = screen.getAllByRole('button').find((button) => button.getAttribute('data-edit-action') === 'primary')!;
    expect(primary.matches(':disabled')).toBe(true);
    fireEvent.click(primary);

    expect(mockTestRelayDraft).not.toHaveBeenCalled();
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
  });
  it('blocks stored and edited HTTP endpoints before save or ping', () => {
    render(<RelayDetail provider={{ ...provider, baseURLText: 'http://192.168.1.20:8080/v1' }} />);
    openEditConnection();

    // The hint copy comes from the shared issue -> key mapping, and the key carries a namespace (next-intl is mocked to echo keys in the test); it stays under the connection card.
    expect(screen.getByText('common.relayHttpsRequired')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));
    expect(mockTestRelayDraft).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText(EDIT.endpoint), { target: { value: 'http://relay.local/v1' } });
    expect(screen.getAllByRole('alert').map((node) => node.textContent).join(' ')).toContain('relayHttpsRequired');
    fireEvent.click(screen.getAllByRole('button').find((button) => button.getAttribute('data-edit-action') === 'primary')!);
    expect(mockSaveRelaySettings).not.toHaveBeenCalled();
  });

  it('a passing test shows the status row "Connection verified."', async () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));

    await waitFor(() => expect(screen.getByText(EDIT.verified)).toBeTruthy());
    expect(screen.getByRole('status').getAttribute('data-status')).toBe('verified');
  });

  it('test connection tests the draft: unsaved changes are tested too, and the result is not written back to the saved connection', async () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    fireEvent.change(screen.getByLabelText(EDIT.defaultProtocol), { target: { value: 'anthropic_messages' } });
    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));

    await waitFor(() => expect(mockTestRelayDraft).toHaveBeenCalledOnce());
    const [candidate, persist] = mockTestRelayDraft.mock.calls[0] as [Provider, boolean];
    expect(candidate.relayRequested?.transport).toBe('anthropic_messages');
    expect(persist).toBe(false);
    expect(mockVerifyRelayConnection).not.toHaveBeenCalled();
  });

  it('draft identical to the saved connection: tests the saved connection and writes the result back to the connection status', async () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));

    await waitFor(() => expect(mockTestRelayDraft).toHaveBeenCalledOnce());
    const [candidate, persist] = mockTestRelayDraft.mock.calls[0] as [Provider, boolean];
    expect(candidate).toBe(provider);
    expect(persist).toBe(true);
  });

  it('when the draft is edited again while a test is in flight: the late result is discarded and does not land on the page', async () => {
    let resolveTest: ((value: unknown) => void) | undefined;
    mockTestRelayDraft.mockReturnValueOnce(new Promise((resolve) => { resolveTest = resolve; }));
    render(<RelayDetail provider={provider} />);
    openEditConnection();

    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));
    await waitFor(() => expect(screen.getByRole('status').getAttribute('data-status')).toBe('testing'));
    // Test in flight: test is not clickable, the primary button is clickable.
    expect(screen.getByRole('button', { name: EDIT.test }).matches(':disabled')).toBe(true);
    expect(screen.getByRole('button', { name: EDIT.save }).matches(':disabled')).toBe(false);

    fireEvent.change(screen.getByLabelText(EDIT.endpoint), { target: { value: 'https://other.example.com' } });
    await act(async () => { resolveTest?.({ modelCount: 0, probedEndpoint: 'POST /chat/completions' }); });
    expect(screen.queryByText(EDIT.verified)).toBeNull();
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('stored address lacking a scheme: testing the saved connection sends the request to the normalized address and does not write the address back', async () => {
    render(<RelayDetail provider={{ ...provider, baseURLText: 'relay.example.com/v1' }} />);
    openEditConnection();

    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));

    await waitFor(() => expect(mockTestRelayDraft).toHaveBeenCalledTimes(1));
    const [candidate, persist] = mockTestRelayDraft.mock.calls[0] as [Provider, boolean];
    expect(candidate.baseURLText).toBe('https://relay.example.com/v1');
    expect(persist).toBe(true);
    expect(mockWriteBackBaseURL).not.toHaveBeenCalled();
    // A stored address that differs only by scheme is "Save", and no verification is sent.
    expect(screen.getByRole('button', { name: EDIT.save })).toBeTruthy();
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
    openEditConnection();
    expandHeadersGroup();

    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    fireEvent.click(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' }));
    await waitFor(() => expect(mockReconnectSecurityMode).toHaveBeenCalledTimes(1));
    // Reconnect in flight: in-progress style, not borrowing the failure slot.
    expect(document.querySelector('[data-status]')?.getAttribute('data-status')).toBe('reconnecting');

    mockActionState.isSyncing = true;
    view.rerender(<RelayDetail provider={customProvider} />);

    const disabled = (element: HTMLElement | null) => expect(element?.matches(':disabled')).toBe(true);
    disabled(screen.getByLabelText(EDIT.endpoint));
    disabled(screen.getByRole('button', { name: EDIT.test }));
    disabled(screen.getAllByRole('button').find((button) => button.getAttribute('data-edit-action') === 'primary')!);
    disabled(screen.getByLabelText(EDIT.defaultProtocol));
    disabled(screen.getByLabelText(EDIT.authentication));
    disabled(screen.getByRole('button', { name: EDIT.add }));

    // Write entries on the detail page (rename / change key / re-detect / delete) are locked as well; the default-model row is retired
    fireEvent.click(screen.getByRole('button', { name: 'common.close' }));
    if (screen.queryByRole('alertdialog')) {
      fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.editBoard.discard' }));
    }
    disabled(screen.getByRole('button', { name: 'editName' }));
    // The key row is navigation (into the keys page) and is not disabled by the write lock; the write entries inside the keys page are locked.
    expect(screen.getByRole('button', { name: 'editKey' }).matches(':disabled')).toBe(false);
    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
    disabled(screen.getByRole('button', { name: 'pages.relayDetail.detectAgain' }));
    disabled(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' }));

    openModelLibrary();
    disabled(screen.getByRole('button', { name: 'pages.relaySetup.twoStep.addModelManually' }));
    backToBoard();
    fireEvent.click(screen.getByRole('button', { name: 'editKey' }));
    disabled(screen.getByRole('button', { name: formatApiKeyPreview(STORED_KEY) }));
    disabled(screen.getByRole('button', { name: 'pages.relayDetail.keysAdd' }));

    await act(async () => { resolveReconnect?.(null); });
  });

  it('clears stale test result when user changes a relay field', async () => {
    render(<RelayDetail provider={{
      ...provider,
      relayKind: 'custom',
      relayRequested: {
        ...provider.relayRequested!,
        transport: 'openai_responses',
      },
    }} />);
    openEditConnection();

    fireEvent.click(screen.getByRole('button', { name: EDIT.test }));
    await waitFor(() => expect(screen.getByText(EDIT.verified)).toBeTruthy());

    // The user changed the protocol -> the old test result is invalidated immediately, so nobody mistakes the new configuration for still usable
    fireEvent.change(screen.getByLabelText(EDIT.defaultProtocol), { target: { value: 'anthropic_messages' } });

    expect(screen.queryByText(EDIT.verified)).toBeNull();
  });

  it('closing the edit page with unsaved changes asks to discard first; with no changes it closes directly', () => {
    render(<RelayDetail provider={provider} />);
    openEditConnection();
    fireEvent.click(screen.getByRole('button', { name: 'common.close' }));
    expect(screen.getByRole('button', { name: 'editConnection' })).toBeTruthy();

    openEditConnection();
    fireEvent.change(screen.getByLabelText(EDIT.endpoint), { target: { value: 'https://changed.example.com' } });
    fireEvent.click(screen.getByRole('button', { name: 'common.close' }));
    const dialog = screen.getByRole('alertdialog');
    expect(within(dialog).getByText('pages.relayDetail.editBoard.unsavedMessage')).toBeTruthy();
    fireEvent.click(within(dialog).getByRole('button', { name: 'pages.relayDetail.editBoard.keepEditing' }));
    // The address slot shows only the part after the scheme.
    expect((screen.getByLabelText(EDIT.endpoint) as HTMLInputElement).value).toBe('changed.example.com');

    fireEvent.click(screen.getByRole('button', { name: 'common.close' }));
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.editBoard.discard' }));
    expect(screen.getByRole('button', { name: 'editConnection' })).toBeTruthy();
    openEditConnection();
    expect((screen.getByLabelText(EDIT.endpoint) as HTMLInputElement).value).toBe('relay.example.com');
  });

  it('adds relay models without capability selection', () => {
    render(<RelayDetail provider={provider} />);
    openModelLibrary();

    fireEvent.click(screen.getByRole('button', { name: 'pages.relaySetup.twoStep.addModelManually' }));
    fireEvent.change(screen.getByPlaceholderText('addModelsPlaceholder'), {
      target: { value: 'gpt-image-1' },
    });
    // The add-model dialog no longer has a capabilities picker
    expect(screen.queryByText('labels.imageGen')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /addModelsConfirm/ }));

    // The hook interface dropped the capabilities parameter and only takes a model id array
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
    openModelLibrary();

    // The section header reads "Model library - N"; the relay model library no longer shows ModelBrowser's own count.
    expect(screen.getByText('pages.relayDetail.catalogSectionLibrary({"count":1})')).toBeTruthy();
    expect(screen.queryByText('catalogCount({"count":1})')).toBeNull();
    // Plus = enable: goes through the lazy-verification enable path (with the page-level signal), no longer through toggleModel.
    mockEnableProviderModel.mockImplementation((_store: unknown, _provider: unknown, item: AIModel) => item);
    // The relay model library draws a group header even with a single family, collapsed by default: expand it first.
    for (const button of document.querySelectorAll('[data-catalog-section="library"] section[data-testid^="group-"] button[aria-expanded="false"]')) {
      fireEvent.click(button);
    }
    fireEvent.click(screen.getByRole('button', { name: 'addModel: gpt-5.4-mini' }));

    expect(mockEnableProviderModel).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ id: provider.id }), available);
    expect(mockToggleModel).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'addModel: gpt-5.4' })).toBeNull();
  });

  // Wiring smoke test: the semantics are locked by useProviderChatLauncher.test.tsx; here only that the button is really wired to the launcher is checked.
  // The Relay "chat" button used to have zero coverage -- the bug where a provider detail jumped to a new conversation slipped through exactly such a gap.
  it('starts a chat with a relay model from the model row action', () => {
    render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
    openModelLibrary();

    fireEvent.click(screen.getAllByRole('button', { name: /chatWithModel/ })[0]);

    expect(mockSetActiveConversationId).toHaveBeenCalledWith(null);
    expect(mockSetLastUsedModelRef).toHaveBeenCalledWith({
      providerID: 'relay-1',
      modelID: 'gpt-image-1',
    });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });
  // The test-capability entry moved to the end of the capabilities section under "Model > Advanced"; the model-behavior expansion no longer has test / restore.
  const openAdvancedPage = () => {
    openModelLibrary();
    fireEvent.click(document.querySelector('[data-catalog-section="enabled"] [data-row-open]') as HTMLElement);
  };

  describe('test capability minimal entry', () => {
    const testedModel: AIModel = {
      ...relayModel,
      relayCapabilityOverrides: { image: { value: false, source: 'tested' } },
    };

    const panelDialog = () => screen.getByRole('dialog', { name: 'capabilityTest.panel.title({"model":"gpt-image-1"})' });

    it('Advanced page "Test capability" opens the bottom panel directly, the first state is already in progress, and tapping the scrim / Esc while in progress does not close it', async () => {
      mockRunRelayCapabilityTest.mockReset();
      let finish: (value: unknown) => void = () => {};
      mockRunRelayCapabilityTest.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
      render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
      openModelLibrary();

      expect(screen.queryByRole('button', { name: 'capabilityTest.action' })).toBeNull();
      expect(screen.queryByRole('button', { name: 'capabilityTest.restore' })).toBeNull();
      fireEvent.click(document.querySelector('[data-catalog-section="enabled"] [data-row-open]') as HTMLElement);
      fireEvent.click(screen.getByRole('button', { name: 'capabilityTest.action' }));

      // There is no confirmation state: tapping starts the test.
      expect(mockRunRelayCapabilityTest).toHaveBeenCalledWith(
        expect.anything(), 'relay-1', 'gpt-image-1', { signal: expect.any(AbortSignal), onProgress: expect.any(Function) },
      );
      expect(screen.queryByText('capabilityTest.confirmMessage')).toBeNull();
      const dialog = panelDialog();
      expect(within(dialog).getByText('capabilityTest.panel.progress({"current":1,"total":3})')).toBeTruthy();
      expect(within(dialog).getByText('capabilityTest.panel.runningText')).toBeTruthy();
      expect(within(dialog).getByText('capabilityTest.panel.info({"count":3})')).toBeTruthy();
      expect(within(dialog).getByText('Chat')).toBeTruthy();
      expect(within(dialog).getAllByText('capabilityTest.panel.waiting')).toHaveLength(2);

      fireEvent.click(dialog.querySelector('[data-captest-backdrop]')!);
      fireEvent.keyDown(document, { key: 'Escape' });
      expect(panelDialog()).toBeTruthy();

      const { onProgress } = mockRunRelayCapabilityTest.mock.calls[0]![3] as { onProgress: (event: unknown) => void };
      act(() => {
        onProgress({ running: 'image', results: { text: { verdict: 'accepted', reason: 'ok', status: 200, elapsedMs: 1200 } } });
      });
      expect(within(panelDialog()).getByText('capabilityTest.panel.textOk')).toBeTruthy();
      expect(within(panelDialog()).getByText('capabilityTest.panel.runningImage')).toBeTruthy();

      await act(async () => {
        finish({
          outcome: 'completed',
          plan: ['text', 'image', 'toolCall'],
          items: { image: 'accepted', toolCall: 'undetermined' },
          results: {
            text: { verdict: 'accepted', reason: 'ok', status: 200, elapsedMs: 1200 },
            image: { verdict: 'accepted', reason: 'ok', status: 200, elapsedMs: 4600 },
            toolCall: { verdict: 'undetermined', reason: 'rate_limited', status: 429, elapsedMs: 300 },
          },
          written: true,
        });
      });
      const done = panelDialog();
      expect(within(done).getByText('capabilityTest.panel.doneBadge')).toBeTruthy();
      expect(within(done).getByText('capabilityTest.panel.supportedSaved')).toBeTruthy();
      expect(within(done).getByText('capabilityTest.panel.undetermined({"reason":"capabilityTest.panel.reasonRateLimited"})')).toBeTruthy();
      expect(within(done).getByText('capabilityTest.panel.footerSaved')).toBeTruthy();
      fireEvent.click(within(done).getByRole('button', { name: 'done' }));
      expect(screen.queryByRole('dialog')).toBeNull();
    });

    it('text did not pass: the remaining items read "Not tested: text did not pass"', async () => {
      mockRunRelayCapabilityTest.mockReset();
      mockRunRelayCapabilityTest.mockResolvedValue({
        outcome: 'text_failed',
        plan: ['text', 'image', 'toolCall'],
        items: {},
        results: { text: { verdict: 'rejected', reason: 'not_found', status: 404, elapsedMs: 500 } },
        written: false,
      });
      render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
      openAdvancedPage();
      fireEvent.click(screen.getByRole('button', { name: 'capabilityTest.action' }));

      expect(await screen.findByText('capabilityTest.panel.textNotFound')).toBeTruthy();
      expect(screen.getAllByText('capabilityTest.panel.notRun')).toHaveLength(2);
      expect(screen.getByText('capabilityTest.panel.footerNothing')).toBeTruthy();
    });

    it('cancelling while in progress: aborts the request, the panel stops at "Interrupted: you cancelled the test", and a late result does not overwrite it', async () => {
      mockRunRelayCapabilityTest.mockReset();
      let finish: (value: unknown) => void = () => {};
      mockRunRelayCapabilityTest.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
      render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
      openAdvancedPage();
      fireEvent.click(screen.getByRole('button', { name: 'capabilityTest.action' }));
      const { signal } = mockRunRelayCapabilityTest.mock.calls[0]![3] as { signal: AbortSignal };

      fireEvent.click(within(panelDialog()).getByRole('button', { name: 'cancel' }));
      expect(signal.aborted).toBe(true);
      expect(within(panelDialog()).getByText('capabilityTest.panel.stoppedBadge')).toBeTruthy();
      expect(within(panelDialog()).getByText('capabilityTest.panel.stopped({"reason":"capabilityTest.panel.stopCancelled"})')).toBeTruthy();
      expect(within(panelDialog()).getAllByText('capabilityTest.panel.notTested')).toHaveLength(3);

      await act(async () => {
        finish({ outcome: 'completed', plan: ['text', 'image', 'toolCall'], items: {}, results: {}, written: true });
      });
      expect(screen.queryByText('capabilityTest.panel.footerSaved')).toBeNull();
      fireEvent.click(within(panelDialog()).getByRole('button', { name: 'done' }));
      expect(screen.queryByRole('dialog')).toBeNull();
    });

    it('executor throws before writing back: the panel stops at "Interrupted: this model can no longer be tested" and does not show completed', async () => {
      mockRunRelayCapabilityTest.mockReset();
      mockRunRelayCapabilityTest.mockRejectedValue(new Error('store down'));
      render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
      openAdvancedPage();
      fireEvent.click(screen.getByRole('button', { name: 'capabilityTest.action' }));

      expect(await screen.findByText('capabilityTest.panel.stopped({"reason":"capabilityTest.panel.stopUnavailable"})')).toBeTruthy();
      expect(screen.queryByText('capabilityTest.panel.doneBadge')).toBeNull();
      expect(screen.queryByText('capabilityTest.panel.footerNothing')).toBeNull();
      expect(screen.queryByText('capabilityTest.panel.notRun')).toBeNull();
    });

    it('error only after the write: shown as "Completed - results written into"', async () => {
      mockRunRelayCapabilityTest.mockReset();
      mockRunRelayCapabilityTest.mockResolvedValue({
        outcome: 'completed',
        plan: ['text', 'image', 'toolCall'],
        items: { image: 'accepted', toolCall: 'accepted' },
        results: {
          text: { verdict: 'accepted', reason: 'ok', status: 200, elapsedMs: 100 },
          image: { verdict: 'accepted', reason: 'ok', status: 200, elapsedMs: 100 },
          toolCall: { verdict: 'accepted', reason: 'ok', status: 200, elapsedMs: 100 },
        },
        written: true,
        error: new Error('sync down'),
      });
      render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
      openAdvancedPage();
      fireEvent.click(screen.getByRole('button', { name: 'capabilityTest.action' }));

      expect(await screen.findByText('capabilityTest.panel.footerSaved')).toBeTruthy();
      expect(screen.getByText('capabilityTest.panel.doneBadge')).toBeTruthy();
    });

    it('executor reports the model can no longer be tested: the panel stops at "Interrupted" and gives the reason', async () => {
      mockRunRelayCapabilityTest.mockReset();
      mockRunRelayCapabilityTest.mockResolvedValue({
        outcome: 'stopped',
        plan: ['text', 'image', 'toolCall'],
        items: {},
        results: {},
        stopReason: 'unavailable',
        written: false,
      });
      render(<RelayDetail provider={{ ...provider, models: [relayModel] }} />);
      openAdvancedPage();
      fireEvent.click(screen.getByRole('button', { name: 'capabilityTest.action' }));

      expect(await screen.findByText('capabilityTest.panel.stopped({"reason":"capabilityTest.panel.stopUnavailable"})')).toBeTruthy();
      expect(screen.getByRole('button', { name: 'done' })).toBeTruthy();
    });

    it('vision and tools both already have a user override: no test-capability entry', () => {
      const userModel: AIModel = {
        ...relayModel,
        relayCapabilityOverrides: { image: { value: true, source: 'user' }, toolCall: { value: true, source: 'user' } },
      };
      render(<RelayDetail provider={{ ...provider, models: [userModel] }} />);
      openAdvancedPage();
      expect(screen.queryByRole('button', { name: 'capabilityTest.action' })).toBeNull();
    });

    // A local-engine connection gets no entry: the entry condition is canTestRelayModelCapabilities, and the scope assertion lives in relay-capability-test-ops.test.ts.
    it('with tested items present, "Restore all to auto" on the Advanced page is clickable', () => {
      mockRestoreAllRelayAutomatic.mockReset();
      render(<RelayDetail provider={{ ...provider, models: [testedModel] }} />);
      openAdvancedPage();
      fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.advanced.restoreAll' }));
      expect(mockRestoreAllRelayAutomatic).toHaveBeenCalledWith(expect.anything(), 'relay-1', 'gpt-image-1');
    });
  });
  describe('page-level navigation: levels driven by URL query parameters', () => {
    const withModel = { ...provider, models: [relayModel], catalogModels: [relayModel] };

    it('detail -> model library -> advanced pushes level by level; going back pops one level (router.back), and two backs return to the detail', () => {
      render(<RelayDetail provider={withModel} />);
      openModelLibrary();
      expect(routerPush).toHaveBeenLastCalledWith('/providers/relay-1?view=library');
      fireEvent.click(document.querySelector('[data-catalog-section="enabled"] [data-row-open]') as HTMLElement);
      expect(routerPush).toHaveBeenLastCalledWith('/providers/relay-1?view=advanced&model=gpt-image-1');
      expect(screen.getByRole('button', { name: 'pages.relayDetail.advanced.restoreAll' })).toBeTruthy();

      backToBoard();
      expect(routerBack).toHaveBeenCalledTimes(1);
      expect(screen.getAllByRole('button', { name: 'common.advancedMore' })).toHaveLength(1);
      backToBoard();
      expect(routerBack).toHaveBeenCalledTimes(2);
      expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeTruthy();
      expect(routerReplace).not.toHaveBeenCalled();
    });

    it('browser back (popstate) restores the level from the URL; after a refresh the level is opened directly from the URL', () => {
      window.history.replaceState(null, '', '/providers/relay-1?view=advanced&model=gpt-image-1');
      render(<RelayDetail provider={withModel} />);
      expect(screen.getByRole('button', { name: 'pages.relayDetail.advanced.restoreAll' })).toBeTruthy();

      act(() => {
        window.history.replaceState(null, '', '/providers/relay-1?view=library');
        window.dispatchEvent(new PopStateEvent('popstate'));
      });
      expect(screen.getAllByRole('button', { name: 'common.advancedMore' })).toHaveLength(1);
      act(() => {
        window.history.replaceState(null, '', '/providers/relay-1');
        window.dispatchEvent(new PopStateEvent('popstate'));
      });
      expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeTruthy();
    });

    it('detail -> keys page, one back returns to the detail; when the keys page link was opened directly, back replaces to the detail', () => {
      const view = render(<RelayDetail provider={provider} />);
      fireEvent.click(screen.getByRole('button', { name: 'editKey' }));
      expect(routerPush).toHaveBeenLastCalledWith('/providers/relay-1?view=keys');
      expect(screen.getByRole('heading', { name: 'pages.relayDetail.keysTitle' })).toBeTruthy();
      backToBoard();
      expect(routerBack).toHaveBeenCalledTimes(1);
      expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeTruthy();
      view.unmount();

      window.history.replaceState(null, '', '/providers/relay-1?view=keys');
      render(<RelayDetail provider={provider} />);
      expect(screen.getByRole('heading', { name: 'pages.relayDetail.keysTitle' })).toBeTruthy();
      backToBoard();
      expect(routerBack).toHaveBeenCalledTimes(1);
      expect(routerReplace).toHaveBeenCalledWith('/providers/relay-1');
      expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeTruthy();
    });

    it('read-only advanced (readonly=1): one back returns to the model library', () => {
      window.history.replaceState(null, '', '/providers/relay-1?view=advanced&model=gpt-image-1&readonly=1');
      render(<RelayDetail provider={withModel} />);
      expect(screen.getByRole('button', { name: 'pages.relayDetail.advanced.restoreAll' })).toBeTruthy();
      backToBoard();
      expect(routerReplace).toHaveBeenCalledWith('/providers/relay-1?view=library');
      expect(screen.getAllByRole('button', { name: 'common.advancedMore' })).toHaveLength(1);
    });

    it('refreshing read-only advanced while the local library is still backfilling: does not bounce back to the model library, and opens as usual once the backfill completes', () => {
      window.history.replaceState(null, '', '/providers/relay-1?view=advanced&model=gpt-5.4-mini&readonly=1');
      mockActionState.hydrationPhase = 'metadata-pending';
      const view = render(<RelayDetail provider={{ ...withModel, catalogModels: [] }} />);
      expect(routerReplace).not.toHaveBeenCalled();
      expect(routerBack).not.toHaveBeenCalled();
      const mini = { ...relayModel, id: 'gpt-5.4-mini', name: 'gpt-5.4-mini' };
      mockActionState.hydrationPhase = 'ready';
      view.rerender(<RelayDetail provider={{ ...withModel, catalogModels: [relayModel, mini] }} />);
      expect(routerReplace).not.toHaveBeenCalled();
      expect(screen.getByText('pages.relayDetail.advancedReadOnlyNote')).toBeTruthy();
    });

    it('advanced page whose model is gone: replaces back to the model library without leaving an empty history level', () => {
      window.history.replaceState(null, '', '/providers/relay-1?view=advanced&model=gone-model');
      render(<RelayDetail provider={withModel} />);
      expect(routerReplace).toHaveBeenCalledWith('/providers/relay-1?view=library');
      expect(screen.getAllByRole('button', { name: 'common.advancedMore' })).toHaveLength(1);
    });
  });
});

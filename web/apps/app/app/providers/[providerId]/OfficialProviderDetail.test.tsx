// @vitest-environment jsdom
import React from 'react';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import type { ResolvedProviderCatalog } from '../../../lib/core/providers/catalog-resolver';
import { OfficialProviderDetail } from './OfficialProviderDetail';

const routerPush = vi.fn();
const routerBack = vi.fn();
const mockDeleteProvider = vi.fn();
const mockSaveName = vi.fn();
const mockSetLastUsedModelRef = vi.fn();
const mockSetActiveConversationId = vi.fn();
const mockShowToast = vi.fn();
const { initMetadataMock, refreshMetadataMock } = vi.hoisted(() => ({
  initMetadataMock: vi.fn(() => Promise.resolve()),
  refreshMetadataMock: vi.fn(() => Promise.resolve()),
}));
let resolvedCatalogMock: ResolvedProviderCatalog = {
  catalog: [],
  enabledModels: [],
  recommendedModels: [],
  defaultModel: null,
  availableModelCount: 0,
  hasManualModels: false,
};

const provider: Provider = {
  id: 'official-1',
  kind: 'openAI',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: 'sk-official',
  apiKeyPreview: 'sk-official',
  baseURLText: 'https://api.openai.com/v1',
};

// Providers returned by the getVanillaStore mock; each test overrides them to drive the three-state decision after a resync.
let storeProvidersMock: Provider[] = [];

// Three-state subscription sign-in availability. The default "not served by the backend" is the current path for every other official provider.
let grokSubscriptionAvailabilityMock: unknown = { state: 'unavailable' };
let openAISubscriptionAvailabilityMock: unknown = { state: 'unavailable' };
const mockSwitchProviderToApiKeyMode = vi.fn();
const mockPersistGrokSubscriptionCredential = vi.fn();
const mockPersistOpenAISubscriptionCredential = vi.fn();

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: routerPush,
    back: routerBack,
  }),
}));

// Note: t must be a stable reference. ProviderBalanceCard puts t in the useCallback deps of load,
// and useEffect depends on load. Returning a new function on every render reruns the effect
// forever, setState included, and hangs the whole vitest worker at 100% CPU instead of reporting
// a timeout. The real next-intl t is memoized.
const translateMock = (key: string, values?: Record<string, unknown>) => (
  typeof values?.model === 'string' ? `${key}:${values.model}` : key
);
vi.mock('next-intl', () => ({
  useTranslations: () => translateMock,
}));

vi.mock('@oriveo/ui', () => ({
  // Forward the rest props: the real Button spreads `{...rest}`, and dropping data-testid makes the button invisible to the test.
  Button: ({ children, onClick, disabled, ...rest }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
  } & Record<string, unknown>) => (
    <button onClick={onClick} disabled={disabled} {...rest}>{children}</button>
  ),
  BackArrowIcon: () => <span data-testid="back-arrow" />,
  StatusPill: ({ label }: { label: string }) => <span>{label}</span>,
}));

vi.mock('../../../lib/hooks/useProviderActions', () => ({
  useProviderActions: () => ({
    isSyncing: false,
    saveKey: vi.fn(),
    saveBaseURL: vi.fn(),
    saveName: mockSaveName,
    resync: vi.fn(),
    toggleModel: vi.fn(),
    enableAllModels: vi.fn(),
    disableAllModels: vi.fn(),
    addModels: vi.fn(),
    removeModel: vi.fn(),
    deleteProvider: mockDeleteProvider,
  }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: {
    setLastUsedModelRef: typeof mockSetLastUsedModelRef;
    setActiveConversationId: typeof mockSetActiveConversationId;
  }) => unknown) =>
    selector({
      setLastUsedModelRef: mockSetLastUsedModelRef,
      setActiveConversationId: mockSetActiveConversationId,
    }),
  getVanillaStore: () => ({ getState: () => ({ providers: storeProvidersMock }) }),
}));

vi.mock('../../../components/Toast', () => ({
  showToast: (...args: unknown[]) => mockShowToast(...args),
}));

vi.mock('../../../components/ProviderIcon', () => ({
  ProviderIcon: () => <span data-testid="provider-icon" />,
}));

vi.mock('./ModelBrowser', () => ({
  ModelBrowser: () => <div data-testid="model-browser" />,
  VendorIdentity: ({ dataTestId }: { dataTestId?: string }) => (
    <span data-testid={dataTestId ?? 'vendor-identity'} />
  ),
}));

vi.mock('../../../components/chat/ModelMetaInline', () => ({
  ModelMetaInline: () => <span data-testid="model-meta" />,
  // The model row renders ModelCommercialMetaInline; without this export the enabled-model list crashes as soon as it renders.
  ModelCommercialMetaInline: () => <span data-testid="model-commercial-meta" />,
}));

vi.mock('./components/BaseURLEditor', () => ({
  BaseURLEditor: ({ onSave }: { onSave: () => void }) => (
    <button data-testid="base-url-editor" onClick={onSave}>baseUrlEdit</button>
  ),
}));

vi.mock('./components/ConfirmDeleteDialog', () => ({
  ConfirmDeleteDialog: ({ onConfirm, onCancel }: { onConfirm: () => void; onCancel: () => void }) => (
    <div data-testid="confirm-delete-dialog">
      <button onClick={onConfirm}>confirmDelete</button>
      <button onClick={onCancel}>cancelDelete</button>
    </div>
  ),
}));

// BrandHero exposes the editName button that drives the rename dialog; the visual part is mocked out to keep the test on pure logic.
vi.mock('./components/ProviderDetailBrandHero', () => ({
  ProviderDetailBrandHero: ({ onEditName, onVerifyConnection }: { onEditName?: () => void; onVerifyConnection?: () => void }) => (
    <div data-testid="brand-hero">
      {onEditName && (
        <button aria-label="editName" onClick={onEditName}>editName</button>
      )}
      {onVerifyConnection && (
        <button aria-label="verifyConnection" onClick={onVerifyConnection}>verifyConnection</button>
      )}
    </div>
  ),
}));

// RecoveryCard mock: the error flow is not under test here, only that nothing crashes.
vi.mock('./components/ProviderConnectionRecoveryCard', () => ({
  ProviderConnectionRecoveryCard: () => <div data-testid="recovery-card" />,
}));

// SettingsPanel exposes the onDelete row, the interaction under test.
vi.mock('./components/ProviderSettingsPanel', () => ({
  ProviderSettingsPanel: ({ onDelete }: { onDelete?: () => void }) => (
    <div data-testid="settings-panel">
      {onDelete && (
        <button aria-label="deleteProvider" onClick={onDelete}>deleteProvider</button>
      )}
    </div>
  ),
}));

// RenameProviderDialog: uncontrolled input plus a save button that reads input.value.
vi.mock('./components/RenameProviderDialog', () => ({
  RenameProviderDialog: ({
    currentName,
    onSave,
    onCancel,
  }: {
    currentName: string;
    onSave: (name: string) => void;
    onCancel: () => void;
  }) => {
    let inputRef: HTMLInputElement | null = null;
    return (
      <div data-testid="rename-dialog">
        <input
          aria-label="renameInput"
          defaultValue={currentName}
          ref={(el) => { inputRef = el; }}
        />
        <button aria-label="saveName" onClick={() => onSave((inputRef?.value ?? '').trim())}>
          saveName
        </button>
        <button aria-label="cancelRename" onClick={onCancel}>cancelRename</button>
      </div>
    );
  },
}));

vi.mock('../../../lib/core/store/selectors', () => ({
  selectResolvedCatalog: () => resolvedCatalogMock,
}));

vi.mock('../../../components/providers/official-endpoint-utils', () => ({
  getOfficialEndpointDescriptionTranslationKey: () => '',
  getOfficialEndpointOptionTranslationKey: () => '',
  isOfficialEndpointProvider: () => false,
  resolveOfficialEndpointOptions: () => [],
}));

vi.mock('../../../lib/core/metadata/metadata-client', () => ({
  getPublicProviderConfig: () => ({}),
  initMetadata: initMetadataMock,
  refreshMetadata: refreshMetadataMock,
  onVersionChange: () => () => {},
  getCachedMetadataVersion: () => 0,
  // Subscription section not served by the backend: every official provider other than Grok / Codex takes this path, and the detail page looks unchanged.
  getGrokSubscriptionAvailability: () => grokSubscriptionAvailabilityMock,
  getOpenAISubscriptionAvailability: () => openAISubscriptionAvailabilityMock,
}));

vi.mock('../../../lib/core/provider-ops', () => ({
  switchProviderToApiKeyMode: (...args: unknown[]) => mockSwitchProviderToApiKeyMode(...args),
  persistGrokSubscriptionCredential: (...args: unknown[]) =>
    mockPersistGrokSubscriptionCredential(...args),
  persistOpenAISubscriptionCredential: (...args: unknown[]) =>
    mockPersistOpenAISubscriptionCredential(...args),
}));

vi.mock('../../../components/providers/GrokSubscriptionAuthorizationDialog', () => ({
  GrokSubscriptionAuthorizationDialog: () => <div data-testid="grok-reauthorize-dialog" />,
}));

describe('OfficialProviderDetail', () => {
  afterEach(() => {
    cleanup();
  });

  beforeEach(() => {
    routerPush.mockReset();
    routerBack.mockReset();
    mockDeleteProvider.mockReset();
    mockSaveName.mockReset();
    mockSetLastUsedModelRef.mockReset();
    initMetadataMock.mockClear();
    refreshMetadataMock.mockClear();
    resolvedCatalogMock = {
      catalog: [],
      enabledModels: [],
      recommendedModels: [],
      defaultModel: null,
      availableModelCount: 0,
      hasManualModels: false,
    };
    mockShowToast.mockReset();
    storeProvidersMock = [provider];
    grokSubscriptionAvailabilityMock = { state: 'unavailable' };
    openAISubscriptionAvailabilityMock = { state: 'unavailable' };
    mockSwitchProviderToApiKeyMode.mockReset();
    mockSwitchProviderToApiKeyMode.mockResolvedValue(true);
    mockPersistGrokSubscriptionCredential.mockReset();
    mockPersistOpenAISubscriptionCredential.mockReset();
  });

  describe('Grok subscription instance', () => {
    const subscriptionProvider: Provider = {
      ...provider,
      id: 'grok-1',
      kind: 'grok',
      apiKey: '',
      apiKeyPreview: '',
      authMode: 'subscription',
      grokSubscription: { accessToken: 'at', obtainedAt: 1 },
    };

    it('does not show a subscription card for an API Key instance', () => {
      render(<OfficialProviderDetail provider={provider} />);
      expect(screen.queryByTestId('grok-subscription-card')).toBeNull();
    });

    it('shows the credential card and the reauthorize entry point for a subscription instance', () => {
      grokSubscriptionAvailabilityMock = { state: 'available', config: {} };
      render(<OfficialProviderDetail provider={subscriptionProvider} />);
      expect(screen.getByTestId('grok-subscription-card')).toBeTruthy();
      expect(screen.getByTestId('grok-subscription-reauthorize')).toBeTruthy();
      expect(screen.queryByTestId('grok-subscription-disabled-notice')).toBeNull();
    });

    it('keeps the connection when the kill switch is off: shows the served copy, drops reauthorize, and keeps the way back to API Key', () => {
      grokSubscriptionAvailabilityMock = { state: 'disabled', notice: 'ops paused it' };
      render(<OfficialProviderDetail provider={subscriptionProvider} />);
      expect(screen.getByTestId('grok-subscription-disabled-notice').textContent).toBe('ops paused it');
      expect(screen.queryByTestId('grok-subscription-reauthorize')).toBeNull();
      expect(screen.getByTestId('grok-subscription-switch-api-key')).toBeTruthy();
    });

    it('falls back to localized copy when the served payload has no disabledNotice, instead of leaving a blank area', () => {
      grokSubscriptionAvailabilityMock = { state: 'disabled' };
      render(<OfficialProviderDetail provider={subscriptionProvider} />);
      expect(screen.getByTestId('grok-subscription-disabled-notice').textContent)
        .toBe('disabledFallback');
    });

    it('switching back to API Key leaves subscription mode and opens key editing', async () => {
      grokSubscriptionAvailabilityMock = { state: 'disabled', notice: 'ops paused it' };
      render(<OfficialProviderDetail provider={subscriptionProvider} />);
      fireEvent.click(screen.getByTestId('grok-subscription-switch-api-key'));
      await waitFor(() => expect(mockSwitchProviderToApiKeyMode).toHaveBeenCalled());
      expect(mockSwitchProviderToApiKeyMode.mock.calls[0]?.[1]).toBe('grok-1');
    });
  });

  describe('Codex subscription instance', () => {
    const codexProvider: Provider = {
      ...provider,
      id: 'openai-1',
      kind: 'openAI',
      apiKey: '',
      apiKeyPreview: '',
      authMode: 'subscription',
      openAISubscription: { accessToken: 'at', accountID: 'acc-1', obtainedAt: 1 },
    };

    it('shows the Codex credential card for a subscription instance rather than reusing the Grok one', () => {
      openAISubscriptionAvailabilityMock = { state: 'available', config: {} };
      render(<OfficialProviderDetail provider={codexProvider} />);
      expect(screen.getByTestId('openai-subscription-card')).toBeTruthy();
      expect(screen.getByTestId('openai-subscription-reauthorize')).toBeTruthy();
      // Key regression: keying only on `authMode === 'subscription'` without looking at kind makes a
      // Codex instance show the Grok card and authorization dialog, exchanging x.ai endpoints for
      // ChatGPT credentials.
      expect(screen.queryByTestId('grok-subscription-card')).toBeNull();
    });

    it('the served Grok state does not affect the three card states of a Codex instance', () => {
      // The two paths have independent kill switches: turning Grok off must not take the entry point away from Codex users.
      grokSubscriptionAvailabilityMock = { state: 'disabled', notice: 'grok paused' };
      openAISubscriptionAvailabilityMock = { state: 'available', config: {} };
      render(<OfficialProviderDetail provider={codexProvider} />);
      expect(screen.getByTestId('openai-subscription-reauthorize')).toBeTruthy();
      expect(screen.queryByTestId('openai-subscription-disabled-notice')).toBeNull();
    });

    it('shows the served copy and keeps the way back to API Key when the Codex kill switch is off', () => {
      openAISubscriptionAvailabilityMock = { state: 'disabled', notice: 'codex paused' };
      render(<OfficialProviderDetail provider={codexProvider} />);
      expect(screen.getByTestId('openai-subscription-disabled-notice').textContent)
        .toBe('codex paused');
      expect(screen.queryByTestId('openai-subscription-reauthorize')).toBeNull();
      expect(screen.getByTestId('openai-subscription-switch-api-key')).toBeTruthy();
    });

    it('shows no subscription card for an OpenAI instance in API Key mode', () => {
      openAISubscriptionAvailabilityMock = { state: 'available', config: {} };
      render(<OfficialProviderDetail provider={{ ...provider, kind: 'openAI' }} />);
      expect(screen.queryByTestId('openai-subscription-card')).toBeNull();
    });
  });

  it('shows a success toast after verifying a healthy connection', async () => {
    storeProvidersMock = [{ ...provider, status: { kind: 'connected' }, lastError: undefined }];
    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByLabelText('verifyConnection'));

    await waitFor(() => expect(mockShowToast).toHaveBeenCalledTimes(1));
    expect(mockShowToast.mock.calls[0]?.[0]).toBe('toast.connectionVerified');
    expect(mockShowToast.mock.calls[0]?.[3]).toBe('success');
  });

  it('shows an error toast when verification leaves the provider in issue state', async () => {
    storeProvidersMock = [{ ...provider, status: { kind: 'issue', message: 'bad' }, lastError: 'bad' }];
    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByLabelText('verifyConnection'));

    await waitFor(() => expect(mockShowToast).toHaveBeenCalledTimes(1));
    expect(mockShowToast.mock.calls[0]?.[3]).toBe('error');
  });

  it('shows a warning toast on unverified soft failure', async () => {
    storeProvidersMock = [{ ...provider, status: { kind: 'connected' }, lastError: 'soft reason' }];
    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByLabelText('verifyConnection'));

    await waitFor(() => expect(mockShowToast).toHaveBeenCalledTimes(1));
    expect(mockShowToast.mock.calls[0]?.[3]).toBe('warning');
  });

  it('does not render usage statistics section (removed, now in separate card)', () => {
    render(<OfficialProviderDetail provider={provider} />);

    // Neither the usage tabs nor the cost figures should be present.
    expect(screen.queryByRole('tab')).toBeNull();
    expect(screen.queryByText('$42.00')).toBeNull();
  });

  it('shows the danger dialog and deletes provider when confirmed', () => {
    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'deleteProvider' }));
    expect(screen.getByTestId('confirm-delete-dialog')).toBeTruthy();

    fireEvent.click(screen.getByText('confirmDelete'));
    expect(mockDeleteProvider).toHaveBeenCalledTimes(1);
  });

  it('renders back button that navigates to providers list', () => {
    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'back' }));
    expect(routerPush).toHaveBeenCalledWith('/providers');
  });

  it('lets users rename the provider from the logo-side title', () => {
    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'editName' }));
    const input = screen.getByDisplayValue('OpenAI');
    fireEvent.change(input, { target: { value: 'Work OpenAI' } });
    fireEvent.click(screen.getByRole('button', { name: 'saveName' }));

    expect(mockSaveName).toHaveBeenCalledWith('Work OpenAI');
  });

  it('uses added-model copy for official provider library sections', () => {
    render(<OfficialProviderDetail provider={provider} />);

    expect(screen.getAllByText('addedModels').length).toBeGreaterThan(0);
    expect(screen.getByText('noAddedModels')).toBeTruthy();
    expect(screen.getByText('addAll')).toBeTruthy();
    expect(screen.getByText('removeAll')).toBeTruthy();
    expect(screen.queryByText('enabledModels')).toBeNull();
  });

  it('renders enabled models flat regardless of metadata vendor groups', () => {
    const groupedProvider: Provider = {
      ...provider,
      kind: 'openRouter',
      models: [
        {
          id: 'anthropic/claude-sonnet-4',
          name: 'claude-sonnet-4',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
        {
          id: 'openai/gpt-4o',
          name: 'gpt-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
      ],
    };

    resolvedCatalogMock = {
      catalog: [],
      enabledModels: [
        {
          id: 'anthropic/claude-sonnet-4',
          name: 'Claude Sonnet 4',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          isEnabled: true,
          isManual: false,
          priceTier: '',
          groupKey: 'anthropic',
          groupName: 'Anthropic',
          sortRank: 200,
        },
        {
          id: 'openai/gpt-4o',
          name: 'GPT-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          isEnabled: true,
          isManual: false,
          priceTier: '',
          groupKey: 'openai',
          groupName: 'OpenAI',
          sortRank: 180,
        },
      ],
      recommendedModels: [],
      defaultModel: null,
      availableModelCount: 0,
      hasManualModels: false,
    };

    render(<OfficialProviderDetail provider={groupedProvider} />);

    expect(screen.queryByTestId('enabled-group-anthropic')).toBeNull();
    expect(screen.queryByTestId('enabled-group-openai')).toBeNull();
    expect(screen.getByText('Claude Sonnet 4')).toBeTruthy();
    expect(screen.getByText('GPT-4o')).toBeTruthy();
  });

  it('does not force refresh metadata when entering detail page', async () => {
    render(<OfficialProviderDetail provider={provider} />);

    await waitFor(() => {
      expect(initMetadataMock).toHaveBeenCalledTimes(1);
    });
    expect(refreshMetadataMock).not.toHaveBeenCalled();
  });

  it('keeps one vendor group plus ungrouped models flat instead of forcing folder mode', () => {
    const mixedProvider: Provider = {
      ...provider,
      kind: 'openRouter',
      models: [
        {
          id: 'openai/gpt-4o',
          name: 'gpt-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
        {
          id: 'custom/manual-model',
          name: 'manual-model',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
    };

    resolvedCatalogMock = {
      catalog: [],
      enabledModels: [
        {
          id: 'openai/gpt-4o',
          name: 'GPT-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          isEnabled: true,
          isManual: false,
          priceTier: '',
          groupKey: 'openai',
          groupName: 'OpenAI',
          sortRank: 180,
        },
        {
          id: 'custom/manual-model',
          name: 'Manual Model',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          isEnabled: true,
          isManual: true,
          priceTier: '',
          sortRank: 0,
        },
      ],
      recommendedModels: [],
      defaultModel: null,
      availableModelCount: 0,
      hasManualModels: true,
    };

    render(<OfficialProviderDetail provider={mixedProvider} />);

    expect(screen.queryByTestId('enabled-group-openai')).toBeNull();
    expect(screen.getByText('GPT-4o')).toBeTruthy();
    expect(screen.getByText('Manual Model')).toBeTruthy();
    expect(screen.getByRole('switch', { name: 'disableModelA11y:GPT-4o' })).toBeTruthy();
    expect(screen.getByRole('switch', { name: 'disableModelA11y:Manual Model' })).toBeTruthy();
  });

  it('starts a chat with an enabled official model from the model row action', () => {
    resolvedCatalogMock = {
      catalog: [],
      enabledModels: [
        {
          id: 'gpt-4o',
          name: 'GPT-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          isEnabled: true,
          isManual: false,
          priceTier: '',
          sortRank: 180,
        },
      ],
      recommendedModels: [],
      defaultModel: null,
      availableModelCount: 0,
      hasManualModels: false,
    };

    render(<OfficialProviderDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'chatWithModel:GPT-4o' }));

    expect(mockSetLastUsedModelRef).toHaveBeenCalledWith({
      providerID: 'official-1',
      modelID: 'gpt-4o',
    });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });
});

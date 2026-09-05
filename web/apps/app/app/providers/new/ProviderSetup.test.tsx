import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { ProviderSetup } from './ProviderSetup';
import type { ProviderError } from '../../../lib/core/providers/errors';

const routerPush = vi.fn();
const routerBack = vi.fn();
const mockSearchParamsGet = vi.fn();
const mockBuildOfficialEnabledModels = vi.fn();
const mockGetMetadataSnapshot = vi.fn();
const mockProviderOpsAdd = vi.fn();
const mockCreateCanonicalUUID = vi.fn();
const mockCreateDeterministicProviderId = vi.fn();
const mockSetHasCompletedOnboarding = vi.fn();
const mockIsOfficialEndpointProvider = vi.fn();
const mockGetOfficialEndpointDescriptionTranslationKey = vi.fn();
const mockGetOfficialEndpointOptionTranslationKey = vi.fn();
const mockGetGrokSubscriptionAvailability = vi.fn();
const mockFetchGrokSubscriptionModels = vi.fn();
const mockGetOpenAISubscriptionAvailability = vi.fn();
const mockFetchOpenAISubscriptionModels = vi.fn();
const mockTrackEvent = vi.fn();

const mockStore: {
  providers: Provider[];
  conversations: Array<{ id: string }>;
  account: null;
  addProvider: () => void;
  setHasCompletedOnboarding: (value: boolean) => void;
} = {
  providers: [],
  conversations: [],
  account: null,
  addProvider: () => {},
  setHasCompletedOnboarding: mockSetHasCompletedOnboarding,
};

const mockModel: AIModel = {
  id: 'model-openai',
  name: 'OpenAI Model',
  capabilities: [],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: 'standard',
};

vi.mock('../../../lib/core/telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/telemetry')>()),
  trackEvent: (...args: unknown[]) => mockTrackEvent(...args),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: routerPush,
    back: routerBack,
  }),
  useSearchParams: () => ({
    get: mockSearchParamsGet,
  }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('@oriveo/shared', async () => {
  const actual = await vi.importActual<typeof import('@oriveo/shared')>('@oriveo/shared');
  return {
    ...actual,
    formatApiKeyPreview: (key: string) => `preview-${key}`,
  };
});

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: typeof mockStore) => unknown) => selector(mockStore),
  getVanillaStore: () => mockStore,
}));

vi.mock('../../../lib/core/provider-ops', () => ({
  addProvider: (...args: unknown[]) => mockProviderOpsAdd(...args),
}));

vi.mock('../../../lib/utils/id-utils', () => ({
  // Another instance of the same kind, and relay, get a random id.
  createCanonicalUUID: () => {
    mockCreateCanonicalUUID();
    return 'provider-uuid';
  },
  // The default official instance gets a deterministic id (async); the test returns one
  // placeholder value so the existing id assertions still apply.
  createDeterministicProviderId: async (...args: unknown[]) => {
    mockCreateDeterministicProviderId(...args);
    return 'provider-uuid';
  },
}));

vi.mock('../../../lib/core/providers/official-model-sync', () => ({
  buildOfficialEnabledModels: (...args: unknown[]) => mockBuildOfficialEnabledModels(...args),
}));

// Partial mock: only the entries this suite cares about are replaced, the rest stay real.
// Replacing the whole module rots as production adds exports -- once the relay transport path
// pulled in getRelayRuntimeConfig, the whole file failed at collect time with
// "No export is defined on the mock". The real getRelayRuntimeConfig returns
// DEFAULT_RELAY_RUNTIME_CONFIG with no side effects when nothing is cached.
vi.mock('../../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/metadata/metadata-client')>()),
  hasPublicProviderConfigSource: () => false,
  listPublicProviderConfigs: () => [],
  initMetadata: () => Promise.resolve(),
  refreshMetadata: () => Promise.resolve(),
  getMetadataSnapshot: (...args: unknown[]) => mockGetMetadataSnapshot(...args),
  getGrokSubscriptionAvailability: () => mockGetGrokSubscriptionAvailability(),
  getOpenAISubscriptionAvailability: () => mockGetOpenAISubscriptionAvailability(),
}));

vi.mock('../../../lib/core/providers/grok-subscription', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/providers/grok-subscription')>()),
  fetchGrokSubscriptionModels: (...args: unknown[]) => mockFetchGrokSubscriptionModels(...args),
}));

// Only IO is replaced: `openAISubscriptionErrorToValidationMessage` keeps its real
// implementation, since the assertion about which reason is written targets that mapping.
vi.mock('../../../lib/core/providers/openai-subscription', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/providers/openai-subscription')>()),
  fetchOpenAISubscriptionModels: (...args: unknown[]) => mockFetchOpenAISubscriptionModels(...args),
}));

// Device code authorization itself is covered by unit tests in `useGrokDeviceAuthorization` and
// core; this file only checks that the entry appears and what is stored after a successful grant.
vi.mock('../../../components/providers/GrokSubscriptionAuthorizationDialog', () => ({
  GrokSubscriptionAuthorizationDialog: ({
    onAuthorized,
  }: {
    onAuthorized: (credential: unknown) => void;
  }) => (
    <button
      data-testid="grok-subscription-dialog-authorize"
      onClick={() =>
        onAuthorized({ accessToken: 'access-token', refreshToken: 'refresh-token', obtainedAt: 1 })
      }
    >
      authorize
    </button>
  ),
}));

vi.mock('../../../components/providers/OpenAISubscriptionAuthorizationDialog', () => ({
  OpenAISubscriptionAuthorizationDialog: ({
    onAuthorized,
  }: {
    onAuthorized: (credential: unknown) => void;
  }) => (
    <button
      data-testid="openai-subscription-dialog-authorize"
      onClick={() =>
        onAuthorized({
          accessToken: 'codex-access-token',
          refreshToken: 'codex-refresh-token',
          // Parsed from the id_token and checked non-empty during authorization; the catalog
          // fetch must use that value rather than looking one up itself.
          accountID: 'codex-account-id',
          obtainedAt: 1,
        })
      }
    >
      authorize
    </button>
  ),
}));

// Add page: crystal hero, category chips, grouped showcase cards and two custom entries.
vi.mock('./ProviderCard', () => ({
  SetupHero: () => <div data-testid="setup-hero" />,
  ProviderCategoryChips: ({
    selected,
    onSelect,
  }: {
    selected: string;
    onSelect: (category: string) => void;
  }) => (
    <div>
      {['all', 'direct', 'aggregators', 'custom'].map((category) => (
        <button
          key={category}
          data-testid={`category-${category}`}
          data-active={selected === category ? 'true' : 'false'}
          onClick={() => onSelect(category)}
        >
          {category}
        </button>
      ))}
    </div>
  ),
  ProviderShowcaseSection: ({
    providers,
    selectedKind,
    onSelect,
  }: {
    label: string;
    providers: Array<{ kind: string; displayName: string }>;
    selectedKind: string | null;
    onSelect: (kind: string) => void;
  }) => (
    <div>
      {providers.map((provider) => (
        <button
          key={provider.kind}
          data-testid={`provider-grid-${provider.kind}`}
          data-selected={selectedKind === provider.kind ? 'true' : 'false'}
          onClick={() => onSelect(provider.kind)}
        >
          {provider.displayName}
        </button>
      ))}
    </div>
  ),
  LocalComputeEntry: ({ onTap }: { onTap: () => void }) => (
    <button data-testid="provider-grid-local-compute" onClick={onTap}>
      local-compute
    </button>
  ),
  CustomRelayEntry: ({ onTap }: { onTap: () => void }) => (
    <button data-testid="provider-grid-custom-endpoint" onClick={onTap}>
      custom-endpoint
    </button>
  ),
}));

vi.mock('../../../components/providers/OfficialEndpointSelector', () => ({
  OfficialEndpointSelector: ({
    options,
    value,
    onChange,
  }: {
    options: Array<{ id: string }>;
    value: string;
    onChange: (value: string) => void;
  }) => (
    <div data-testid="official-endpoint-selector" data-value={value}>
      {options.map((option) => (
        <button
          key={option.id}
          data-testid={`endpoint-${option.id}`}
          onClick={() => onChange(option.id)}
        >
          {option.id}
        </button>
      ))}
    </div>
  ),
}));

vi.mock('../../../components/providers/official-endpoint-utils', () => ({
  getOfficialEndpointDescriptionTranslationKey: (...args: unknown[]) =>
    mockGetOfficialEndpointDescriptionTranslationKey(...args),
  getOfficialEndpointOptionTranslationKey: (...args: unknown[]) =>
    mockGetOfficialEndpointOptionTranslationKey(...args),
  isOfficialEndpointProvider: (...args: unknown[]) =>
    mockIsOfficialEndpointProvider(...args),
}));

// Pick the provider first, then fill the key inline: the openRouter showcase card has to be
// selected before the key field appears.
async function selectOpenRouter() {
  fireEvent.click(await screen.findByTestId('provider-grid-openRouter'));
}

describe('ProviderSetup', () => {
  beforeEach(() => {
    routerPush.mockReset();
    routerBack.mockReset();
    mockSearchParamsGet.mockReset();
    mockBuildOfficialEnabledModels.mockReset();
    mockGetMetadataSnapshot.mockReset();
    mockProviderOpsAdd.mockReset();
    mockTrackEvent.mockReset();
    mockCreateCanonicalUUID.mockReset();
    mockCreateDeterministicProviderId.mockReset();
    mockSetHasCompletedOnboarding.mockReset();
    mockIsOfficialEndpointProvider.mockReset();
    mockGetOfficialEndpointDescriptionTranslationKey.mockReset();
    mockGetOfficialEndpointOptionTranslationKey.mockReset();
    mockSearchParamsGet.mockReturnValue(null);
    mockIsOfficialEndpointProvider.mockReturnValue(false);
    mockGetOfficialEndpointDescriptionTranslationKey.mockReturnValue('');
    mockGetOfficialEndpointOptionTranslationKey.mockReturnValue(null);
    mockStore.providers = [];
    mockStore.conversations = [];
    mockGetMetadataSnapshot.mockReturnValue({ providers: {} });
    mockGetGrokSubscriptionAvailability.mockReset();
    mockFetchGrokSubscriptionModels.mockReset();
    // Default: the backend sends no subscription section, so the add flow is unchanged.
    mockGetGrokSubscriptionAvailability.mockReturnValue({ state: 'unavailable' });
    mockFetchGrokSubscriptionModels.mockResolvedValue({
      ok: true,
      value: [
        { id: 'grok-4.6', supportsWebSearch: true, supportsReasoning: true, reasoningEfforts: ['high'] },
        { id: 'grok-4.5', supportsWebSearch: false, supportsReasoning: false, reasoningEfforts: [] },
      ],
    });
    mockGetOpenAISubscriptionAvailability.mockReset();
    mockFetchOpenAISubscriptionModels.mockReset();
    mockGetOpenAISubscriptionAvailability.mockReturnValue({ state: 'unavailable' });
    mockFetchOpenAISubscriptionModels.mockResolvedValue({
      ok: true,
      value: [
        {
          slug: 'gpt-5.6-sol', supportsWebSearch: true,
          supportedReasoningLevels: ['low', 'medium', 'high'], supportsImageInput: true,
        },
        { slug: 'gpt-5.5', supportsWebSearch: false, supportedReasoningLevels: [], supportsImageInput: false },
      ],
    });
  });

  it('redirects to the dedicated relay setup page when the kind query param requests relay', async () => {
    mockSearchParamsGet.mockImplementation((key: string) => (key === 'kind' ? 'relay' : null));

    render(<ProviderSetup />);

    await waitFor(() => {
      expect(routerPush).toHaveBeenCalledWith('/providers/relay/new');
    });
  });

  it('keeps local compute and custom endpoint out of All and routes each Custom entry directly', async () => {
    render(<ProviderSetup />);

    expect(screen.queryByRole('searchbox')).toBeNull();
    expect(screen.queryByTestId('provider-grid-local-compute')).toBeNull();
    expect(screen.queryByTestId('provider-grid-custom-endpoint')).toBeNull();

    fireEvent.click(await screen.findByTestId('category-custom'));
    fireEvent.click(await screen.findByTestId('provider-grid-local-compute'));
    fireEvent.click(await screen.findByTestId('provider-grid-custom-endpoint'));

    await waitFor(() => {
      expect(routerPush).toHaveBeenCalledWith('/providers/relay/new?mode=local');
      expect(routerPush).toHaveBeenCalledWith('/providers/relay/new');
    });
  });

  it('marks the provider API key field as a non-login secret', async () => {
    render(<ProviderSetup />);
    await selectOpenRouter();

    const input = await screen.findByPlaceholderText('sk-or-...');
    expect(input.getAttribute('autocomplete')).toBe('new-password');
    expect(input.getAttribute('name')).toBe('provider-api-key');
    expect(input.getAttribute('type')).toBe('text');
    expect(input.getAttribute('data-secret-visibility')).toBe('masked');
  });

  it('switches the SiliconFlow API key link with the selected endpoint', async () => {
    mockSearchParamsGet.mockImplementation((key: string) =>
      key === 'kind' ? 'siliconFlow' : null,
    );
    mockIsOfficialEndpointProvider.mockImplementation((kind: string) =>
      kind === 'siliconFlow',
    );
    mockGetOfficialEndpointDescriptionTranslationKey.mockReturnValue(
      'officialEndpointDescriptionSiliconFlow',
    );
    mockGetOfficialEndpointOptionTranslationKey.mockImplementation(
      (_kind: string, optionId: string) => `endpointOptions.siliconFlow.${optionId}`,
    );

    render(<ProviderSetup />);

    const keyLink = await screen.findByRole('link', { name: 'getKeyAt' });
    expect(keyLink.getAttribute('href')).toBe('https://cloud.siliconflow.cn/account/ak');

    fireEvent.click(await screen.findByTestId('endpoint-intl'));

    await waitFor(() => {
      expect(keyLink.getAttribute('href')).toBe('https://cloud.siliconflow.com/account/ak');
    });
  });

  // The submission telemetry has to come from a real click path: testing the builder alone only
  // tests the consumer, and a producer that never calls it would still pass.
  it('emits one diagnostic provider_key_validated when the user presses connect', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [mockModel],
      defaultModelId: mockModel.id,
      catalogModels: [],
    });

    render(<ProviderSetup />);
    await selectOpenRouter();
    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'sk-test-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    await waitFor(() => expect(mockTrackEvent).toHaveBeenCalledWith(
      'provider_key_validated',
      expect.anything(),
    ));
    const [, properties] = mockTrackEvent.mock.calls
      .find(([event]) => event === 'provider_key_validated') ?? [];
    expect(properties).toMatchObject({
      provider_kind: 'openrouter',
      success: true,
      error_code: '',
      endpoint: 'https://openrouter.ai/api/v1',
      endpoint_host: 'openrouter.ai',
      entry_point: 'onboarding',
      is_first_provider: true,
      connection_attempts: 1,
      auth_mode: 'api_key',
      setup_surface: 'provider_setup',
    });
  });

  it('connects non-relay provider, adds it, and pushes to /chat when first provider', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [mockModel],
      defaultModelId: mockModel.id,
      catalogModels: [],
    });

    render(<ProviderSetup />);
    await selectOpenRouter();

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: '  sk-test-key  ' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
    expect(mockProviderOpsAdd).toHaveBeenCalledWith(mockStore, expect.objectContaining({
      kind: 'openRouter',
      apiKey: 'sk-test-key',
      baseURLText: 'https://openrouter.ai/api/v1',
      id: 'provider-uuid',
      apiKeyPreview: 'preview-sk-test-key',
    }));
    // The first instance of a kind gets a deterministic id (the default path), not a random one.
    expect(mockCreateDeterministicProviderId).toHaveBeenCalled();
    expect(mockCreateCanonicalUUID).not.toHaveBeenCalled();
    expect(mockSetHasCompletedOnboarding).toHaveBeenCalledWith(true);
    await waitFor(() => {
      expect(routerPush).toHaveBeenCalledWith('/chat');
    });
  });

  it('renders syncing status above the provider grid so it stays near the top', async () => {
    render(<ProviderSetup />);
    await selectOpenRouter();

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'sk-test-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    const status = await screen.findByText('statusValidatingAndSyncing');
    const providerSelection = await screen.findByTestId('provider-grid-openRouter');

    expect(
      Boolean(status.compareDocumentPosition(providerSelection) & Node.DOCUMENT_POSITION_FOLLOWING),
    ).toBe(true);
  });

  it('creates a second official provider instance with an auto suffix instead of reusing the existing kind', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [mockModel],
      defaultModelId: mockModel.id,
      catalogModels: [],
    });
    mockStore.providers = [{
      id: 'existing-openrouter',
      kind: 'openRouter',
      status: { kind: 'connected' },
      models: [mockModel],
      catalogModels: [],
      apiKey: 'sk-old',
      apiKeyPreview: 'preview-old',
    }];

    render(<ProviderSetup />);
    await selectOpenRouter();

    // openRouter is already connected, so the already-connected guard appears first; choosing
    // 'add another account' reveals the key field.
    fireEvent.click(await screen.findByRole('button', { name: 'addAnotherAccount' }));

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'sk-second-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
    // A second instance gets a random id (createCanonicalUUID) rather than a deterministic one.
    expect(mockCreateCanonicalUUID).toHaveBeenCalledTimes(1);
    expect(mockCreateDeterministicProviderId).not.toHaveBeenCalled();
    expect(mockProviderOpsAdd).toHaveBeenCalledWith(mockStore, expect.objectContaining({
      id: 'provider-uuid',
      kind: 'openRouter',
      customName: 'OpenRouter 2',
      apiKey: 'sk-second-key',
    }));
    expect(mockBuildOfficialEnabledModels).toHaveBeenCalledWith(
      'openRouter',
      expect.anything(),
      {},
      expect.anything(),
    );
  });

  it('routes to /providers when a provider already exists', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [mockModel],
      defaultModelId: mockModel.id,
      catalogModels: [],
    });
    mockStore.providers = [{
      id: 'existing',
      kind: 'openAI',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [],
      apiKey: 'sk',
      apiKeyPreview: 'sk-',
    }];

    render(<ProviderSetup />);
    await selectOpenRouter();

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'sk-test-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
    expect(mockSetHasCompletedOnboarding).toHaveBeenCalledWith(true);
    await waitFor(() => {
      expect(routerPush).toHaveBeenCalledWith('/providers');
    });
  });

  it('Setup path: official provider uses metadata-only (buildOfficialEnabledModels)', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [mockModel],
      defaultModelId: mockModel.id,
      catalogModels: [],
    });

    render(<ProviderSetup />);
    await selectOpenRouter();

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'sk-test-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
    // buildOfficialEnabledModels must be called.
    expect(mockBuildOfficialEnabledModels).toHaveBeenCalled();
    // catalogModels is empty on the added provider.
    expect(mockProviderOpsAdd).toHaveBeenCalledWith(
      mockStore,
      expect.objectContaining({ catalogModels: [] }),
    );
  });

  it('Setup path: empty metadata catalog surfaces emptyModelCatalog error', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [],
      defaultModelId: '',
      catalogModels: [],
    });

    render(<ProviderSetup />);
    await selectOpenRouter();

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'sk-test-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    expect(await screen.findByText('emptyModelCatalog.title')).toBeTruthy();
    expect(mockProviderOpsAdd).not.toHaveBeenCalled();
  });

  it('shows a dismissible top error banner when connect fails', async () => {
    mockBuildOfficialEnabledModels.mockReturnValue({
      models: [],
      defaultModelId: '',
      catalogModels: [],
    });

    render(<ProviderSetup />);
    await selectOpenRouter();

    fireEvent.change(await screen.findByPlaceholderText('sk-or-...'), {
      target: { value: 'bad-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSync' }));

    expect(await screen.findByTestId('provider-setup-error-banner')).toBeTruthy();
    expect(screen.getByText('emptyModelCatalog.title')).toBeTruthy();
    expect(mockProviderOpsAdd).not.toHaveBeenCalled();
    expect(routerPush).not.toHaveBeenCalledWith('/chat');

    fireEvent.click(screen.getByTestId('provider-setup-error-dismiss'));

    await waitFor(() => {
      expect(screen.queryByTestId('provider-setup-error-banner')).toBeNull();
    });
  });
  describe('Grok subscription sign-in entry', () => {
    const AVAILABLE_CONFIG = {
      state: 'available' as const,
      config: {
        clientId: 'client',
        scopes: 'openid',
        deviceAuthorizationEndpoint: 'https://auth.x.ai/oauth2/device/code',
        tokenEndpoint: 'https://auth.x.ai/oauth2/token',
        trustedVerificationHosts: ['accounts.x.ai'],
        resourceBaseURL: 'https://cli-chat-proxy.grok.com/v1',
        requiredHeaders: {},
        modelsPath: '/models',
        chatPath: '/chat/completions',
        modelsURL: 'https://cli-chat-proxy.grok.com/v1/models',
        chatURL: 'https://cli-chat-proxy.grok.com/v1/chat/completions',
        pollIntervalSeconds: 5,
        pollTimeoutSeconds: 1800,
      },
    };

    async function selectGrok() {
      fireEvent.click(await screen.findByTestId('provider-grid-grok'));
    }

    it('leaves the Grok add flow unchanged when the backend sends no subscription section', async () => {
      render(<ProviderSetup />);
      await selectGrok();
      expect(screen.queryByTestId('grok-mode-subscription')).toBeNull();
    });

    it('hides the new entry when the kill switch is off', async () => {
      mockGetGrokSubscriptionAvailability.mockReturnValue({ state: 'disabled', notice: 'paused' });
      render(<ProviderSetup />);
      await selectGrok();
      expect(screen.queryByTestId('grok-mode-subscription')).toBeNull();
    });

    it('offers the two-way choice when available, and only for Grok', async () => {
      mockGetGrokSubscriptionAvailability.mockReturnValue(AVAILABLE_CONFIG);
      render(<ProviderSetup />);
      await selectOpenRouter();
      expect(screen.queryByTestId('grok-mode-subscription')).toBeNull();
      await selectGrok();
      expect(await screen.findByTestId('grok-mode-subscription')).toBeTruthy();
      expect(screen.getByTestId('grok-mode-api-key').getAttribute('aria-checked')).toBe('true');
    });

    it('hides the key field and the bottom CTA once subscription is chosen, showing the x.ai sign-in entry instead', async () => {
      mockGetGrokSubscriptionAvailability.mockReturnValue(AVAILABLE_CONFIG);
      render(<ProviderSetup />);
      await selectGrok();
      fireEvent.click(await screen.findByTestId('grok-mode-subscription'));

      expect(await screen.findByTestId('grok-subscription-connect')).toBeTruthy();
      expect(screen.queryByPlaceholderText('xai-...')).toBeNull();
      expect(screen.queryByRole('button', { name: 'connectAndSync' })).toBeNull();
    });

    it('stores a subscription instance after a successful grant: live catalog, always-empty apiKey, credentials only in local fields', async () => {
      mockGetGrokSubscriptionAvailability.mockReturnValue(AVAILABLE_CONFIG);
      render(<ProviderSetup />);
      await selectGrok();
      fireEvent.click(await screen.findByTestId('grok-mode-subscription'));
      fireEvent.click(await screen.findByTestId('grok-subscription-connect'));
      fireEvent.click(await screen.findByTestId('grok-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      expect(provider.kind).toBe('grok');
      expect(provider.authMode).toBe('subscription');
      expect(provider.apiKey).toBe('');
      expect(provider.grokSubscription?.accessToken).toBe('access-token');
      // The catalog must be fetched live through the subscription path, not taken from the
      // metadata-only official catalog.
      expect(mockFetchGrokSubscriptionModels).toHaveBeenCalledWith('access-token');
      expect(provider.models.map((model) => model.id)).toEqual(['grok-4.6', 'grok-4.5']);
      expect(mockBuildOfficialEnabledModels).not.toHaveBeenCalled();
    });

    it('leaves no dead official catalog when the catalog cannot be fetched: clears it and writes an explicit reason', async () => {
      mockGetGrokSubscriptionAvailability.mockReturnValue(AVAILABLE_CONFIG);
      mockFetchGrokSubscriptionModels.mockResolvedValue({ ok: false, error: 'catalogUnavailable' });
      render(<ProviderSetup />);
      await selectGrok();
      fireEvent.click(await screen.findByTestId('grok-mode-subscription'));
      fireEvent.click(await screen.findByTestId('grok-subscription-connect'));
      fireEvent.click(await screen.findByTestId('grok-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      expect(provider.models).toEqual([]);
      expect(provider.lastError).toContain('Grok subscription model list');
    });
  });

  describe('Codex (ChatGPT subscription sign-in) entry', () => {
    const AVAILABLE_CODEX_CONFIG = {
      state: 'available' as const,
      config: {
        clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
        deviceAuthorizationEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/usercode',
        deviceTokenEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/token',
        tokenEndpoint: 'https://auth.openai.com/oauth/token',
        verificationURL: 'https://auth.openai.com/codex/device',
        redirectURI: 'https://auth.openai.com/deviceauth/callback',
        trustedVerificationHosts: ['auth.openai.com'],
        resourceBaseURL: 'https://chatgpt.com/backend-api/codex',
        requiredHeaders: { originator: 'oriveo', version: '0.148.0' },
        modelsPath: '/models',
        chatPath: '/responses',
        modelsURL: 'https://chatgpt.com/backend-api/codex/models',
        responsesURL: 'https://chatgpt.com/backend-api/codex/responses',
        pollIntervalSeconds: 5,
        pollTimeoutSeconds: 900,
      },
    };

    async function selectOpenAI() {
      fireEvent.click(await screen.findByTestId('provider-grid-openAI'));
    }

    it('leaves the OpenAI add flow unchanged when the backend sends no subscription section', async () => {
      render(<ProviderSetup />);
      await selectOpenAI();
      expect(screen.queryByTestId('openai-mode-subscription')).toBeNull();
    });

    it('hides the new entry when the kill switch is off', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue({ state: 'disabled', notice: 'paused' });
      render(<ProviderSetup />);
      await selectOpenAI();
      expect(screen.queryByTestId('openai-mode-subscription')).toBeNull();
    });

    it('offers the two-way choice when available, and only for OpenAI', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      render(<ProviderSetup />);
      await selectOpenRouter();
      expect(screen.queryByTestId('openai-mode-subscription')).toBeNull();
      await selectOpenAI();
      expect(await screen.findByTestId('openai-mode-subscription')).toBeTruthy();
      expect(screen.getByTestId('openai-mode-api-key').getAttribute('aria-checked')).toBe('true');
    });

    it('keeps the two paths independent: the Grok availability state does not affect the OpenAI entry', async () => {
      // With a single availability predicate, turning Grok off would close the Codex entry too.
      mockGetGrokSubscriptionAvailability.mockReturnValue({ state: 'disabled', notice: 'grok paused' });
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      render(<ProviderSetup />);
      await selectOpenAI();
      expect(await screen.findByTestId('openai-mode-subscription')).toBeTruthy();
    });

    it('hides the key field and the bottom CTA once subscription is chosen, showing the ChatGPT sign-in entry instead', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      render(<ProviderSetup />);
      await selectOpenAI();
      fireEvent.click(await screen.findByTestId('openai-mode-subscription'));

      expect(await screen.findByTestId('openai-subscription-connect')).toBeTruthy();
      expect(screen.queryByRole('button', { name: 'connectAndSync' })).toBeNull();
    });

    it('stores a subscription instance after a successful grant: live catalog, always-empty apiKey, credentials only in local fields', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      render(<ProviderSetup />);
      await selectOpenAI();
      fireEvent.click(await screen.findByTestId('openai-mode-subscription'));
      fireEvent.click(await screen.findByTestId('openai-subscription-connect'));
      fireEvent.click(await screen.findByTestId('openai-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      expect(provider.kind).toBe('openAI');
      expect(provider.authMode).toBe('subscription');
      expect(provider.apiKey).toBe('');
      expect(provider.openAISubscription?.accessToken).toBe('codex-access-token');
      expect(provider.openAISubscription?.accountID).toBe('codex-account-id');
      // Credentials must land in their own field: sharing one field with Grok would write the
      // wrong path's token on renewal.
      expect(provider.grokSubscription).toBeUndefined();
      // The catalog must be fetched live through the subscription path, carrying the parsed accountID.
      expect(mockFetchOpenAISubscriptionModels)
        .toHaveBeenCalledWith('codex-access-token', 'codex-account-id');
      expect(provider.models.map((model) => model.id)).toEqual(['gpt-5.6-sol', 'gpt-5.5']);
      expect(mockBuildOfficialEnabledModels).not.toHaveBeenCalled();
    });

    it('copies capabilities from the upstream declaration: a capability bit exists only when the upstream declares it', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      render(<ProviderSetup />);
      await selectOpenAI();
      fireEvent.click(await screen.findByTestId('openai-mode-subscription'));
      fireEvent.click(await screen.findByTestId('openai-subscription-connect'));
      fireEvent.click(await screen.findByTestId('openai-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      const [sol, mini] = provider.models;
      expect(sol?.capabilities).toEqual(['text', 'web', 'reasoning', 'image']);
      expect(sol?.upstreamReasoningLevels).toEqual(['low', 'medium', 'high']);
      // An empty array from the upstream means unsupported; no capability may be guessed from a slug.
      expect(mini?.capabilities).toEqual(['text']);
      expect(mini?.reasoningModeAvailable).toBe(false);
      expect(mini?.upstreamReasoningLevels).toBeUndefined();
    });

    it('leaves no dead official catalog when the catalog cannot be fetched: clears it and writes the Codex reason', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      mockFetchOpenAISubscriptionModels.mockResolvedValue({ ok: false, error: 'catalogUnavailable' });
      render(<ProviderSetup />);
      await selectOpenAI();
      fireEvent.click(await screen.findByTestId('openai-mode-subscription'));
      fireEvent.click(await screen.findByTestId('openai-subscription-connect'));
      fireEvent.click(await screen.findByTestId('openai-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      expect(provider.models).toEqual([]);
      expect(provider.lastError).toContain('Codex model list');
    });

    // Regression: writing connected here means the recovery card, which only shows for issue or
    // needsKey, never appears, and the user gets a 'connected' instance with zero models and no
    // reason at all. A successful grant does not imply the catalog backend is reachable, and that
    // real reason needs somewhere to land; the predicate is the same one the resync path uses.
    it('sets status to issue when the catalog cannot be fetched, so the reason has somewhere to show', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      mockFetchOpenAISubscriptionModels.mockResolvedValue({ ok: false, error: 'catalogUnavailable' });
      render(<ProviderSetup />);
      await selectOpenAI();
      fireEvent.click(await screen.findByTestId('openai-mode-subscription'));
      fireEvent.click(await screen.findByTestId('openai-subscription-connect'));
      fireEvent.click(await screen.findByTestId('openai-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      expect(provider.status.kind).toBe('issue');
      // When the catalog cannot be fetched at all (as opposed to being filtered empty), the
      // 'refresh the connection' reason still applies, because a retry does help in that case.
      expect(provider.status.kind === 'issue' && provider.status.message).toContain('Codex model list');
    });

    it('stays connected when the catalog is fine, without reporting a false failure', async () => {
      mockGetOpenAISubscriptionAvailability.mockReturnValue(AVAILABLE_CODEX_CONFIG);
      mockFetchOpenAISubscriptionModels.mockResolvedValue({
        ok: true,
        value: [{ slug: 'gpt-5.6-sol', supportsWebSearch: true, supportedReasoningLevels: [], supportsImageInput: false }],
      });
      render(<ProviderSetup />);
      await selectOpenAI();
      fireEvent.click(await screen.findByTestId('openai-mode-subscription'));
      fireEvent.click(await screen.findByTestId('openai-subscription-connect'));
      fireEvent.click(await screen.findByTestId('openai-subscription-dialog-authorize'));

      await waitFor(() => expect(mockProviderOpsAdd).toHaveBeenCalled());
      const provider = mockProviderOpsAdd.mock.calls[0][1] as Provider;
      expect(provider.status.kind).toBe('connected');
      expect(provider.lastError).toBeUndefined();
      expect(provider.models.length).toBeGreaterThan(0);
    });
  });
});

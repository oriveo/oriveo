import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { ProviderList } from './ProviderList';

const routerPush = vi.fn();
const getProviderBalanceCachedMock = vi.fn();
const getAllConversationsMock = vi.fn();

type MockState = {
  providers: Provider[];
  conversations: Array<{ providerID: string; isDraft: boolean; updatedAt: string; messages: Array<Record<string, unknown>> }>;
  hydrationPhase: 'ready' | 'loading';
};

let mockState: MockState;

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
}));

vi.mock('../../components/providers/ProvidersClusterHeader', () => ({
  ProvidersClusterHeader: () => <div data-testid="providers-cluster-header" />,
}));

vi.mock('../../components/providers/ProviderListCard', () => ({
  ProviderListCard: ({ provider, providerBalance, onClick }: {
    provider: Provider;
    providerBalance?: { total: number } | null;
    onClick: () => void;
  }) => (
    <button
      data-testid={`provider-card-${provider.id}`}
      data-provider-balance={providerBalance?.total ?? ''}
      onClick={onClick}
    >
      {provider.id}
    </button>
  ),
}));

vi.mock('../../components/providers/ProviderHeroCard', () => ({
  ProviderHeroCard: ({ provider, onClick }: { provider: Provider; onClick: () => void }) => (
    <button data-testid={`provider-hero-${provider.id}`} onClick={onClick}>
      hero
    </button>
  ),
}));

vi.mock('../../components/providers/ProviderCostSummaryCard', () => ({
  ProviderCostSummaryCard: ({
    summary,
  }: { summary: { totalCost: number; source: string } }) => (
    <div
      data-testid="cost-card"
      data-total={summary.totalCost}
      data-source={summary.source}
    >
      cost card
    </div>
  ),
}));

vi.mock('../../lib/infra/storage/idb', () => ({
  getAllConversations: () => getAllConversationsMock(),
}));

vi.mock('../../lib/core/providers/balance', async () => {
  const actual = await vi.importActual<typeof import('../../lib/core/providers/balance')>(
    '../../lib/core/providers/balance',
  );
  return {
    ...actual,
    getProviderBalanceCached: (...args: unknown[]) => getProviderBalanceCachedMock(...args),
  };
});

vi.mock('../../lib/core/store/selectors', () => ({
  selectResolvedCatalog: () => ({ availableModelCount: 5 }),
}));

vi.mock('../../lib/core/metadata/metadata-client', () => ({
  onVersionChange: () => () => {},
}));

const baseProvider: Provider = {
  id: 'provider-1',
  kind: 'openAI',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: 'sk-test',
  apiKeyPreview: 'sk-t',
  baseURLText: 'https://api.example.com/v1',
};

const now = new Date().toISOString();

function buildConversation(providerId: string) {
  return {
    providerID: providerId,
    isDraft: false,
    updatedAt: now,
    messages: [
      {
        role: 'assistant',
        state: 'delivered',
        providerKind: 'openAI',
        estimatedCost: 1,
        createdAt: now,
      },
    ],
  };
}

async function flushProviderListMountEffects() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe('ProviderList', () => {
  beforeEach(() => {
    routerPush.mockReset();
    mockState = {
      providers: [baseProvider],
      conversations: [buildConversation(baseProvider.id)],
      hydrationPhase: 'ready',
    };
    getProviderBalanceCachedMock.mockReset();
    getAllConversationsMock.mockReset();
    getAllConversationsMock.mockResolvedValue([]);
  });

  it('renders provider list and routes to add/new cards', async () => {
    render(<ProviderList />);
    await flushProviderListMountEffects();

    fireEvent.click(screen.getByRole('button', { name: 'addProvider' }));
    expect(routerPush).toHaveBeenCalledWith('/providers/new');

    fireEvent.click(screen.getByTestId(`provider-card-${baseProvider.id}`));
    expect(routerPush).toHaveBeenCalledWith(`/providers/${baseProvider.id}`);
  });

  it('renders visual icons for the provider page section headers', async () => {
    render(<ProviderList />);
    await flushProviderListMountEffects();

    expect(
      screen.getByTestId('providers-section-active').querySelector('[data-section-icon="active"]'),
    ).toBeTruthy();
    expect(
      screen.getByTestId('providers-section-all').querySelector('[data-section-icon="all"]'),
    ).toBeTruthy();
    expect(
      screen.getByTestId('providers-section-costs').querySelector('[data-section-icon="costs"]'),
    ).toBeTruthy();
  });

  it('loads account balance for each balance-capable BYOK provider row', async () => {
    mockState.providers = [{
      ...baseProvider,
      id: 'deepseek-1',
      kind: 'deepseek',
      apiKey: 'sk-deepseek',
      apiKeyPreview: 'sk-d',
      baseURLText: 'https://api.deepseek.com/v1',
    }];
    getProviderBalanceCachedMock.mockResolvedValue({
      currency: 'USD',
      total: 1.85,
      fetchedAt: new Date(),
    });

    render(<ProviderList />);

    const row = screen.getByTestId('provider-card-deepseek-1');
    await waitFor(() => expect(row.getAttribute('data-provider-balance')).toBe('1.85'));
    expect(getProviderBalanceCachedMock).toHaveBeenCalledWith(
      'deepseek-1',
      'deepseek',
      'sk-deepseek',
      'https://api.deepseek.com/v1',
      false,
    );
  });

  it('shows cost card from IDB local fallback when remote usage fetch fails', async () => {
    mockState.conversations = [];
    const nowIso = new Date().toISOString();
    getAllConversationsMock.mockResolvedValue([
      {
        id: 'conv-with-cost',
        providerID: baseProvider.id,
        providerKind: 'openAI',
        title: 'has cost',
        previewText: 'preview',
        messages: [
          {
            id: 'm1',
            role: 'assistant',
            state: 'delivered',
            providerKind: 'openAI',
            providerID: baseProvider.id,
            estimatedCost: 0.42,
            createdAt: nowIso,
            text: '...',
          },
        ],
        isDraft: false,
        updatedAt: nowIso,
        createdAt: nowIso,
        remoteMessageCount: 1,
      },
    ]);

    render(<ProviderList />);

    await waitFor(() => {
      const card = screen.getByTestId('cost-card');
      expect(card.getAttribute('data-total')).toBe('0.42');
      expect(card.getAttribute('data-source')).toBe('local_device');
    });
  });
});

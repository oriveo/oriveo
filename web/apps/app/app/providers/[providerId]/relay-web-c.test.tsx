import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { IntlMessageFormat } from 'intl-messageformat';
import { fireEvent, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import { RelayDetail } from './RelayDetail';
import { relayDetailBoard, relayDetailRowIconColorToken } from './relay-detail-board';

/**
 * Generation-parameters entry: a connection-level Parameters row in the detail page's "Models" group,
 * opens a Dialog (Model selector on top + GenerationParameterPanel); enabled rows in the model library no longer have a tuning button.
 */

const mocks = vi.hoisted(() => ({ routerPush: vi.fn() }));

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: vi.fn() }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

vi.mock('../../../lib/hooks/useProviderActions', () => ({
  useProviderActions: () => ({
    isSyncing: false,
    catalogLoadState: 'loaded',
    relaySettingsSaveFailure: null,
    saveKey: vi.fn(),
    removeKey: vi.fn(),
    clearRelayCredentials: vi.fn(),
    reconnectRelaySecurityMode: vi.fn(),
    verifyRelayConnection: vi.fn(),
    saveBaseURL: vi.fn(),
    writeBackBaseURL: vi.fn(),
    saveName: vi.fn(),
    saveRelaySettings: vi.fn(),
    relaySettingsSavePlan: () => ({ needsVerification: false, needsCatalogRefresh: false }),
    saveRelaySettingsUnverified: vi.fn(),
    retryRelaySettingsSave: vi.fn(),
    clearRelaySettingsSaveFailure: vi.fn(),
    refreshRelayCatalog: vi.fn(),
    addModels: vi.fn(),
    toggleModel: vi.fn(),
    removeModel: vi.fn(),
    deleteProvider: vi.fn(),
  }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: Record<string, unknown>) => unknown) =>
    selector({ setLastUsedModelRef: vi.fn(), setActiveConversationId: vi.fn() }),
  getVanillaStore: () => ({ getState: () => ({ providers: [] }) }),
}));

vi.mock('../../../components/Toast', () => ({ showToast: vi.fn() }));

// The panel itself has its own tests; here only the provider + model it receives are checked (the scope is still the model_default of provider + model).
vi.mock('../../../components/generation/GenerationParameterPanel', () => ({
  GenerationParameterPanel: ({ provider, model }: { provider: Provider; model: AIModel }) => (
    <div data-testid="generation-panel" data-provider={provider.id} data-model={model.id} />
  ),
}));

function model(id: string): AIModel {
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

const KEY = 'sk-relay-secret-0123456789';

function relayProvider(models: AIModel[]): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: KEY,
    apiKeyPreview: formatApiKeyPreview(KEY),
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayRequested: {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      modelID: models[0]?.id ?? '',
      resolvedAPIBaseURL: 'https://api.myrelay.dev/v1',
    },
  };
}

const openParameters = () => {
  fireEvent.click(document.querySelector('[data-board-row="parameters"]') as HTMLElement);
  return screen.getByRole('dialog', { name: 'common.generationParameters' });
};

describe('generation-parameters entry = the Parameters row of the detail page Models group', () => {
  it('board: the Parameters row of the Models group comes after web search, title common.generationParameters, no subtitle / trailing value, rose color', () => {
    const rows = relayDetailBoard(relayProvider([model('a'), model('b')])).modelRows;
    expect(rows.map((row) => row.id)).toEqual(['modelLibrary', 'webSearch', 'parameters']);
    const parameters = rows.find((row) => row.id === 'parameters')!;
    expect(parameters).toEqual({ id: 'parameters', titleKey: 'common.generationParameters', action: 'openParameters' });
    expect(relayDetailRowIconColorToken('parameters')).toBe('--o-row-rose');
  });

  it('tapping Parameters opens the dialog: the Model selector defaults to the first enabled one, options = enabled models, the panel receives that model; switching model switches the panel', () => {
    render(<RelayDetail provider={relayProvider([model('gpt-5.4'), model('claude-sonnet-4.5')])} />);
    const dialog = openParameters();
    const select = within(dialog).getByRole('combobox', { name: 'pages.relaySetup.field.model' }) as HTMLSelectElement;
    expect([...select.options].map((option) => option.value)).toEqual(['gpt-5.4', 'claude-sonnet-4.5']);
    expect(select.value).toBe('gpt-5.4');
    const panel = () => within(dialog).getByTestId('generation-panel');
    expect(panel().getAttribute('data-provider')).toBe('relay-1');
    expect(panel().getAttribute('data-model')).toBe('gpt-5.4');

    fireEvent.change(select, { target: { value: 'claude-sonnet-4.5' } });
    expect(panel().getAttribute('data-model')).toBe('claude-sonnet-4.5');

    fireEvent.click(within(dialog).getByRole('button', { name: 'common.close' }));
    expect(screen.queryByRole('dialog', { name: 'common.generationParameters' })).toBeNull();
  });

  it('with only 1 enabled model the Model selector is not shown and the panel receives that model directly', () => {
    render(<RelayDetail provider={relayProvider([model('only-one')])} />);
    const dialog = openParameters();
    expect(within(dialog).queryByRole('combobox')).toBeNull();
    expect(within(dialog).getByTestId('generation-panel').getAttribute('data-model')).toBe('only-one');
  });

  it('enabled rows in the model library no longer have a tuning button and no longer expand a panel inline', () => {
    const { container } = render(<RelayDetail provider={relayProvider([model('a'), model('b')])} />);
    fireEvent.click(container.querySelector('[data-board-row="modelLibrary"]') as HTMLElement);
    const rows = [...container.querySelectorAll('[data-catalog-section="enabled"] [data-catalog-row]')];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      expect(within(row as HTMLElement).queryByRole('button', { name: 'generationParameters' })).toBeNull();
    }
    expect(screen.queryByTestId('generation-panel')).toBeNull();
  });

  it('the sample relayDetail page shows the Parameters row too', async () => {
    const fence = await import('../../dev/relay-shots/relay-shots-fence');
    const uninstall = fence.installRelayShotsFence();
    try {
      const data = await import('../../dev/relay-shots/relay-shots-data');
      // The shared sample manifest lives outside web/ (cwd is this app).
      const manifest = JSON.parse(readFileSync(join(process.cwd(), '../../../shared/test-fixtures/shots/relay.v1.json'), 'utf8'));
      const rows = relayDetailBoard(data.demoRelayProvider('relayDetail', manifest)).modelRows;
      expect(rows.map((row) => row.id)).toEqual(['modelLibrary', 'webSearch', 'parameters']);
    } finally {
      uninstall();
    }
  });
});

describe('model count plural (ru)', () => {
  it('ru pages.relayDetail.modelsCount renders from the actual messages/ru.json values: 1 / 2 / 5 = iOS one / few / many', () => {
    const ru = JSON.parse(readFileSync(join(process.cwd(), 'messages', 'ru.json'), 'utf8')) as {
      pages: { relayDetail: { modelsCount: string } };
    };
    const format = new IntlMessageFormat(ru.pages.relayDetail.modelsCount, 'ru');
    expect([1, 2, 5].map((count) => format.format({ count }))).toEqual(['1 модель', '2 модели', '5 моделей']);
  });
});

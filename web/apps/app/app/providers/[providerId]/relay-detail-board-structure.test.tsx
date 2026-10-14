import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, LocalEngineKind, Provider } from '@oriveo/shared';
import { formatApiKeyPreview, inferRelayKind } from '@oriveo/shared';
import { createAppStore } from '../../../lib/core/store/app-store';
import { RelayDetail } from './RelayDetail';
import { setProviderDetailNotice, takeProviderDetailNotice } from './provider-detail-notice';
import {
  RELAY_DETAIL_TEXT,
  relayDetailBoard,
  relayDetailKind,
  relayDetailRecoveryCard,
  relayDetailRowIconColorToken,
  type DetailRow,
  type DetailRowID,
} from './relay-detail-board';

/**
 * Detail page board structure snapshot: asserts the row order / keys / values produced by relayDetailBoard,
 * and the rows, buttons and the single entry point for actions rendered by the production RelayDetail component.
 */

/** Edit-save passes a patch evaluated against the live record: evaluate against the connection as of page open, then assert. */
function savedRelayPatch(live: Provider): Record<string, unknown> {
  const arg = mocks.saveRelaySettings.mock.calls[0]![0] as unknown;
  return (typeof arg === 'function' ? (arg as (provider: Provider) => Record<string, unknown>)(live) : arg) as Record<string, unknown>;
}

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  saveRelaySettings: vi.fn(),
  saveName: vi.fn(),
  saveKey: vi.fn(),
  removeKey: vi.fn(),
  deleteProvider: vi.fn(),
  showToast: vi.fn(),
  verifyRelayConnection: vi.fn(),
  store: null as unknown,
  isSyncing: false,
}));

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
    isSyncing: mocks.isSyncing,
    catalogLoadState: 'loaded',
    relaySettingsSaveFailure: null,
    saveKey: mocks.saveKey,
    removeKey: mocks.removeKey,
    clearRelayCredentials: vi.fn(),
    reconnectRelaySecurityMode: vi.fn(),
    verifyRelayConnection: mocks.verifyRelayConnection,
    saveBaseURL: vi.fn(),
    writeBackBaseURL: vi.fn(),
    saveName: mocks.saveName,
    saveRelaySettings: mocks.saveRelaySettings,
    relaySettingsSavePlan: () => ({ needsVerification: false, needsCatalogRefresh: false }),
    saveRelaySettingsUnverified: vi.fn(),
    retryRelaySettingsSave: vi.fn(),
    clearRelaySettingsSaveFailure: vi.fn(),
    refreshRelayCatalog: vi.fn(),
    addModels: vi.fn(),
    toggleModel: vi.fn(),
    removeModel: vi.fn(),
    deleteProvider: mocks.deleteProvider,
  }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: Record<string, unknown>) => unknown) =>
    selector({ setLastUsedModelRef: vi.fn(), setActiveConversationId: vi.fn() }),
  getVanillaStore: () => mocks.store ?? { getState: () => ({ providers: [] }) },
}));

vi.mock('../../../components/Toast', () => ({
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

/* ── Fixtures ── */

function readFixture<T>(...segments: string[]): T {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, ...segments);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    dir = path.dirname(dir);
  }
  throw new Error(`${segments.join('/')} not found`);
}

interface ThinkingCase {
  caseId: string;
  engineProfile: LocalEngineKind | null;
  channel: 'chat' | 'native';
  declaredThinking: boolean | null;
  expect: 'toggle' | 'nonChatNotice' | 'usesModelDefaultNotice' | 'unsupported';
}
const engineExpectations = readFixture<{ thinking: { cases: ThinkingCase[] } }>(
  'shared', 'test-fixtures', 'local-engine', 'engine-expectations.v1.json',
);

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...extra,
  };
}

const KEY = 'sk-relay-secret-0123456789';

function relayProvider(overrides: Partial<Provider> = {}): Provider {
  const enabled = [model('claude-sonnet-4.5', { isDefault: true }), model('gpt-5.4')];
  const others = Array.from({ length: 40 }, (_, index) => model(`catalog-${index}`));
  return {
    id: 'relay-1',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled, ...others],
    apiKey: KEY,
    apiKeyPreview: formatApiKeyPreview(KEY),
    baseURLText: 'https://api.myrelay.dev',
    lastCheckedAt: '2026-10-11T06:02:00.000Z',
    relayKind: 'openai_compatible',
    relayRequested: {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      modelID: 'claude-sonnet-4.5',
      resolvedAPIBaseURL: 'https://api.myrelay.dev/v1',
      resolvedAPIBaseURLs: {
        anthropic_messages: 'https://api.myrelay.dev/v1',
        gemini_generate_content: 'https://api.myrelay.dev/v1beta',
      },
    },
    ...overrides,
  };
}

function localProvider(
  engine: LocalEngineKind,
  channel: 'chat' | 'native' = 'chat',
  declaredThinking?: boolean,
): Provider {
  const declaration = declaredThinking === undefined ? undefined : { thinking: declaredThinking };
  const enabled = [model('qwen3-8b-q4', { isDefault: true, ...(declaration ? { engineDeclaration: declaration } : {}) })];
  return {
    id: 'local-1',
    kind: 'relay',
    customName: 'Mac mini',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled, model('llama-3-8b'), model('phi-4')],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: 'http://192.168.1.20:8080',
    relayKind: 'custom',
    relayRequested: {
      transport: channel === 'native' ? 'llamacpp_native' : 'openai_chat_completions',
      authMode: 'none',
      securityMode: 'local_http',
      engineProfile: engine,
      modelID: 'qwen3-8b-q4',
    },
  };
}

const ids = (rows: DetailRow[]) => rows.map((row) => row.id);
const rowIDsInDOM = (container: HTMLElement, section: string) =>
  [...container.querySelectorAll(`[data-board-section="${section}"] [data-board-row]`)]
    .map((element) => element.getAttribute('data-board-row'));

beforeEach(() => {
  mocks.routerPush.mockReset();
  mocks.saveRelaySettings.mockReset();
  mocks.saveRelaySettings.mockResolvedValue(true);
  mocks.saveName.mockReset();
  mocks.saveKey.mockReset();
  mocks.removeKey.mockReset();
  mocks.deleteProvider.mockReset();
  mocks.showToast.mockReset();
  mocks.verifyRelayConnection.mockReset();
  mocks.verifyRelayConnection.mockResolvedValue(undefined);
  takeProviderDetailNotice('relay-1');
  takeProviderDetailNotice('local-1');
  mocks.store = null;
  mocks.isSyncing = false;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('BOARD-DETAIL-01 relay connection card and model card', () => {
  it('BOARD-DETAIL-01 row order, values, bottom button keys (with root URL)', () => {
    const board = relayDetailBoard(relayProvider());

    expect(board.form).toBe('relay');
    // Header model count = enabled ∪ catalog, de-duplicated (2 + 40 = 42)
    expect(board.modelCount).toBe(42);
    expect(board.checkedAt).toBe('2026-10-11T06:02:00.000Z');
    expect(ids(board.connectionRows)).toEqual(['endpoint', 'apiKey', 'defaultProtocol', 'basePaths']);
    expect(board.connectionRows.map((row) => row.titleKey)).toEqual([
      RELAY_DETAIL_TEXT.endpoint,
      RELAY_DETAIL_TEXT.apiKey,
      'pages.relayDetail.defaultProtocolRow',
      'pages.relayDetail.basePaths',
    ]);
    const [endpoint, apiKey, protocol, basePaths] = board.connectionRows;
    expect(endpoint!.value).toEqual({ literal: 'https://api.myrelay.dev' });
    // The request URL row is tappable and opens Edit Connection (BOARD-DETAIL-14).
    expect(endpoint!.action).toBe('editConnection');
    expect(apiKey!.value).toEqual({ literal: formatApiKeyPreview(KEY) });
    expect(apiKey!.trailingKey).toBe(RELAY_DETAIL_TEXT.keysAddMoreHint);
    expect(apiKey!.action).toBe('openKeys');
    // Protocol proper names within the family (same as iOS).
    expect(protocol!.value).toEqual({ literal: 'OpenAI Chat Completions' });
    expect(protocol!.action).toBe('editConnection');
    expect(basePaths!.basePaths).toEqual([
      { protocol: 'Chat', path: '/v1' },
      { protocol: 'Messages', path: '/v1' },
      { protocol: 'Gemini', path: '/v1beta' },
    ]);

    // A relay has no default model: the default model row is removed.
    // The model card has an extra "Web Search" row below the model library row.
    expect(ids(board.modelRows)).toEqual(['modelLibrary', 'webSearch', 'parameters']);
    expect(board.modelRows[0]).toMatchObject({
      titleKey: RELAY_DETAIL_TEXT.modelLibrary,
      value: { key: 'pages.relayDetail.librarySummary', values: { enabled: 2, available: 40 } },
      action: 'openLibrary',
    });
    expect(board.detectButtonKey).toBe('pages.relayDetail.detectAgain');
    expect(board.deleteButtonKey).toBe('pages.relayDetail.deleteCustomRelay');
    // The footnote for a selected protocol only mentions refreshing the catalog (BOARD-DETAIL-13).
    expect(board.footnoteKey).toBe('pages.relayDetail.detectFootnoteSelected');
  });

  it('BOARD-DETAIL-01 root URL: the single-value root of an auto connection goes to Chat; the same-protocol table wins over the single-value root', () => {
    const auto = relayDetailBoard(relayProvider({
      relayRequested: { transport: 'auto', authMode: 'bearer', resolvedAPIBaseURL: 'https://api.myrelay.dev/v1' },
    }));
    expect(auto.connectionRows.find((row) => row.id === 'basePaths')?.basePaths).toEqual([
      { protocol: 'Chat', path: '/v1' },
    ]);
    const both = relayDetailBoard(relayProvider({
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        resolvedAPIBaseURL: 'https://api.myrelay.dev/legacy',
        resolvedAPIBaseURLs: { openai_chat_completions: 'https://api.myrelay.dev/v2' },
      },
    }));
    expect(both.connectionRows.find((row) => row.id === 'basePaths')?.basePaths).toEqual([
      { protocol: 'Chat', path: '/v2' },
    ]);
  });

  it('BOARD-DETAIL-01 the whole row is hidden when there is no root URL; auth required with no Key (S1) shows the tap-to-set prompt and is tappable', () => {
    const board = relayDetailBoard(relayProvider({
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    }));
    expect(ids(board.connectionRows)).toEqual(['endpoint', 'apiKey', 'defaultProtocol']);
    expect(board.connectionRows[1]!.value).toEqual({ key: 'pages.providerDetail.hero.tapToSet' });
    expect(board.connectionRows[1]!.trailingKey).toBeUndefined();
    expect(board.connectionRows[1]!.action).toBe('openKeys');
  });

  it('BOARD-DETAIL-01 production component renders per board: row order, status row, two bottom buttons and footnote', () => {
    const { container } = render(<RelayDetail provider={relayProvider()} />);

    expect(rowIDsInDOM(container, 'connection')).toEqual(['endpoint', 'apiKey', 'defaultProtocol', 'basePaths']);
    expect(rowIDsInDOM(container, 'models')).toEqual(['modelLibrary', 'webSearch', 'parameters']);
    expect(screen.getByText('pages.relayDetail.modelsCount({"count":42})')).toBeTruthy();
    expect(screen.getByText(/pages\.relayDetail\.checkedAt/)).toBeTruthy();
    // Does not say connected / online
    expect(screen.queryByText('connected')).toBeNull();
    expect(screen.getByRole('button', { name: 'pages.relayDetail.detectAgain' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeTruthy();
    expect(screen.getByText('pages.relayDetail.detectFootnoteSelected')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'editConnection' })).toBeTruthy();
    expect(container.innerHTML).not.toContain(KEY);
  });

  it('BOARD-DETAIL-01 status row shows only the model count when there is no detection time', () => {
    render(<RelayDetail provider={relayProvider({ lastCheckedAt: undefined })} />);
    expect(screen.queryByText(/pages\.relayDetail\.checkedAt/)).toBeNull();
  });
});

describe('BOARD-DETAIL-02 local connection card and model card', () => {
  it('BOARD-DETAIL-02 row order + N17; the llama.cpp channel row opens Edit Connection, the rest have no chevron', () => {
    const board = relayDetailBoard(localProvider('llamacpp'));

    expect(board.form).toBe('local');
    expect(ids(board.connectionRows)).toEqual(['engineAddress', 'engine', 'channel', 'apiKey']);
    expect(board.connectionRows.map((row) => row.titleKey)).toEqual([
      'pages.relayDetail.engineAddress',
      'pages.relayDetail.engineDetected',
      'pages.relayDetail.channelRow',
      RELAY_DETAIL_TEXT.apiKey,
    ]);
    expect(board.connectionRows[0]!.value).toEqual({ literal: 'http://192.168.1.20:8080' });
    expect(board.connectionRows[1]!.value).toEqual({ literal: 'llama.cpp' });
    expect(board.connectionRows[2]!.action).toBe('editConnection');
    // S0 (no auth required and no Key stored): N7, not tappable.
    expect(board.connectionRows[3]).toMatchObject({ value: { key: 'pages.relayDetail.noKey' }, action: null });
    // Local HTTPS connection with a stored Key (bearer, credentials required): mask + "can add multiple" hint, tappable to change the Key
    const base = localProvider('llamacpp');
    const keyed = relayDetailBoard({
      ...base,
      apiKey: KEY,
      apiKeyPreview: formatApiKeyPreview(KEY),
      relayRequested: { ...base.relayRequested!, authMode: 'bearer', securityMode: 'remote_https' },
    });
    expect(keyed.connectionRows[3]).toMatchObject({
      value: { literal: formatApiKeyPreview(KEY) },
      trailingKey: RELAY_DETAIL_TEXT.keysAddMoreHint,
      action: 'openKeys',
    });
    // Tappable iff credentials are required || a Key is stored: S3 (plaintext connection carrying a Key) is tappable; the change-Key dialog offers remove / replace
    const conflict = relayDetailBoard({
      ...relayProvider(),
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', securityMode: 'local_http' },
    });
    expect(conflict.connectionRows[1]!.action).toBe('openKeys');
    // No auth required but a Key is stored: tappable
    const noAuthWithKey = relayDetailBoard({
      ...relayProvider(),
      relayRequested: { transport: 'openai_chat_completions', authMode: 'none' },
      relayResolvedAuthMode: 'none',
    });
    expect(noAuthWithKey.connectionRows[1]).toMatchObject({ action: 'openKeys', value: { literal: formatApiKeyPreview(KEY) } });
    // No auth required: no trailing hint on the row
    expect(noAuthWithKey.connectionRows[1]!.trailingKey).toBeUndefined();

    expect(ids(board.modelRows)).toEqual(['modelLibrary', 'thinking', 'parameters']);
    expect(board.modelRows[0]!.value).toEqual({
      key: 'pages.relayDetail.librarySummaryLocal',
      values: { enabled: 1, available: 2 },
    });
    expect(board.modelRows[1]).toMatchObject({
      titleKey: RELAY_DETAIL_TEXT.thinking,
      trailingKey: 'pages.relayDetail.readOnly',
      action: null,
    });
    expect(board.deleteButtonKey).toBe('pages.relayDetail.deleteConnection');

    const ollama = relayDetailBoard(localProvider('ollama'));
    expect(ollama.connectionRows[1]!.value).toEqual({ literal: 'Ollama' });
    expect(ollama.connectionRows[2]!.action).toBeNull();
  });

  it('BOARD-DETAIL-02 production component renders local row order and the delete-connection button', () => {
    const { container } = render(<RelayDetail provider={localProvider('llamacpp')} />);

    expect(rowIDsInDOM(container, 'connection')).toEqual(['engineAddress', 'engine', 'channel', 'apiKey']);
    expect(rowIDsInDOM(container, 'models')).toEqual(['modelLibrary', 'thinking', 'parameters']);
    expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteConnection' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeNull();
    expect(screen.getByText('pages.relayDetail.readOnly')).toBeTruthy();
    expect(screen.getByText('pages.relayDetail.noKey')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'apiKey' })).toBeNull();
  });
});

describe('BOARD-DETAIL-03 local thinking row, three copy variants (engine-expectations.v1.json)', () => {
  const EXPECTED_KEY: Record<ThinkingCase['expect'], string> = {
    toggle: 'pages.relayDetail.thinkingTemplate',
    nonChatNotice: 'pages.relayDetail.thinkingModel',
    usesModelDefaultNotice: 'pages.relayDetail.thinkingModel',
    unsupported: 'pages.relayDetail.thinkingUnsupportedModel',
  };
  const cases = engineExpectations.thinking.cases.filter((item) => item.engineProfile !== null);

  it('BOARD-DETAIL-03 fixtures cover the three copy variants', () => {
    expect(new Set(cases.map((item) => EXPECTED_KEY[item.expect])).size).toBe(3);
  });

  it.each(cases.map((item) => [item.caseId, item] as const))('BOARD-DETAIL-03 %s', (_caseId, item) => {
    const board = relayDetailBoard(localProvider(
      item.engineProfile!,
      item.channel,
      item.declaredThinking ?? undefined,
    ));
    const thinking = board.modelRows.find((row) => row.id === 'thinking');
    // Display name of the fallback model (lastUsed -> first enabled) for the unsupported placeholder; no longer writes "default model".
    expect(thinking?.value).toEqual(item.expect === 'unsupported'
      ? { key: EXPECTED_KEY[item.expect], values: { model: 'qwen3-8b-q4' } }
      : { key: EXPECTED_KEY[item.expect] });
  });

  it('BOARD-DETAIL-03 unsupported placeholder follows the display name of the lastUsed fallback model', () => {
    const base = localProvider('ollama', 'chat', false);
    const provider: Provider = {
      ...base,
      models: [...base.models, model('phi-4', { name: 'Phi 4', engineDeclaration: { thinking: false } })],
    };
    const board = relayDetailBoard(provider, { providerID: provider.id, modelID: 'phi-4' });
    expect(board.modelRows.find((row) => row.id === 'thinking')?.value).toEqual({
      key: 'pages.relayDetail.thinkingUnsupportedModel',
      values: { model: 'Phi 4' },
    });
  });

  it('BOARD-DETAIL-03 relay has no thinking row', () => {
    expect(relayDetailBoard(relayProvider()).modelRows.some((row) => row.id === 'thinking')).toBe(false);
  });
});

describe('BOARD-DETAIL-04 single entry point for actions', () => {
  it('BOARD-DETAIL-04 detail page has rename / change Key / delete (default model is gone), and none of edit connection', () => {
    render(<RelayDetail provider={relayProvider()} />);

    expect(screen.getByRole('button', { name: 'editName' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'editKey' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
    expect(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeTruthy();
    // The old full-page settings area no longer appears on the detail page
    expect(screen.queryByLabelText('relayType')).toBeNull();
    expect(screen.queryByRole('button', { name: 'saveRelaySettings' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));

    expect(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'common.save' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'editName' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'editKey' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'apiKey' })).toBeNull();
    expect(screen.queryByLabelText('defaultModelLabel')).toBeNull();
    expect(screen.queryByRole('button', { name: /pages\.relaySetup\.field\.defaultModel/ })).toBeNull();
    expect(screen.queryByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'deleteRelay' })).toBeNull();
  });

  it('BOARD-DETAIL-04 rename, change Key and delete go through the existing domain actions', () => {
    render(<RelayDetail provider={relayProvider()} />);

    fireEvent.click(screen.getByRole('button', { name: 'editName' }));
    fireEvent.change(screen.getByDisplayValue('myrelay.dev'), { target: { value: 'Work' } });
    fireEvent.click(screen.getByRole('button', { name: 'saveName' }));
    expect(mocks.saveName).toHaveBeenCalledWith('Work');

    // The keys row opens the keys page; the implicit single-key "replace key" still uses the existing change-Key dialog.
    fireEvent.click(screen.getByRole('button', { name: 'editKey' }));
    expect(mocks.routerPush).toHaveBeenCalledWith(expect.stringMatching(/\?view=keys$/));
    fireEvent.click(screen.getByRole('button', { name: formatApiKeyPreview(KEY) }));
    fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.keyReplace$/ }));
    const dialog = screen.getByRole('dialog');
    const input = within(dialog).getByLabelText('apiKey') as HTMLInputElement;
    expect(input.getAttribute('data-secret-visibility')).toBe('masked');
    expect(input.value).toBe('');
    fireEvent.click(within(dialog).getByRole('button', { name: 'common.close' }));
    expect(screen.queryByRole('dialog')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'back' }));

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' }));
    fireEvent.click(screen.getByRole('button', { name: 'delete' }));
    expect(mocks.deleteProvider).toHaveBeenCalledTimes(1);
  });

  it('BOARD-DETAIL-04 saving Edit Connection carries neither relayRequested.modelID nor models (writes stopped)', async () => {
    const provider = relayProvider({
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', modelID: 'gpt-5.4' },
    });
    render(<RelayDetail provider={provider} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));
    fireEvent.click(screen.getByRole('button', { name: 'common.save' }));
    await waitFor(() => expect(mocks.saveRelaySettings).toHaveBeenCalledTimes(1));
    const editPatch = savedRelayPatch(provider) as { relayRequested: { modelID?: string }; models?: unknown };
    expect(editPatch.relayRequested.modelID).toBeUndefined();
    expect(editPatch.models).toBeUndefined();
  });

  it('BOARD-DETAIL-04 no auth required but a Key is stored: the remove-stored-Key action stays under the keys row', () => {
    render(<RelayDetail provider={relayProvider({
      relayRequested: { transport: 'openai_chat_completions', authMode: 'none' },
      relayResolvedAuthMode: 'none',
    })} />);

    fireEvent.click(screen.getByRole('button', { name: 'removeKey' }));
    expect(mocks.removeKey).toHaveBeenCalledTimes(1);
  });

  it('BOARD-DETAIL-04 the model library row opens a sub-page holding the enabled models and the model library', () => {
    render(<RelayDetail provider={relayProvider()} />);

    expect(screen.queryByRole('button', { name: 'common.advancedMore' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.modelLibrary/ }));
    // Removal moves into the "⋯" of the enabled row (BOARD-CATALOG-15): one per enabled model.
    expect(screen.getAllByRole('button', { name: 'common.advancedMore' })).toHaveLength(2);
    expect(screen.getByText('pages.relayDetail.catalogSectionLibrary({"count":40})')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'pages.relayDetail.deleteCustomRelay' })).toBeNull();
  });
});

describe('BOARD-DETAIL-05 re-detect button', () => {
  function catalogResponse() {
    return new Response(JSON.stringify({ object: 'list', data: [{ id: 'fresh-model', object: 'model' }] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  function seedStore(provider: Provider) {
    const store = createAppStore();
    store.getState().addProvider(provider);
    mocks.store = store;
    return store;
  }

  it('BOARD-DETAIL-05 tapping calls production redetectRelayModels, is disabled while in progress, and writes the detection time on success', async () => {
    const provider = relayProvider({ models: [], catalogModels: [], lastCheckedAt: undefined });
    const store = seedStore(provider);
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => {
      await gate;
      return catalogResponse();
    });
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.detectAgain' }));

    const running = await screen.findByRole('button', { name: 'pages.relaySetup.detecting' });
    expect((running as HTMLButtonElement).disabled).toBe(true);
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    await act(async () => { release(); });
    await screen.findByRole('button', { name: 'pages.relayDetail.detectAgain' });
    const saved = store.getState().providers.find((item) => item.id === provider.id)!;
    expect(saved.catalogModels.map((item) => item.id)).toEqual(['fresh-model']);
    expect(saved.lastCheckedAt).toBeTruthy();
    expect(mocks.showToast).not.toHaveBeenCalled();
  });

  it('BOARD-DETAIL-05 a skipped catalog refresh (protocol does not fetch a catalog) does not write the detection time', async () => {
    const provider = relayProvider({
      models: [],
      catalogModels: [],
      lastCheckedAt: undefined,
      // All four cloud protocols refresh the catalog; only llamacpp_native is skipped.
      relayRequested: { transport: 'llamacpp_native', authMode: 'none' },
    });
    const store = seedStore(provider);
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(catalogResponse());
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.detectAgain' }));
    await screen.findByRole('button', { name: 'pages.relaySetup.detecting' });
    await screen.findByRole('button', { name: 'pages.relayDetail.detectAgain' });

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(store.getState().providers[0]!.lastCheckedAt).toBeUndefined();
    expect(mocks.showToast).not.toHaveBeenCalled();
  });

  it('BOARD-DETAIL-05 a failed catalog refresh does not write the detection time and uses the existing error presentation', async () => {
    const provider = relayProvider({ models: [], catalogModels: [], lastCheckedAt: undefined });
    const store = seedStore(provider);
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{"error":"boom"}', { status: 500 }));
    render(<RelayDetail provider={provider} />);

    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.detectAgain' }));

    await waitFor(() => expect(mocks.showToast).toHaveBeenCalled());
    expect(mocks.showToast.mock.calls[0]![0]).toBe('catalogFetchFailed');
    expect(store.getState().providers[0]!.lastCheckedAt).toBeUndefined();
  });
});

describe('BOARD-DETAIL-06 auto connection', () => {
  const autoProvider = relayProvider({
    relayKind: 'openai_compatible',
    relayRequested: { transport: 'auto', authMode: 'auto' },
  });

  it('BOARD-DETAIL-06 inferRelayKind(auto) = Custom, read-time kind Custom (not written back), N2 value Auto', () => {
    expect(inferRelayKind({ transport: 'auto', authMode: 'auto' })).toBe('custom');
    expect(relayDetailKind(autoProvider)).toBe('custom');
    // How the add page stores it: taken from the connection protocol, auto -> custom
    expect(relayDetailKind({ relayKind: 'openai_compatible', relayRequested: { transport: 'auto', authMode: 'bearer' } }))
      .toBe('custom');
    expect(relayDetailKind({ relayKind: 'anthropic_compatible', relayRequested: { transport: 'anthropic_messages', authMode: 'x_api_key' } }))
      .toBe('anthropic_compatible');
    const protocol = relayDetailBoard(autoProvider).connectionRows.find((row) => row.id === 'defaultProtocol');
    // On the detail page the auto value reads "Auto · detect per model" (BOARD-DETAIL-13).
    expect(protocol?.value).toEqual({ key: RELAY_DETAIL_TEXT.autoPerModel });
  });

  it('BOARD-DETAIL-06 default protocol is Auto in Edit Connection; relayKind is derived from the default protocol on save (auto -> custom)', async () => {
    render(<RelayDetail provider={autoProvider} />);
    expect(screen.getByText(RELAY_DETAIL_TEXT.autoPerModel)).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));
    expect(screen.queryByLabelText('relayType')).toBeNull();
    expect((screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol') as HTMLSelectElement).value).toBe('auto');

    // A stored relayKind that differs from the one derived from the default protocol is still just "Save" (BOARD-EDIT-06).
    fireEvent.click(screen.getByRole('button', { name: 'common.save' }));
    await waitFor(() => expect(mocks.saveRelaySettings).toHaveBeenCalledTimes(1));
    expect(savedRelayPatch(autoProvider)).toMatchObject({
      relayKind: 'custom',
      relayRequested: { transport: 'auto' },
    });
  });
});

describe('BOARD-DETAIL-07 local Edit Connection channel selector', () => {
  it('BOARD-DETAIL-07 llama.cpp has two selectable options and only one channel control is shown (no default protocol menu)', () => {
    render(<RelayDetail provider={{ ...localProvider('llamacpp'), relayKind: 'openai_compatible' }} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));

    const channel = screen.getByLabelText('pages.relaySetup.localTileChannel') as HTMLSelectElement;
    expect([...channel.options].map((option) => option.value)).toEqual(['openai_chat_completions', 'llamacpp_native']);
    expect(screen.queryByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeNull();
  });

  it('BOARD-DETAIL-07 a stored local connection of kind Custom also shows only the channel, no protocol menu', () => {
    render(<RelayDetail provider={localProvider('llamacpp')} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));

    expect(screen.getAllByLabelText('pages.relaySetup.localTileChannel')).toHaveLength(1);
    expect(screen.queryByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeNull();
  });

  it.each(['ollama', 'lmstudio', 'vllm', 'openwebui'] as const)('BOARD-DETAIL-07 %s is read-only with one option', (engine) => {
    render(<RelayDetail provider={localProvider(engine)} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));

    expect(screen.queryByRole('combobox', { name: 'pages.relaySetup.localTileChannel' })).toBeNull();
    const readOnly = document.querySelector('[data-edit-row="channel"]')!;
    expect(readOnly.textContent).toContain('pages.relaySetup.localTileChannel');
    expect(readOnly.textContent).toContain('Chat Completions');
    expect(screen.queryByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeNull();
  });

  it('BOARD-DETAIL-07 changing the channel saves through the existing save and keeps the three engine fields', async () => {
    const provider = localProvider('llamacpp');
    const opened = {
      ...provider,
      relayRequested: { ...provider.relayRequested!, certificateFingerprint: 'ab:cd' },
    };
    render(<RelayDetail provider={opened} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));

    fireEvent.change(screen.getByLabelText('pages.relaySetup.localTileChannel'), { target: { value: 'llamacpp_native' } });
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.editBoard.validateAndSave' }));

    await waitFor(() => expect(mocks.saveRelaySettings).toHaveBeenCalledTimes(1));
    expect(savedRelayPatch(opened)).toMatchObject({
      relayRequested: {
        transport: 'llamacpp_native',
        engineProfile: 'llamacpp',
        securityMode: 'local_http',
        certificateFingerprint: 'ab:cd',
      },
    });
  });
});

/* ── Keys row navigation and inline keys ── */

function multiKeyProvider(count = 5): Provider {
  const base = relayProvider();
  const extra = Array.from({ length: count - 1 }, (_, index) => ({
    id: `k${index + 2}`,
    apiKey: `sk-extra-${index + 2}-0123456789`,
    ...(index === 1 ? { name: 'Spare' } : {}),
    ...(index === 0 ? { status: { state: 'invalid' as const, httpStatus: 401 } } : {}),
  }));
  return {
    ...base,
    relayKeys: [{ id: 'initial', apiKey: '', name: 'Main', status: { state: 'ok' } }, ...extra],
    models: base.models.map((item) => ({ ...item, relayKeyID: 'initial' })),
    // The first 3 catalog models are listed only by k2; the rest only by the primary key.
    catalogModels: base.catalogModels.map((item, index) => ({
      ...item,
      relayListedByKeyIDs: index >= 2 && index < 5 ? ['k2'] : ['initial'],
    })),
  };
}

describe('BOARD-DETAIL-08 single-key row opens the keys page', () => {
  it('BOARD-DETAIL-08 implicit / 1 key: keeps today\'s single row, the action now opens the keys page; authMode none with no Key is still not tappable', () => {
    const row = relayDetailBoard(relayProvider()).connectionRows.find((item) => item.id === 'apiKey')!;
    expect(row).toMatchObject({
      titleKey: RELAY_DETAIL_TEXT.apiKey,
      value: { literal: formatApiKeyPreview(KEY) },
      trailingKey: RELAY_DETAIL_TEXT.keysAddMoreHint,
      action: 'openKeys',
    });
    expect(row.keys).toBeUndefined();
    const oneExplicit = relayDetailBoard(relayProvider({ relayKeys: [{ id: 'initial', apiKey: '', name: 'Main' }] }));
    expect(oneExplicit.connectionRows.find((item) => item.id === 'apiKey')).toMatchObject({
      titleKey: RELAY_DETAIL_TEXT.apiKey,
      action: 'openKeys',
    });
    const none = relayDetailBoard(localProvider('ollama')).connectionRows.find((item) => item.id === 'apiKey')!;
    expect(none.action).toBeNull();
  });

  it('BOARD-DETAIL-08 production component: tapping the keys row pushes ?view=keys to the keys page and no longer shows the change-Key dialog', () => {
    render(<RelayDetail provider={relayProvider()} />);
    fireEvent.click(screen.getByRole('button', { name: 'editKey' }));

    expect(mocks.routerPush).toHaveBeenCalledWith(expect.stringMatching(/\?view=keys$/));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.getByRole('heading', { name: 'pages.relayDetail.keysTitle' })).toBeTruthy();
  });
});

describe('BOARD-DETAIL-09 multi-key inline', () => {
  it('BOARD-DETAIL-09 >=2 keys: title row API Keys · N keys, first 3 keys inline (name or mask / mask / catalog count or — / status word / primary badge / status mark; same row component as the keys page), overflow gives more', () => {
    const row = relayDetailBoard(multiKeyProvider(5)).connectionRows.find((item) => item.id === 'apiKey')!;
    expect(row).toMatchObject({
      titleKey: 'pages.relayDetail.keysTitle',
      value: { key: 'pages.relayDetail.keysCount', values: { count: 5 } },
      action: 'openKeys',
      keysMore: 2,
    });
    expect(row.keys).toEqual([
      {
        id: 'initial',
        title: 'Main',
        preview: formatApiKeyPreview(KEY),
        catalog: { key: 'pages.relayDetail.keyCatalogCount', values: { count: 39 } },
        statusKey: 'pages.relayDetail.keyStatusOk',
        primaryBadge: true,
        statusMark: 'dot',
      },
      {
        id: 'k2',
        title: formatApiKeyPreview('sk-extra-2-0123456789'),
        preview: formatApiKeyPreview('sk-extra-2-0123456789'),
        catalog: { key: 'pages.relayDetail.keyCatalogCount', values: { count: 3 } },
        statusKey: 'pages.relayDetail.keyStatusInvalid',
        primaryBadge: false,
        statusMark: 'warning',
      },
      {
        id: 'k3',
        title: 'Spare',
        preview: formatApiKeyPreview('sk-extra-3-0123456789'),
        catalog: { key: 'pages.relayDetail.keyCatalogNone' },
        statusKey: null,
        primaryBadge: false,
        statusMark: null,
      },
    ]);
    const three = relayDetailBoard(multiKeyProvider(3)).connectionRows.find((item) => item.id === 'apiKey')!;
    expect(three.keys).toHaveLength(3);
    expect(three.keysMore).toBeUndefined();
  });

  it('BOARD-DETAIL-09 production component renders 3 inline rows and the "N more" row, without leaking plaintext', () => {
    const { container } = render(<RelayDetail provider={multiKeyProvider(5)} />);
    const inline = container.querySelectorAll('[data-board-section="connection"] [data-key-inline]');
    expect([...inline].map((element) => element.getAttribute('data-key-inline'))).toEqual(['initial', 'k2', 'k3']);
    expect(screen.getByText('pages.relayDetail.keysMore({"count":2})')).toBeTruthy();
    expect(screen.getByText('pages.relayDetail.keysCount({"count":5})')).toBeTruthy();
    expect(container.innerHTML).not.toContain('sk-extra-2-0123456789');
    expect(container.innerHTML).not.toContain(KEY);
  });
});

describe('BOARD-DETAIL-10 header', () => {
  it('BOARD-DETAIL-10 relay avatar uses the unified resolver, a pencil is visible next to the name, status row model count = enabled ∪ catalog', () => {
    const board = relayDetailBoard(relayProvider());
    expect(board.avatar).toEqual({ kind: 'initial', text: 'M' });
    expect(board.modelCount).toBe(42);

    const { container } = render(<RelayDetail provider={relayProvider({ customName: 'OpenRouter \u5907\u7528' })} />);
    const header = container.querySelector('header')!;
    expect(header.querySelector('[data-relay-avatar]')?.getAttribute('data-relay-avatar')).toBe('brand:openrouter');
    expect(within(header).getByRole('button', { name: 'editName' })).toBeTruthy();
    expect(within(header).getByText('pages.relayDetail.modelsCount({"count":42})')).toBeTruthy();
  });

  it('BOARD-DETAIL-10 local header unchanged: does not use the relay avatar', () => {
    expect(relayDetailBoard(localProvider('ollama')).avatar).toBeNull();
    const { container } = render(<RelayDetail provider={localProvider('ollama')} />);
    expect(container.querySelector('header [data-relay-avatar]')).toBeNull();
  });
});

describe('detail row icons are colored per row', () => {
  const expected: Record<DetailRowID, string | null> = {
    modelLibrary: '--o-row-teal',
    endpoint: '--o-row-cyan',
    engineAddress: '--o-row-cyan',
    defaultProtocol: '--o-row-indigo',
    channel: '--o-row-indigo',
    apiKey: '--o-row-orange',
    engine: '--o-row-rose',
    webSearch: '--o-cap-web-search',
    thinking: '--o-cap-reasoning',
    parameters: '--o-row-rose',
    basePaths: null,
  };

  it('detail row icons are colored per row', () => {
    for (const [id, token] of Object.entries(expected) as [DetailRowID, string | null][]) {
      expect(relayDetailRowIconColorToken(id), id).toBe(token);
    }
  });

  it('production component row icons take their color from the mapping; the large header icon does not take a row color', () => {
    for (const provider of [relayProvider(), localProvider('llamacpp')]) {
      const { container, unmount } = render(<RelayDetail provider={provider} />);
      const icons = Array.from(container.querySelectorAll<HTMLElement>('[data-row]'));
      expect(icons.length).toBeGreaterThan(0);
      for (const icon of icons) {
        const id = icon.dataset.row as DetailRowID;
        expect(icon.getAttribute('style'), id).toContain(`var(${expected[id]})`);
      }
      unmount();
    }
  });

  it('the five row color tokens are defined in both light and dark themes', () => {
    let dir = process.cwd();
    let file = '';
    for (let depth = 0; depth < 8 && !file; depth += 1) {
      const candidate = path.join(dir, 'packages', 'ui', 'src', 'tokens', 'variables.css');
      if (existsSync(candidate)) file = candidate;
      dir = path.dirname(dir);
    }
    const css = readFileSync(file, 'utf8');
    for (const name of ['teal', 'cyan', 'indigo', 'orange', 'rose']) {
      expect(css.match(new RegExp(`--o-row-${name}:`, 'g'))?.length, name).toBe(2);
    }
  });
});

describe('trailing hint on the keys row', () => {
  const apiKeyRowOf = (provider: Provider) =>
    relayDetailBoard(provider).connectionRows.find((row) => row.id === 'apiKey')!;

  it('with only one key stored the trailing hint says multiple keys can be added', () => {
    expect(RELAY_DETAIL_TEXT.keysAddMoreHint).toBe('pages.relayDetail.keysAddMoreHint');
    expect(apiKeyRowOf(relayProvider())).toMatchObject({
      value: { literal: formatApiKeyPreview(KEY) },
      trailingKey: RELAY_DETAIL_TEXT.keysAddMoreHint,
      action: 'openKeys',
    });

    const { container } = render(<RelayDetail provider={relayProvider()} />);
    const row = container.querySelector<HTMLElement>('[data-board-row="apiKey"]')!;
    const hint = row.querySelector<HTMLElement>('[data-row-hint="addMoreKeys"]')!;
    expect(hint.textContent).toBe(RELAY_DETAIL_TEXT.keysAddMoreHint);
    // Not a button: the whole row is the only tap target, and the hint is read as part of this row.
    expect(row.tagName).toBe('BUTTON');
    expect(hint.closest('button')).toBe(row);
    expect(row.querySelectorAll('button').length).toBe(0);
    expect(row.getAttribute('aria-describedby')).toBe(hint.id);
    expect(container.innerHTML).not.toContain('pages.relayDetail.keySaved');
  });

  it('the hint does not appear for multiple keys / unset / no key needed', () => {
    const multi = relayProvider({
      relayKeys: [{ id: 'initial', apiKey: '', name: 'Main' }, { id: 'k2', apiKey: 'sk-second-0123456789', name: 'Second' }],
    });
    const unset = relayProvider({ apiKey: '', apiKeyPreview: '' });
    const noKeyNeeded = localProvider('llamacpp');
    const noAuthWithKey = relayProvider({
      relayRequested: { transport: 'openai_chat_completions', authMode: 'none' },
      relayResolvedAuthMode: 'none',
    });
    // No auth required but a Key is stored: mask and tappability stay as before, nothing goes at the row end.
    expect(apiKeyRowOf(noAuthWithKey)).toMatchObject({ value: { literal: formatApiKeyPreview(KEY) }, action: 'openKeys' });
    expect(apiKeyRowOf(multi).keys?.length).toBe(2);
    expect(apiKeyRowOf(unset).value).toEqual({ key: 'pages.providerDetail.hero.tapToSet' });
    expect(apiKeyRowOf(noKeyNeeded).value).toEqual({ key: 'pages.relayDetail.noKey' });
    for (const provider of [multi, unset, noKeyNeeded, noAuthWithKey]) {
      expect(apiKeyRowOf(provider).trailingKey).toBeUndefined();
      const { container, unmount } = render(<RelayDetail provider={provider} />);
      expect(container.querySelector('[data-row-hint]')).toBeNull();
      expect(container.querySelector('[data-board-row="apiKey"] [aria-describedby], [data-board-row="apiKey"][aria-describedby]')).toBeNull();
      expect(container.innerHTML).not.toContain(RELAY_DETAIL_TEXT.keysAddMoreHint);
      unmount();
    }
  });
});

describe('BOARD-DETAIL-11 model card row order (connection-level parameters row)', () => {
  it('BOARD-DETAIL-11 relay [modelLibrary, webSearch, parameters], local [modelLibrary, thinking, parameters], no Settings section', () => {
    // The parameters entry is the last row of the Models group, same as iOS; still no Settings section.
    expect(ids(relayDetailBoard(relayProvider()).modelRows)).toEqual(['modelLibrary', 'webSearch', 'parameters']);
    expect(ids(relayDetailBoard(localProvider('llamacpp')).modelRows)).toEqual(['modelLibrary', 'thinking', 'parameters']);
    for (const provider of [relayProvider(), localProvider('ollama')]) {
      const { container, unmount } = render(<RelayDetail provider={provider} />);
      expect([...container.querySelectorAll('[data-board-section]')].map((node) => node.getAttribute('data-board-section')))
        .toEqual(['connection', 'models']);
      expect(container.querySelector('[data-board-section="models"] [data-board-row="parameters"]')?.textContent).toBe('common.generationParameters');
      unmount();
    }
  });
});

describe('BOARD-DETAIL-12 relay / local recovery card', () => {
  const issue = (overrides: Partial<Provider> = {}) => relayProvider({
    status: { kind: 'issue', message: 'Upstream said no' },
    lastError: '  Upstream said no  ',
    ...overrides,
  });

  it('BOARD-DETAIL-12 hidden when the connection is healthy; with an issue shows [Edit Connection, API Keys, Re-verify], title warning not tappable, reason row = lastError (trimmed)', () => {
    expect(relayDetailRecoveryCard(relayProvider(), false, false)).toBeNull();
    const card = relayDetailRecoveryCard(issue(), false, false)!;
    expect(card).toMatchObject({
      titleKey: 'pages.relayDetail.recoveryIssueTitle',
      titleIcon: 'warning',
      titleAction: null,
      reason: 'Upstream said no',
    });
    expect(card.actions.map((action) => [action.id, action.titleKey, action.destination])).toEqual([
      ['editConnection', 'pages.relayDetail.editConnection', 'editConnection'],
      ['apiKeys', 'pages.relayDetail.keysTitle', 'openKeys'],
      ['reverify', 'pages.relayDetail.verifyAgain', null],
    ]);
    expect(card.actions.every((action) => !action.running && !action.disabled)).toBe(true);
  });

  it('BOARD-DETAIL-12 missing Key: the title becomes the missing-Key sentence (key icon, tappable to the keys page), no reason row', () => {
    const card = relayDetailRecoveryCard(relayProvider({ apiKey: '', apiKeyPreview: '', lastError: 'boom' }), false, false)!;
    expect(card).toMatchObject({
      titleKey: 'pages.providerDetail.recoveryCard.needsKeyHeadline',
      titleIcon: 'key',
      titleAction: 'openKeys',
      reason: null,
    });
    expect(card.actions.map((action) => action.id)).toEqual(['editConnection', 'apiKeys', 'reverify']);
  });

  it('BOARD-DETAIL-12 no credentials needed (authMode none / local without auth) means no apiKeys; a missing Key does not count; local with auth is the same as relay', () => {
    const noneRelay = issue({ apiKey: '', apiKeyPreview: '', relayRequested: { transport: 'openai_chat_completions', authMode: 'none' } });
    expect(relayDetailRecoveryCard(noneRelay, false, false)!.actions.map((action) => action.id)).toEqual(['editConnection', 'reverify']);
    expect(relayDetailRecoveryCard({ ...noneRelay, status: { kind: 'connected' } }, false, false)).toBeNull();
    const local: Provider = { ...localProvider('ollama'), status: { kind: 'issue', message: 'down' } };
    expect(relayDetailRecoveryCard(local, false, false)!.actions.map((action) => action.id)).toEqual(['editConnection', 'reverify']);
    const localAuth = localProvider('ollama');
    const withAuth: Provider = {
      ...localAuth,
      relayRequested: { ...localAuth.relayRequested!, authMode: 'bearer' },
    };
    expect(relayDetailRecoveryCard(withAuth, false, false)).toMatchObject({ titleIcon: 'key', titleAction: 'openKeys' });
    expect(relayDetailRecoveryCard(withAuth, false, false)!.actions.map((action) => action.id)).toEqual(['editConnection', 'apiKeys', 'reverify']);
  });

  it('BOARD-DETAIL-12 re-verify in flight: only reverify running + disabled; omitsDetail omits only the reason row', () => {
    const running = relayDetailRecoveryCard(issue(), true, false)!;
    expect(running.actions.map((action) => [action.id, action.running, action.disabled])).toEqual([
      ['editConnection', false, false],
      ['apiKeys', false, false],
      ['reverify', true, true],
    ]);
    const omitted = relayDetailRecoveryCard(issue(), false, true)!;
    const full = relayDetailRecoveryCard(issue(), false, false)!;
    expect(omitted.reason).toBeNull();
    expect({ ...omitted, reason: full.reason }).toEqual(full);
  });

  it('BOARD-DETAIL-12 production component: action mapping is not crossed, re-verify goes through verifyRelayConnection and guards against double taps, no Dismiss', async () => {
    let release: () => void = () => {};
    mocks.verifyRelayConnection.mockImplementation(() => new Promise<void>((resolve) => { release = resolve; }));
    render(<RelayDetail provider={issue()} />);

    const card = screen.getByRole('region', { name: 'pages.relayDetail.recoveryIssueTitle' });
    expect(within(card).getByText('Upstream said no')).toBeTruthy();
    expect(within(card).queryByRole('button', { name: /dismiss/i })).toBeNull();
    expect(screen.queryByTestId('recovery-edit-api-key')).toBeNull();

    const reverify = within(card).getByRole('button', { name: 'pages.relayDetail.verifyAgain' });
    fireEvent.click(reverify);
    fireEvent.click(reverify);
    expect(mocks.verifyRelayConnection).toHaveBeenCalledTimes(1);
    await waitFor(() => expect((reverify as HTMLButtonElement).disabled).toBe(true));
    expect(reverify.getAttribute('aria-busy')).toBe('true');
    expect((within(card).getByRole('button', { name: 'pages.relayDetail.editConnection' }) as HTMLButtonElement).disabled).toBe(false);
    await act(async () => { release(); });
    await waitFor(() => expect((reverify as HTMLButtonElement).disabled).toBe(false));

    fireEvent.click(within(card).getByRole('button', { name: 'pages.relayDetail.keysTitle' }));
    expect(mocks.routerPush).toHaveBeenCalledWith(expect.stringMatching(/\?view=keys$/));
  });

  it('BOARD-DETAIL-12 production component: the edit-connection action opens Edit Connection; the missing-Key title is tappable to the keys page', () => {
    const { unmount } = render(<RelayDetail provider={issue()} />);
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.editConnection' }));
    expect(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeTruthy();
    expect(mocks.routerPush).not.toHaveBeenCalled();
    unmount();

    render(<RelayDetail provider={relayProvider({ apiKey: '', apiKeyPreview: '' })} />);
    fireEvent.click(screen.getByRole('button', { name: 'pages.providerDetail.recoveryCard.needsKeyHeadline' }));
    expect(mocks.routerPush).toHaveBeenCalledWith(expect.stringMatching(/\?view=keys$/));
  });

  it('BOARD-DETAIL-12 the one-time notice omits the reason row for an unverified save; "N models added" does not omit it', () => {
    setProviderDetailNotice('relay-1', { unverifiedReason: 'Saved without verifying' });
    const first = render(<RelayDetail provider={issue()} />);
    const omitted = screen.getByRole('region', { name: 'pages.relayDetail.recoveryIssueTitle' });
    expect(within(omitted).queryByText('Upstream said no')).toBeNull();
    // Three action rows + the top-right x.
    expect(within(omitted).getAllByRole('button')).toHaveLength(4);
    first.unmount();

    setProviderDetailNotice('relay-1', { count: 3 });
    render(<RelayDetail provider={issue()} />);
    expect(within(screen.getByRole('region', { name: 'pages.relayDetail.recoveryIssueTitle' })).getByText('Upstream said no')).toBeTruthy();
  });
});

describe('BOARD-DETAIL-13 two footnote states', () => {
  it('BOARD-DETAIL-13 auto: footnote carries the protocol sentence + default protocol value Auto · detected per model; selected protocol: footnote only refreshes the catalog + protocol name; local has a fixed sentence', () => {
    const auto = relayDetailBoard(relayProvider({ relayRequested: { transport: 'auto', authMode: 'bearer' } }));
    expect(auto.footnoteKey).toBe('pages.relayDetail.detectFootnote');
    expect(auto.connectionRows.find((row) => row.id === 'defaultProtocol')?.value)
      .toEqual({ key: 'pages.relayDetail.protocolAutoPerModel' });
    const names: Record<string, string> = {
      openai_chat_completions: 'OpenAI Chat Completions',
      openai_responses: 'OpenAI Responses',
      anthropic_messages: 'Messages',
      gemini_generate_content: 'generateContent',
    };
    for (const [transport, label] of Object.entries(names)) {
      const board = relayDetailBoard(relayProvider({ relayRequested: { transport: transport as never, authMode: 'bearer' } }));
      expect(board.footnoteKey).toBe('pages.relayDetail.detectFootnoteSelected');
      expect((board.connectionRows.find((row) => row.id === 'defaultProtocol')?.value as { literal: string }).literal)
        .toBe(label);
    }
    expect(relayDetailBoard(localProvider('llamacpp')).footnoteKey).toBe('pages.relayDetail.detectFootnoteSelected');
    expect(relayDetailBoard(localProvider('llamacpp', 'native')).footnoteKey).toBe('pages.relayDetail.detectFootnoteSelected');
    expect(relayDetailBoard(localProvider('ollama')).footnoteKey).toBe('pages.relayDetail.detectFootnoteSelected');
  });
});

describe('BOARD-DETAIL-14 tappable address row', () => {
  it('BOARD-DETAIL-14 the request URL row and the default protocol row both open Edit Connection; the local engine URL is always tappable and the engine row is not', () => {
    const relay = relayDetailBoard(relayProvider());
    const action = (board: typeof relay, id: DetailRowID) => board.connectionRows.find((row) => row.id === id)?.action;
    expect(action(relay, 'endpoint')).toBe('editConnection');
    expect(action(relay, 'endpoint')).toBe(action(relay, 'defaultProtocol'));
    for (const engine of ['llamacpp', 'ollama', 'lmstudio'] as LocalEngineKind[]) {
      const local = relayDetailBoard(localProvider(engine));
      expect(action(local, 'engineAddress')).toBe('editConnection');
      expect(action(local, 'engine')).toBeNull();
    }
  });

  it('BOARD-DETAIL-14 production component: tapping the request URL row opens Edit Connection', () => {
    const { container } = render(<RelayDetail provider={relayProvider()} />);
    const endpoint = container.querySelector('[data-board-row="endpoint"]')!;
    expect(endpoint.tagName).toBe('BUTTON');
    fireEvent.click(endpoint);
    expect(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeTruthy();
  });
});

describe('BOARD-EDIT-19 draft changes while a save is in flight', () => {
  it('BOARD-EDIT-19 a draft changed mid-save does not lose later edits: the result is discarded, the page stays open, and isStale is passed so the write is invalidated', async () => {
    let resolveSave: (saved: boolean) => void = () => {};
    mocks.saveRelaySettings.mockImplementation(() => new Promise<boolean>((resolve) => { resolveSave = resolve; }));
    render(<RelayDetail provider={relayProvider()} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));
    fireEvent.click(screen.getByRole('button', { name: 'common.save' }));
    await waitFor(() => expect(mocks.saveRelaySettings).toHaveBeenCalledTimes(1));

    // The URL slot shows only the part after the scheme.
    fireEvent.change(screen.getByDisplayValue('api.myrelay.dev'), { target: { value: 'https://later.myrelay.dev' } });
    const options = mocks.saveRelaySettings.mock.calls[0]![1] as { isStale?: () => boolean } | undefined;
    expect(options?.isStale?.()).toBe(true);
    await act(async () => { resolveSave(true); });

    expect(screen.getByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeTruthy();
    expect(screen.getByDisplayValue('later.myrelay.dev')).toBeTruthy();
  });

  it('BOARD-EDIT-19 draft unchanged: closes the page as usual, isStale is false', async () => {
    let resolveSave: (saved: boolean) => void = () => {};
    mocks.saveRelaySettings.mockImplementation(() => new Promise<boolean>((resolve) => { resolveSave = resolve; }));
    render(<RelayDetail provider={relayProvider()} />);
    fireEvent.click(screen.getByRole('button', { name: 'editConnection' }));
    fireEvent.click(screen.getByRole('button', { name: 'common.save' }));
    await waitFor(() => expect(mocks.saveRelaySettings).toHaveBeenCalledTimes(1));
    const options = mocks.saveRelaySettings.mock.calls[0]![1] as { isStale?: () => boolean } | undefined;
    expect(options?.isStale?.()).toBe(false);
    await act(async () => { resolveSave(true); });
    expect(screen.queryByLabelText('pages.relayDetail.editBoard.defaultProtocol')).toBeNull();
  });
});

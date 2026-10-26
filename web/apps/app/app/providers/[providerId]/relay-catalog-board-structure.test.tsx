import 'fake-indexeddb/auto';
import fs from 'node:fs';
import path from 'node:path';
import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type LocalEngineKind, type Provider, type RelayKeyEntry } from '@oriveo/shared';
import { inferModelFamily } from '@oriveo/shared';
import { relayCatalogGroups } from '@oriveo/shared/relay/relay-catalog-grouping';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { RelayDetail } from './RelayDetail';
import { parseRelayDetailPage, relayDetailPageQuery } from './relay-detail-nav';
import {
  RELAY_CATALOG_CAPS,
  RELAY_CATALOG_TEXT,
  relayCatalogBoard,
  relayCatalogEnableAllModelIDs,
  relayCatalogHeader,
  relayCatalogKeyStrip,
  relayCatalogLayout,
  type RelayCatalogBoardModel,
  type RelayCatalogFilter,
  type RelayCatalogRow,
} from './relay-catalog-board';
import { recordRelayNegativeCache, RELAY_NEGATIVE_CACHE_TTL_MS } from '../../../lib/core/chat/relay-negative-cache';
import { recordInputNegativeCache } from '../../../lib/core/capability/input-negative-cache';
import { inputNegativeCacheTarget } from '../../../lib/core/capability/truth/input-truth-adapter';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../../lib/core/chat/stream-options';
import { rememberRelayCatalogEndpointTypes } from '../../../lib/core/providers/relay-probe-candidates';
import { connectLocalEngineInBrowser } from '../../../lib/core/providers/local-browser-probe';
import { createRelayManualModel, disableProviderModel, enableProviderModels } from '../../../lib/core/provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../../lib/core/providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { createAppStore } from '../../../lib/core/store/app-store';
import { buildModelBrowserGroups } from './model-browser-groups';
import { relayStepTwoGroups } from '../relay/new/relay-setup-two-step';
import type * as ProbeOps from '../../../lib/core/relay-model-probe-ops';

/**
 * Model library (Catalog) structure snapshot: asserts the chips / sections / rows produced by relayCatalogBoard,
 * and the section headers, rows, legend and footnote that the production component RelayDetail renders on the model library subpage from it.
 */

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  routerReplace: vi.fn(),
  refreshCatalogInStore: vi.fn(),
  enableWithProbe: vi.fn(),
  redetect: vi.fn(),
  /** If given, returned as getVanillaStore() (a real store); the default is an empty shell. */
  store: null as unknown,
  sendMessageStream: vi.fn(),
  removeModel: vi.fn(),
  catalogLoadState: 'loaded' as 'loaded' | 'loading' | 'failed' | 'idle',
  /** If given, replaces the reasoning recipe state; everything else runs the production functions. */
  reasoningState: undefined as undefined | 'auto_available' | 'unavailable' | 'unknown',
}));

vi.mock('../../../lib/core/chat/capability-control-presentation', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/chat/capability-control-presentation')>();
  return {
    ...actual,
    presentCapabilityControl: (...args: Parameters<typeof actual.presentCapabilityControl>) => {
      const result = actual.presentCapabilityControl(...args);
      return args[2] === 'reasoning' && mocks.reasoningState
        ? { ...result, state: mocks.reasoningState }
        : result;
    },
  };
});

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

vi.mock('../../../lib/core/providers/adapters/relay', () => ({
  sendMessageStream: (...args: unknown[]) => mocks.sendMessageStream(...args),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: vi.fn(), replace: mocks.routerReplace }),
}));

vi.mock('../../../lib/core/providers/provider-sync', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/providers/provider-sync')>()),
  refreshRelayCatalogInStore: (...args: unknown[]) => mocks.refreshCatalogInStore(...args),
}));

// The component tests only check wiring (the signal carried by enable / re-detect); the production behavior of the lazy-verification state goes through importActual in BOARD-CATALOG-11.
vi.mock('../../../lib/core/relay-model-probe-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/relay-model-probe-ops')>()),
  enableProviderModelWithProbe: (...args: unknown[]) => mocks.enableWithProbe(...args),
  redetectRelayModels: (...args: unknown[]) => mocks.redetect(...args),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
  useLocale: () => 'en',
}));

vi.mock('../../../lib/hooks/useProviderActions', () => ({
  useProviderActions: () => ({
    isSyncing: false,
    catalogLoadState: mocks.catalogLoadState,
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
    removeModel: (...args: unknown[]) => mocks.removeModel(...args),
    deleteProvider: vi.fn(),
  }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: Record<string, unknown>) => unknown) =>
    selector({ setLastUsedModelRef: vi.fn(), setActiveConversationId: vi.fn() }),
  getVanillaStore: () => mocks.store ?? { getState: () => ({ providers: [] }) },
}));

vi.mock('../../../components/Toast', () => ({
  showToast: vi.fn(),
}));

/* -- fixtures -- */

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

function relayProvider(
  enabled: AIModel[],
  catalogOnly: AIModel[],
  overrides: Partial<Provider> = {},
): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = 'openai_chat_completions';
  requested.resolvedAPIBaseURL = 'https://api.myrelay.dev/v1';
  return {
    id: 'relay-catalog',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled.filter((item) => item.isManual !== true), ...catalogOnly],
    apiKey: 'sk-relay-secret-0123456789',
    apiKeyPreview: 'sk-r…6789',
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'https://api.myrelay.dev/v1',
    relayResolvedTransport: 'openai_chat_completions',
    relayResolvedAuthMode: 'bearer',
    ...overrides,
  };
}

/**
 * auto-detected connection (dispatch still lands on Chat). Per-model probes, "Unknown" on enabled rows, "Verify on enable" on catalog rows and the enable hint
 * only appear on this kind of connection; when the user picks the connection protocol these rows are always "Set by you".
 */
function asAuto(provider: Provider): Provider {
  return { ...provider, relayRequested: { ...provider.relayRequested!, transport: 'auto' } };
}

function localProvider(enabled: AIModel[], catalogOnly: AIModel[], engine: LocalEngineKind = 'ollama'): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'none';
  requested.securityMode = 'local_http';
  requested.transport = 'openai_chat_completions';
  requested.resolvedAPIBaseURL = 'http://127.0.0.1:11434/v1';
  requested.engineProfile = engine;
  return {
    id: 'local-catalog',
    kind: 'relay',
    customName: 'Mac mini',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled, ...catalogOnly],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: 'http://127.0.0.1:11434',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'http://127.0.0.1:11434/v1',
    relayResolvedTransport: 'openai_chat_completions',
    relayResolvedAuthMode: 'none',
  };
}

const NOW = Date.parse('2026-10-11T08:00:00.000Z');

function board(provider: Provider, filter: RelayCatalogFilter = 'all', catalogLoaded = true): RelayCatalogBoardModel {
  return relayCatalogBoard({
    provider,
    enabledModels: provider.models,
    catalogModels: provider.catalogModels,
    catalogLoaded,
    filter,
    now: NOW,
  });
}

const rowOf = (b: RelayCatalogBoardModel, id: string): RelayCatalogRow =>
  [...b.enabled.rows, ...b.library.rows].find((row) => row.model.id === id)!;

const capsOf = (row: RelayCatalogRow) => Object.fromEntries(row.caps.map((cap) => [cap.cap, cap.state]));

function openLibrary(provider: Provider) {
  const view = render(<RelayDetail provider={provider} />);
  fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.modelLibrary/ }));
  return view;
}

/** The relay model library draws group headers however many groups there are, collapsed by default: expand the groups first to see catalog rows. */
function expandLibraryGroups(container: HTMLElement) {
  for (const button of container.querySelectorAll('[data-catalog-section="library"] section[data-testid^="group-"] button[aria-expanded="false"]')) {
    fireEvent.click(button);
  }
}

/** The row's tap button (tapping a row dispatches only by tapTarget). */
const rowOpen = (row: HTMLElement) => row.querySelector('[data-row-open]') as HTMLElement;

const domRowIDs = (container: HTMLElement, section: 'enabled' | 'library') =>
  [...container.querySelectorAll(`[data-catalog-section="${section}"] [data-catalog-row]`)]
    .map((element) => element.getAttribute('data-catalog-row'));

beforeEach(() => {
  // The negative-cache TTL is 7 days: pin the clock to NOW so the fixed fixture time never ages out.
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
  mocks.routerPush.mockReset();
  mocks.routerReplace.mockReset();
  mocks.refreshCatalogInStore.mockReset();
  mocks.refreshCatalogInStore.mockResolvedValue({ state: 'loaded', catalogModels: [] });
  mocks.enableWithProbe.mockReset();
  mocks.enableWithProbe.mockImplementation((_store: unknown, _provider: unknown, item: AIModel) => item);
  mocks.redetect.mockReset();
  mocks.redetect.mockResolvedValue('loaded');
  mocks.store = null;
  mocks.catalogLoadState = 'loaded';
  mocks.reasoningState = undefined;
  mocks.sendMessageStream.mockReset();
  mocks.removeModel.mockReset();
  resetCapabilityEvidenceIdentitiesForTesting();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

/* -- cases -- */

describe('BOARD-CATALOG-01 section header counts + legend + footnote + no source badge on rows', () => {
  const enabled = [model('claude-sonnet-4.5', { isDefault: true }), model('gpt-5.4')];
  const others = Array.from({ length: 40 }, (_, index) => model(`catalog-${index}`));

  it('BOARD-CATALOG-01 section counts: enabled = enabled count, model library = catalog minus enabled', () => {
    const b = board(relayProvider(enabled, others));
    expect(b.enabled.count).toBe(2);
    expect(b.library.count).toBe(40);
    expect(b.enabled.rows.map((row) => row.model.id)).toEqual(['claude-sonnet-4.5', 'gpt-5.4']);
    expect(b.library.rows).toHaveLength(40);
  });

  it('BOARD-CATALOG-01 duplicate catalog ids count once (deduplicated, then minus enabled)', () => {
    const provider = relayProvider(enabled, [...others, model('catalog-0'), model('gpt-5.4')]);
    const b = board(provider);
    expect(b.library.count).toBe(40);
    expect(b.library.rows.filter((row) => row.model.id === 'catalog-0')).toHaveLength(1);
    expect(b.library.rows.some((row) => row.model.id === 'gpt-5.4')).toBe(false);
  });

  it('BOARD-CATALOG-01 production component: section headers, the three legend items, the footnote, and no source badge on rows', () => {
    const { container } = openLibrary(relayProvider(enabled, others));
    expect(screen.getByText(`${RELAY_CATALOG_TEXT.sectionEnabled}({"count":2})`)).toBeTruthy();
    expect(screen.getByText(`${RELAY_CATALOG_TEXT.sectionLibrary}({"count":40})`)).toBeTruthy();
    const legend = container.querySelector('[data-catalog-legend]')!;
    expect([...legend.querySelectorAll('[data-legend-item]')].map((item) => item.textContent)).toEqual([
      RELAY_CATALOG_TEXT.legendSupported,
      RELAY_CATALOG_TEXT.legendUnknown,
      RELAY_CATALOG_TEXT.legendUnsupported,
    ]);
    expect(container.querySelector('[data-catalog-footnote]')?.textContent).toBe(RELAY_CATALOG_TEXT.sourcesFootnote);
    expect(domRowIDs(container, 'enabled')).toEqual(['claude-sonnet-4.5', 'gpt-5.4']);
    expect(container.querySelectorAll('[data-catalog-row] [data-source-badge]')).toHaveLength(0);
  });
});

describe('BOARD-CATALOG-02 filter chips', () => {
  const enabled = [
    model('claude-opus', { relayTransport: 'anthropic_messages', relayTransportSource: 'observed' }),
    model('gpt-5.4'),
  ];
  const catalogOnly = [
    model('gemini-3-pro', { relayTransport: 'gemini_generate_content' }),
    model('claude-haiku', { relayTransport: 'anthropic_messages' }),
    model('o4-mini'),
  ];

  it('BOARD-CATALOG-02 All + the protocols present in the rows, in the fixed order Chat / Responses / Messages / Gemini', () => {
    const provider = relayProvider(enabled, [...catalogOnly, model('o3-pro', { relayTransport: 'openai_responses' })]);
    expect(board(provider).chips).toEqual(['all', 'Chat', 'Responses', 'Messages', 'Gemini']);
    expect(board(relayProvider(enabled, catalogOnly)).chips).toEqual(['all', 'Chat', 'Messages', 'Gemini']);
  });

  it('BOARD-CATALOG-02 fewer than two distinct protocols: no chips; a local connection: no chips', () => {
    expect(board(relayProvider([model('a')], [model('b')])).chips).toEqual([]);
    const local = localProvider([model('qwen3:0.6b')], [model('llama3', { relayTransport: 'anthropic_messages' })]);
    expect(board(local).chips).toEqual([]);
  });

  it('BOARD-CATALOG-02 after selecting, the enabled section and the catalog section are filtered together, counts unchanged', () => {
    const b = board(relayProvider(enabled, catalogOnly), 'Messages');
    expect(b.filter).toBe('Messages');
    expect(b.enabled.rows.map((row) => row.model.id)).toEqual(['claude-opus']);
    expect(b.library.rows.map((row) => row.model.id)).toEqual(['claude-haiku']);
    expect(b.enabled.count).toBe(2);
    expect(b.library.count).toBe(3);
    // When the selected protocol is no longer among the chips (the rows changed), fall back to All.
    expect(board(relayProvider([model('a')], [model('b')]), 'Gemini').filter).toBe('all');
  });

  it('BOARD-CATALOG-02 production component: chip order and, after a tap, both sections filter together', () => {
    const { container } = openLibrary(relayProvider(enabled, catalogOnly));
    const chips = [...container.querySelectorAll('[data-catalog-chip]')].map((chip) => chip.getAttribute('data-catalog-chip'));
    expect(chips).toEqual(['all', 'Chat', 'Messages', 'Gemini']);
    expect(container.querySelector('[data-catalog-chip="all"]')?.textContent).toBe(RELAY_CATALOG_TEXT.filterAll);
    fireEvent.click(container.querySelector('[data-catalog-chip="Messages"]')!);
    expect(container.querySelector('[data-catalog-chip="Messages"]')?.getAttribute('aria-pressed')).toBe('true');
    expect(domRowIDs(container, 'enabled')).toEqual(['claude-opus']);
    expect(screen.getByText(`${RELAY_CATALOG_TEXT.sectionLibrary}({"count":3})`)).toBeTruthy();
    // The relay model library does not show the official providers' capability filter chips.
    expect(container.querySelectorAll('[data-cap]')).toHaveLength(0);
  });
});

describe('BOARD-CATALOG-03 protocol chip = effectiveTransport', () => {
  it('BOARD-CATALOG-03 model-level > connection default; auto -> Chat; catalog-row candidates are not drawn; local nil', () => {
    const enabled = [model('o3', { relayTransport: 'openai_responses', relayTransportSource: 'reachable' }), model('plain')];
    const candidate = model('gemini-candidate');
    const provider = relayProvider(enabled, [candidate]);
    provider.relayRequested!.transport = 'anthropic_messages';
    // The catalog gave supported_endpoint_types candidates: a candidate is not evidence, so it is not drawn.
    rememberRelayCatalogEndpointTypes(provider.id, { 'gemini-candidate': ['gemini'] });
    const b = board(provider);
    for (const row of [...b.enabled.rows, ...b.library.rows]) {
      expect(row.protocol).not.toBeNull();
    }
    expect(rowOf(b, 'o3').protocol).toBe('Responses');
    expect(rowOf(b, 'plain').protocol).toBe('Messages');
    expect(rowOf(b, 'gemini-candidate').protocol).toBe('Messages');
    expect(effectiveTransport(provider, candidate)).toBe('anthropic_messages');
    rememberRelayCatalogEndpointTypes(provider.id, undefined);

    const auto = relayProvider([model('plain')], []);
    auto.relayRequested!.transport = 'auto';
    expect(rowOf(board(auto), 'plain').protocol).toBe('Chat');

    const local = localProvider([model('qwen3:0.6b')], [model('llama3')]);
    expect(rowOf(board(local), 'qwen3:0.6b').protocol).toBeNull();
    expect(rowOf(board(local), 'llama3').protocol).toBeNull();
  });

  it('BOARD-CATALOG-03 production component: enabled rows draw the protocol dot and name, local rows do not', () => {
    const { container, unmount } = openLibrary(relayProvider(
      [model('o3', { relayTransport: 'openai_responses', relayTransportSource: 'observed' })],
      [],
    ));
    const row = container.querySelector('[data-catalog-row="o3"]')!;
    expect(row.querySelector('[data-protocol]')?.getAttribute('data-protocol')).toBe('Responses');
    expect(row.querySelector('[data-protocol]')?.textContent).toBe('Responses');
    unmount();

    const local = openLibrary(localProvider([model('qwen3:0.6b')], []));
    expect(local.container.querySelector('[data-catalog-row="qwen3:0.6b"] [data-protocol]')).toBeNull();
  });
});

describe('BOARD-CATALOG-04 enabled row status', () => {
  const rows = [
    model('observed', { relayTransport: 'openai_chat_completions', relayTransportSource: 'observed' }),
    model('reachable', { relayTransport: 'openai_chat_completions', relayTransportSource: 'reachable' }),
    model('user', { relayTransport: 'anthropic_messages', relayTransportSource: 'user' }),
    model('none'),
    // Old data: a model-level protocol whose source was dropped / an auto persisted to storage.
    model('legacy-source', { relayTransport: 'openai_responses' }),
    model('legacy-auto', { relayTransport: 'auto' as unknown as AIModel['relayTransport'], relayTransportSource: 'observed' }),
  ];

  it('BOARD-CATALOG-04 observed -> Verified, reachable -> Reachable, user -> Set by you, no model-level protocol -> Unknown', () => {
    const b = board(asAuto(relayProvider(rows, [])));
    expect(b.enabled.rows.map((row) => row.status)).toEqual([
      'verified', 'reachable', 'setByYou', 'unknownUntilSent', 'unknownUntilSent', 'unknownUntilSent',
    ]);
  });

  it('BOARD-CATALOG-04 catalog-missing takes priority; manually entered models are never marked; an unloaded catalog is not marked', () => {
    const missing = model('gone', { relayTransport: 'openai_chat_completions', relayTransportSource: 'observed' });
    const manual = model('typed', { isManual: true });
    const provider = asAuto(relayProvider([missing, manual], []));
    provider.catalogModels = [];
    const b = board(provider);
    expect(rowOf(b, 'gone').status).toBe('missingFromCatalog');
    expect(rowOf(b, 'typed').status).toBe('unknownUntilSent');
    expect(rowOf(board(provider, 'all', false), 'gone').status).toBe('verified');
  });

  it('BOARD-CATALOG-04 production component: the status text renders by the board copy key', () => {
    const missing = model('gone');
    const provider = asAuto(relayProvider([...rows, missing], []));
    provider.catalogModels = provider.catalogModels.filter((item) => item.id !== 'gone');
    const { container } = openLibrary(provider);
    const statusOf = (id: string) => container.querySelector(`[data-catalog-row="${id}"] [data-status]`)?.textContent;
    expect(statusOf('observed')).toBe(RELAY_CATALOG_TEXT.status.verified);
    expect(statusOf('reachable')).toBe(RELAY_CATALOG_TEXT.status.reachable);
    expect(statusOf('user')).toBe(RELAY_CATALOG_TEXT.status.setByYou);
    expect(statusOf('none')).toBe(RELAY_CATALOG_TEXT.status.unknownUntilSent);
    expect(statusOf('legacy-source')).toBe(RELAY_CATALOG_TEXT.status.unknownUntilSent);
    expect(statusOf('gone')).toBe(RELAY_CATALOG_TEXT.status.missingFromCatalog);
  });
});

describe('BOARD-CATALOG-04b explicit connection protocol', () => {
  function chosenProvider(enabled: AIModel[], catalogOnly: AIModel[]): Provider {
    const provider = relayProvider(enabled, catalogOnly);
    return { ...provider, relayRequested: { ...provider.relayRequested!, transport: 'anthropic_messages' } };
  }

  it('the model row status under an explicit connection protocol is user-set', () => {
    const provider = chosenProvider(
      [
        model('follows'),
        model('legacy-auto', { relayTransport: 'auto' as unknown as AIModel['relayTransport'], relayTransportSource: 'observed' }),
        model('observed', { relayTransport: 'openai_chat_completions', relayTransportSource: 'observed' }),
        model('reachable', { relayTransport: 'openai_chat_completions', relayTransportSource: 'reachable' }),
        model('user', { relayTransport: 'openai_responses', relayTransportSource: 'user' }),
      ],
      [model('library-blank'), model('library-with-files', { nativeFileMimes: ['application/pdf'] })],
    );
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const b = board(provider);
    // A model without a protocol of its own follows the connection protocol the user picked; a model's own protocol is still written by its source as before.
    expect(b.enabled.rows.map((row) => [row.model.id, row.status])).toEqual([
      ['follows', 'setByYou'], ['legacy-auto', 'setByYou'],
      ['observed', 'verified'], ['reachable', 'reachable'], ['user', 'setByYou'],
    ]);
    expect(rowOf(b, 'follows').protocol).toBe('Messages');
    expect(rowOf(b, 'library-blank').status).toBe('setByYou');
    expect(rowOf(b, 'library-with-files').status).toBe('setByYou');

    // The same models on an auto-detected connection keep every status unchanged.
    const auto = board(asAuto(relayProvider([model('follows')], [model('library-with-files', { nativeFileMimes: ['application/pdf'] })])));
    expect(rowOf(auto, 'follows').status).toBe('unknownUntilSent');
    expect(rowOf(auto, 'library-with-files').status).toBe('verifyOnEnable');
  });

  it('explicit connection protocol: catalog-missing and no-access-to-the-current-key still take priority as before; a local connection still has no status', () => {
    const provider = chosenProvider([model('gone'), model('denied', { relayDeniedKeyID: 'initial' })], []);
    provider.catalogModels = provider.catalogModels.filter((item) => item.id !== 'gone');
    const b = board(provider);
    expect(rowOf(b, 'gone').status).toBe('missingFromCatalog');
    expect(rowOf(b, 'denied').status).toBe('denied');
    expect(rowOf(board(localProvider([model('llama3')], [])), 'llama3').status).toBeNull();
  });

  it('explicit connection protocol: the production component renders the existing "Set by you" copy key, and enabling sends no probe so no enable hint appears', () => {
    const { container } = openLibrary(chosenProvider([model('follows')], [model('library-blank')]));
    expandLibraryGroups(container);
    const statusOf = (id: string) => container.querySelector(`[data-catalog-row="${id}"] [data-status]`)?.textContent;
    expect(statusOf('follows')).toBe(RELAY_CATALOG_TEXT.status.setByYou);
    expect(statusOf('library-blank')).toBe(RELAY_CATALOG_TEXT.status.setByYou);
    expect(screen.queryByText('pages.relayDetail.catalogEnableHint')).toBeNull();
  });
});

describe('BOARD-CATALOG-05 catalog row status', () => {
  it('BOARD-CATALOG-05 auto-detected connection: a non-unknown capability -> Verified when enabled; user-picked connection protocol -> Set by you', () => {
    const provider = relayProvider([], [model('with-files', { nativeFileMimes: ['application/pdf'] }), model('blank')]);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const b = board(provider);
    expect(capsOf(rowOf(b, 'blank'))).toEqual({
      image: 'unknown', file: 'unknown', thinking: 'unknown', tool: 'unknown', web: 'unknown',
    });
    // This connection's protocol was picked by the user: catalog rows no longer write "Unknown / Verify on enable" (enabling sends no probe).
    expect(rowOf(b, 'blank').status).toBe('setByYou');
    expect(rowOf(b, 'with-files').status).toBe('setByYou');
    expect(rowOf(board(asAuto(provider)), 'with-files').status).toBe('verifyOnEnable');
  });

  it('BOARD-CATALOG-05 local connection: catalog rows have no status, enabled rows only have catalog-missing', () => {
    const provider = localProvider([model('qwen3:0.6b'), model('gone')], [model('llama3', { nativeFileMimes: ['application/pdf'] })]);
    provider.catalogModels = provider.catalogModels.filter((item) => item.id !== 'gone');
    const b = board(provider);
    expect(rowOf(b, 'llama3').status).toBeNull();
    expect(rowOf(b, 'qwen3:0.6b').status).toBeNull();
    expect(rowOf(b, 'gone').status).toBe('missingFromCatalog');
  });
});

describe('BOARD-CATALOG-06 relay five capabilities, three states', () => {
  function relayWith(item: AIModel): Provider {
    const provider = relayProvider([item], []);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    return provider;
  }
  // Vision / file only honor negative cache v2 (key and verdict revision come from the production write target); tool still uses the v1 toolCall tier.
  const negative = (provider: Provider, item: AIModel, kind: 'image' | 'file' | 'toolCall', at = NOW) => {
    if (kind === 'toolCall') {
      recordRelayNegativeCache({
        connectionId: provider.id, modelId: item.id, transport: effectiveTransport(provider, item), kind,
      }, at);
      return;
    }
    const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(item, 'automatic', false), item);
    const target = inputNegativeCacheTarget(provider, item, streamOptions, kind === 'image' ? 'vision_input' : 'file_input');
    expect(target).not.toBeNull();
    recordInputNegativeCache(target!.key, { signatureId: 'test.rejected', verdictRevision: target!.verdictRevision }, at);
  };
  // The projection and capability evidence judge negative cache expiry by Date.now(): this group pins the clock at NOW (faking Date only).
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(NOW);
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('BOARD-CATALOG-06 order image / file / thinking / tool / web', () => {
    expect(RELAY_CATALOG_CAPS).toEqual(['image', 'file', 'thinking', 'tool', 'web']);
    const provider = relayWith(model('blank'));
    expect(rowOf(board(provider), 'blank').caps.map((cap) => cap.cap)).toEqual(['image', 'file', 'thinking', 'tool', 'web']);
  });

  it('BOARD-CATALOG-06 vision: no evidence -> unknown; negative cache -> unsupported; a tested override cannot beat the negative cache, a user override does', () => {
    const blank = model('blank');
    const provider = relayWith(blank);
    expect(capsOf(rowOf(board(provider), 'blank')).image).toBe('unknown');
    negative(provider, blank, 'image');
    expect(capsOf(rowOf(board(provider), 'blank')).image).toBe('unsupported');

    const tested = model('blank', { relayCapabilityOverrides: { image: { value: true, source: 'tested' } } });
    const withTested = { ...provider, models: [tested], catalogModels: [tested] };
    expect(capsOf(rowOf(board(withTested), 'blank')).image).toBe('supported');
    negative(withTested, tested, 'image');
    expect(capsOf(rowOf(board(withTested), 'blank')).image).toBe('unsupported');

    const added = model('blank', {
      capabilityOverrides: { vision_input: { op: 'add', setAt: new Date(NOW).toISOString(), baseVerdict: 'unknown' } },
    });
    const withAdded = { ...provider, models: [added], catalogModels: [added] };
    negative(withAdded, added, 'image');
    expect(capsOf(rowOf(board(withAdded), 'blank')).image).toBe('supported');
  });

  it('BOARD-CATALOG-06 file: allowlist -> supported; unexpired negative cache -> unsupported; once expired it returns to the allowlist', () => {
    const item = model('files', { nativeFileMimes: ['application/pdf'] });
    const provider = relayWith(item);
    expect(capsOf(rowOf(board(provider), 'files')).file).toBe('supported');
    negative(provider, item, 'file', NOW - RELAY_NEGATIVE_CACHE_TTL_MS - 1);
    expect(capsOf(rowOf(board(provider), 'files')).file).toBe('supported');
    negative(provider, item, 'file');
    expect(capsOf(rowOf(board(provider), 'files')).file).toBe('unsupported');
  });

  it('BOARD-CATALOG-06 a file override comes before the negative cache and the allowlist: On + file negative cache -> supported; Off + non-empty allowlist -> unsupported', () => {
    const on = model('file-on', { relayCapabilityOverrides: { file: { value: true, source: 'user' } } });
    const onProvider = relayWith(on);
    negative(onProvider, on, 'file');
    expect(capsOf(rowOf(board(onProvider), 'file-on')).file).toBe('supported');
    // A tested override cannot beat the negative cache.
    const tested = model('file-tested', { relayCapabilityOverrides: { file: { value: true, source: 'tested' } } });
    const testedProvider = relayWith(tested);
    expect(capsOf(rowOf(board(testedProvider), 'file-tested')).file).toBe('supported');
    negative(testedProvider, tested, 'file');
    expect(capsOf(rowOf(board(testedProvider), 'file-tested')).file).toBe('unsupported');

    const off = model('file-off', {
      nativeFileMimes: ['application/pdf'],
      relayCapabilityOverrides: { file: { value: false, source: 'user' } },
    });
    expect(capsOf(rowOf(board(relayWith(off)), 'file-off')).file).toBe('unsupported');
  });

  it('BOARD-CATALOG-06 thinking: adjustable levels -> supported; recipe unavailable is not treated as unsupported -> unknown', () => {
    const provider = relayWith(model('thinker'));
    mocks.reasoningState = 'auto_available';
    expect(capsOf(rowOf(board(provider), 'thinker')).thinking).toBe('supported');
    mocks.reasoningState = 'unavailable';
    expect(capsOf(rowOf(board(provider), 'thinker')).thinking).toBe('unknown');
  });

  it('BOARD-CATALOG-06 tools: negative cache -> unsupported', () => {
    const item = model('tools');
    const provider = relayWith(item);
    expect(capsOf(rowOf(board(provider), 'tools')).tool).toBe('unknown');
    negative(provider, item, 'toolCall');
    expect(capsOf(rowOf(board(provider), 'tools')).tool).toBe('unsupported');
  });

  it('BOARD-CATALOG-06 production component: each row has five icons with three states', () => {
    const item = model('files', { nativeFileMimes: ['application/pdf'] });
    const provider = relayWith(item);
    negative(provider, item, 'toolCall');
    const { container } = openLibrary(provider);
    const icons = [...container.querySelectorAll('[data-catalog-row="files"] [data-cap-icon]')];
    expect(icons.map((icon) => [icon.getAttribute('data-cap-icon'), icon.getAttribute('data-cap-state')])).toEqual([
      ['image', 'unknown'], ['file', 'supported'], ['thinking', 'unknown'], ['tool', 'unsupported'], ['web', 'unknown'],
    ]);
  });
});

describe('BOARD-CATALOG-07 local engine declarations (the production connector against shared fixtures)', () => {
  type RecordedExchange = {
    request: { method: string; path: string; body?: { model?: string } };
    response: { status: number; contentType: string; body?: unknown; text?: string };
  };
  type DeclarationCase = {
    caseId: string;
    engine: string;
    modelId: string;
    inChatCatalog?: boolean;
    expect?: { image: boolean | null; toolCall: boolean | null; thinking: boolean | null };
  };

  function fixture<T>(name: string): T {
    let directory = process.cwd();
    while (path.dirname(directory) !== directory) {
      const candidate = path.join(directory, 'shared/test-fixtures/local-engine', name);
      if (fs.existsSync(candidate)) return JSON.parse(fs.readFileSync(candidate, 'utf8')) as T;
      directory = path.dirname(directory);
    }
    throw new Error(`local engine fixture ${name} not found`);
  }

  const recordings = fixture<{ engines: Record<string, { records: RecordedExchange[] }> }>('engine-declarations.v1.json');
  const cases = fixture<{ declarations: { cases: DeclarationCase[] } }>('engine-expectations.v1.json')
    .declarations.cases.filter((item) => item.engine === 'ollama' && item.inChatCatalog !== false && item.expect);

  /** Fake server: replies only with the recorded original text; paths not listed return 404 text/plain. */
  function serveOllama() {
    const served = recordings.engines.ollama!.records;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = new URL(String(input));
      const method = init?.method ?? 'GET';
      const requestedModel = typeof init?.body === 'string'
        ? (JSON.parse(init.body) as { model?: string }).model
        : undefined;
      const hit = served.find((record) => record.request.method === method
        && record.request.path === url.pathname
        && (record.request.body?.model === undefined || record.request.body.model === requestedModel));
      if (!hit) return new Response('404 page not found', { status: 404, headers: { 'content-type': 'text/plain' } });
      const payload = hit.response.body !== undefined ? JSON.stringify(hit.response.body) : hit.response.text ?? '';
      return new Response(payload, { status: hit.response.status, headers: { 'content-type': hit.response.contentType } });
    });
    mocks.sendMessageStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream<string>({
        start(controller) {
          controller.enqueue('ok');
          controller.close();
        },
      }),
    });
  }

  beforeEach(() => {
    Object.defineProperty(navigator, 'permissions', {
      configurable: true,
      value: { query: vi.fn().mockResolvedValue({ state: 'granted' }) },
    });
  });

  it('BOARD-CATALOG-07 declaration true -> supported, declaration false -> unsupported (image / tool / thinking)', async () => {
    expect(cases.length).toBeGreaterThan(0);
    serveOllama();
    const connected = await connectLocalEngineInBrowser({
      engine: 'ollama', endpoint: 'http://127.0.0.1:18080', securityMode: 'local_http',
    });
    expect(connected).toMatchObject({ state: 'ready' });
    // The same shape as when the add page saves: the model objects produced by the production connector + per-model declarations.
    const models: AIModel[] = connected.models.map((runtime) => ({
      ...createRelayManualModel(runtime.id),
      ...(runtime.engineDeclaration ? { engineDeclaration: runtime.engineDeclaration } : {}),
    }));
    const provider = localProvider(models.slice(0, 1), models.slice(1));
    provider.baseURLText = connected.endpoint;
    provider.relayRequested!.resolvedAPIBaseURL = connected.apiBaseURL;
    provider.relayResolvedBaseURLText = connected.apiBaseURL;
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const b = board(provider);
    const state = (value: boolean) => (value ? 'supported' : 'unsupported');
    for (const item of cases) {
      const caps = capsOf(rowOf(b, item.modelId));
      if (item.expect!.image !== null) expect([item.caseId, caps.image]).toEqual([item.caseId, state(item.expect!.image)]);
      if (item.expect!.toolCall !== null) expect([item.caseId, caps.tool]).toEqual([item.caseId, state(item.expect!.toolCall)]);
      if (item.expect!.thinking !== null) {
        expect([item.caseId, caps.thinking]).toEqual([item.caseId, state(item.expect!.thinking)]);
      }
    }
  });
});

describe('BOARD-CATALOG-08 trailing and the Default badge', () => {
  it('BOARD-CATALOG-08 enabled [newChat, more], catalog [add], unavailable [unavailable]; enable order is not changed by a legacy isDefault', () => {
    // A relay has no default model: a legacy isDefault is not moved to the front and shows no badge.
    const provider = relayProvider(
      [model('main'), model('second', { isDefault: true })],
      [model('extra'), model('offline', { isAvailable: false })],
    );
    const b = board(provider);
    // Trailing follows the 6-4 rule: enabled rows no longer have a small arrow.
    expect(b.enabled.rows.map((row) => [row.model.id, row.trailing])).toEqual([
      ['main', ['newChat', 'more']],
      ['second', ['newChat', 'more']],
    ]);
    expect(b.library.rows.map((row) => [row.model.id, row.trailing])).toEqual([
      ['extra', ['add']],
      ['offline', ['unavailable']],
    ]);
  });

  it('BOARD-CATALOG-08 production component: a legacy isDefault model row shows no Default badge, and an enabled row has New chat + the overflow menu on the right', () => {
    const { container } = openLibrary(relayProvider([model('main', { isDefault: true }), model('second')], []));
    const main = container.querySelector('[data-catalog-row="main"]') as HTMLElement;
    expect(within(main).queryByText('pages.modelSwitcher.defaultShort')).toBeNull();
    expect(main.querySelector('[data-trailing="more"]')).not.toBeNull();
  });

  it('BOARD-CATALOG-08 production component: catalog rows are visible after a search, with add / unavailable on the right', () => {
    const { container } = openLibrary(relayProvider([], [model('extra-model'), model('extra-offline', { isAvailable: false })]));
    fireEvent.change(screen.getByRole('textbox', { name: 'searchModels' }), { target: { value: 'extra' } });
    const trailingOf = (id: string) => container.querySelector(`[data-catalog-row="${id}"] [data-trailing]`)?.getAttribute('data-trailing');
    expect(trailingOf('extra-model')).toBe('add');
    expect(trailingOf('extra-offline')).toBe('unavailable');
  });
});

/* -- Model library groups, keys, lazy-verification and manual-add cases -- */

type GroupFixture = { cases: { id: string; models: string[]; serverFamilies: Record<string, string>; expected: { id: string; label: string | null; models: string[] }[] }[] };

function groupFixture(): GroupFixture {
  let directory = process.cwd();
  while (path.dirname(directory) !== directory) {
    const candidate = path.join(directory, 'shared/test-fixtures/relay/catalog-groups.v1.json');
    if (fs.existsSync(candidate)) return JSON.parse(fs.readFileSync(candidate, 'utf8')) as GroupFixture;
    directory = path.dirname(directory);
  }
  throw new Error('catalog-groups.v1.json not found');
}

function key(id: string, extra: Partial<RelayKeyEntry> = {}): RelayKeyEntry {
  return { id, apiKey: id === 'initial' ? '' : `sk-${id}-0123456789abcdef`, ...extra };
}

/** A relay with two keys: the main key lists gpt, k-claude lists claude. */
function twoKeyProvider(enabled: AIModel[], catalogOnly: AIModel[], keys: RelayKeyEntry[] = [
  key('initial', { name: 'OpenAI', status: { state: 'ok', httpStatus: 200 } }),
  key('k-claude', { status: { state: 'invalid', httpStatus: 401 } }),
]): Provider {
  const base = relayProvider(enabled, catalogOnly);
  return {
    ...base,
    relayKeys: keys,
    catalogModels: base.catalogModels.map((item) => ({
      ...item,
      relayListedByKeyIDs: item.id.startsWith('claude') ? ['k-claude'] : ['initial'],
    })),
  };
}

describe('BOARD-CATALOG-09 model library groups = a shared pure function (family: cache by-model, then heuristic), shared with step 2', () => {
  const ids = groupFixture().cases[0]!.models;
  const catalog = ids.map((id) => model(id, { groupKey: 'legacy', groupName: 'Legacy' }));

  it('BOARD-CATALOG-09 buildModelBrowserGroups (relay) has the same group order and names as the pure function, Other uses the localized title and sits last; official is unchanged', () => {
    const expected = relayCatalogGroups(catalog, inferModelFamily);
    const groups = buildModelBrowserGroups({
      catalogModels: catalog, query: '', capFilter: null, sortBy: 'recommended', providerKind: 'relay',
      providerLabel: 'example.com', preserveCatalogOrder: true, otherGroupTitle: 'OTHER',
    });
    expect(groups.map((group) => [group.id, group.title, group.models.map((item) => item.id)]))
      .toEqual(expected.map((group) => [group.id, group.label ?? 'OTHER', group.models.map((item) => item.id)]));
    expect(groups.map((group) => group.title)).toEqual(['Anthropic', 'OpenAI', 'Google', 'DeepSeek', 'OTHER']);
    // Step 2 uses the same projection as the model library.
    const stepTwo = relayStepTwoGroups({ catalogModels: catalog, host: 'example.com', query: '', otherTitle: 'OTHER' });
    expect(stepTwo.map((group) => [group.id, group.title, group.models.map((item) => item.id)]))
      .toEqual(groups.map((group) => [group.id, group.title, group.models.map((item) => item.id)]));
    // Official providers still group by metadata groupKey.
    const official = buildModelBrowserGroups({
      catalogModels: catalog, query: '', capFilter: null, sortBy: 'recommended', providerKind: 'openRouter',
      providerLabel: 'OpenRouter',
    });
    expect(official.map((group) => group.id)).toEqual(['legacy']);
  });

  it('BOARD-CATALOG-09 production component: the catalog area is grouped by family, groups are collapsed by default, and the Other group title goes through catalogGroupOther', () => {
    const { container } = openLibrary(relayProvider([], ids.map((id) => model(id))));
    const sections = [...container.querySelectorAll('[data-catalog-section="library"] section[data-testid^="group-"]')];
    expect(sections.map((section) => section.getAttribute('data-testid'))).toEqual([
      'group-anthropic', 'group-openai', 'group-google', 'group-deepseek', 'group-other',
    ]);
    expect(sections.every((section) => section.getAttribute('data-expanded') === 'false')).toBe(true);
    expect(within(sections[4] as HTMLElement).getByText('catalogGroupOther')).toBeTruthy();
  });
});

describe('BOARD-CATALOG-10 header + key chips on enabled rows + per-key status bar', () => {
  const enabled = [model('gpt-4o', { relayKeyID: 'initial' }), model('claude-opus-4', { relayKeyID: 'k-claude' })];
  const catalogOnly = [model('gpt-4.1'), model('claude-sonnet-4-5')];

  it('BOARD-CATALOG-10 header: host - model count (enabled union catalog) - key count (only with 2 or more keys); a local connection has no avatar', () => {
    expect(relayCatalogHeader(twoKeyProvider(enabled, catalogOnly))).toMatchObject({ host: 'api.myrelay.dev', modelCount: 4, keyCount: 2 });
    expect(relayCatalogHeader(twoKeyProvider(enabled, catalogOnly)).avatar).not.toBeNull();
    expect(relayCatalogHeader(relayProvider(enabled, catalogOnly))).toMatchObject({ modelCount: 4, keyCount: null });
    expect(relayCatalogHeader(localProvider([model('llama3')], [])).avatar).toBeNull();
  });

  it('BOARD-CATALOG-10 2 or more keys: enabled rows carry a key chip (name or mask); with 1 key there is none', () => {
    const b = board(twoKeyProvider(enabled, catalogOnly));
    expect(b.enabled.rows.map((row) => [row.model.id, row.keyChip])).toEqual([
      ['gpt-4o', 'OpenAI'],
      ['claude-opus-4', 'sk-k…cdef'],
    ]);
    expect(b.library.rows.every((row) => row.keyChip === null)).toBe(true);
    expect(board(relayProvider(enabled, catalogOnly)).enabled.rows.every((row) => row.keyChip === null)).toBe(true);
  });

  it('BOARD-CATALOG-10 status bar: an ok key shows a check + catalog count; a failed key shows "<code> <status word>" + Retry; an unchecked key has neither check nor Retry; with 1 key it does not appear', () => {
    const provider = twoKeyProvider(enabled, catalogOnly, [
      key('initial', { name: 'OpenAI', status: { state: 'ok', httpStatus: 200 } }),
      key('k-claude', { status: { state: 'invalid', httpStatus: 401 } }),
      key('k-new', { name: 'New' }),
    ]);
    expect(relayCatalogKeyStrip(provider)).toEqual([
      { id: 'initial', title: 'OpenAI', catalogCount: 2, state: 'ok', statusKey: 'pages.relayDetail.keyStatusOk', retry: false },
      { id: 'k-claude', title: 'sk-k…cdef', catalogCount: 2, state: 'failed', httpStatus: 401, statusKey: 'pages.relayDetail.keyStatusInvalid', retry: true },
      { id: 'k-new', title: 'New', catalogCount: 0, state: 'unchecked', statusKey: null, retry: false },
    ]);
    expect(relayCatalogKeyStrip(relayProvider(enabled, catalogOnly))).toEqual([]);
  });

  it('BOARD-CATALOG-10 production component: header, chips and status bar; a failed key\'s Retry refreshes only that key (onlyKeyIDs)', () => {
    const provider = twoKeyProvider(enabled, catalogOnly);
    const { container } = openLibrary(provider);
    expect(container.querySelector('[data-library-subtitle]')?.textContent)
      .toBe('api.myrelay.dev · pages.relayDetail.modelsCount({"count":4}) · pages.relayDetail.keysCount({"count":2})');
    expect(container.querySelector('[data-library-header] [data-relay-avatar]')).not.toBeNull();
    expect(container.querySelector('[data-catalog-row="claude-opus-4"] [data-key-chip]')?.textContent).toBe('sk-k…cdef');
    const strip = [...container.querySelectorAll('[data-key-strip-item]')];
    expect(strip.map((item) => item.getAttribute('data-key-strip-item'))).toEqual(['initial', 'k-claude']);
    expect(strip[0]!.querySelector('[data-key-strip-ok]')).not.toBeNull();
    expect(strip[1]!.textContent).toContain('401 pages.relayDetail.keyStatusInvalid');
    expect(within(strip[0] as HTMLElement).queryByRole('button')).toBeNull();
    fireEvent.click(within(strip[1] as HTMLElement).getByRole('button', { name: 'common.retry' }));
    expect(mocks.refreshCatalogInStore).toHaveBeenCalledWith(expect.anything(), provider, { onlyKeyIDs: ['k-claude'] });
  });
});

describe('BOARD-CATALOG-11 three new states on enabled rows: no access > verifying > not connected > existing (the lazy-verification state lives in memory only)', () => {
  const actualOps = () => vi.importActual<typeof ProbeOps>('../../../lib/core/relay-model-probe-ops');

  it('BOARD-CATALOG-11 priority: no access beats verifying, verifying beats not connected, not connected beats existing (including catalog-missing)', () => {
    const provider = twoKeyProvider(
      [
        model('gpt-4o', { relayKeyID: 'initial', relayDeniedKeyID: 'initial' }),
        model('gpt-4.1', { relayKeyID: 'initial' }),
        model('gpt-5', { relayKeyID: 'initial', relayTransport: 'openai_chat_completions', relayTransportSource: 'observed' }),
        model('gone', { relayKeyID: 'initial' }),
      ],
      [],
    );
    const withoutGone = asAuto({ ...provider, catalogModels: provider.catalogModels.filter((item) => item.id !== 'gone') });
    const probeStates = new Map<string, ProbeOps.RelayLazyProbeState>([
      ['gpt-4o', { phase: 'inFlight' }],
      ['gpt-4.1', { phase: 'inFlight' }],
      ['gpt-5', { phase: 'failed', statusCode: 404 }],
      ['gone', { phase: 'failed' }],
    ]);
    const b = relayCatalogBoard({
      provider: withoutGone, enabledModels: withoutGone.models, catalogModels: withoutGone.catalogModels,
      catalogLoaded: true, filter: 'all', now: NOW, probeStates,
    });
    expect(b.enabled.rows.map((row) => [row.model.id, row.status])).toEqual([
      ['gpt-4o', 'denied'],
      ['gpt-4.1', 'verifying'],
      ['gpt-5', 'unreachable'],
      ['gone', 'unreachable'],
    ]);
    expect(board(withoutGone).enabled.rows.map((row) => row.status)).toEqual(['denied', 'unknownUntilSent', 'verified', 'missingFromCatalog']);
  });

  it('BOARD-CATALOG-11 production lazy verification: in flight -> verifying; all candidates failed -> not connected (with reason and status code); success / rebind / re-detect clear it, and nothing is persisted', async () => {
    const ops = await actualOps();
    const provider = asAuto(twoKeyProvider([model('gpt-4o', { relayKeyID: 'initial' })], [model('gpt-4.1'), model('claude-sonnet-4-5')]));
    const store = createAppStore();
    store.getState().addProvider(provider);
    let rejectPing: ((error: unknown) => void) | undefined;
    // Family unknown -> only Chat as a candidate: one failed ping and all candidates are out.
    const ping = vi.fn(() => new Promise((_resolve, reject) => { rejectPing = reject; }));
    const settled = new Promise<boolean>((resolve) => {
      ops.enableProviderModelWithProbe(store, provider, model('gpt-4.1'), {
        ping, lookupFamily: async () => undefined, onProbeSettled: resolve,
      });
    });
    await vi.waitFor(() => expect(ping).toHaveBeenCalledTimes(1));
    expect(ops.relayLazyProbeState(provider.id, 'gpt-4.1')).toEqual({ phase: 'inFlight' });
    rejectPing!({ status: 403, message: 'Forbidden' });
    expect(await settled).toBe(false);
    expect(ops.relayLazyProbeState(provider.id, 'gpt-4.1')).toMatchObject({ phase: 'failed', statusCode: 403 });
    // Not persisted: the models in storage have no new fields at all.
    const storedModel = store.getState().providers[0]!.models.find((item) => item.id === 'gpt-4.1')!;
    expect(Object.keys(storedModel).some((field) => /probe|unreachable/i.test(field))).toBe(false);

    // Rebinding clears it; a lazy-verification success after rebinding leaves no state either.
    await ops.applyRelayKeyOperation(store, store.getState().providers[0]!, { type: 'rebind', modelID: 'gpt-4.1', keyID: 'k-claude' }, {
      ping: async () => ({}), lookupFamily: async () => undefined,
    });
    expect(ops.relayLazyProbeState(provider.id, 'gpt-4.1')).toBeUndefined();

    // Re-detect clears all of this connection's states.
    ops.__setRelayLazyProbeStateForTest(provider.id, 'gpt-4o', { phase: 'failed', statusCode: 500 });
    ops.__setRelayLazyProbeStateForTest(provider.id, 'claude-sonnet-4-5', { phase: 'failed', statusCode: 500 });
    await ops.redetectRelayModels(store, store.getState().providers[0]!, { ping: async () => ({}), lookupFamily: async () => undefined });
    expect(ops.relayLazyProbeState(provider.id, 'gpt-4o')).toBeUndefined();
    expect(ops.relayLazyProbeState(provider.id, 'claude-sonnet-4-5')).toBeUndefined();
  });

  it('BOARD-CATALOG-11 production component: "Not connected - view reason" is tappable, the dialog has a title + reason sentence + status code', async () => {
    const ops = await actualOps();
    const provider = relayProvider([model('gpt-4o')], []);
    ops.__setRelayLazyProbeStateForTest(provider.id, 'gpt-4o', { phase: 'failed', statusCode: 404, error: { message: 'model not found' } });
    try {
      const { container } = openLibrary(provider);
      const row = container.querySelector('[data-catalog-row="gpt-4o"]') as HTMLElement;
      fireEvent.click(within(row).getByRole('button', { name: RELAY_CATALOG_TEXT.status.unreachable }));
      const dialog = screen.getByRole('dialog');
      expect(within(dialog).getByText('pages.relayDetail.catalogUnreachableTitle')).toBeTruthy();
      expect(dialog.textContent).toContain('404');
      expect(dialog.textContent).toContain('model not found');
    } finally {
      ops.clearRelayLazyProbeStates(provider.id);
    }
  });
});

describe('BOARD-CATALOG-12 failure card / empty catalog / the single manual add', () => {
  const manualAdd = 'pages.relaySetup.twoStep.addModelManually';

  it('BOARD-CATALOG-12 layout: the failure card appears only for a single failed key; success but empty draws no catalog area; a local connection shows no enable hint', () => {
    const single = asAuto(relayProvider([model('a')], [model('b')]));
    expect(relayCatalogLayout({ provider: single, catalogLoadState: 'failed', libraryCount: 1 }))
      .toEqual({ failureCard: true, showLibrary: true, enableHint: 'probe' });
    // The user picked the connection protocol: enabling sends no probe, so only the second half of the hint appears.
    expect(relayCatalogLayout({ provider: relayProvider([model('a')], [model('b')]), catalogLoadState: 'loaded', libraryCount: 1 }))
      .toEqual({ failureCard: false, showLibrary: true, enableHint: 'noProbe' });
    expect(relayCatalogLayout({ provider: single, catalogLoadState: 'loaded', libraryCount: 0 }))
      .toEqual({ failureCard: false, showLibrary: false, enableHint: null });
    expect(relayCatalogLayout({ provider: twoKeyProvider([model('a')], []), catalogLoadState: 'failed', libraryCount: 0 }))
      .toEqual({ failureCard: false, showLibrary: false, enableHint: null });
    expect(relayCatalogLayout({ provider: localProvider([], [model('m')]), catalogLoadState: 'loaded', libraryCount: 1 }))
      .toEqual({ failureCard: false, showLibrary: true, enableHint: null });
  });

  it('BOARD-CATALOG-12 production component: the failure card is full width with only Retry, the old catalog still shows below it, and the only manual add on the whole page is at the page foot', () => {
    mocks.catalogLoadState = 'failed';
    const { container } = openLibrary(relayProvider([model('a')], [model('old-1'), model('old-2')]));
    const card = container.querySelector('[data-catalog-failure-card]') as HTMLElement;
    expect(within(card).getByText('pages.relayDetail.catalogFetchFailedTitle')).toBeTruthy();
    expect(within(card).getAllByRole('button').map((button) => button.textContent)).toEqual(['common.retry']);
    // The old catalog still shows after the failure card.
    const library = container.querySelector('[data-catalog-section="library"]') as HTMLElement;
    expect(library).not.toBeNull();
    expect(card.compareDocumentPosition(library) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getAllByRole('button', { name: manualAdd })).toHaveLength(1);
    expect(screen.queryByRole('button', { name: 'addModels' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'addMoreModels' })).toBeNull();
  });

  it('BOARD-CATALOG-12 production component: success but empty draws no catalog area, while the enabled area and the manual add at the page foot stay as usual; with an empty enabled area there is still only one manual add', () => {
    const { container } = openLibrary(relayProvider([model('a')], []));
    expect(container.querySelector('[data-catalog-section="library"]')).toBeNull();
    expect(container.querySelector('[data-catalog-failure-card]')).toBeNull();
    expect(container.querySelector('[data-catalog-section="enabled"]')).not.toBeNull();
    expect(screen.getAllByRole('button', { name: manualAdd })).toHaveLength(1);
  });
});

describe('BOARD-CATALOG-13 catalog row: tapping the row = read-only advanced (zero requests), the plus = enable; enable hint', () => {
  it('BOARD-CATALOG-13 tapping a row pushes read-only advanced and sends no request on open; the plus goes through lazy-verification enable', () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const provider = asAuto(relayProvider([model('gpt-4o')], [model('gpt-4.1')]));
    const { container } = openLibrary(provider);
    expect(screen.getByText('pages.relayDetail.catalogEnableHint')).toBeTruthy();
    // Even with a single family a group header is drawn, collapsed by default: expand it first.
    expandLibraryGroups(container);
    const row = container.querySelector('[data-catalog-row="gpt-4.1"]') as HTMLElement;
    fireEvent.click(within(row).getByRole('button', { name: 'addModel: gpt-4.1' }));
    expect(mocks.enableWithProbe).toHaveBeenCalledWith(expect.anything(), provider, provider.catalogModels[1], expect.objectContaining({ signal: expect.any(AbortSignal) }));

    fireEvent.click(rowOpen(row));
    expect(mocks.routerPush).toHaveBeenCalledWith('/?view=advanced&model=gpt-4.1&readonly=1');
    expect(container.querySelector('[data-advanced-page]')).not.toBeNull();
    expect(screen.getByText('pages.relayDetail.advancedReadOnlyNote')).toBeTruthy();
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(mocks.sendMessageStream).not.toHaveBeenCalled();
    expect(mocks.enableWithProbe).toHaveBeenCalledTimes(1);
  });

  it('BOARD-CATALOG-13 a local connection shows no enable hint', () => {
    openLibrary(localProvider([model('llama3')], [model('qwen3')]));
    expect(screen.queryByText('pages.relayDetail.catalogEnableHint')).toBeNull();
  });
});

describe('W4 lazy verification and re-detect carry an AbortSignal, and leaving the detail page cancels them', () => {
  it('W4 unmounting the detail page: the signals taken by lazy-verification enable and re-detect are both aborted', async () => {
    const provider = relayProvider([model('gpt-4o')], [model('gpt-4.1')]);
    const { container, unmount } = openLibrary(provider);
    expandLibraryGroups(container);
    const row = container.querySelector('[data-catalog-row="gpt-4.1"]') as HTMLElement;
    fireEvent.click(within(row).getByRole('button', { name: 'addModel: gpt-4.1' }));
    const enableSignal = (mocks.enableWithProbe.mock.calls[0]![3] as { signal: AbortSignal }).signal;
    expect(enableSignal.aborted).toBe(false);
    unmount();
    expect(enableSignal.aborted).toBe(true);

    // Re-detect (the detail board button) carries the page-level signal as well.
    mocks.redetect.mockImplementation(() => new Promise(() => {}));
    const second = render(<RelayDetail provider={provider} />);
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.detectAgain' }));
    const redetectSignal = (mocks.redetect.mock.calls[0]![2] as { signal: AbortSignal }).signal;
    expect(redetectSignal.aborted).toBe(false);
    second.unmount();
    expect(redetectSignal.aborted).toBe(true);
  });
});

/* -- Row model tapTarget / trailing / menu / screen-reader value / enable hint / add all -- */

describe('BOARD-CATALOG-14 row model tapTarget and trailing', () => {
  it('BOARD-CATALOG-14 enabled rows (including unavailable) -> advanced + [newChat, more]; catalog rows -> readOnlyAdvanced + [add] / [unavailable]', () => {
    const provider = relayProvider(
      [model('main'), model('offline-enabled', { isAvailable: false })],
      [model('extra'), model('offline', { isAvailable: false })],
    );
    const b = board(provider);
    expect(b.enabled.rows.map((row) => [row.model.id, row.tapTarget, row.trailing])).toEqual([
      ['main', 'advanced', ['newChat', 'more']],
      ['offline-enabled', 'advanced', ['newChat', 'more']],
    ]);
    expect(b.library.rows.map((row) => [row.model.id, row.tapTarget, row.trailing])).toEqual([
      ['extra', 'readOnlyAdvanced', ['add']],
      ['offline', 'readOnlyAdvanced', ['unavailable']],
    ]);
    // A local connection uses the same set.
    const local = board(localProvider([model('llama3')], [model('qwen3')]));
    expect(local.enabled.rows[0]).toMatchObject({ tapTarget: 'advanced', trailing: ['newChat', 'more'] });
    expect(local.library.rows[0]).toMatchObject({ tapTarget: 'readOnlyAdvanced', trailing: ['add'] });
  });
});

describe('BOARD-CATALOG-14b the view dispatches row taps only by tapTarget', () => {
  it('BOARD-CATALOG-14b production component: tapping an enabled row enters writable advanced; the trailing has New chat and the overflow menu; there is no x and no small arrow', () => {
    const { container } = openLibrary(relayProvider([model('gpt-4o'), model('gpt-4.1')], [model('gpt-5')]));
    const row = container.querySelector('[data-catalog-row="gpt-4o"]') as HTMLElement;
    expect([...row.querySelectorAll('[data-trailing]')].map((item) => item.getAttribute('data-trailing'))).toEqual(['newChat', 'more']);
    expect(row.querySelector('[data-trailing="chevron"]')).toBeNull();
    expect(within(row).queryByRole('button', { name: 'removeModel' })).toBeNull();
    // The per-model generation-parameters button has moved into the Parameters row of the detail page.
    expect(within(row).queryByRole('button', { name: 'generationParameters' })).toBeNull();

    fireEvent.click(rowOpen(row));
    expect(mocks.routerPush).toHaveBeenCalledWith('/?view=advanced&model=gpt-4o');
    expect(container.querySelector('[data-advanced-page]')).not.toBeNull();
    expect(container.querySelector('[data-advanced-readonly-note]')).toBeNull();
  });

  it('BOARD-CATALOG-14b production component: "New chat" on an enabled row opens the chat', () => {
    const { container } = openLibrary(relayProvider([model('gpt-4o')], []));
    const row = container.querySelector('[data-catalog-row="gpt-4o"]') as HTMLElement;
    fireEvent.click(row.querySelector('[data-trailing="newChat"]') as HTMLElement);
    expect(mocks.routerPush).toHaveBeenCalledWith('/chat');
  });

  it('BOARD-CATALOG-14b production component: tapping a catalog row enters read-only advanced, only the plus enables', () => {
    const provider = asAuto(relayProvider([model('gpt-4o')], [model('gpt-4.1')]));
    const { container } = openLibrary(provider);
    expandLibraryGroups(container);
    const row = container.querySelector('[data-catalog-row="gpt-4.1"]') as HTMLElement;
    fireEvent.click(rowOpen(row));
    expect(mocks.routerPush).toHaveBeenCalledWith('/?view=advanced&model=gpt-4.1&readonly=1');
    expect(mocks.enableWithProbe).not.toHaveBeenCalled();
  });

  it('BOARD-CATALOG-14b rows without a board context (official) stay as before: tapping a row = enable', async () => {
    const { ModelBrowser } = await import('./ModelBrowser');
    const onToggle = vi.fn();
    const official = model('gpt-4o');
    render(
      <ModelBrowser catalogModels={[official]} providerKind="openAI" providerLabel="OpenAI" onToggleModel={onToggle} />,
    );
    fireEvent.click(screen.getByRole('button', { name: 'addModel: gpt-4o' }));
    expect(onToggle).toHaveBeenCalledWith(official);
    expect(screen.queryByRole('button', { name: 'pages.providerDetail.addAll' })).toBeNull();
  });
});

describe('BOARD-CATALOG-15 the overflow menu has only Remove; with 1 left it is greyed out + a reason', () => {
  it('BOARD-CATALOG-15 menu model: with 2 or more models they are removable; with 1 left it is greyed out with a reason; catalog rows have none; local is the same', () => {
    const two = board(relayProvider([model('a'), model('b')], [model('c')]));
    expect(two.enabled.rows.map((row) => row.menu)).toEqual([
      [{ action: 'remove', enabled: true, reasonKey: null }],
      [{ action: 'remove', enabled: true, reasonKey: null }],
    ]);
    expect(two.library.rows[0]!.menu).toEqual([]);
    const one = board(relayProvider([model('a')], [model('c')]));
    expect(one.enabled.rows[0]!.menu).toEqual([
      { action: 'remove', enabled: false, reasonKey: RELAY_CATALOG_TEXT.removeLastReason },
    ]);
    expect(RELAY_CATALOG_TEXT.removeLastReason).toBe('pages.relayDetail.catalogRemoveLastReason');
    const local = board(localProvider([model('llama3')], []));
    expect(local.enabled.rows[0]!.menu).toEqual([
      { action: 'remove', enabled: false, reasonKey: RELAY_CATALOG_TEXT.removeLastReason },
    ]);
    // Even if only 1 row is visible after filtering, it is judged by the total number of enabled models.
    const filtered = board(relayProvider([
      model('a', { relayTransport: 'openai_responses', relayTransportSource: 'observed' }),
      model('b'),
    ], []), 'Responses');
    expect(filtered.enabled.rows.map((row) => row.menu[0]!.enabled)).toEqual([true]);
  });

  it('BOARD-CATALOG-15 production removal uses the same rule: with only 1 relay model left it is refused and nothing is written; with 2 or more it is removed as usual', () => {
    const store = createAppStore();
    const provider = relayProvider([model('only')], []);
    store.getState().addProvider(provider);
    expect(disableProviderModel(store, provider, 'only')).toBe(false);
    expect(store.getState().providers[0]!.models.map((item) => item.id)).toEqual(['only']);

    const local = localProvider([model('llama3')], []);
    store.getState().addProvider(local);
    expect(disableProviderModel(store, local, 'llama3')).toBe(false);

    const pair = { ...relayProvider([model('a'), model('b')], []), id: 'relay-pair' };
    store.getState().addProvider(pair);
    expect(disableProviderModel(store, pair, 'a')).toBe(true);
    expect(store.getState().providers.find((item) => item.id === 'relay-pair')!.models.map((item) => item.id)).toEqual(['b']);
  });

  it('BOARD-CATALOG-15 production component: the overflow menu has only Remove; with 1 left it is greyed out + a reason sentence and tapping does not remove; with 2 or more tapping Remove removes', () => {
    const single = openLibrary(relayProvider([model('only')], []));
    const row = single.container.querySelector('[data-catalog-row="only"]') as HTMLElement;
    fireEvent.click(row.querySelector('[data-trailing="more"]') as HTMLElement);
    const menu = within(row).getByRole('menu');
    const items = within(menu).getAllByRole('menuitem');
    expect(items.map((item) => item.textContent)).toEqual(['common.remove']);
    expect((items[0] as HTMLButtonElement).disabled).toBe(true);
    expect(within(menu).getByText('pages.relayDetail.catalogRemoveLastReason')).toBeTruthy();
    fireEvent.click(items[0]!);
    expect(mocks.removeModel).not.toHaveBeenCalled();
    single.unmount();

    const pair = openLibrary(relayProvider([model('a'), model('b')], []));
    const rowA = pair.container.querySelector('[data-catalog-row="a"]') as HTMLElement;
    fireEvent.click(rowA.querySelector('[data-trailing="more"]') as HTMLElement);
    const remove = within(within(rowA).getByRole('menu')).getByRole('menuitem', { name: 'common.remove' }) as HTMLButtonElement;
    expect(remove.disabled).toBe(false);
    fireEvent.click(remove);
    expect(mocks.removeModel).toHaveBeenCalledWith('a');
  });
});

describe('BOARD-CATALOG-16 three states of the enable hint', () => {
  it('BOARD-CATALOG-16 connection auto -> the full sentence (probes will be sent); connection chosen -> only the second half; local shows none', () => {
    const auto = asAuto(relayProvider([model('a')], [model('b')]));
    expect(relayCatalogLayout({ provider: auto, catalogLoadState: 'loaded', libraryCount: 1 }).enableHint).toBe('probe');
    const chosen = relayProvider([model('a')], [model('b')]);
    expect(relayCatalogLayout({ provider: chosen, catalogLoadState: 'loaded', libraryCount: 1 }).enableHint).toBe('noProbe');
    const local = localProvider([model('a')], [model('b')]);
    expect(relayCatalogLayout({ provider: local, catalogLoadState: 'loaded', libraryCount: 1 }).enableHint).toBeNull();
    expect(RELAY_CATALOG_TEXT.enableHint).toEqual({
      probe: 'pages.relayDetail.catalogEnableHint',
      noProbe: 'pages.relayDetail.catalogEnableHintNoProbe',
    });
  });

  it('BOARD-CATALOG-16 production component: a connection with a chosen protocol shows the second half', () => {
    openLibrary(relayProvider([model('gpt-4o')], [model('gpt-4.1')]));
    expect(screen.getByText('pages.relayDetail.catalogEnableHintNoProbe')).toBeTruthy();
    expect(screen.queryByText('pages.relayDetail.catalogEnableHint')).toBeNull();
  });
});

describe('BOARD-CATALOG-17 row screen-reader value', () => {
  const titles = [
    'common.modelOptionsVisionTitle',
    'common.modelOptionsFilesTitle',
    'pages.relaySetup.localTileThinking',
    'pages.relayDetail.advanced.toolCalls',
    'common.capabilityControlWebSearch',
  ];

  it('BOARD-CATALOG-17 per icon order, item by item "capability name status word", on both kinds of rows', () => {
    const provider = relayProvider(
      [model('enabled', { nativeFileMimes: ['application/pdf'], relayCapabilityOverrides: { image: { value: false, source: 'user' } } })],
      [model('catalog')],
    );
    const b = board(provider);
    const enabled = b.enabled.rows[0]!;
    expect(enabled.accessibilityValue.map((item) => item.titleKey)).toEqual(titles);
    const stateKey = { supported: 'pages.relayDetail.capabilityTest.supported', unknown: 'pages.relayDetail.advanced.unknown', unsupported: 'pages.relayDetail.capabilityTest.unsupported' };
    expect(enabled.accessibilityValue.map((item) => item.stateKey)).toEqual(enabled.caps.map((cap) => stateKey[cap.state]));
    expect(capsOf(enabled)).toMatchObject({ image: 'unsupported', file: 'supported' });
    expect(b.library.rows[0]!.accessibilityValue.map((item) => item.titleKey)).toEqual(titles);
  });

  it('BOARD-CATALOG-17 production component: the row button screen-reader text = model name + "capability name status word" joined with ", "; icons are aria-hidden', () => {
    const { container } = openLibrary(relayProvider([model('gpt-4o')], [model('gpt-4.1')]));
    expandLibraryGroups(container);
    for (const id of ['gpt-4o', 'gpt-4.1']) {
      const row = container.querySelector(`[data-catalog-row="${id}"]`) as HTMLElement;
      const label = rowOpen(row).getAttribute('aria-label')!;
      const parts = label.split(', ');
      expect(parts[0]).toBe(id);
      expect(parts.slice(1).map((part) => part.split(' ')[0])).toEqual(titles);
      expect([...row.querySelectorAll('[data-cap-icon]')].every((icon) => icon.getAttribute('aria-hidden') === 'true')).toBe(true);
    }
  });
});

describe('BOARD-CATALOG-18 group header add all', () => {
  it('BOARD-CATALOG-18 enableAllModelIDs = not enabled AND available AND the key it lands on is not judged no-access (listed under another key still counts); order follows the group rows', () => {
    const provider = twoKeyProvider(
      [model('gpt-4o', { relayKeyID: 'initial' })],
      [
        model('claude-b'),
        model('claude-denied', { relayDeniedKeyID: 'k-claude' }),
        model('claude-other-denied', { relayDeniedKeyID: 'initial' }),
        model('claude-offline', { isAvailable: false }),
        model('claude-a'),
      ],
    );
    const group = provider.catalogModels.filter((item) => item.id.startsWith('claude') || item.id === 'gpt-4o');
    expect(relayCatalogEnableAllModelIDs(provider, group)).toEqual(['claude-b', 'claude-other-denied', 'claude-a']);
    expect(relayCatalogEnableAllModelIDs(provider, [provider.catalogModels[0]!])).toEqual([]);
  });

  it('BOARD-CATALOG-18 production component: a relay group header shows "Add All", and none shows when the group has nothing enablable', () => {
    const provider = relayProvider([model('gpt-4o')], [model('gpt-4.1'), model('claude-offline', { isAvailable: false })]);
    const { container } = openLibrary(provider);
    const groups = [...container.querySelectorAll('[data-testid^="group-"]')] as HTMLElement[];
    expect(groups.length).toBe(2);
    const withButton = groups.filter((group) => within(group).queryByRole('button', { name: 'pages.providerDetail.addAll' }));
    expect(withButton).toHaveLength(1);
    expect(withButton[0]!.textContent).toContain('1');
  });

  it('BOARD-CATALOG-18 production component: even with a single family a group header is drawn with "Add All"; local is the same', () => {
    const single = openLibrary(asAuto(relayProvider([model('gpt-4o')], [model('gpt-4.1'), model('gpt-5')])));
    const groups = [...single.container.querySelectorAll('[data-catalog-section="library"] section[data-testid^="group-"]')] as HTMLElement[];
    expect(groups).toHaveLength(1);
    expect(within(groups[0]!).getByRole('button', { name: 'pages.providerDetail.addAll' })).toBeTruthy();
    single.unmount();

    const local = openLibrary(localProvider([model('llama3')], [model('qwen3')]));
    const localGroups = [...local.container.querySelectorAll('[data-catalog-section="library"] section[data-testid^="group-"]')] as HTMLElement[];
    expect(localGroups).toHaveLength(1);
    expect(within(localGroups[0]!).getByRole('button', { name: 'pages.providerDetail.addAll' })).toBeTruthy();
  });
});

describe('BOARD-CATALOG-19 add all: the production path writes back once with zero probes (connection auto)', () => {
  it('BOARD-CATALOG-19 appends what the group can enable, writes the connection back only once, key ownership is the same as a single enable, zero probes, and returns the number added', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const ops = await vi.importActual<typeof ProbeOps>('../../../lib/core/relay-model-probe-ops');
    const provider = asAuto(twoKeyProvider(
      [model('gpt-4o', { relayKeyID: 'initial', isManual: true })],
      [model('claude-sonnet-4-5'), model('claude-opus-4-1'), model('gpt-4.1')],
    ));
    const store = createAppStore();
    store.getState().addProvider(provider);
    const updateSpy = vi.spyOn(store.getState(), 'updateProvider');
    const latest = store.getState().providers[0]!;
    const group = latest.catalogModels.filter((item) => item.id.startsWith('claude'));

    expect(enableProviderModels(store, latest, group)).toBe(2);
    expect(updateSpy).toHaveBeenCalledTimes(1);
    const stored = store.getState().providers[0]!;
    // Manually entered models are kept, and the additions are appended after them.
    expect(stored.models.map((item) => [item.id, item.relayKeyID])).toEqual([
      ['gpt-4o', 'initial'],
      ['claude-sonnet-4-5', 'k-claude'],
      ['claude-opus-4-1', 'k-claude'],
    ]);
    expect(stored.models.every((item) => item.relayTransport === undefined && item.relayTransportSource === undefined)).toBe(true);
    for (const id of ['claude-sonnet-4-5', 'claude-opus-4-1']) expect(ops.relayLazyProbeState(provider.id, id)).toBeUndefined();
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(mocks.sendMessageStream).not.toHaveBeenCalled();
    // Everything already enabled: returns 0 and writes nothing.
    expect(enableProviderModels(store, stored, group)).toBe(0);
    expect(updateSpy).toHaveBeenCalledTimes(1);

    // For contrast: enabling a single model probes.
    const ping = vi.fn(async () => ({}));
    ops.enableProviderModelWithProbe(store, store.getState().providers[0]!, latest.catalogModels.find((item) => item.id === 'gpt-4.1')!, {
      ping, lookupFamily: async () => undefined,
    });
    await vi.waitFor(() => expect(ping).toHaveBeenCalledTimes(1));
    ops.clearRelayLazyProbeStates(provider.id);
  });

  it('BOARD-CATALOG-19 production component: tapping Add All writes once and toasts "Added N models"', async () => {
    const { showToast } = await import('../../../components/Toast');
    // Two families: take the group with two models and tap Add All.
    const provider = asAuto(relayProvider([model('gpt-4o')], [model('claude-sonnet-4-5'), model('claude-opus-4-1'), model('gpt-4.1')]));
    const store = createAppStore();
    store.getState().addProvider(provider);
    mocks.store = store;
    const updateSpy = vi.spyOn(store.getState(), 'updateProvider');
    const { container } = openLibrary(provider);
    const group = ([...container.querySelectorAll('[data-testid^="group-"]')] as HTMLElement[])
      .find((item) => item.textContent?.includes('2') && within(item).queryByRole('button', { name: 'pages.providerDetail.addAll' }))!;
    fireEvent.click(within(group).getByRole('button', { name: 'pages.providerDetail.addAll' }));
    expect(updateSpy).toHaveBeenCalledTimes(1);
    expect(store.getState().providers[0]!.models.map((item) => item.id)).toEqual(['gpt-4o', 'claude-sonnet-4-5', 'claude-opus-4-1']);
    expect(mocks.enableWithProbe).not.toHaveBeenCalled();
    expect(vi.mocked(showToast)).toHaveBeenLastCalledWith('pages.relayDetail.catalogAddedModels({"count":2})', 3000, undefined, 'success');
  });
});

describe('BOARD-CATALOG-20 key(id) filter', () => {
  const enabled = [model('gpt-4o', { relayKeyID: 'initial' }), model('claude-opus-4', { relayKeyID: 'k-claude' })];
  const catalogOnly = [model('gpt-4.1'), model('claude-sonnet-4-5')];

  it('BOARD-CATALOG-20 criterion = the lister includes that key (default = the main key); the enabled section uses the same criterion; counts unchanged; the chip sits after All', () => {
    const base = twoKeyProvider(enabled, catalogOnly);
    // gpt-4.1 is listed by both keys; deepseek carries no lister (default = the main key).
    const provider: Provider = {
      ...base,
      catalogModels: [
        ...base.catalogModels.map((item) => (item.id === 'gpt-4.1' ? { ...item, relayListedByKeyIDs: ['initial', 'k-claude'] } : item)),
        model('deepseek-chat'),
      ],
    };
    const b = board(provider, { key: 'k-claude' });
    expect(b.filter).toEqual({ key: 'k-claude' });
    expect(b.chips).toEqual(['all', { key: 'k-claude' }]);
    expect(b.filterKeyTitle).toBe('sk-k…cdef');
    expect(b.enabled.rows.map((row) => row.model.id)).toEqual(['claude-opus-4']);
    expect(b.library.rows.map((row) => row.model.id)).toEqual(['gpt-4.1', 'claude-sonnet-4-5']);
    expect(b.enabled.count).toBe(2);
    expect(b.library.count).toBe(3);

    const primary = board(provider, { key: 'initial' });
    expect(primary.filterKeyTitle).toBe('OpenAI');
    expect(primary.enabled.rows.map((row) => row.model.id)).toEqual(['gpt-4o']);
    expect(primary.library.rows.map((row) => row.model.id)).toEqual(['gpt-4.1', 'deepseek-chat']);
    // When not in effect there is no key chip.
    expect(board(provider).chips).toEqual([]);
    expect(board(provider).filterKeyTitle).toBeNull();
  });

  it('BOARD-CATALOG-20 coexists with protocol chips: All, key, protocol; a single (implicit) key can also be filtered by key', () => {
    const provider = twoKeyProvider(enabled, [...catalogOnly, model('claude-haiku', { relayTransport: 'anthropic_messages' })]);
    expect(board(provider, { key: 'k-claude' }).chips).toEqual(['all', { key: 'k-claude' }, 'Chat', 'Messages']);
    const single = board(relayProvider([model('a')], [model('b')]), { key: 'initial' });
    expect(single.filter).toEqual({ key: 'initial' });
    expect(single.chips).toEqual(['all', { key: 'initial' }]);
    expect(single.library.rows.map((row) => row.model.id)).toEqual(['b']);
  });

  it('BOARD-CATALOG-20 the key no longer exists or its catalog is 0 -> falls back to All, the chip does not appear', () => {
    const provider = twoKeyProvider(enabled, catalogOnly, [
      key('initial', { name: 'OpenAI' }),
      key('k-claude'),
      key('k-new', { name: 'New' }),
    ]);
    for (const filter of [{ key: 'gone' }, { key: 'k-new' }]) {
      const b = board(provider, filter);
      expect(b.filter).toBe('all');
      expect(b.chips).toEqual([]);
      expect(b.filterKeyTitle).toBeNull();
      expect(b.enabled.rows).toHaveLength(2);
    }
  });

  it('BOARD-CATALOG-20 production component: chip copy catalogFilterKey(name); tapping All leaves and the chip disappears', () => {
    window.history.replaceState(null, '', '/providers/relay-catalog?view=library&key=k-claude');
    try {
      const { container } = render(<RelayDetail provider={twoKeyProvider(enabled, catalogOnly)} />);
      const chips = () => [...container.querySelectorAll('[data-catalog-chip]')].map((chip) => chip.getAttribute('data-catalog-chip'));
      expect(chips()).toEqual(['all', 'key']);
      expect(container.querySelector('[data-catalog-chip="key"]')?.textContent)
        .toBe(`${RELAY_CATALOG_TEXT.filterKey}({"name":"sk-k…cdef"})`);
      fireEvent.click(container.querySelector('[data-catalog-chip="all"]')!);
      expect(chips()).toEqual([]);
      expect(domRowIDs(container, 'enabled')).toEqual(['gpt-4o', 'claude-opus-4']);
      // Leaving the key filter drops key= from the URL, so a refresh no longer returns to the key filter.
      expect(mocks.routerReplace).toHaveBeenLastCalledWith('/providers/relay-catalog?view=library');
    } finally {
      window.history.replaceState(null, '', '/');
    }
  });
});

describe('BOARD-CATALOG-21 entering the model library by key(id)', () => {
  const enabled = [model('gpt-4o', { relayKeyID: 'initial' }), model('claude-opus-4', { relayKeyID: 'k-claude' })];
  const catalogOnly = [model('gpt-4.1'), model('claude-sonnet-4-5')];

  it('BOARD-CATALOG-21 query string round trip: ?view=library&key=<id>', () => {
    expect(parseRelayDetailPage('?view=library&key=k-claude')).toEqual({ view: 'library', keyID: 'k-claude' });
    expect(relayDetailPageQuery({ view: 'library', keyID: 'k-claude' })).toBe('?view=library&key=k-claude');
    expect(parseRelayDetailPage('?view=library')).toEqual({ view: 'library' });
    expect(relayDetailPageQuery({ view: 'library' })).toBe('?view=library');
  });

  it('BOARD-CATALOG-21 production component: enter with a key first, then enter without a key -> back to All (navigateTo)', () => {
    window.history.replaceState(null, '', '/providers/relay-catalog?view=keys');
    try {
      const { container } = render(<RelayDetail provider={twoKeyProvider(enabled, catalogOnly)} />);
      fireEvent.click(container.querySelector('[data-key-row="k-claude"]')!);
      fireEvent.click(within(screen.getByRole('dialog')).getAllByRole('button')[0]!);
      expect(container.querySelector('[data-catalog-chip="key"]')?.getAttribute('aria-pressed')).toBe('true');
      // Go back to the home page, then enter from the "Model library" row without a key.
      fireEvent.click(screen.getAllByRole('button', { name: 'back' })[0]!);
      fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.modelLibrary/ }));
      expect(container.querySelector('[data-catalog-chip="key"]')).toBeNull();
      expect(domRowIDs(container, 'enabled')).toEqual(['gpt-4o', 'claude-opus-4']);
    } finally {
      window.history.replaceState(null, '', '/');
    }
  });

  it('BOARD-CATALOG-21 production component: browser forward / back to a model library without a key -> back to All (popstate)', () => {
    window.history.replaceState(null, '', '/providers/relay-catalog?view=library&key=k-claude');
    try {
      const { container } = render(<RelayDetail provider={twoKeyProvider(enabled, catalogOnly)} />);
      expect(container.querySelector('[data-catalog-chip="key"]')?.getAttribute('aria-pressed')).toBe('true');
      act(() => {
        window.history.replaceState(null, '', '/providers/relay-catalog?view=library');
        window.dispatchEvent(new PopStateEvent('popstate'));
      });
      expect(container.querySelector('[data-catalog-chip="key"]')).toBeNull();
      expect(domRowIDs(container, 'enabled')).toEqual(['gpt-4o', 'claude-opus-4']);
    } finally {
      window.history.replaceState(null, '', '/');
    }
  });

  it('BOARD-CATALOG-21 production component: the first frame already has the key(id) filter selected', () => {
    window.history.replaceState(null, '', '/providers/relay-catalog?view=library&key=k-claude');
    try {
      const { container } = render(<RelayDetail provider={twoKeyProvider(enabled, catalogOnly)} />);
      expect(container.querySelector('[data-catalog-chip="key"]')?.getAttribute('aria-pressed')).toBe('true');
      expect(container.querySelector('[data-catalog-chip="all"]')?.getAttribute('aria-pressed')).toBe('false');
      expect(domRowIDs(container, 'enabled')).toEqual(['claude-opus-4']);
    } finally {
      window.history.replaceState(null, '', '/');
    }
  });
});

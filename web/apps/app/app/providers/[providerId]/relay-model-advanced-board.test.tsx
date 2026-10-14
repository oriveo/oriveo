import 'fake-indexeddb/auto';
import { fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type Attachment, type LocalEngineKind, type Provider, type RelayKeyEntry } from '@oriveo/shared';
import { effectiveAPIRoot, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { RelayDetail } from './RelayDetail';
import {
  RELAY_ADVANCED_CAPS,
  RELAY_ADVANCED_SEGMENTS,
  RELAY_ADVANCED_TEXT,
  relayModelAdvancedBoard,
  type RelayModelAdvancedBoard,
} from './relay-model-advanced-board';
import { createAppStore } from '../../../lib/core/store/app-store';
import {
  probeRelayModelTransportOnce,
  restoreAllRelayAutomatic,
  setRelayCapabilityOverride,
  setRelayModelTransport,
  setRelayReasoningLevels,
} from '../../../lib/core/relay-model-advanced-ops';
import { isRelayNegativeCached, recordRelayNegativeCache } from '../../../lib/core/chat/relay-negative-cache';
import { resolveAttachmentLine } from '../../../lib/core/attachments/attachment-transport-resolver';
import { decideAttachmentRoute } from '../../../lib/core/attachments/attachment-router';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../../lib/core/chat/stream-options';
import { presentCapabilityControl } from '../../../lib/core/chat/capability-control-presentation';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../../lib/core/providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { rememberRelayCatalogEndpointTypes } from '../../../lib/core/providers/relay-probe-candidates';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { RELAY_WEB_FRAGMENT_TEMPLATES } from '@oriveo/shared/relay/web-fragments';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import { replaceRelayWebFragments } from '../../../lib/core/chat/relay-web-fragments';
import { writeRelayWebProbeRecord } from '../../../lib/core/chat/relay-web-probe-records';

/**
 * Model > Advanced: asserts the output of relayModelAdvancedBoard, the on-disk result of the write functions,
 * the output of the three consumers via the production path (attachment routing / image-generation dispatch / thinking control resolution), and the entry and page structure of the production component.
 */

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  applyKeyOp: vi.fn(),
  /** If given, used as the capability runtime (so the reasoning recipe is judged effective); by default follows production (not loaded = empty). */
  capabilityRuntime: undefined as undefined | Record<string, unknown>,
}));

vi.mock('../../../lib/core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/metadata/metadata-client')>();
  return {
    ...actual,
    getCapabilityRuntime: () => (mocks.capabilityRuntime ?? actual.getCapabilityRuntime()) as ReturnType<typeof actual.getCapabilityRuntime>,
  };
});

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

vi.mock('../../../lib/core/relay-model-probe-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/relay-model-probe-ops')>()),
  applyRelayKeyOperation: (...args: unknown[]) => mocks.applyKeyOp(...args),
}));

vi.mock('../../../components/Toast', () => ({
  showToast: vi.fn(),
}));

/* ── Fixtures ── */

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

function relayProvider(enabled: AIModel[]): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = 'openai_chat_completions';
  requested.resolvedAPIBaseURL = 'https://api.myrelay.dev/v1';
  return {
    id: 'relay-advanced',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled],
    apiKey: 'sk-relay-secret-0123456789',
    apiKeyPreview: 'sk-r…6789',
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'https://api.myrelay.dev/v1',
    relayResolvedTransport: 'openai_chat_completions',
    relayResolvedAuthMode: 'bearer',
  };
}

function localProvider(enabled: AIModel[], engine: LocalEngineKind = 'ollama'): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'none';
  requested.securityMode = 'local_http';
  requested.transport = 'openai_chat_completions';
  requested.resolvedAPIBaseURL = 'http://127.0.0.1:11434/v1';
  requested.engineProfile = engine;
  return {
    id: 'local-advanced',
    kind: 'relay',
    customName: 'Mac mini',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled],
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

function board(provider: Provider, id: string, probe: Parameters<typeof relayModelAdvancedBoard>[0]['probe'] = null): RelayModelAdvancedBoard {
  const item = provider.models.find((entry) => entry.id === id)!;
  return relayModelAdvancedBoard({ provider, model: item, now: NOW, probe });
}

const rowOf = (b: RelayModelAdvancedBoard, cap: string) => b.capabilityRows.find((row) => row.cap === cap)!;

function storeWith(provider: Provider) {
  const store = createAppStore();
  store.getState().addProvider(provider);
  return store;
}

const stored = (store: ReturnType<typeof createAppStore>, providerID: string, id: string) => {
  const provider = store.getState().providers.find((item) => item.id === providerID)!;
  return {
    provider,
    model: provider.models.find((item) => item.id === id)!,
    catalog: provider.catalogModels.find((item) => item.id === id)!,
  };
};

const negative = (provider: Provider, item: AIModel, kind: 'image' | 'file' | 'toolCall') =>
  recordRelayNegativeCache({ connectionId: provider.id, modelId: item.id, transport: effectiveTransport(provider, item), kind }, NOW);

const isNegative = (provider: Provider, item: AIModel, kind: 'image' | 'file' | 'toolCall') =>
  isRelayNegativeCached({ connectionId: provider.id, modelId: item.id, transport: effectiveTransport(provider, item), kind }, NOW);

/**
 * Make the production thinking control resolve to non-empty levels: Relay only allows the fixed verdicts custom_only / relay_user_directory (auto_available is
 * rejected by FIXED_VERDICTS), with availableIntents = low / deep (plus the switch off), i.e. the two cells Fast / Deep. Production Relay models carry no
 * capabilityControls, so the automatic set is empty; this is only to drive the intersection logic. The v2 control vocabulary has no automatic (REASONING_INTENTS).
 */
function withReasoningRecipe(item: AIModel): AIModel {
  mocks.capabilityRuntime = { recipes: {}, sourceIndex: {}, controlDefinitions: {} };
  return {
    ...item,
    capabilityControls: {
      reasoning: { state: 'custom_only', reasonCode: 'relay_user_directory', availableIntents: ['off', 'low', 'deep'] },
    },
  } as AIModel;
}

function openLibrary(provider: Provider) {
  const view = render(<RelayDetail provider={provider} />);
  fireEvent.click(screen.getByRole('button', { name: /pages\.relayDetail\.modelLibrary/ }));
  return view;
}

/** An enabled row opens writable Advanced when tapped (CATALOG-14b; the old small trailing chevron is removed). */
function openAdvanced(provider: Provider) {
  const view = openLibrary(provider);
  fireEvent.click(view.container.querySelector('[data-catalog-section="enabled"] [data-row-open]') as HTMLElement);
  return view;
}

beforeEach(() => {
  mocks.routerPush.mockReset();
  mocks.applyKeyOp.mockReset();
  mocks.applyKeyOp.mockResolvedValue(true);
  mocks.capabilityRuntime = undefined;
  resetCapabilityEvidenceIdentitiesForTesting();
});

afterEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

/* ── Cases ── */

describe('BOARD-ADVANCED-01 page structure', () => {
  it('BOARD-ADVANCED-01 Relay: five protocol segments, five capability rows (web search after tool calling), appliesNow at the page end, four legend items', () => {
    const b = board(relayProvider([model('gpt-5.4')]), 'gpt-5.4');
    expect(b.header).toEqual({ modelName: 'gpt-5.4', host: 'api.myrelay.dev' });
    expect(RELAY_ADVANCED_SEGMENTS).toEqual(['auto', 'openai_chat_completions', 'openai_responses', 'anthropic_messages', 'gemini_generate_content']);
    expect(b.protocolRow.kind).toBe('relay');
    expect(RELAY_ADVANCED_CAPS).toEqual(['image', 'file', 'imageGeneration', 'toolCall', 'web']);
    expect(b.capabilityRows.map((row) => row.cap)).toEqual(['image', 'file', 'imageGeneration', 'toolCall', 'web']);
    // An empty automatic set shows no thinking card (ADVANCED-15); the footer becomes "changes apply immediately" (ADVANCED-16).
    expect(b.thinking).toBeNull();
    expect(b.legend).toEqual(['catalog', 'detected', 'tested', 'user']);
    expect(b.footer).toBe('appliesNow');
  });

  it('BOARD-ADVANCED-01 local: Channel is read-only, no thinking section, the legend has only engine declaration and manual setting; only llama.cpp has channelHint', () => {
    const ollama = board(localProvider([model('qwen3:0.6b')]), 'qwen3:0.6b');
    expect(ollama.protocolRow).toMatchObject({ kind: 'local', channelHint: false });
    expect(ollama.thinking).toBeNull();
    expect(ollama.legend).toEqual(['engine', 'user']);
    expect(ollama.capabilityRows).toHaveLength(5);
    // A local engine has no web search: the web row shows Unknown.
    expect(rowOf(ollama, 'web')).toMatchObject({ state: 'unknown', stateKey: RELAY_ADVANCED_TEXT.imageGenerationUnknown, source: null });

    const llama = board(localProvider([model('gemma')], 'llamacpp'), 'gemma');
    expect(llama.protocolRow).toMatchObject({ kind: 'local', channelHint: true });
  });

  it('BOARD-ADVANCED-01 production component: section order protocol -> capabilities (thinking omitted when empty), appliesNow at the page end', () => {
    const { container } = openAdvanced(relayProvider([model('gpt-5.4')]));
    const sections = [...container.querySelectorAll('[data-advanced-section]')].map((el) => el.getAttribute('data-advanced-section'));
    expect(sections).toEqual(['protocol', 'capabilities']);
    expect(container.querySelectorAll('[data-advanced-segment]')).toHaveLength(5);
    expect([...container.querySelectorAll('[data-advanced-cap]')].map((el) => el.getAttribute('data-advanced-cap')))
      .toEqual(['image', 'file', 'imageGeneration', 'toolCall', 'web']);
    expect(screen.getByText(RELAY_ADVANCED_TEXT.appliesNow)).toBeTruthy();
  });

  it('BOARD-ADVANCED-01 production component: a local connection has a read-only channel, no segments, no thinking section', () => {
    const { container } = openAdvanced(localProvider([model('gemma')], 'llamacpp'));
    expect(container.querySelectorAll('[data-advanced-segment]')).toHaveLength(0);
    expect(container.querySelector('[data-advanced-section="thinking"]')).toBeNull();
    expect(screen.getByText(RELAY_ADVANCED_TEXT.channelHint)).toBeTruthy();
  });
});

describe('BOARD-ADVANCED-02 protocol note rows', () => {
  const apiRootPath = (provider: Provider, item: AIModel) => new URL(effectiveAPIRoot(provider, item)!).pathname;

  it('BOARD-ADVANCED-02 no model-level protocol: Auto is selected, autoEquals = connection default; when the connection is fixed it reads as follow-connection with status user-set (ADVANCED-14)', () => {
    const item = model('plain');
    const provider = relayProvider([item]);
    expect(board(provider, 'plain').protocolRow).toEqual({
      kind: 'relay',
      selected: 'auto',
      autoEquals: 'Chat',
      autoEqualsConnectionDefault: true,
      status: 'setByYou',
      apiRoot: apiRootPath(provider, item),
    });
  });

  it('BOARD-ADVANCED-02 reachable / observed count as an automatic result: Auto stays selected, autoEquals = effectiveTransport', () => {
    const reachable = model('r', { relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    const observed = model('o', { relayTransport: 'anthropic_messages', relayTransportSource: 'observed' });
    const provider = relayProvider([reachable, observed]);
    expect(board(provider, 'r').protocolRow).toMatchObject({ selected: 'auto', autoEquals: 'Responses', status: 'reachable', apiRoot: apiRootPath(provider, reachable) });
    expect(board(provider, 'o').protocolRow).toMatchObject({ selected: 'auto', autoEquals: 'Messages', status: 'verified' });
  });

  it('BOARD-ADVANCED-02 user source: that protocol is selected, no autoEquals, status Set by you', () => {
    const item = model('u', { relayTransport: 'gemini_generate_content', relayTransportSource: 'user' });
    const provider = relayProvider([item]);
    expect(board(provider, 'u').protocolRow).toMatchObject({
      selected: 'gemini_generate_content', autoEquals: null, status: 'setByYou', apiRoot: apiRootPath(provider, item),
    });
  });
});

describe('BOARD-ADVANCED-03 protocol write and single-protocol probe', () => {
  it('BOARD-ADVANCED-03 choosing Chat -> user, models and catalogModels are written together; choosing Auto clears', () => {
    const provider = relayProvider([model('m', { relayTransport: 'openai_responses', relayTransportSource: 'reachable' })]);
    const store = storeWith(provider);
    expect(setRelayModelTransport(store, provider.id, 'm', 'openai_chat_completions')).toBe(true);
    let state = stored(store, provider.id, 'm');
    for (const entry of [state.model, state.catalog]) {
      expect(entry).toMatchObject({ relayTransport: 'openai_chat_completions', relayTransportSource: 'user' });
    }
    expect(board(state.provider, 'm').protocolRow).toMatchObject({ selected: 'openai_chat_completions', status: 'setByYou' });

    expect(setRelayModelTransport(store, provider.id, 'm', null)).toBe(true);
    state = stored(store, provider.id, 'm');
    for (const entry of [state.model, state.catalog]) {
      expect(entry.relayTransport).toBeUndefined();
      expect(entry.relayTransportSource).toBeUndefined();
    }
    expect(board(state.provider, 'm').protocolRow).toMatchObject({ selected: 'auto' });
  });

  it('BOARD-ADVANCED-03 probe passes -> Reachable; fails -> Not reachable and the source is still user; only this one protocol is checked', async () => {
    const provider = relayProvider([model('m')]);
    const store = storeWith(provider);
    setRelayModelTransport(store, provider.id, 'm', 'anthropic_messages');
    const current = stored(store, provider.id, 'm').provider;

    const pinged: unknown[] = [];
    const pass = await probeRelayModelTransportOnce(current, 'm', 'anthropic_messages', {
      ping: async (input) => { pinged.push(input.model); },
    });
    expect(pass).toBe('reachable');
    expect(pinged).toEqual([{ relayTransport: 'anthropic_messages' }]);
    expect(board(current, 'm', { transport: 'anthropic_messages', result: pass! }).protocolRow).toMatchObject({ status: 'reachable' });

    const fail = await probeRelayModelTransportOnce(current, 'm', 'anthropic_messages', {
      ping: async () => { throw new Error('404'); },
    });
    expect(fail).toBe('notReachable');
    expect(stored(store, provider.id, 'm').model).toMatchObject({ relayTransport: 'anthropic_messages', relayTransportSource: 'user' });
    expect(board(current, 'm', { transport: 'anthropic_messages', result: fail! }).protocolRow).toMatchObject({ status: 'notReachable' });
    // The result belongs to a different protocol (the user has switched away): discarded, not shown.
    expect(board(current, 'm', { transport: 'openai_responses', result: fail! }).protocolRow).toMatchObject({ status: 'setByYou' });
  });
});

describe('BOARD-ADVANCED-04 four automatic-status rows and source order', () => {
  function relayWith(item: AIModel): Provider {
    const provider = relayProvider([item]);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    return provider;
  }

  it('BOARD-ADVANCED-04 no evidence: vision / file / tools unknown (remembered after sending), image generation unknown uses Unknown, no source', () => {
    const b = board(relayWith(model('blank')), 'blank');
    expect(b.capabilityRows.map((row) => [row.cap, row.state, row.source, row.control])).toEqual([
      ['image', 'unknown', null, 'auto'],
      ['file', 'unknown', null, 'auto'],
      ['imageGeneration', 'unknown', null, 'auto'],
      ['toolCall', 'unknown', null, 'auto'],
      ['web', 'unknown', null, 'auto'],
    ]);
    expect(rowOf(b, 'imageGeneration').stateKey).toBe(RELAY_ADVANCED_TEXT.imageGenerationUnknown);
    expect(rowOf(b, 'image').stateKey).toBe(RELAY_ADVANCED_TEXT.state.unknown);
  });

  it('BOARD-ADVANCED-04 official catalog inheritance -> Official catalog', () => {
    const item = model('inherit', { capabilities: ['text', 'image', 'imageGeneration'], nativeFileMimes: ['application/pdf'] });
    const b = board(relayWith(item), 'inherit');
    for (const cap of ['image', 'file', 'imageGeneration']) {
      expect([cap, rowOf(b, cap).state, rowOf(b, cap).source]).toEqual([cap, 'supported', 'catalog']);
    }
  });

  it('BOARD-ADVANCED-04 unexpired negative cache -> Detected, overrides the official catalog', () => {
    const item = model('cached', { nativeFileMimes: ['application/pdf'] });
    const provider = relayWith(item);
    negative(provider, item, 'file');
    negative(provider, item, 'toolCall');
    negative(provider, item, 'image');
    const b = board(provider, 'cached');
    for (const cap of ['image', 'file', 'toolCall']) {
      expect([cap, rowOf(b, cap).state, rowOf(b, cap).source]).toEqual([cap, 'unsupported', 'detected']);
    }
  });

  it('BOARD-ADVANCED-04 tested overrides negative cache, user overrides tested; the control shows On / Off', () => {
    const item = model('ovr', {
      relayCapabilityOverrides: {
        image: { value: true, source: 'tested' },
        toolCall: { value: false, source: 'user' },
        file: { value: true, source: 'user' },
        imageGeneration: { value: false, source: 'user' },
      },
    });
    const provider = relayWith(item);
    negative(provider, item, 'image');
    const b = board(provider, 'ovr');
    expect(b.capabilityRows.map((row) => [row.cap, row.state, row.source, row.control])).toEqual([
      ['image', 'supported', 'tested', 'on'],
      ['file', 'supported', 'user', 'on'],
      ['imageGeneration', 'unsupported', 'user', 'off'],
      ['toolCall', 'unsupported', 'user', 'off'],
      ['web', 'unknown', null, 'auto'],
    ]);
  });

  it('BOARD-ADVANCED-04 engine declaration counts as a source only when there is an engineProfile', () => {
    const declared = model('qwen3:0.6b', { engineDeclaration: { image: true, toolCall: false } });
    const local = localProvider([declared]);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), local.id);
    const b = board(local, 'qwen3:0.6b');
    expect([rowOf(b, 'image').source, rowOf(b, 'toolCall').source]).toEqual(['engine', 'engine']);
    expect([rowOf(b, 'image').state, rowOf(b, 'toolCall').state]).toEqual(['supported', 'unsupported']);

    const remote = board(relayWith(declared), 'qwen3:0.6b');
    expect([rowOf(remote, 'image').source, rowOf(remote, 'toolCall').source]).toEqual([null, null]);
  });
});

describe('BOARD-ADVANCED-05 override writes', () => {
  it('BOARD-ADVANCED-05 On / Off write user (both tables) and clear only the negative cache of the same tier', () => {
    const item = model('m', { relayCapabilityOverrides: { image: { value: false, source: 'tested' } } });
    const provider = relayProvider([item]);
    const store = storeWith(provider);
    negative(provider, item, 'image');
    negative(provider, item, 'file');
    negative(provider, item, 'toolCall');

    expect(setRelayCapabilityOverride(store, provider.id, 'm', 'file', true)).toBe(true);
    let state = stored(store, provider.id, 'm');
    for (const entry of [state.model, state.catalog]) {
      expect(entry.relayCapabilityOverrides).toEqual({
        image: { value: false, source: 'tested' },
        file: { value: true, source: 'user' },
      });
    }
    expect([isNegative(provider, item, 'file'), isNegative(provider, item, 'image'), isNegative(provider, item, 'toolCall')])
      .toEqual([false, true, true]);

    setRelayCapabilityOverride(store, provider.id, 'm', 'toolCall', false);
    state = stored(store, provider.id, 'm');
    expect(state.model.relayCapabilityOverrides?.toolCall).toEqual({ value: false, source: 'user' });
    expect(isNegative(provider, item, 'toolCall')).toBe(false);
    expect(isNegative(provider, item, 'image')).toBe(true);
  });

  it('BOARD-ADVANCED-05 Auto deletes the key (both tested and user), and if everything is deleted the whole field is omitted', () => {
    const item = model('m', {
      relayCapabilityOverrides: { image: { value: false, source: 'tested' }, imageGeneration: { value: true, source: 'user' } },
    });
    const provider = relayProvider([item]);
    const store = storeWith(provider);
    setRelayCapabilityOverride(store, provider.id, 'm', 'image', null);
    expect(stored(store, provider.id, 'm').model.relayCapabilityOverrides).toEqual({ imageGeneration: { value: true, source: 'user' } });
    setRelayCapabilityOverride(store, provider.id, 'm', 'imageGeneration', null);
    const state = stored(store, provider.id, 'm');
    expect('relayCapabilityOverrides' in state.model).toBe(false);
    expect('relayCapabilityOverrides' in state.catalog).toBe(false);
  });
});

describe('BOARD-ADVANCED-06 five thinking cells', () => {
  it('BOARD-ADVANCED-06 cells outside the automatic set are not tappable; with no override the whole automatic set is selected', () => {
    const item = withReasoningRecipe(model('think'));
    const b = board(relayProvider([item]), 'think');
    expect(b.thinking).toEqual({
      kind: 'levels',
      cells: [
        { level: 'automatic', available: false, selected: false, canToggle: false },
        { level: 'fast', available: true, selected: true, canToggle: true },
        { level: 'balanced', available: false, selected: false, canToggle: false },
        { level: 'deep', available: true, selected: true, canToggle: true },
        { level: 'max', available: false, selected: false, canToggle: false },
      ],
    });
  });

  it('BOARD-ADVANCED-06 only narrows, the last cell cannot be deselected, selecting back to the full set deletes the override', () => {
    const item = withReasoningRecipe(model('think'));
    const provider = relayProvider([item]);
    const store = storeWith(provider);
    // Levels outside the automatic set are not written in.
    expect(setRelayReasoningLevels(store, provider.id, 'think', ['deep', 'balanced'])).toBe(true);
    let state = stored(store, provider.id, 'think');
    expect(state.model.relayCapabilityOverrides?.reasoningLevels).toEqual({ value: ['deep'], source: 'user' });
    expect(state.catalog.relayCapabilityOverrides?.reasoningLevels).toEqual({ value: ['deep'], source: 'user' });
    const narrowed = board(state.provider, 'think');
    expect(narrowed.thinking?.kind === 'levels' && narrowed.thinking.cells.map((cell) => [cell.level, cell.selected, cell.canToggle])).toEqual([
      ['automatic', false, false],
      ['fast', false, true],
      ['balanced', false, false],
      ['deep', true, false],
      ['max', false, false],
    ]);
    // All outside the automatic set: not written.
    expect(setRelayReasoningLevels(store, provider.id, 'think', ['max'])).toBe(false);

    expect(setRelayReasoningLevels(store, provider.id, 'think', ['deep', 'fast'])).toBe(true);
    state = stored(store, provider.id, 'think');
    expect(state.model.relayCapabilityOverrides).toBeUndefined();
  });

  it('BOARD-ADVANCED-06 automatic set empty: the whole card is hidden (ADVANCED-15); a local connection shows no section', () => {
    expect(board(relayProvider([model('plain')]), 'plain').thinking).toBeNull();
    expect(board(localProvider([withReasoningRecipe(model('local'))]), 'local').thinking).toBeNull();
  });

  it('BOARD-ADVANCED-06 production component: no thinking card when the set is empty', () => {
    const { container } = openAdvanced(relayProvider([model('plain')]));
    expect(container.querySelector('[data-advanced-section="thinking"]')).toBeNull();
    expect(container.querySelectorAll('[data-thinking-cell]')).toHaveLength(0);
  });
});

describe('BOARD-ADVANCED-07 restore all to automatic + test capabilities entry', () => {
  it('BOARD-ADVANCED-07 clears all overrides and the user protocol, not the negative cache; not tappable when there is nothing to clear', () => {
    const item = model('m', {
      relayTransport: 'openai_responses',
      relayTransportSource: 'user',
      relayCapabilityOverrides: {
        image: { value: true, source: 'tested' },
        file: { value: false, source: 'user' },
        reasoningLevels: { value: ['deep'], source: 'user' },
      },
    });
    const provider = relayProvider([item]);
    expect(board(provider, 'm').restoreAllEnabled).toBe(true);
    const store = storeWith(provider);
    negative(provider, item, 'toolCall');

    expect(restoreAllRelayAutomatic(store, provider.id, 'm')).toBe(true);
    const state = stored(store, provider.id, 'm');
    for (const entry of [state.model, state.catalog]) {
      expect(entry.relayCapabilityOverrides).toBeUndefined();
      expect(entry.relayTransport).toBeUndefined();
      expect(entry.relayTransportSource).toBeUndefined();
    }
    expect(isNegative(provider, item, 'toolCall')).toBe(true);
    expect(board(state.provider, 'm').restoreAllEnabled).toBe(false);
    expect(restoreAllRelayAutomatic(store, provider.id, 'm')).toBe(false);
  });

  it('BOARD-ADVANCED-07 a reachable protocol does not count as clearable', () => {
    const item = model('m', { relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    expect(board(relayProvider([item]), 'm').restoreAllEnabled).toBe(false);
  });

  it('BOARD-ADVANCED-07 production component: test capabilities is on the Advanced page; the model behavior expansion no longer has test / restore', () => {
    openLibrary(relayProvider([model('m')]));
    expect(screen.queryByRole('button', { name: 'capabilityTest.action' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'capabilityTest.restore' })).toBeNull();

    fireEvent.click(document.querySelector('[data-catalog-section="enabled"] [data-row-open]') as HTMLElement);
    expect(screen.getByRole('button', { name: 'capabilityTest.action' })).toBeTruthy();
    expect((screen.getByRole('button', { name: RELAY_ADVANCED_TEXT.restoreAll }) as HTMLButtonElement).disabled).toBe(true);
  });
});

describe('BOARD-ADVANCED-08 file override consumption (production attachment routing)', () => {
  const textPDF: Attachment = {
    id: 'pdf-1',
    kind: 'file',
    fileName: 'notes.pdf',
    mimeType: 'application/pdf',
    base64Data: 'extracted text',
    originalBase64Data: 'JVBERi0xLjQK',
  } as Attachment;

  async function routeOf(provider: Provider, item: AIModel) {
    const streamOptions = { relayTransport: effectiveTransport(provider, item) };
    const line = await resolveAttachmentLine({ provider, model: item, streamOptions, toolLoop: false });
    return decideAttachmentRoute(textPDF, line, item);
  }

  const responsesModel = (extra: Partial<AIModel> = {}) =>
    model('m', { relayTransport: 'openai_responses', relayTransportSource: 'user', ...extra });

  it('BOARD-ADVANCED-08 no override: empty whitelist -> text; On -> native; Off -> text', async () => {
    const plain = responsesModel();
    expect(await routeOf(relayProvider([plain]), plain)).toBe('client_extract');
    const on = responsesModel({ relayCapabilityOverrides: { file: { value: true, source: 'user' } } });
    expect(await routeOf(relayProvider([on]), on)).toBe('native');
    const off = responsesModel({
      nativeFileMimes: ['application/pdf'], pdfNativeDefault: true,
      relayCapabilityOverrides: { file: { value: false, source: 'user' } },
    });
    expect(await routeOf(relayProvider([off]), off)).toBe('client_extract');
  });

  it('BOARD-ADVANCED-08 protocol envelope does not accept native files: On is still text', async () => {
    const chat = model('m', {
      relayTransport: 'openai_chat_completions', relayTransportSource: 'user',
      relayCapabilityOverrides: { file: { value: true, source: 'user' } },
    });
    expect(await routeOf(relayProvider([chat]), chat)).toBe('client_extract');
  });

  it('BOARD-ADVANCED-08 On overrides the file negative cache', async () => {
    const withMimes = responsesModel({ nativeFileMimes: ['application/pdf'], pdfNativeDefault: true });
    const provider = relayProvider([withMimes]);
    negative(provider, withMimes, 'file');
    expect(await routeOf(provider, withMimes)).toBe('client_extract');
    const on = { ...withMimes, relayCapabilityOverrides: { file: { value: true, source: 'user' as const } } };
    expect(await routeOf(provider, on)).toBe('native');
  });
});

describe('BOARD-ADVANCED-09 image-generation override consumption (production image dispatch decision)', () => {
  it('BOARD-ADVANCED-09 true -> goes to image generation; false -> does not, even if capabilities include image generation', () => {
    const plain = model('img');
    expect(buildStreamOptionsFromIntent(plain, 'automatic', false)?.supportsImageGen ?? false).toBe(false);
    const forced = model('img', { relayCapabilityOverrides: { imageGeneration: { value: true, source: 'user' } } });
    expect(buildStreamOptionsFromIntent(forced, 'automatic', false)?.supportsImageGen).toBe(true);
    const capable = model('img', { capabilities: ['text', 'imageGeneration'], imageGenProfile: 'default' });
    expect(buildStreamOptionsFromIntent(capable, 'automatic', false)?.supportsImageGen).toBe(true);
    const disabled = { ...capable, relayCapabilityOverrides: { imageGeneration: { value: false, source: 'user' as const } } };
    expect(buildStreamOptionsFromIntent(disabled, 'automatic', false)?.supportsImageGen).toBe(false);
  });
});

describe('BOARD-ADVANCED-09 forced streaming for image generation follows the image-generation override', () => {
  it('BOARD-ADVANCED-09 Responses route: override On (capabilities lack image generation) -> forced streaming; override Off (capabilities include it) -> not forced', () => {
    const forced = model('img', {
      relayTransport: 'openai_responses', relayTransportSource: 'user',
      relayCapabilityOverrides: { imageGeneration: { value: true, source: 'user' } },
    });
    const driver = model('chat-driver');
    // The connection itself turned streaming off: relayStream can only come from the image-generation force.
    const streamOff = (models: AIModel[]): Provider => {
      const base = relayProvider(models);
      return { ...base, relayRequested: { ...base.relayRequested!, stream: false } };
    };
    const provider = streamOff([forced, driver]);
    const on = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(forced, 'automatic', false), forced);
    expect(on?.relayStream).toBe(true);

    const disabled = model('img', {
      capabilities: ['text', 'imageGeneration'], imageGenProfile: 'default',
      relayTransport: 'openai_responses', relayTransportSource: 'user',
      relayCapabilityOverrides: { imageGeneration: { value: false, source: 'user' } },
    });
    const off = buildProviderStreamOptions(streamOff([disabled, driver]), buildStreamOptionsFromIntent(disabled, 'automatic', false), disabled);
    expect(off?.relayStream).toBe(false);
  });
});

describe('BOARD-ADVANCED-10 thinking-level override consumption (production thinking control resolution)', () => {
  it('BOARD-ADVANCED-10 available levels = automatic ∩ override; the switch toggle does not take part in narrowing', () => {
    const item = withReasoningRecipe(model('think'));
    const provider = relayProvider([item]);
    expect(presentCapabilityControl(provider, item, 'reasoning').availableIntents).toEqual(['off', 'low', 'deep']);
    const narrowed = { ...item, relayCapabilityOverrides: { reasoningLevels: { value: ['fast', 'max'], source: 'user' as const } } };
    expect(presentCapabilityControl(provider, narrowed, 'reasoning').availableIntents).toEqual(['off', 'low']);
    // The panel and this page share one source: this page draws its cells from the same resolved set.
    const b = board({ ...provider, models: [narrowed] }, 'think');
    expect(b.thinking?.kind === 'levels' && b.thinking.cells.filter((cell) => cell.selected).map((cell) => cell.level)).toEqual(['fast']);
  });
});

describe('BOARD-ADVANCED-11 enabled row entry', () => {
  it('BOARD-ADVANCED-11 tapping the row opens Advanced; the row-end new-conversation opens chat (replaces the old "tap row opens chat, chevron opens Advanced")', () => {
    const provider = relayProvider([model('gpt-5.4')]);
    const { container } = openLibrary(provider);
    const row = container.querySelector('[data-catalog-row="gpt-5.4"]') as HTMLElement;
    fireEvent.click(within(row).getByRole('button', { name: 'chatWithModel({"model":"gpt-5.4"})' }));
    expect(mocks.routerPush).toHaveBeenCalledWith('/chat');

    fireEvent.click(row.querySelector('[data-row-open]') as HTMLElement);
    expect(container.querySelector('[data-advanced-page]')).not.toBeNull();
    expect(screen.getAllByText('gpt-5.4').length).toBeGreaterThan(0);
  });
});

/* ── Key section and key rebinding ── */

function twoKeys(enabled: AIModel[], catalog: AIModel[]): Provider {
  const keys: RelayKeyEntry[] = [
    { id: 'initial', name: 'OpenAI', apiKey: '' },
    { id: 'k-b', apiKey: 'sk-kb-0123456789abcdef' },
  ];
  return { ...relayProvider(enabled), relayKeys: keys, catalogModels: catalog };
}

describe('BOARD-ADVANCED-12 Key section under the protocol section when there are >=2 keys', () => {
  afterEach(() => {
    window.history.replaceState(null, '', '/');
  });
  const listedByBoth = (id: string) => model(id, { relayListedByKeyIDs: ['initial', 'k-b'] });

  it('BOARD-ADVANCED-12 current binding (name or mask + mask), menu Auto + each key; Auto = recompute by the rules after removing this model', () => {
    // gpt-4.1 is the same family and bound to k-b: after removing gpt-4o recompute -> k-b; gpt-4o is currently bound to initial != the rule result -> the menu shows initial.
    const provider = twoKeys(
      [model('gpt-4o', { relayKeyID: 'initial' }), model('gpt-4.1', { relayKeyID: 'k-b' })],
      [listedByBoth('gpt-4o'), listedByBoth('gpt-4.1')],
    );
    const section = board(provider, 'gpt-4o').keySection!;
    expect(section).toEqual({
      current: { id: 'initial', title: 'OpenAI', preview: 'sk-r…6789' },
      selected: 'initial',
      autoKeyID: 'k-b',
      options: [
        { id: 'initial', title: 'OpenAI', preview: 'sk-r…6789' },
        { id: 'k-b', title: 'sk-k…cdef', preview: 'sk-k…cdef' },
      ],
    });
    // When the current binding equals the rule result the menu shows Auto.
    const followsRule = { ...provider, models: [model('gpt-4o', { relayKeyID: 'k-b' }), model('gpt-4.1', { relayKeyID: 'k-b' })] };
    expect(board(followsRule, 'gpt-4o').keySection).toMatchObject({ selected: 'auto', autoKeyID: 'k-b', current: { id: 'k-b' } });
  });

  it('BOARD-ADVANCED-12 with only 1 key the Key section is hidden', () => {
    expect(board(relayProvider([model('gpt-4o')]), 'gpt-4o').keySection).toBeNull();
  });

  it('BOARD-ADVANCED-12 production component: picking a key -> rebind; picking Auto -> rebind to the rule result; picking the current key writes nothing; an Auto note under the section', () => {
    const provider = twoKeys(
      [model('gpt-4o', { relayKeyID: 'initial' }), model('gpt-4.1', { relayKeyID: 'k-b' })],
      [listedByBoth('gpt-4o'), listedByBoth('gpt-4.1')],
    );
    window.history.replaceState(null, '', '/providers/relay-advanced?view=advanced&model=gpt-4o');
    const { container } = render(<RelayDetail provider={provider} />);
    const section = container.querySelector('[data-advanced-section="key"]') as HTMLElement;
    expect(section).not.toBeNull();
    // The Key section comes after the protocol section and before the capability section (thinking omitted when the automatic set is empty).
    expect([...container.querySelectorAll('[data-advanced-section]')].map((item) => item.getAttribute('data-advanced-section')))
      .toEqual(['protocol', 'key', 'capabilities']);
    expect(within(section).getByText('pages.relayDetail.advancedKeyAutoHint')).toBeTruthy();
    expect(section.textContent).toContain('OpenAI');
    const select = within(section).getByRole('combobox', { name: 'pages.relayDetail.advancedKeySection' }) as HTMLSelectElement;
    expect([...select.options].map((option) => [option.value, option.textContent])).toEqual([
      ['auto', 'pages.relayDetail.protocolAuto'],
      ['initial', 'OpenAI · sk-r…6789'],
      ['k-b', 'sk-k…cdef'],
    ]);
    expect(select.value).toBe('initial');

    fireEvent.change(select, { target: { value: 'initial' } });
    expect(mocks.applyKeyOp).not.toHaveBeenCalled();
    fireEvent.change(select, { target: { value: 'k-b' } });
    expect(mocks.applyKeyOp).toHaveBeenLastCalledWith(expect.anything(), provider, { type: 'rebind', modelID: 'gpt-4o', keyID: 'k-b' }, { signal: expect.any(AbortSignal) });
    fireEvent.change(select, { target: { value: 'auto' } });
    expect(mocks.applyKeyOp).toHaveBeenLastCalledWith(expect.anything(), provider, { type: 'rebind', modelID: 'gpt-4o', keyID: 'k-b' }, { signal: expect.any(AbortSignal) });
    expect(mocks.applyKeyOp).toHaveBeenCalledTimes(2);
  });
});

describe('BOARD-ADVANCED-13 read-only Advanced opened from a catalog row', () => {
  afterEach(() => {
    window.history.replaceState(null, '', '/');
  });

  it('BOARD-ADVANCED-13 read-only: no test-capabilities entry, the Key section shows the rule result as Auto', () => {
    const provider = twoKeys([model('gpt-4o', { relayKeyID: 'k-b' })], [model('gpt-4o', { relayListedByKeyIDs: ['initial', 'k-b'] }), model('gpt-4.1', { relayListedByKeyIDs: ['initial', 'k-b'] })]);
    const catalogOnly = provider.catalogModels[1]!;
    const b = relayModelAdvancedBoard({ provider, model: catalogOnly, now: NOW, readOnly: true });
    expect(b.readOnly).toBe(true);
    expect(b.testEntry).toBe(false);
    expect(b.keySection).toMatchObject({ selected: 'auto', autoKeyID: 'k-b', current: { id: 'k-b' } });
  });

  it('BOARD-ADVANCED-13 production component: one read-only sentence on top, protocol / capabilities / keys / thinking are all non-operable, back works, opening makes zero requests', () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const enabled = model('gpt-4o', { relayKeyID: 'initial' });
    const provider = twoKeys([enabled], [model('gpt-4o', { relayListedByKeyIDs: ['initial'] }), model('gpt-4.1', { relayListedByKeyIDs: ['initial', 'k-b'] })]);
    window.history.replaceState(null, '', '/providers/relay-advanced?view=advanced&model=gpt-4.1&readonly=1');
    const { container } = render(<RelayDetail provider={provider} />);
    const page = container.querySelector('[data-advanced-page]') as HTMLElement;
    expect(page).not.toBeNull();
    expect(page.querySelector('[data-advanced-readonly-note]')?.textContent).toBe('pages.relayDetail.advancedReadOnlyNote');
    expect(within(page).queryByRole('button', { name: 'pages.relayDetail.capabilityTest.action' })).toBeNull();
    expect(within(page).queryByText('capabilityTest.action')).toBeNull();
    const controls = [
      ...page.querySelectorAll('[data-advanced-segment]'),
      ...page.querySelectorAll('select'),
      ...page.querySelectorAll('[data-thinking-cell]'),
    ];
    expect(controls.length).toBeGreaterThan(5);
    expect(controls.every((control) => (control as HTMLButtonElement).disabled)).toBe(true);
    expect((within(page).getByRole('button', { name: RELAY_ADVANCED_TEXT.restoreAll }) as HTMLButtonElement).disabled).toBe(true);
    expect((within(page).getByRole('button', { name: 'back' }) as HTMLButtonElement).disabled).toBe(false);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(mocks.applyKeyOp).not.toHaveBeenCalled();
  });
});

/* ── Two note lines / card order / footer ── */

const asAutoConnection = (provider: Provider): Provider =>
  ({ ...provider, relayRequested: { ...provider.relayRequested!, transport: 'auto' } });

describe('BOARD-ADVANCED-14 protocol card, two note lines', () => {
  afterEach(() => {
    rememberRelayCatalogEndpointTypes('relay-advanced', undefined);
    window.history.replaceState(null, '', '/');
  });

  it('BOARD-ADVANCED-14 connection auto or the model has a detected / remembered protocol -> "Auto = X"; connection fixed and the model has no protocol of its own -> the follow-connection sentence', () => {
    const plain = model('plain');
    const reachable = model('r', { relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    const observed = model('o', { relayTransport: 'anthropic_messages', relayTransportSource: 'observed' });
    const auto = asAutoConnection(relayProvider([plain, reachable]));
    expect(board(auto, 'plain').protocolRow).toMatchObject({ selected: 'auto', autoEquals: 'Chat', autoEqualsConnectionDefault: false, status: 'unknownUntilSent' });
    expect(board(auto, 'r').protocolRow).toMatchObject({ autoEquals: 'Responses', autoEqualsConnectionDefault: false, status: 'reachable' });

    const chosen = relayProvider([plain, observed]);
    expect(board(chosen, 'plain').protocolRow).toMatchObject({ selected: 'auto', autoEquals: 'Chat', autoEqualsConnectionDefault: true, status: 'setByYou' });
    expect(board(chosen, 'o').protocolRow).toMatchObject({ autoEquals: 'Messages', autoEqualsConnectionDefault: false, status: 'verified' });
    expect(RELAY_ADVANCED_TEXT.autoEqualsConnectionDefault).toBe('pages.relayDetail.advanced.autoEqualsConnectionDefault');
  });

  it('BOARD-ADVANCED-14 model-set protocol: no line 1, line 2 = Set by you, a single test only swaps the status word', () => {
    const item = model('u', { relayTransport: 'gemini_generate_content', relayTransportSource: 'user' });
    const provider = relayProvider([item]);
    expect(board(provider, 'u').protocolRow).toMatchObject({ autoEquals: null, autoEqualsConnectionDefault: false, status: 'setByYou' });
    const statusOf = (result: 'running' | 'reachable' | 'notReachable') =>
      (board(provider, 'u', { transport: 'gemini_generate_content', result }).protocolRow as { status: string }).status;
    expect([statusOf('running'), statusOf('reachable'), statusOf('notReachable')]).toEqual(['testing', 'reachable', 'notReachable']);
  });

  it('BOARD-ADVANCED-14 production component: line 1 / line 2 drawn separately, line 2 = status word · API root; the local channel card has no note line', () => {
    const provider = relayProvider([model('plain')]);
    window.history.replaceState(null, '', '/providers/relay-advanced?view=advanced&model=plain');
    const { container, unmount } = render(<RelayDetail provider={provider} />);
    expect(container.querySelector('[data-advanced-auto-line]')?.textContent)
      .toBe('pages.relayDetail.advanced.autoEqualsConnectionDefault({"value":"Chat"})');
    expect(container.querySelector('[data-advanced-status-line]')?.textContent)
      .toBe('pages.relayDetail.catalogStatusSetByYou · pages.relayDetail.advanced.apiRoot({"value":"/v1"})');
    unmount();

    window.history.replaceState(null, '', '/providers/local-advanced?view=advanced&model=gemma');
    const local = render(<RelayDetail provider={localProvider([model('gemma')])} />);
    expect(local.container.querySelector('[data-advanced-auto-line]')).toBeNull();
    expect(local.container.querySelector('[data-advanced-status-line]')).toBeNull();
  });
});

describe('BOARD-ADVANCED-14b "Auto =" reads the first-launch protocol', () => {
  afterEach(() => rememberRelayCatalogEndpointTypes('relay-advanced', undefined));

  it('BOARD-ADVANCED-14b unverified model, first endpoint types entry anthropic -> "Auto = Messages"', () => {
    const provider = asAutoConnection(relayProvider([model('claude-x')]));
    rememberRelayCatalogEndpointTypes(provider.id, { 'claude-x': ['anthropic', 'openai'] });
    expect(board(provider, 'claude-x').protocolRow).toMatchObject({ autoEquals: 'Messages', autoEqualsConnectionDefault: false });
  });
});

describe('BOARD-ADVANCED-15 card order and thinking card', () => {
  it('BOARD-ADVANCED-15 empty automatic set shows no thinking card; local has no thinking card; the title key is unchanged (value changed to the iOS copy)', () => {
    expect(board(relayProvider([model('plain')]), 'plain').thinking).toBeNull();
    expect(board(relayProvider([withReasoningRecipe(model('think'))]), 'think').thinking).toMatchObject({ kind: 'levels' });
    expect(board(localProvider([withReasoningRecipe(model('local'))]), 'local').thinking).toBeNull();
    expect(RELAY_ADVANCED_TEXT.thinkingLevels).toBe('pages.relayDetail.advanced.thinkingLevels');
  });

  it('BOARD-ADVANCED-15 production component: [protocol, capabilities] (1 key, thinking empty); [protocol, Key, capabilities, thinking] (2 keys, thinking non-empty)', () => {
    const plain = openAdvanced(relayProvider([model('plain')]));
    expect([...plain.container.querySelectorAll('[data-advanced-section]')].map((el) => el.getAttribute('data-advanced-section')))
      .toEqual(['protocol', 'capabilities']);
    plain.unmount();

    const think = withReasoningRecipe(model('gpt-4o', { relayKeyID: 'initial' }));
    window.history.replaceState(null, '', '/providers/relay-advanced?view=advanced&model=gpt-4o');
    const { container } = render(<RelayDetail provider={twoKeys([think], [think])} />);
    expect([...container.querySelectorAll('[data-advanced-section]')].map((el) => el.getAttribute('data-advanced-section')))
      .toEqual(['protocol', 'key', 'capabilities', 'thinking']);
    expect(within(container.querySelector('[data-advanced-section="thinking"]') as HTMLElement)
      .getAllByText(RELAY_ADVANCED_TEXT.thinkingLevels).length).toBeGreaterThan(0);
    window.history.replaceState(null, '', '/');
  });
});

describe('BOARD-ADVANCED-16 footer only in the writable state', () => {
  afterEach(() => window.history.replaceState(null, '', '/'));

  it('BOARD-ADVANCED-16 writable -> appliesNow; read-only -> no footer; read-only + connection fixed: line 1 is also the follow-connection sentence', () => {
    const provider = relayProvider([model('gpt-4o')]);
    expect(board(provider, 'gpt-4o').footer).toBe('appliesNow');
    const readOnly = relayModelAdvancedBoard({ provider, model: model('gpt-4.1'), now: NOW, readOnly: true });
    expect(readOnly.footer).toBeNull();
    expect(readOnly.protocolRow).toMatchObject({ autoEquals: 'Chat', autoEqualsConnectionDefault: true });
    expect(RELAY_ADVANCED_TEXT.appliesNow).toBe('pages.relayDetail.advanced.appliesNow');
  });

  it('BOARD-ADVANCED-16 production component: writable state footer "Changes apply right away..."; not shown in the read-only state from a catalog row', () => {
    const writable = openAdvanced(relayProvider([model('gpt-4o')]));
    expect(writable.container.querySelector('[data-advanced-footer]')?.textContent).toBe('pages.relayDetail.advanced.appliesNow');
    expect(screen.queryByText(RELAY_ADVANCED_TEXT.localOnly)).toBeNull();
    writable.unmount();

    const provider = { ...relayProvider([model('gpt-4o')]), catalogModels: [model('gpt-4o'), model('gpt-4.1')] };
    window.history.replaceState(null, '', '/providers/relay-advanced?view=advanced&model=gpt-4.1&readonly=1');
    const { container } = render(<RelayDetail provider={provider} />);
    expect(container.querySelector('[data-advanced-page]')).not.toBeNull();
    expect(container.querySelector('[data-advanced-footer]')).toBeNull();
  });
});

describe('Single probe after a manually chosen protocol writes key status', () => {
  it('passes -> the effective key is normal (a single key materializes one entry); when no store is passed nothing is written', async () => {
    const provider = relayProvider([model('m')]);
    const store = storeWith(provider);
    setRelayModelTransport(store, provider.id, 'm', 'anthropic_messages');
    const current = stored(store, provider.id, 'm').provider;

    await probeRelayModelTransportOnce(current, 'm', 'anthropic_messages', { ping: async () => {} });
    expect(stored(store, provider.id, 'm').provider.relayKeys).toBeUndefined();

    const pass = await probeRelayModelTransportOnce(current, 'm', 'anthropic_messages', { store, ping: async () => {} });
    expect(pass).toBe('reachable');
    expect(stored(store, provider.id, 'm').provider.relayKeys).toEqual([
      { id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: expect.any(String) } },
    ]);
  });
});

/* -- Advanced page web row (shared/test-fixtures/relay/web-probe.v1.json presentationCases advanced) -- */

type WebAdvancedCase = {
  caseId: string;
  savedFragment: boolean;
  record: { result: 'searched' | 'rejected' | 'silent'; fragmentHash: 'current' | 'other' } | null;
  userOverride: boolean | null;
  expect: { advanced: { statusId: string; source: 'tested' | 'user' | null } };
};

const webAdvancedCases: WebAdvancedCase[] = (() => {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-probe.v1.json');
    if (existsSync(candidate)) return (JSON.parse(readFileSync(candidate, 'utf8')) as { presentationCases: { cases: WebAdvancedCase[] } }).presentationCases.cases;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('web-probe.v1.json not found');
    dir = parent;
  }
})();

describe('RL2-WEBPROBE-15 Advanced page web row', () => {
  const SAVED = { web_search_options: { search_context_size: 'high' } };
  const TEMPLATE = RELAY_WEB_FRAGMENT_TEMPLATES.openai_chat_completions;
  const OTHER = { web_search_options: { search_context_size: 'low' } };

  for (const item of webAdvancedCases) {
    it(`RL2-WEBPROBE-15 ADV-${item.caseId}`, () => {
      const overrides = item.userOverride === null ? {} : { relayCapabilityOverrides: { web: { value: item.userOverride, source: 'user' as const } } };
      const provider = relayProvider([model('web-m', overrides)]);
      replaceRelayWebFragments(provider.id, item.savedFragment ? { openai_chat_completions: SAVED } : {});
      if (item.record) {
        writeRelayWebProbeRecord({ connectionId: provider.id, modelId: 'web-m', transport: 'openai_chat_completions' }, {
          result: item.record.result, source: 'tested', at: '2026-10-14T12:00:00.000Z',
          fragmentHash: relayWebFragmentHash(item.record.fragmentHash === 'current' ? (item.savedFragment ? SAVED : TEMPLATE) : OTHER),
        });
      }
      const row = rowOf(board(provider, 'web-m'), 'web');
      expect({ statusId: row.webStatusId, source: row.source }, item.caseId).toEqual(item.expect.advanced);
      expect(row.control, item.caseId).toBe(item.userOverride === null ? 'auto' : item.userOverride ? 'on' : 'off');
    });
  }

  it('RL2-WEBPROBE-15 same-card convention for the control: tested true -> On, tested false -> Off, no value -> Auto', () => {
    const tested = (value: boolean) => model('t', { relayCapabilityOverrides: { web: { value, source: 'tested' } } });
    const provider = relayProvider([tested(true)]);
    replaceRelayWebFragments(provider.id, {});
    writeRelayWebProbeRecord({ connectionId: provider.id, modelId: 't', transport: 'openai_chat_completions' }, {
      result: 'searched', source: 'tested', at: '2026-10-14T12:00:00.000Z', fragmentHash: relayWebFragmentHash(TEMPLATE),
    });
    expect(rowOf(board(provider, 't'), 'web')).toMatchObject({ webStatusId: 'web_probe_searched', source: 'tested', control: 'on' });
    expect(rowOf(board(relayProvider([tested(false)]), 't'), 'web').control).toBe('off');
    expect(rowOf(board(relayProvider([model('t')]), 't'), 'web').control).toBe('auto');
  });

  it('RL2-WEBPROBE-15 On / Off write the web override (user); Auto clears it (both user and tested); restoring everything to automatic clears it too', () => {
    const provider = relayProvider([model('m', { relayCapabilityOverrides: { web: { value: true, source: 'tested' } } })]);
    const store = storeWith(provider);
    expect(setRelayCapabilityOverride(store, provider.id, 'm', 'web', false)).toBe(true);
    let state = stored(store, provider.id, 'm');
    for (const entry of [state.model, state.catalog]) expect(entry.relayCapabilityOverrides).toEqual({ web: { value: false, source: 'user' } });
    expect(rowOf(board(store.getState().providers[0]!, 'm'), 'web')).toMatchObject({ source: 'user', control: 'off' });

    setRelayCapabilityOverride(store, provider.id, 'm', 'web', null);
    state = stored(store, provider.id, 'm');
    expect('relayCapabilityOverrides' in state.model).toBe(false);

    setRelayCapabilityOverride(store, provider.id, 'm', 'web', true);
    expect(restoreAllRelayAutomatic(store, provider.id, 'm')).toBe(true);
    expect('relayCapabilityOverrides' in stored(store, provider.id, 'm').model).toBe(false);
  });

  it('RL2-WEBPROBE-15 undecided protocol -> Unknown', () => {
    const provider = relayProvider([model('auto-m')]);
    provider.relayRequested = { ...provider.relayRequested!, transport: 'auto' };
    const row = rowOf(board(provider, 'auto-m'), 'web');
    expect(row).toMatchObject({ state: 'unknown', stateKey: RELAY_ADVANCED_TEXT.imageGenerationUnknown, source: null, control: 'auto' });
    expect(row.webStatusId).toBeUndefined();
  });

  it('RL2-WEBPROBE-15 production component: the web row follows tool calling, titled Web search', () => {
    const { container } = openAdvanced(relayProvider([model('gpt-5.4')]));
    const web = container.querySelector('[data-advanced-cap="web"]')!;
    expect(web).toBeTruthy();
    expect(within(web as HTMLElement).getByText(RELAY_ADVANCED_TEXT.capTitle.web)).toBeTruthy();
  });
});

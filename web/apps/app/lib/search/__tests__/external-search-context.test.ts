import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { resetDBConnection } from '../../infra/storage/idb';
import { setActiveUID } from '../../infra/storage/partition';
import {
  closeSearchDB,
  deleteConversationSearchSource,
  getConversationSearchSource,
  migrateGuestSearchData,
  saveCustomSearchService,
  savePresetSearchService,
  setConversationSearchSource,
  type StoredCustomSearchService,
  type StoredPresetSearchService,
} from '../search-service-store';
import { __resetSettingsCatalogForTests, loadSettingsCatalog, searchConnectionsFromProviders, type SearchServiceView } from '../search-settings-data';
import {
  adoptDraftSearchSource,
  externalSearchFacts,
  loadExternalSearchDataForSend,
  readConversationSearchSource,
  readDraftSearchSource,
  writeConversationSearchSource,
} from '../external-search-context';
import {
  resolveModelOptionCapabilityShape,
  webSearchFacts,
  webSearchRouteForm,
} from '../../core/chat/model-option-capability-shape';
import { externalSearchSendState } from '../../core/chat/external-search-send';
import { updateSearchSource } from '@oriveo/core/search/search-route';

// External search wiring: sending uses only the cached catalog, one routing input, a new conversation's source stays in memory, deleting a conversation / guest migration carries the source, and the service name never degrades to "model built-in".

// The shared definition of panelWritable (requires a runtime identity) lives in composer-web-preference; here it is toggled per case to test "no identity -> the per-conversation choice has no effect".
const identity = vi.hoisted(() => ({ writable: true }));
vi.mock('../../core/chat/composer-web-preference', async () => ({
  ...await vi.importActual<typeof import('../../core/chat/composer-web-preference')>('../../core/chat/composer-web-preference'),
  composerWebPreferenceWritable: () => identity.writable,
}));

vi.mock('../../core/sync', async () => {
  const actual = await vi.importActual<typeof import('../../core/sync')>('../../core/sync');
  return { ...actual, getSyncAdapter: () => ({ didUpdatePreferences: vi.fn() }) };
});

const UID = 'user-route';
const preset: StoredPresetSearchService = {
  id: 'svc-deepseek', kind: 'preset', serviceId: 'deepseek', name: 'DeepSeek', regionId: 'cn',
  boundHost: 'api.deepseek.com', connectionRef: null, createdAt: 1, updatedAt: 1,
};
const custom: StoredCustomSearchService = {
  id: 'svc-custom', kind: 'custom', name: 'Home SearXNG', protocol: 'searxng',
  address: 'https://searx.example.com', mapping: null, createdAt: 2, updatedAt: 2,
};
const external = { methods: { 'p1:m1': 'external' as const }, serviceId: 'svc-custom', serviceName: 'Home SearXNG', notice: null };

beforeEach(async () => {
  await closeSearchDB(UID);
  await closeSearchDB('guest');
  resetDBConnection();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
  await setActiveUID(UID);
  __resetSettingsCatalogForTests();
});
afterEach(() => vi.unstubAllGlobals());

describe('(1) before sending only the cached catalog is used', () => {
  it('no cache = catalog unavailable: presets not selectable, custom still selectable, and no network request is sent', async () => {
    await savePresetSearchService(UID, preset, { key: 'sk-1' });
    await saveCustomSearchService(UID, custom);
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    const data = await loadExternalSearchDataForSend();
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(data?.catalog.available).toBe(false);
    expect(data?.snapshot.services.map((v) => [v.record.id, v.row.status])).toEqual([
      ['svc-deepseek', 'catalog_unavailable'],
      ['svc-custom', 'ready'],
    ]);
  });

  it('after the panel has fetched the catalog, sending uses that cache (still sending no request)', async () => {
    await savePresetSearchService(UID, preset, { key: 'sk-1' });
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ available: true, entries: [], withdrawn: [] }))));
    await loadSettingsCatalog();
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    expect((await loadExternalSearchDataForSend())?.catalog.available).toBe(true);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('no service on this device at all: the catalog is not read, returns null directly', async () => {
    expect(await loadExternalSearchDataForSend()).toBeNull();
  });

  it('catalog unavailable is not a fallback: the read path does not rewrite the preset service the user chose', async () => {
    await savePresetSearchService(UID, preset, { key: 'sk-1' });
    const stored = { ...external, serviceId: 'svc-deepseek', serviceName: 'DeepSeek' };
    await setConversationSearchSource(UID, 'conv-1', stored);
    const data = (await loadExternalSearchDataForSend())!;
    await readConversationSearchSource({ data, conversationId: 'conv-1', modelKey: 'p1:m1' });
    expect(await getConversationSearchSource(UID, 'conv-1')).toEqual(stored);
  });
});

describe('(2) panel and send share one facts set, the combined entry decides in one place', () => {
  it('form by providerFormOf: subscription Grok / other subscriptions / official', () => {
    expect(webSearchRouteForm({ kind: 'grok', authMode: 'subscription' } as Provider)).toBe('subscription_grok');
    expect(webSearchRouteForm({ kind: 'openAI', authMode: 'subscription' } as Provider)).toBe('subscription_codex');
    expect(webSearchRouteForm({ kind: 'openAI', authMode: 'apiKey' } as Provider)).toBe('byok');
  });

  it('facts: control state -> recipeWeb, rejected facts as-is, hosted web available; relay gives statusId', () => {
    const base = { protocolUndecided: false, nativeRejected: true, toolCall: 'supported' as const };
    expect(webSearchFacts({ ...base, form: 'byok', status: 'automaticAvailable' })).toEqual({
      form: 'byok', recipeWeb: 'auto_available', nativeRejected: true, managedWebAvailable: true, toolCall: 'supported',
    });
    expect(webSearchFacts({ ...base, form: 'byok', status: 'customOnly' })?.recipeWeb).toBe('custom_only');
    expect(webSearchFacts({ ...base, form: 'byok', status: 'pending' })?.recipeWeb).toBe('none');
    expect(webSearchFacts({ ...base, form: 'relay', status: 'unknown', relayWeb: { localEngine: false, hasFragment: true } })).toEqual({
      form: 'relay', relayStatus: 'web_probe_unverified', toolCall: 'supported',
    });
    expect(webSearchFacts({ ...base, form: 'relay', status: 'unknown' })).toBeNull();
    // Non-BYOK / subscription Codex does not read recipeWeb
    expect(webSearchFacts({ ...base, form: 'managed', status: 'automaticAvailable' })?.recipeWeb).toBe('none');
    expect(webSearchFacts({ ...base, form: 'subscription_grok', status: 'alwaysOn' })?.recipeWeb).toBe('none');
  });

  it('send: rejected + 1 service, external already tapped -> native fields suppressed; free is not suppressed', () => {
    const provider = { id: 'p1', kind: 'openAI', authMode: 'apiKey', models: [] } as unknown as Provider;
    const model = { id: 'm1', name: 'gpt' } as unknown as AIModel;
    const view = { record: custom, name: 'Home SearXNG', row: { status: 'ready' } } as unknown as SearchServiceView;
    const data = { catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view], defaultId: 'svc-custom' } };
    const armed = externalSearchSendState({ provider, model, data, stored: external, nativeRejected: true, webOn: true });
    expect(armed).toMatchObject({ nativeWeb: 'withdrawn_or_rejected', nativeFieldsSuppressed: true, toggleOn: true });
    const notArmed = externalSearchSendState({ provider, model, data, stored: null, nativeRejected: true, webOn: true });
    expect(notArmed).toMatchObject({ armHint: true, nativeFieldsSuppressed: false, toggleOn: false });
  });

  it('send and panel share the same panelWritable definition: no runtime identity -> the per-conversation choice has no effect and fields are not suppressed', () => {
    const provider = { id: 'p1', kind: 'openAI', authMode: 'apiKey', models: [] } as unknown as Provider;
    const model = { id: 'm1', name: 'gpt' } as unknown as AIModel;
    const view = { record: custom, name: 'Home SearXNG', row: { status: 'ready' } } as unknown as SearchServiceView;
    identity.writable = false;
    try {
      const state = externalSearchSendState({ provider, model, data: { catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view], defaultId: 'svc-custom' } }, stored: external, nativeRejected: true, webOn: true });
      expect(state).toMatchObject({ source: { method: 'default' }, nativeFieldsSuppressed: false, oneTapArms: false });
    } finally {
      identity.writable = true;
    }
  });
});

describe('(4) a new conversation has no id: the source stays in memory, written once under the real id after the conversation is created', () => {
  it('a draft source choice is not persisted; after adopt the real id has a value and the draft is cleared; pre-send reads it', async () => {
    await saveCustomSearchService(UID, custom);
    const next = await writeConversationSearchSource({
      uid: UID, conversationId: undefined, draftSessionId: 'draft-1', stored: null, modelKey: 'p1:m1',
      event: { type: 'pick_service', serviceId: 'svc-custom', serviceName: 'Home SearXNG' },
    });
    expect(readDraftSearchSource('draft-1')).toEqual(next);
    expect(await getConversationSearchSource(UID, 'draft-1')).toBeNull();

    adoptDraftSearchSource({ draftSessionId: 'draft-1', conversationId: 'conv-new' });
    expect(readDraftSearchSource('draft-1')).toBeNull();
    const data = (await loadExternalSearchDataForSend())!;
    const { stored, resolved } = await readConversationSearchSource({ data, conversationId: 'conv-new', modelKey: 'p1:m1', persist: false });
    expect(stored).toEqual(next);
    expect(resolved.method).toBe('external');
  });

  it('draft never chosen: adopt writes nothing', async () => {
    adoptDraftSearchSource({ draftSessionId: 'draft-2', conversationId: 'conv-2' });
    expect(await getConversationSearchSource(UID, 'conv-2')).toBeNull();
  });
});

describe('(5) deleting a conversation deletes its source; guest migration carries sources with conversations', () => {
  it('deleteConversationSearchSource deletes conversationSource:<id>', async () => {
    await setConversationSearchSource(UID, 'conv-del', external);
    await deleteConversationSearchSource(UID, 'conv-del');
    expect(await getConversationSearchSource(UID, 'conv-del')).toBeNull();
  });

  it('migration carries only the sources of migrated conversations and does not overwrite what the account already has', async () => {
    await saveCustomSearchService('guest', custom);
    await setConversationSearchSource('guest', 'conv-a', external);
    await setConversationSearchSource('guest', 'conv-b', external);
    const own = { ...external, serviceName: 'mine' };
    await setConversationSearchSource(UID, 'conv-b', own);
    await migrateGuestSearchData(UID, ['conv-a', 'conv-b']);
    expect(await getConversationSearchSource(UID, 'conv-a')).toEqual(external);
    expect(await getConversationSearchSource(UID, 'conv-b')).toEqual(own);

    await setConversationSearchSource('guest', 'conv-c', external);
    await migrateGuestSearchData(UID, []);
    expect(await getConversationSearchSource(UID, 'conv-c')).toBeNull();
  });
});

describe('(8) service name goes through searchServiceDisplayName, method external never degrades to "model built-in"', () => {
  it('a model that can go native chose an external service: the source sub-line is the service name', () => {
    const view = { record: custom, name: 'Home SearXNG', row: { status: 'ready' } } as unknown as SearchServiceView;
    const { input } = externalSearchFacts({
      data: { catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view], defaultId: 'svc-custom' } },
      stored: { ...external, serviceName: null },
      modelKey: 'p1:m1', form: 'byok', currentProviderKind: 'openAI', toolCall: 'supported', panelWritable: true,
    });
    const row = resolveModelOptionCapabilityShape({
      capability: 'web', status: 'automaticAvailable', availableIntents: ['automatic'], selectedIntent: 'automatic',
      connection: 'official', isWritable: true, protocolUndecided: false, rejectedIntents: [],
      chatTemplateThinkingIsOn: false, supportsChatTemplate: false, externalSearch: input,
    });
    expect(row).toMatchObject({ kind: 'toggleWithSource', path: 'external_tool', card: { link: { key: 'card.sourceLine', args: { name: 'Home SearXNG' } } } });
  });
});

describe('external must be tapped once to take effect (production path)', () => {
  it('native-model conversation with web on -> switch to a model that cannot go native -> sending does not search, the card shows off', () => {
    const view = { record: custom, name: 'Home SearXNG', row: { status: 'ready' } } as unknown as SearchServiceView;
    const data = { catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view], defaultId: 'svc-custom' } };
    // Web is on for the native model, and the source is model built-in (native was chosen)
    const stored = { methods: { 'p1:native': 'native' }, serviceId: null, serviceName: null, notice: null };
    const provider = { id: 'p1', kind: 'openAI', authMode: 'apiKey', models: [] } as unknown as Provider;
    const nonNative = { id: 'plain', name: 'plain' } as unknown as AIModel;
    // Send: a model without a recipe (unknown) + 1 service + web on -> external never tapped, fields not suppressed, external path not taken
    const send = externalSearchSendState({ provider, model: nonNative, data, stored, nativeRejected: false, webOn: true });
    expect(send).toMatchObject({ armHint: true, nativeFieldsSuppressed: false, toggleOn: false, chipLit: false, route: { path: 'none' } });
    // Panel: same facts, the card shows off "Off · Home SearXNG can search"
    const { input } = externalSearchFacts({ data, stored, modelKey: 'p1:plain', form: 'byok', currentProviderKind: 'openAI', toolCall: 'supported', panelWritable: true });
    const row = resolveModelOptionCapabilityShape({
      capability: 'web', status: 'unsupported', availableIntents: [], selectedIntent: 'automatic',
      connection: 'official', isWritable: true, protocolUndecided: false, rejectedIntents: [],
      chatTemplateThinkingIsOn: false, supportsChatTemplate: false, externalSearch: input,
    });
    expect(row).toMatchObject({
      kind: 'toggleWithSource', isOn: false, controls: 'external', serviceId: 'svc-custom',
      card: { status: { key: 'card.offUseService', args: { name: 'Home SearXNG' } }, notes: [{ key: 'card.armHint', args: { name: 'Home SearXNG' } }] },
    });
  });
});

describe('external arming, production path', () => {
  const provider = { id: 'p1', kind: 'openAI', authMode: 'apiKey', models: [] } as unknown as Provider;
  const plain = { id: 'm1', name: 'plain' } as unknown as AIModel;
  const ready = { record: custom, name: 'Home SearXNG', row: { status: 'ready' } } as unknown as SearchServiceView;
  const catalog = { available: true, entries: [], withdrawn: [] };
  const panelRow = (data: Parameters<typeof externalSearchFacts>[0]['data'], stored: unknown, selectedIntent: 'automatic' | 'off') => {
    const { input } = externalSearchFacts({ data, stored, modelKey: 'p1:m1', form: 'byok', currentProviderKind: 'openAI', toolCall: 'supported', panelWritable: true });
    return resolveModelOptionCapabilityShape({
      capability: 'web', status: 'unsupported', availableIntents: [], selectedIntent,
      connection: 'official', isWritable: true, protocolUndecided: false, rejectedIntents: [],
      chatTemplateThinkingIsOn: false, supportsChatTemplate: false, externalSearch: input,
    });
  };

  it('a model that cannot go native has external on, conversation web off -> sending goes external, chip lit', () => {
    const data = { catalog, connections: [], snapshot: { services: [ready], defaultId: 'svc-custom' } };
    const state = externalSearchSendState({ provider, model: plain, data, stored: external, nativeRejected: false, webOn: false });
    expect(state).toMatchObject({ nativeFieldsSuppressed: true, chipLit: true, toggleOn: true, toggleControls: 'external' });
    expect(panelRow(data, external, 'off')).toMatchObject({ kind: 'toggleWithSource', isOn: true, controls: 'external' });
  });

  it('manually turning external off -> only disarms this model, conversation web (webOn) is unaffected, the card shows off', () => {
    const data = { catalog, connections: [], snapshot: { services: [ready], defaultId: 'svc-custom' } };
    const after = updateSearchSource({ stored: external, modelKey: 'p1:m1', event: { type: 'disarm' } });
    expect(after).toEqual({ methods: {}, serviceId: 'svc-custom', serviceName: 'Home SearXNG', notice: null });
    const state = externalSearchSendState({ provider, model: plain, data, stored: after, nativeRejected: false, webOn: true });
    // Conversation web stays on (webOn was not written), external is off, give the not-armed explanation
    expect(state).toMatchObject({ toggleOn: false, armHint: true, nativeFieldsSuppressed: false });
  });

  it('deleting a service -> external off, hint shown', () => {
    const other = { record: { ...custom, id: 'svc-other', name: 'Other' }, name: 'Other', row: { status: 'ready' } } as unknown as SearchServiceView;
    const data = { catalog, connections: [], snapshot: { services: [other], defaultId: 'svc-other' } };
    const state = externalSearchSendState({ provider, model: plain, data, stored: external, nativeRejected: false, webOn: true });
    expect(state).toMatchObject({ toggleOn: false, nativeFieldsSuppressed: false, source: { method: 'default', notice: { fromName: 'Home SearXNG' } } });
    const row = panelRow(data, external, 'automatic');
    expect(row).toMatchObject({ kind: 'toggleWithSource', isOn: false });
    expect((row as { card: { notes: Array<{ key: string }> } }).card.notes[0]).toEqual({ key: 'card.fallbackNotice', args: { from: 'Home SearXNG' } });
  });

  it('catalog unavailable -> the card keeps the choice and shows a note', () => {
    const presetView = { record: preset, name: 'DeepSeek', row: { status: 'catalog_unavailable' } } as unknown as SearchServiceView;
    const stored = { methods: { 'p1:m1': 'external' }, serviceId: 'svc-deepseek', serviceName: 'DeepSeek', notice: null };
    const data = { catalog: { available: false, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [presetView], defaultId: 'svc-deepseek' } };
    const row = panelRow(data, stored, 'automatic');
    expect(row).toMatchObject({
      kind: 'toggleWithSource', isOn: true, serviceId: 'svc-deepseek',
      card: { status: { key: 'card.useService', args: { name: 'DeepSeek' } }, notes: [{ key: 'row.catalogUnavailable', args: {} }] },
    });
  });

  it('guest with no services still migrates sources', async () => {
    await setConversationSearchSource('guest', 'conv-g', external);
    await migrateGuestSearchData(UID, ['conv-g']);
    expect(await getConversationSearchSource(UID, 'conv-g')).toEqual(external);
  });
});

describe('reusable connection = official BYOK (by providerFormOf, not by comparing kind)', () => {
  it('relay / subscription login / no key all do not count', () => {
    const p = (over: Partial<Provider>) => ({ id: over.kind ?? 'x', models: [], apiKey: 'sk-1', ...over }) as Provider;
    const out = searchConnectionsFromProviders([
      p({ id: 'ds', kind: 'deepseek' }),
      p({ id: 'relay', kind: 'relay' }),
      p({ id: 'sub', kind: 'openAI', authMode: 'subscription' }),
      p({ id: 'nokey', kind: 'moonshot', apiKey: '' }),
    ]);
    expect(out.map((c) => c.id)).toEqual(['ds']);
  });
});

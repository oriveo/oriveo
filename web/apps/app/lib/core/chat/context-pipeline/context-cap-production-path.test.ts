import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Cap tiers and price line (Web): the price line T comes from the production metadata decoder and enters the budget at the window factory;
 * Relay does not use T. Tier = conversation contextCap ?? global contextDefaultCap.
 * B is taken from the manifest the production send path wrote to the Ledger, or from the plan built by compaction / the rejection pre-check.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  compactionBudgets: [] as Array<number | null>,
}));

// B for compaction: taken from the snapshot production chatCompactionContextOf hands to the coordinator, with the implementation called unchanged.
vi.mock('./chat-context', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./chat-context')>();
  return {
    ...actual,
    chatCompactionContextOf: (...args: Parameters<typeof actual.chatCompactionContextOf>) => {
      const ctx = actual.chatCompactionContextOf(...args);
      mocks.compactionBudgets.push(ctx?.B ?? null);
      return ctx;
    },
  };
});

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { ContextAssembler, type AssembleInput } from '@oriveo/core/context/assemble';
import type { ContextPlan } from '@oriveo/core/context/plan';
import { createAppStore, type AppStore } from '../../store/app-store';
import {
  __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata, resolveCatalogModel,
} from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { getContextManifests } from '../../../infra/storage/context-ledger-store';
import { exportBackup } from '../../../backup/backup-export';
import { parseBackupFile } from '../../../backup/backup-format';
import { executeImport, generateImportPreview } from '../../../backup/backup-import';
import { getAllConversations, putConversation } from '../../../infra/storage/idb';
import { chatContextRejectBeforeSend } from './chat-context';
import { compactConversationNow } from './manual-compaction';

const GROK_ID = 'grok-4.7';
const LONG_CONTEXT = { thresholdTokens: 200000, promptPerMToken: 4, completionPerMToken: 12, cacheReadPerMToken: 1 };

function metadataWith(grokPricing: Record<string, unknown>) {
  const grokModels = {
    [GROK_ID]: {
      canonicalModelId: GROK_ID,
      contextLength: 2000000,
      pricingUnit: 'per_token',
      pricingStatus: 'priced',
      capabilities: ['text'],
      pricing: grokPricing,
    },
  };
  return {
    version: 1,
    contractVersion: 1,
    updatedAt: '2026-10-17T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {
      grok: { models: grokModels },
    },
    providerConfigs: [],
  };
}

const GROK_PRICING = { promptPerMToken: 2, completionPerMToken: 6, longContext: LONG_CONTEXT };

async function seedMetadata(grokPricing: Record<string, unknown> = GROK_PRICING) {
  // The bad-shape cases feed invalid values: the fixture is treated as a raw response and is not constrained by the static ModelPricing type.
  await __seedMetadataCacheForTest({ data: metadataWith(grokPricing) as never, timestamp: Date.now() });
  await initMetadata();
}

// The window is not written on the model: both W and T come only from the catalog decoding result.
const catalogModel = {
  id: GROK_ID, name: GROK_ID, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  transport: 'openai_chat_completions',
} as unknown as AIModel;
// The model of the same name on Relay carries W 2000000 itself.
const windowedModel = { ...catalogModel, contextLength: 2000000 } as AIModel;

const grokProvider = {
  id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [catalogModel], catalogModels: [], apiKey: 'sk-grok', apiKeyPreview: '••',
} as unknown as Provider;
const relayProvider = {
  id: 'relay-grok', kind: 'relay', status: { kind: 'connected' }, models: [windowedModel], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;

const okOpenAIChat = () => new Response([
  'data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}',
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
  'data: [DONE]',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });

let conversationId = 'conv-cap-0';
let conversationSeq = 0;

function conversationFor(provider: Provider, model: AIModel, extra: Partial<Conversation> = {}): Conversation {
  return {
    id: conversationId, title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: provider.kind,
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
    updatedAt: '2026-10-17T00:00:00.000Z', createdAt: '2026-10-17T00:00:00.000Z',
    ...extra,
  } as Conversation;
}

interface SendSetup {
  /** Extra conversation fields (such as contextCap); default = follow the global value. */
  conversation?: Partial<Conversation>;
  /** Global contextDefaultCap; default = unset (auto). */
  globalCap?: unknown;
  /** After the store is built and before sending (e.g. changing the conversation through the production path). */
  prepare?: (store: StoreApi<AppStore>) => void | Promise<void>;
}

function storeFor(provider: Provider, model: AIModel, setup: SendSetup): StoreApi<AppStore> {
  const store = createAppStore({ providers: [provider], conversations: [conversationFor(provider, model, setup.conversation)] });
  if (setup.globalCap !== undefined) {
    store.setState({ preferences: { ...store.getState().preferences, contextDefaultCap: setup.globalCap as never } });
  }
  mocks.store = store;
  return store;
}

/** Returns the B of the manifest this request wrote to the Ledger. */
async function sendAndReadBudget(provider: Provider, model: AIModel, setup: SendSetup = {}): Promise<number | null> {
  const store = storeFor(provider, model, setup);
  await setup.prepare?.(store);
  const current = store.getState().conversations.find((c) => c.id === conversationId)!;
  await sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
  }, { text: 'hello', prevMessages: current.messages, conversation: current, provider, model, reasoningMode: 'automatic' }).done;
  const manifests = await getContextManifests(conversationId);
  expect(manifests).toHaveLength(1);
  expect(manifests[0].model).toBe(GROK_ID);
  return manifests[0].B;
}

function chatMessage(id: string, role: 'user' | 'assistant', text: string): ChatMessage {
  return {
    id, role, text, providerKind: 'grok', providerName: 'grok', modelName: GROK_ID, estimatedCost: 0, state: 'delivered',
    createdAt: '2026-10-17T00:00:00.000Z',
  } as unknown as ChatMessage;
}

// grok W 2000000: R = max(O, W/10) = 200000, U = 1800000.
const GROK_U = 2000000 - 200000;

beforeEach(() => {
  conversationSeq += 1;
  conversationId = `conv-cap-${conversationSeq}`;
  localStorage.clear();
  __resetMetadataClientForTest();
  mocks.compactionBudgets.length = 0;
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string | null, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL ?? 'https://api.official.example/v1', options, {
      transport: { fetch: async () => okOpenAIChat() },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
  vi.restoreAllMocks();
});

describe('context cap production path (price line)', () => {
  it('grok_auto_price_line_caps_budget', async () => {
    await seedMetadata();
    // T comes from the object the production decoder produced and is not filled into the model by hand.
    expect(resolveCatalogModel(GROK_ID, 'grok')?.pricing?.longContext?.thresholdTokens).toBe(200000);
    expect('longContext' in catalogModel).toBe(false);

    expect(await sendAndReadBudget(grokProvider, catalogModel)).toBe(200000);
  });

  it('relay_ignores_price_line', async () => {
    // On Web this is structural: resolveCatalogModel(id, 'relay') is always null, so Relay never gets the catalog price line;
    // windowOf still explicitly leaves T unset for kind === 'relay'; this case guards that with a same-named model of W 2000000, B is bound only by the auto default tier.
    await seedMetadata();
    expect(await sendAndReadBudget(relayProvider, windowedModel)).toBe(256000);
  });

  it('metadata_decodes_long_context', async () => {
    await seedMetadata();
    const decoded = resolveCatalogModel(GROK_ID, 'grok');
    expect(decoded?.pricing?.longContext).toEqual(LONG_CONTEXT);
    expect(decoded?.pricing?.promptPerToken).toBe(2 / 1_000_000);

    // cacheReadPerMToken may be omitted.
    __resetMetadataClientForTest();
    const { cacheReadPerMToken: _cacheRead, ...withoutCacheRead } = LONG_CONTEXT;
    await seedMetadata({ ...GROK_PRICING, longContext: withoutCacheRead });
    expect(resolveCatalogModel(GROK_ID, 'grok')?.pricing?.longContext).toEqual(withoutCacheRead);

    // thresholdTokens is accepted when it is an integer value (200000.0 decodes to 200000).
    __resetMetadataClientForTest();
    await seedMetadata({ ...GROK_PRICING, longContext: { ...LONG_CONTEXT, thresholdTokens: 200000.0 } });
    expect(resolveCatalogModel(GROK_ID, 'grok')?.pricing?.longContext?.thresholdTokens).toBe(200000);

    // A bad shape only drops longContext; the rest of the pricing works as usual.
    const badShapes: unknown[] = [
      { ...LONG_CONTEXT, thresholdTokens: '200000' },
      { ...LONG_CONTEXT, thresholdTokens: 0 },
      { ...LONG_CONTEXT, thresholdTokens: 200000.5 },
      { ...LONG_CONTEXT, thresholdTokens: 2147483648 },
      { ...LONG_CONTEXT, promptPerMToken: -1 },
      { ...LONG_CONTEXT, completionPerMToken: undefined },
      { ...LONG_CONTEXT, promptPerMToken: 'x' },
      { ...LONG_CONTEXT, cacheReadPerMToken: 'x' },
      'long',
      [],
    ];
    for (const longContext of badShapes) {
      __resetMetadataClientForTest();
      await seedMetadata({ ...GROK_PRICING, longContext });
      const resolved = resolveCatalogModel(GROK_ID, 'grok');
      expect(resolved?.pricing).not.toBeNull();
      expect(resolved?.pricing && 'longContext' in resolved.pricing).toBe(false);
      expect(resolved?.pricing?.promptPerToken).toBe(2 / 1_000_000);
      expect(resolved?.pricing?.completionPerToken).toBe(6 / 1_000_000);
      expect(resolved?.contextLength).toBe(2000000);
    }
  });
});

describe('context cap production path (conversation cap ?? global default)', () => {
  it('backup_restored_cap_drives_budget', async () => {
    await seedMetadata();
    // Production export (IDB -> zip), then parse and import (replaceAll -> IDB); the read-back conversation goes into the store and is sent.
    await putConversation(conversationFor(grokProvider, catalogModel, { contextCap: 190000 }));
    const blob = await exportBackup({ includeApiKeys: false });
    const parsed = await parseBackupFile(new File([blob], 'backup.zip'));
    await executeImport(await generateImportPreview(parsed.backupFile, parsed.imageEntries), 'replaceAll');
    const restored = (await getAllConversations()).find((c) => c.id === conversationId);
    expect(restored?.contextCap).toBe(190000);

    const B = await sendAndReadBudget(grokProvider, catalogModel, { conversation: { contextCap: restored?.contextCap } });
    expect(B).toBe(190000);
  });

  it('global_custom_cap_applies_when_following', async () => {
    await seedMetadata();
    expect(await sendAndReadBudget(grokProvider, catalogModel, { globalCap: 300000 })).toBe(300000);
  });

  it('conversation_unlimited_overrides_global', async () => {
    await seedMetadata();
    const B = await sendAndReadBudget(grokProvider, catalogModel, { conversation: { contextCap: 'unlimited' }, globalCap: 64000 });
    expect(B).toBe(GROK_U);
  });

  it('compaction_uses_conversation_cap', async () => {
    await seedMetadata();
    storeFor(grokProvider, catalogModel, {
      conversation: {
        contextCap: 64000,
        messages: [chatMessage('u1', 'user', 'first'), chatMessage('a1', 'assistant', 'reply'), chatMessage('u2', 'user', 'second')],
      },
    });
    await compactConversationNow(conversationId);
    expect(mocks.compactionBudgets.length).toBeGreaterThan(0);
    expect(mocks.compactionBudgets.every((B) => B === 64000)).toBe(true);
  });

  it('reject_precheck_uses_conversation_cap', async () => {
    await seedMetadata();
    const store = storeFor(grokProvider, catalogModel, { conversation: { contextCap: 64000 } });
    const plans: Array<{ input: AssembleInput; plan: ContextPlan }> = [];
    const assemble = ContextAssembler.assemble;
    vi.spyOn(ContextAssembler, 'assemble').mockImplementation((input: AssembleInput) => {
      const plan = assemble(input);
      plans.push({ input, plan });
      return plan;
    });
    const conversation = store.getState().conversations[0];
    const reject = await chatContextRejectBeforeSend({
      store, conversation, provider: grokProvider, model: catalogModel,
      messages: [chatMessage('u1', 'user', 'hello')], latestUserText: 'hello',
    });
    expect(reject).toBeNull();
    expect(plans).toHaveLength(1);
    expect(plans[0].plan.budget.B).toBe(64000);
  });
});

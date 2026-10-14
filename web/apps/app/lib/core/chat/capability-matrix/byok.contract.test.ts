// @vitest-environment jsdom
//
// Capability matrix: the four official BYOK cells.
// Connections always use an official API key; metadata comes from the Server official recipe source (capability_runtime.v1.json) and is fed in through
// the metadata injection point of buildProviderRequest. Assertions look at objects actually produced by the production builder / outbound gate / send leg.

import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'uid-byok',
}));
// Surroundings of the library send orchestration (same seams as operations-library-send.test.ts): prompt injection, settlement reporting,
// sync, analytics, library tool execution and the confirmation dialog. Routing, memory, the agent loop and the send leg are production implementations.
vi.mock('../prompt-injection', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../prompt-injection')>()),
  buildPromptInjectionContext: vi.fn(async () => ({ systemContent: '', memoryInjected: false, retrievalCost: 0 })),
}));
vi.mock('../send-completion', () => ({ reportSendCompletion: vi.fn(), reportUsageAndBudget: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: vi.fn(() => null) }));
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: vi.fn(),
}));
vi.mock('../../library/api', () => ({ executeLibraryTool: vi.fn() }));
vi.mock('../../library/confirmation', () => ({
  requestLibraryConfirmation: vi.fn(),
  clearOwnLibraryConfirmation: vi.fn(),
}));
vi.mock('../../../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn(async () => null),
  imageSizeBytes: vi.fn(async () => 0),
}));

import { filterRequestCapabilityIntent } from '../stream-options';
import { webPreferenceReachesTheWire } from '../capability-control-presentation';
import { recordCapabilityRejection } from '../capability-recovery-runtime';
import { resolveAttachmentCapabilities } from '../attachment-policy';
import { sendLibraryMessage } from '../operations-library-send';
import { createAppStore } from '../../store/app-store';
import { resolveAttachmentLine } from '../../attachments/attachment-transport-resolver';
import { buildChatHistory } from '../../../utils/chat-stream-utils';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
} from '../../metadata/metadata-client';

const officialRecipes = (JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../shared/capabilityrecipe/capability_runtime.v1.json'),
  'utf8',
)) as { recipes: Record<string, { requestOps: Array<{ op: string; intent?: string; pointer: string; value: unknown }> }> }).recipes;

const WEB_RECIPE = 'openai.responses.web.v1';
const REASONING_RECIPE = 'openai.responses.reasoning.v1';
const MODEL_ID = 'gpt-5.4';
const RUNTIME_REVISION = 'runtime-byok-1';
const ALL_TIERS = ['low', 'balanced', 'deep', 'max'] as const;
type Tier = (typeof ALL_TIERS)[number];

/** Official /api/metadata shape: the model's capabilityControls point at the Server official recipe. */
function officialMetadata(capabilityControls: Record<string, unknown>): RuntimeMetadataResponse {
  const recipeRefs = Object.values(capabilityControls)
    .map((control) => (control as { recipeRef?: string }).recipeRef)
    .filter((ref): ref is string => typeof ref === 'string');
  return {
    version: 2,
    updatedAt: '2026-10-11T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
    capabilityRuntime: {
      schemaVersion: 2, revision: RUNTIME_REVISION, generatedAt: '2026-10-11T00:00:00Z',
      recipes: Object.fromEntries(recipeRefs.map((ref) => [ref, officialRecipes[ref]])),
      controlDefinitions: {}, sourceIndex: {}, responseEvidenceDefinitions: {},
    },
    providers: {
      openAI: {
        resolveMap: { [MODEL_ID]: MODEL_ID },
        models: { [MODEL_ID]: { transport: 'openai_responses', capabilityControls } },
      },
    },
  } as unknown as RuntimeMetadataResponse;
}

function officialProvider(kind: Provider['kind'] = 'openAI', id = 'byok-openai'): Provider {
  return {
    id, kind, status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'sk-byok', apiKeyPreview: 'sk-…', authMode: 'apiKey',
  } as Provider;
}

/** The capabilityControls written into the AIModel and the one delivered via metadata are the same copy. */
function syncedModel(metadata: RuntimeMetadataResponse, overrides: Partial<AIModel> = {}): AIModel {
  const entry = (metadata as unknown as { providers: { openAI: { models: Record<string, Record<string, unknown>> } } })
    .providers.openAI.models[MODEL_ID];
  return {
    id: MODEL_ID, name: 'GPT-5.4', capabilities: ['text'], reasoningModeAvailable: true,
    isAvailable: true, isDefault: true, priceTier: '$', transport: 'openai_responses',
    capabilityControls: entry.capabilityControls,
    ...overrides,
  } as unknown as AIModel;
}

const recoveryIdentity = {
  connectionId: '00000000-0000-4000-8000-0000000000b1',
  canonicalModelId: MODEL_ID,
  finalTransport: 'openai_responses',
  runtimeRevision: RUNTIME_REVISION,
};

function rejectTier(tier: Tier): void {
  recordCapabilityRejection(recoveryIdentity, {
    version: 1,
    action: 'user_confirmed_resend_without_located_setting',
    source: 'provider_recipe',
    owners: ['reasoning'],
    locatedPointers: ['/reasoning/effort'],
    recipeRef: REASONING_RECIPE,
  }, Date.now(), { reasoningIntent: tier });
}

/** Plain send: outbound gate -> production dispatch. */
async function sendOfficial(input: {
  metadata: RuntimeMetadataResponse;
  web: 'off' | 'automatic';
  reasoningIntent: 'off' | Tier;
  withRecoveryIdentity?: boolean;
}): Promise<Record<string, unknown>> {
  // The browser-side metadata cache and dispatch read the same payload (the outbound gate's recipe runtime takes it from here).
  await __seedMetadataCacheForTest({
    data: { ...input.metadata, contractVersion: 1, providerConfigs: [] } as never,
    timestamp: Date.now(),
  });
  await initMetadata();
  const provider = officialProvider();
  const model = syncedModel(input.metadata);
  const gate = filterRequestCapabilityIntent({
    provider,
    model,
    reasoningMode: 'automatic',
    webSearchEnabled: input.web !== 'off',
    webReachesTheWire: webPreferenceReachesTheWire({ provider, model, transportIdentity: 'openai_responses' }),
    streamOptions: {
      capabilityPreferences: { web: input.web, reasoningIntent: input.reasoningIntent },
      ...(input.withRecoveryIdentity ? { capabilityRecoveryIdentity: recoveryIdentity } : {}),
    },
  });
  const request = await buildProviderRequest({
    providerKind: 'openAI', apiKey: 'sk-byok', modelID: MODEL_ID,
    messages: [{ role: 'user', content: 'hello' }],
    options: gate,
  }, async () => input.metadata);
  return request.body as Record<string, unknown>;
}

/** The { pointer: value } the recipe writes for an intent (an op without an intent applies to every non-off intent). */
function recipeWrites(recipeRef: string, intent: string): Array<{ pointer: string; value: unknown }> {
  return officialRecipes[recipeRef].requestOps
    .filter((op) => op.intent === undefined || op.intent === intent)
    .map((op) => ({ pointer: op.pointer, value: op.value }));
}

function at(body: Record<string, unknown>, pointer: string): unknown {
  const parts = pointer.split('/').slice(1).filter((part) => part !== '-');
  return parts.reduce<unknown>((value, key) => (value as Record<string, unknown> | undefined)?.[key], body);
}

const WEB_FIELDS = /"(?:tools|tool_choice|web_search_options|web_search|search_parameters|plugins)"|web_search/;

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  __resetMetadataClientForTest();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('CAP-BYOK · web search', () => {
  it('CAP-BYOK-WEB-01 recipe delivers web auto_available and the user turns web search on: the production builder request body contains the fields the recipe writes', async () => {
    const metadata = officialMetadata({ web: { state: 'auto_available', recipeRef: WEB_RECIPE } });
    const body = await sendOfficial({ metadata, web: 'automatic', reasoningIntent: 'off' });

    const writes = recipeWrites(WEB_RECIPE, 'automatic');
    expect(writes.length).toBeGreaterThan(0);
    for (const { pointer, value } of writes) {
      const actual = at(body, pointer);
      if (pointer.endsWith('/-')) expect(actual).toContainEqual(value);
      else expect(actual).toEqual(value);
    }
  });

  it('CAP-BYOK-WEB-02 same model without a recipe (control missing / unknown), preference still on: the request body has no web search fields', async () => {
    for (const controls of [{}, { web: { state: 'unknown' } }]) {
      const metadata = officialMetadata(controls);
      const body = await sendOfficial({ metadata, web: 'automatic', reasoningIntent: 'off' });
      expect(JSON.stringify(body)).not.toMatch(WEB_FIELDS);

      // Same even when the outbound gate lets it through: with no recipe the builder compiles no web search fields.
      const forced = await buildProviderRequest({
        providerKind: 'openAI', apiKey: 'sk-byok', modelID: MODEL_ID,
        messages: [{ role: 'user', content: 'hello' }],
        options: { supportsWebSearch: true, capabilityPreferences: { web: 'automatic', reasoningIntent: 'off' } },
      }, async () => metadata);
      expect(JSON.stringify(forced.body)).not.toMatch(WEB_FIELDS);
    }
  });
});

describe('CAP-BYOK · reasoning', () => {
  const reasoningMetadata = () => officialMetadata({
    reasoning: { state: 'auto_available', recipeRef: REASONING_RECIPE, availableIntents: [...ALL_TIERS] },
  });
  const effortFor = (tier: Tier) =>
    recipeWrites(REASONING_RECIPE, tier).find((write) => write.pointer === '/reasoning/effort')?.value;

  it('CAP-BYOK-REASON-01 recipe availableIntents has several tiers and one is picked: the request body holds the value the recipe writes for that tier', async () => {
    for (const tier of ALL_TIERS) {
      const body = await sendOfficial({ metadata: reasoningMetadata(), web: 'off', reasoningIntent: tier });
      expect(at(body, '/reasoning/effort')).toBe(effortFor(tier));
    }
    expect(effortFor('balanced')).toBe('medium');
  });

  it('CAP-BYOK-REASON-02 after upstream rejected max, a plain send picking max lands on the nearest tier (down first); rejecting deep does not affect balanced; only when all are rejected is the item omitted', async () => {
    rejectTier('max');
    const fallback = await sendOfficial({
      metadata: reasoningMetadata(), web: 'off', reasoningIntent: 'max', withRecoveryIdentity: true,
    });
    expect(at(fallback, '/reasoning/effort')).toBe(effortFor('deep'));

    localStorage.clear();
    rejectTier('deep');
    const balanced = await sendOfficial({
      metadata: reasoningMetadata(), web: 'off', reasoningIntent: 'balanced', withRecoveryIdentity: true,
    });
    expect(at(balanced, '/reasoning/effort')).toBe(effortFor('balanced'));
    // deep rejected, deep selected: first fall down to balanced
    const deep = await sendOfficial({
      metadata: reasoningMetadata(), web: 'off', reasoningIntent: 'deep', withRecoveryIdentity: true,
    });
    expect(at(deep, '/reasoning/effort')).toBe(effortFor('balanced'));

    localStorage.clear();
    rejectTier('low');
    const upward = await sendOfficial({
      metadata: reasoningMetadata(), web: 'off', reasoningIntent: 'low', withRecoveryIdentity: true,
    });
    // When there is no tier below, go up
    expect(at(upward, '/reasoning/effort')).toBe(effortFor('balanced'));

    localStorage.clear();
    for (const tier of ALL_TIERS) rejectTier(tier);
    const none = await sendOfficial({
      metadata: reasoningMetadata(), web: 'off', reasoningIntent: 'max', withRecoveryIdentity: true,
    });
    expect(none).not.toHaveProperty('reasoning');
  });
});

describe('CAP-BYOK · attachments', () => {
  const PDF = 'application/pdf';
  const RAW_PDF = 'JVBERi0xLjQKb3JpdmVv';

  it('CAP-BYOK-ATTACH-01 model nativeFileMimes contains PDF and the Anthropic Messages line attaches a PDF: the request body has a native document block and no text fallback', async () => {
    const anthropicModelId = 'claude-sonnet-byok';
    const metadata = {
      version: 2, updatedAt: '2026-10-11T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
      providers: {
        anthropic: {
          resolveMap: { [anthropicModelId]: anthropicModelId },
          models: { [anthropicModelId]: { transport: 'anthropic_messages' } },
        },
      },
    } as unknown as RuntimeMetadataResponse;
    const provider = officialProvider('anthropic', 'byok-anthropic');
    const model = {
      id: anthropicModelId, name: 'Claude', capabilities: ['text', 'file'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '$', nativeFileMimes: [PDF], pdfNativeDefault: true,
    } as AIModel;
    const message = {
      id: 'u1', role: 'user', text: 'Summarize the file', providerKind: 'anthropic', providerName: 'Anthropic',
      modelName: 'Claude', estimatedCost: 0, state: 'delivered', createdAt: '2026-10-11T00:00:00Z',
      attachments: [{
        id: 'report.pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF,
        originalBase64Data: RAW_PDF, base64Data: 'EXTRACTED-BODY-TEXT', extractedTotalLines: 1,
      } as Attachment],
    } as ChatMessage;

    const line = await resolveAttachmentLine({ provider, model, officialMetadata: async () => metadata });
    expect(line).toMatchObject({ transport: 'anthropic_messages', exact: true });
    const history = await buildChatHistory([message], model, line);
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'sk-byok', modelID: anthropicModelId,
      messages: history as never,
    }, async () => metadata);
    const body = JSON.stringify(request.body);

    expect(body).toContain('"type":"document"');
    expect(body).toContain(RAW_PDF);
    expect(body).not.toContain('EXTRACTED-BODY-TEXT');
    expect(body).not.toContain('<FILE_NAME>');
  });

  it('CAP-BYOK-ATTACH-02 model vision unknown (no positive image evidence in the catalog): the image recognition / photo library entry is hidden', () => {
    const model = {
      id: MODEL_ID, name: 'GPT-5.4', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '$', transport: 'openai_chat',
    } as AIModel;
    const capabilities = resolveAttachmentCapabilities(officialProvider(), model, {
      image: true, nativeFile: false, textFileInline: true,
    });
    expect(capabilities.supportsImage).toBe(false);
  });
});

describe('CAP-BYOK · tools (library leg, server-side retrieval unavailable)', () => {
  const ACTIVE_NOTION = {
    id: 'notion-1', provider: 'notion' as const, displayName: 'Notion', scopes: [], status: 'active' as const,
  };
  const DETERMINISTIC_TOOLS_400 = { error: { message: 'This model does not support tools' } };

  /** Fake /api/chat/stream: only records the library leg's request body. */
  function fakeChatStream(responses: Array<() => Response>) {
    const bodies: Array<Record<string, unknown>> = [];
    vi.stubGlobal('fetch', vi.fn(async (url: unknown, init?: RequestInit) => {
      if (!String(url).includes('/api/chat/stream')) throw new Error(`unexpected request ${String(url)}`);
      bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      const next = responses.shift();
      if (!next) throw new Error('unexpected extra leg');
      return next();
    }));
    return bodies;
  }
  const plainAnswer = () => new Response(
    'data: {"choices":[{"delta":{"content":"Plain answer"}}]}\n\ndata: [DONE]\n\n',
    { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
  );
  const toolsRejected = () => new Response(JSON.stringify(DETERMINISTIC_TOOLS_400), {
    status: 400,
    headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
  });

  function libraryModel(overrides: Partial<AIModel>): AIModel {
    return {
      id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '$', promptPrice: 0, completionPrice: 0,
      transport: 'openai_chat',
      ...overrides,
    } as AIModel;
  }

  function conversation(): Conversation {
    return {
      id: 'conv-byok', title: 'Research', hasCustomTitle: false, providerID: 'byok-openai', providerKind: 'openAI',
      modelID: 'gpt-4o', previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
      createdAt: '2026-10-11T00:00:00.000Z', updatedAt: '2026-10-11T00:00:00.000Z',
    } as Conversation;
  }

  /** Production library send orchestration: routing -> memory read -> agent loop -> send leg -> memory write. */
  async function sendLibraryTurn(model: AIModel) {
    // In production useStreamChat has already awaited initMetadata before sending: the official catalog is in hand, so routing can tell which path to take.
    await __seedMetadataCacheForTest({
      data: {
        version: 2, contractVersion: 1, updatedAt: '2026-10-11T00:00:00Z',
        profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
        providers: {
          openAI: { resolveMap: { 'gpt-4o': 'gpt-4o' }, models: { 'gpt-4o': { transport: 'openai_chat' } } },
        },
        providerConfigs: [],
      } as never,
      timestamp: Date.now(),
    });
    await initMetadata();
    const provider = { ...officialProvider(), models: [model] } as Provider;
    const conv = conversation();
    const store = createAppStore({ conversations: [conv], libraryConnections: [ACTIVE_NOTION] });
    const handle = sendLibraryMessage({ store, appendChunk: vi.fn(), te: (key) => key }, {
      text: 'Find the roadmap', prevMessages: [], conversation: conv, provider, model,
      reasoningMode: 'automatic', cancelledText: 'Cancelled', errorTitle: 'Failed', errorDetail: 'Try again',
      errorDetails: {
        library_needs_reauth: 'Reconnect', library_quota_exceeded: 'Quota',
        library_rate_limited: 'Busy', library_unavailable: 'Unavailable',
      },
    });
    await handle.done;
    return store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
  }

  it('CAP-BYOK-TOOL-01 model toolCall unknown, library on, server-side retrieval unavailable: the first-leg request body carries tools', async () => {
    const bodies = fakeChatStream([plainAnswer]);
    const model = libraryModel({});
    expect(model.toolCall).toBeUndefined();

    const assistant = await sendLibraryTurn(model);

    expect(assistant).toMatchObject({ state: 'delivered' });
    expect(bodies).toHaveLength(1);
    expect((bodies[0].tools as unknown[] | undefined)?.length).toBeGreaterThan(0);
    expect(bodies[0].toolChoice).toBe('auto');
  });

  it('CAP-BYOK-TOOL-02 hand-typed model id on an official connection, first leg deterministic tools 4xx: resend once without tools, record false, and the next first leg omits them', async () => {
    const bodies = fakeChatStream([toolsRejected, plainAnswer, plainAnswer]);
    const manual = libraryModel({ id: 'my-finetune-2026', name: 'my-finetune-2026', isManual: true });

    const first = await sendLibraryTurn(manual);
    expect(first).toMatchObject({ state: 'delivered', toolFallbackNotice: 'library_not_searched' });
    expect(bodies).toHaveLength(2);
    expect((bodies[0].tools as unknown[]).length).toBeGreaterThan(0);
    expect(bodies[1]).not.toHaveProperty('tools');

    // Remembered (eligible for memory write): the next send omits tools on its first leg, and only sends once.
    const second = await sendLibraryTurn(manual);
    expect(second).toMatchObject({ state: 'delivered', toolFallbackNotice: 'library_not_searched' });
    expect(bodies).toHaveLength(3);
    expect(bodies[2]).not.toHaveProperty('tools');
  });
});

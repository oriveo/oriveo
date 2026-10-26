import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * "Continue generating" goes back through the assembler: continueAnswering and sendMessage share one outbound chain, purpose=continue.
 * Assertions are on the request body the production Relay orchestration layer actually sent through transport.fetch and the outbound options handed to sendStream;
 * the continuation state goes through the real continuation-lifecycle (fake IndexedDB).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '@oriveo/core/providers/types';
import { CONTEXT_ASSEMBLE_CONSTANTS, ContextAssembler } from '@oriveo/core/context/assemble';
import { MemoryItems } from '@oriveo/core/context/memory-items';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  libraryRoute: null as null | 'agent' | 'server',
  runServerResearch: vi.fn(),
  intentGate: vi.fn(),
  parameterGate: vi.fn(),
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../library/routing', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../library/routing')>();
  return {
    ...actual,
    resolveLibraryResearchRouteNow: (...args: Parameters<typeof actual.resolveLibraryResearchRouteNow>) =>
      mocks.libraryRoute ?? actual.resolveLibraryResearchRouteNow(...args),
  };
});

// The two outbound gates pass through unchanged; only the input and output of the continuation call are recorded.
vi.mock('../stream-options', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../stream-options')>();
  mocks.intentGate.mockImplementation(actual.filterRequestCapabilityIntent);
  mocks.parameterGate.mockImplementation(actual.filterGenerationParameterOverrides);
  return {
    ...actual,
    filterRequestCapabilityIntent: (...args: Parameters<typeof actual.filterRequestCapabilityIntent>) => mocks.intentGate(...args),
    filterGenerationParameterOverrides: (...args: Parameters<typeof actual.filterGenerationParameterOverrides>) => mocks.parameterGate(...args),
  };
});

vi.mock('../library-server-research', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../library-server-research')>()),
  runLibraryServerResearch: (...args: unknown[]) => mocks.runServerResearch(...args),
}));

import { existsSync, readFileSync } from 'node:fs';
import { ContextContinuation } from '@oriveo/core/context/continuation';
import path from 'node:path';
import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { continueAnswering, sendMessage } from '../operations';
import type { filterRequestCapabilityIntent } from '../stream-options';
import { continueLibraryAnswering } from '../operations-library-send';
import { batchAppendStreaming } from '../stream-batcher';

const provider = {
  id: 'relay-continue', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const model = {
  id: 'continue-model', name: 'continue-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;

/** Official Grok: the catalog registers openai_responses, and the recipe's continuation basis is omit. */
const grokProvider = {
  id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'xai-key', apiKeyPreview: '••',
} as unknown as Provider;
const grokModel = { ...model, id: 'grok-fixture', name: 'grok-fixture' } as AIModel;
const GROK = { provider: grokProvider, model: grokModel };
type Connection = { provider: Provider; model: AIModel };
const RELAY: Connection = { provider, model };

async function seedGrokResponsesCatalog() {
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({
    data: replayMetadata('grok', grokModel.id, 'openai_responses', 'grok.responses.reasoning.v1'),
    timestamp: Date.now(),
  });
  await initMetadata();
}

const MEMORY = 'I prefer green tea';
const CONV_ID = 'conv-continue';
/** Local memory entry (injection reads store.memoryItems, no longer memoryText). */
const MEMORY_ITEM = MemoryItems.canonical({
  id: 'item-memory', kind: 'fact', content: MEMORY, mutationId: 'item-memory-m', deviceId: 'device-test',
  createdAt: '2026-10-01T00:00:00.000Z',
});

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
const ok = () => new Response(['data: {"choices":[{"delta":{"content":" more"}}]}', 'data: [DONE]'].map((f) => `${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

function newStore(messages: ChatMessage[] = [], connection: Connection = RELAY) {
  const conv = {
    id: CONV_ID, title: 'T', hasCustomTitle: false, providerID: connection.provider.id, modelID: connection.model.id,
    providerKind: connection.provider.kind, previewText: '', estimatedCost: 0,
    isDraft: false, messages, draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [connection.provider], conversations: [conv as never] });
  store.setState({ preferences: { ...store.getState().preferences, memoryText: MEMORY }, memoryItems: [MEMORY_ITEM] });
  mocks.store = store;
  return store;
}
const ctxOf = (store: ReturnType<typeof createAppStore>) => ({
  store, appendChunk: (chunk: string) => batchAppendStreaming(CONV_ID, chunk), te: (key: string) => key,
});
const conversationOf = (store: ReturnType<typeof createAppStore>) => store.getState().conversations[0];
const lastBody = () => sentBodies[sentBodies.length - 1];
const lastOptions = () => mocks.sendStream.mock.calls.at(-1)?.[5] as StreamOptions | undefined;

/** The continue system the assembler produces directly from the same input: the request body's system must equal it verbatim. */
function expectedContinueSystem(): string | null {
  return ContextAssembler.assemble({
    purpose: 'continue',
    window: { W: null, windowKind: 'total', maxOutput: {} },
    conversation: { id: CONV_ID, useMemory: true },
    memoryItems: [{ id: 'memory', kind: 'fact', content: MEMORY }],
    history: [],
  }).system;
}

async function continueTarget(store: ReturnType<typeof createAppStore>, messageId: string, connection: Connection = RELAY) {
  const conv = conversationOf(store);
  await continueAnswering(ctxOf(store), {
    messageId, conversation: conv, messages: conv.messages, ...connection, reasoningMode: 'automatic',
  }).done;
}

/** First send: the upstream stream hands out a previous_id continuation state (instructionsMode comes from the recipe; missing = basis not confirmed). */
async function sendCapturingPreviousId(
  store: ReturnType<typeof createAppStore>, instructionsMode?: 'resend' | 'omit', connection: Connection = RELAY,
) {
  const events: StreamEvent[] = [
    { type: 'delta', content: 'partial' } as StreamEvent,
    {
      type: 'continuation',
      continuation: {
        kind: 'previous_id', step: 1,
        state: { previousResponseId: 'resp_1', ...(instructionsMode ? { instructionsMode } : {}) },
      },
    } as StreamEvent,
    { type: 'done' } as StreamEvent,
  ];
  mocks.sendStream.mockImplementationOnce(() => ({
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
    abort: () => undefined,
  }));
  const conv = conversationOf(store);
  await sendMessage(ctxOf(store), {
    text: 'question', prevMessages: conv.messages, conversation: conv, ...connection, reasoningMode: 'automatic',
  }).done;
  const assistant = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
  expect(assistant.text).toBe('partial');
  return assistant;
}

beforeEach(() => {
  localStorage.clear();
  sentBodies.length = 0;
  __resetMetadataClientForTest();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
          return ok();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('context pipeline continue', () => {
  it('continue_uses_continue_prompt_and_keeps_target', async () => {
    const user = { id: 'u-1', role: 'user', text: 'question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z' } as ChatMessage;
    const target = { id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted', createdAt: '2026-10-15T00:00:02.000Z' } as ChatMessage;
    const store = newStore([user, target]);
    await continueTarget(store, target.id);

    const system = expectedContinueSystem();
    expect(system).toContain('<oriveo-memory>');
    expect(lastBody().messages).toEqual([
      { role: 'system', content: system },
      { role: 'user', content: 'question' },
      { role: 'assistant', content: 'partial' },
      { role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt },
    ]);
    expect(JSON.stringify(lastBody())).not.toContain('[Continue from where you left off]');
    const saved = conversationOf(store).messages.find((m) => m.id === target.id) as ChatMessage;
    expect(saved).toMatchObject({ state: 'delivered', text: 'partial more' });
  });

  it('continue_records_memory_ids', async () => {
    const user = { id: 'u-1', role: 'user', text: 'question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z' } as ChatMessage;
    const target = { id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted', createdAt: '2026-10-15T00:00:02.000Z' } as ChatMessage;
    const store = newStore([user, target]);
    await continueTarget(store, target.id);

    expect(JSON.stringify(lastBody())).toContain(MEMORY);
    const saved = conversationOf(store).messages.find((m) => m.id === target.id) as ChatMessage;
    expect(saved).toMatchObject({ state: 'delivered', text: 'partial more', memoryItemIds: [MEMORY_ITEM.id] });
  });

  it('continue_library_agent_no_tool_loop', async () => {
    // Continuing a library Agent answer is also text-only continuation: history cut at the target + the continuation sentence, no tool loop, no tools.
    const user = { id: 'u-1', role: 'user', text: 'question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z' } as ChatMessage;
    const target = {
      id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted', createdAt: '2026-10-15T00:00:02.000Z',
      libraryResearchEnabled: true, researchSteps: [{ id: 'step-1', tool: 'library_search', label: 'Search', status: 'completed', step: 1 }],
    } as unknown as ChatMessage;
    const store = newStore([user, target]);
    const assembleSpy = vi.spyOn(ContextAssembler, 'assemble');
    // The first answer went through the library Agent route.
    mocks.libraryRoute = 'agent';
    try {
      const conv = conversationOf(store);
      await continueLibraryAnswering(ctxOf(store), {
        messageId: target.id, conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
      }).done;
      const purposes = assembleSpy.mock.results.map((result) => (result.value as { purpose: string }).purpose);
      expect(purposes).toContain('continue');
      expect(purposes).not.toContain('toolLoopLeg');
    } finally {
      mocks.libraryRoute = null;
      assembleSpy.mockRestore();
    }

    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(lastBody().messages).toEqual([
      { role: 'system', content: expectedContinueSystem() },
      { role: 'user', content: 'question' },
      { role: 'assistant', content: 'partial' },
      { role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt },
    ]);
    expect(lastBody()).not.toHaveProperty('tools');
    const saved = conversationOf(store).messages.find((m) => m.id === target.id) as ChatMessage;
    expect(saved).toMatchObject({ state: 'delivered', text: 'partial more' });
  });

  it('continue_server_research_keeps_evidence', async () => {
    // Continuing on the server research route still passes libraryServerResearch: the evidence re-enters [D], and it is still a single purpose=continue request.
    const EVIDENCE = 'Kyoto evidence paragraph';
    mocks.runServerResearch.mockReset().mockResolvedValue({
      entries: [{ citation: 1, title: 'Kyoto', text: EVIDENCE }], citations: [], steps: [], warnings: [], documentCount: 1,
    });
    const user = { id: 'u-1', role: 'user', text: 'question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z' } as ChatMessage;
    const target = {
      id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted', createdAt: '2026-10-15T00:00:02.000Z',
      libraryResearchEnabled: true,
    } as unknown as ChatMessage;
    const store = newStore([user, target]);
    const assembleSpy = vi.spyOn(ContextAssembler, 'assemble');
    mocks.libraryRoute = 'server';
    try {
      const conv = conversationOf(store);
      await continueLibraryAnswering(ctxOf(store), {
        messageId: target.id, conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
      }).done;
      const purposes = assembleSpy.mock.results.map((result) => (result.value as { purpose: string }).purpose);
      expect(purposes).toContain('continue');
      expect(purposes).not.toContain('toolLoopLeg');
    } finally {
      mocks.libraryRoute = null;
      assembleSpy.mockRestore();
    }

    expect(mocks.runServerResearch).toHaveBeenCalledTimes(1);
    expect(mocks.runServerResearch.mock.calls[0]?.[0]).toMatchObject({ query: 'question' });
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    const messages = lastBody().messages;
    expect(messages.slice(0, 3)).toEqual([
      { role: 'system', content: expectedContinueSystem() },
      { role: 'user', content: 'question' },
      { role: 'assistant', content: 'partial' },
    ]);
    expect(JSON.stringify(messages.at(-1))).toContain(EVIDENCE);
    expect(JSON.stringify(messages.at(-1))).toContain(JSON.stringify(CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt).slice(1, -1));
    expect(lastBody()).not.toHaveProperty('tools');
    const saved = conversationOf(store).messages.find((m) => m.id === target.id) as ChatMessage;
    expect(saved).toMatchObject({ state: 'delivered', text: 'partial more' });
  });

  it('continue_stateful_single_decision', async () => {
    // Stateful continuation is decided once: the app layer's conclusion goes to the builder with the outbound options, and the builder attaches previous_response_id by it instead of deciding again from the recipe.
    // The fixture recipe's basis is resend while the app layer decided omit from the continuation state: deciding once per layer would diverge.
    await seedGrokResponsesCatalog();
    const store = newStore([], GROK);
    const assistant = await sendCapturingPreviousId(store, 'omit', GROK);
    const decideSpy = vi.spyOn(ContextContinuation, 'decideContinuation');
    const builtBodies: Array<Record<string, unknown>> = [];
    mocks.sendStream.mockImplementationOnce((_kind: unknown, apiKey: string, _modelID: string, messages: never, _baseURL: string, options: StreamOptions) => {
      const built = buildProviderRequest({
        providerKind: 'openAI', apiKey, modelID: 'gpt-fixture', messages,
        options: { reasoning: 'balanced' },
        ...(options.continuation ? { continuation: options.continuation } : {}),
        ...(options.continuationFingerprint ? { continuationFingerprint: options.continuationFingerprint } : {}),
        ...(options.continuationDecision ? { continuationDecision: options.continuationDecision } : {}),
      }, async () => replayMetadata('openAI', 'gpt-fixture', 'openai_responses', 'openai.responses.reasoning.v1'));
      return {
        stream: new ReadableStream<StreamEvent>({
          async start(controller) {
            builtBodies.push((await built).body as never);
            controller.enqueue({ type: 'delta', content: ' more' } as StreamEvent);
            controller.enqueue({ type: 'done' } as StreamEvent);
            controller.close();
          },
        }),
        abort: () => undefined,
      };
    });
    try {
      await continueTarget(store, assistant.id, GROK);
      expect(decideSpy).toHaveBeenCalledTimes(1);
    } finally {
      decideSpy.mockRestore();
    }
    expect(lastOptions()?.continuationDecision).toEqual({ kind: 'stateful', previousResponseId: 'resp_1', sendInstructions: false });
    expect(builtBodies[0]).toMatchObject({ previous_response_id: 'resp_1' });
    expect(builtBodies[0]).not.toHaveProperty('instructions');
  });

  it('continue_stateful_omit_drops_instructions', async () => {
    // Official Grok goes through openai_responses with recipe basis omit: the request body the production builder produces has only the continuation sentence and no instructions.
    await seedGrokResponsesCatalog();
    const store = newStore([], GROK);
    const assistant = await sendCapturingPreviousId(store, 'omit', GROK);
    const builtBodies: Array<Record<string, unknown>> = [];
    mocks.sendStream.mockImplementationOnce((_kind: unknown, apiKey: string, modelID: string, messages: never, _baseURL: string, options: StreamOptions) => {
      const built = buildProviderRequest({
        providerKind: 'grok', apiKey, modelID, messages,
        options: { reasoning: 'balanced' },
        ...(options.continuation ? { continuation: options.continuation } : {}),
        ...(options.continuationFingerprint ? { continuationFingerprint: options.continuationFingerprint } : {}),
        ...(options.continuationDecision ? { continuationDecision: options.continuationDecision } : {}),
      }, async () => replayMetadata('grok', grokModel.id, 'openai_responses', 'grok.responses.reasoning.v1'));
      return {
        stream: new ReadableStream<StreamEvent>({
          async start(controller) {
            builtBodies.push((await built).body as never);
            controller.enqueue({ type: 'delta', content: ' more' } as StreamEvent);
            controller.enqueue({ type: 'done' } as StreamEvent);
            controller.close();
          },
        }),
        abort: () => undefined,
      };
    });
    await continueTarget(store, assistant.id, GROK);

    // omit: only the continuation sentence is sent, no history or system; the fingerprint matches the previous leg.
    expect(mocks.sendStream.mock.calls.at(-1)?.[3]).toEqual([{ role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt }]);
    expect(builtBodies[0]).toMatchObject({ previous_response_id: 'resp_1' });
    expect(builtBodies[0]).not.toHaveProperty('instructions');
    expect(JSON.stringify(builtBodies[0])).not.toContain('question');
    expect(lastOptions()?.continuation).toMatchObject({ kind: 'previous_id', state: { previousResponseId: 'resp_1' } });
    expect(lastOptions()?.continuationFingerprint).toEqual({ systemChanged: false, modelChanged: false, checkpointChanged: false });
  });

  it('continue_outbound_drops_keys_filtered_by_capability_and_parameter_gates', async () => {
    // Continuation delegates to runChatOutbound: capability intent and generation parameters go through the same gates as sending, and keys the gates drop do not enter the continuation request body.
    const user = { id: 'u-1', role: 'user', text: 'question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z' } as ChatMessage;
    const target = { id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted', createdAt: '2026-10-15T00:00:02.000Z' } as ChatMessage;
    const store = newStore([user, target]);
    const transient = { temperature: { state: 'value', value: 0.2 } } as const;
    const conv = conversationOf(store);
    await continueAnswering(ctxOf(store), {
      messageId: target.id, conversation: conv, messages: conv.messages, ...RELAY,
      reasoningMode: 'deep', webSearchEnabled: true, transientGenerationParameters: transient,
    }).done;

    // The actual input and output of this continuation on the two gates: the thinking level, web search and temperature are all dropped by the gates.
    const intentCall = mocks.intentGate.mock.calls.at(-1)?.[0] as Parameters<typeof filterRequestCapabilityIntent>[0];
    expect(intentCall).toMatchObject({ reasoningMode: 'deep', webSearchEnabled: true });
    const gatedIntent = mocks.intentGate.mock.results.at(-1)?.value as ReturnType<typeof filterRequestCapabilityIntent>;
    expect(gatedIntent.reasoning).toBeUndefined();
    expect(gatedIntent.supportsWebSearch).toBe(false);
    expect(mocks.parameterGate.mock.calls.at(-1)?.[2]).toEqual(transient);
    expect(mocks.parameterGate.mock.results.at(-1)?.value).toBeUndefined();

    const options = lastOptions();
    expect(options?.reasoning).toBeUndefined();
    expect(options?.supportsWebSearch).toBe(false);
    expect(options?.generationParameters).toBeUndefined();
    const body = lastBody() as Record<string, unknown>;
    for (const key of ['reasoning', 'reasoning_effort', 'thinking', 'temperature', 'tools', 'web_search_options']) {
      expect(body, `continue body must not carry ${key}`).not.toHaveProperty(key);
    }
    expect(body.messages).toEqual([
      { role: 'system', content: expectedContinueSystem() },
      { role: 'user', content: 'question' },
      { role: 'assistant', content: 'partial' },
      { role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt },
    ]);
  });

  it('continue_non_responses_protocol_full_plan', async () => {
    // previous_response_id only exists in the Responses protocol: this time goes through relay chat completions, so even with previous_id state only the full plan can be sent.
    const store = newStore();
    const assistant = await sendCapturingPreviousId(store, 'omit');
    await continueTarget(store, assistant.id);

    expect(lastOptions()?.continuationDecision).toEqual({ kind: 'fullPlan' });
    expect(lastBody().messages).toEqual([
      { role: 'system', content: expectedContinueSystem() },
      { role: 'user', content: 'question' },
      { role: 'assistant', content: 'partial' },
      { role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt },
    ]);
  });

  it('continue_mode_missing_sends_full_plan', async () => {
    const store = newStore();
    const assistant = await sendCapturingPreviousId(store);
    await continueTarget(store, assistant.id);

    // The recipe did not confirm the continuation basis: full plan (system + history cut at the target + continuation sentence).
    expect(lastBody().messages).toEqual([
      { role: 'system', content: expectedContinueSystem() },
      { role: 'user', content: 'question' },
      { role: 'assistant', content: 'partial' },
      { role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt },
    ]);
    expect(lastOptions()?.continuationFingerprint).toEqual({ systemChanged: false, modelChanged: false, checkpointChanged: false });
  });

  // Replay-type continuation: dispatch replays the target assistant by the recipe (insertReplayBeforeFinalUser),
  // so the continue outbound history must not carry it again: the request body the production buildProviderRequest produces may contain only one assistant.
  for (const item of REPLAY_CASES) {
    it(`continue_replay_kind_drops_target (${item.continuation.kind})`, async () => {
      const store = newStore();
      const assistant = await sendCapturingContinuation(store, item.continuation);
      const builtBodies: Array<{ messages: Array<{ role: string; content: unknown }> }> = [];
      mocks.sendStream.mockImplementationOnce((_kind: unknown, apiKey: string, modelID: string, messages: never, _baseURL: string, options: StreamOptions) => {
        const built = buildProviderRequest({
          providerKind: item.providerKind, apiKey, modelID: item.modelID, messages,
          options: { reasoning: item.reasoning },
          ...(options.continuation ? { continuation: options.continuation } : {}),
        }, async () => replayMetadata(item.providerKind, item.modelID, item.transport, item.recipeRef));
        return {
          stream: new ReadableStream<StreamEvent>({
            async start(controller) {
              builtBodies.push((await built).body as never);
              controller.enqueue({ type: 'delta', content: ' more' } as StreamEvent);
              controller.enqueue({ type: 'done' } as StreamEvent);
              controller.close();
            },
          }),
          abort: () => undefined,
        };
      });
      await continueTarget(store, assistant.id);

      expect(lastOptions()?.continuation).toMatchObject({ kind: item.continuation.kind });
      const roles = builtBodies[0]!.messages.map((message) => message.role);
      expect(roles.filter((role) => role === 'assistant')).toHaveLength(1);
      expect(roles.at(-1)).toBe('user');
      expect(JSON.stringify(builtBodies[0]!.messages.filter((message) => message.role === 'assistant')))
        .toContain(item.replayMarker);
    });
  }
});

const REPLAY_CASES: Array<{
  providerKind: 'anthropic' | 'deepseek'; modelID: string; transport: string; recipeRef: string;
  continuation: ContinuationIntent; replayMarker: string; reasoning: 'balanced' | 'deep';
}> = [
  {
    providerKind: 'anthropic', modelID: 'claude-fixture', transport: 'anthropic_messages', recipeRef: 'anthropic.messages.reasoning.v1',
    continuation: { kind: 'replay_blocks', step: 1, state: { blocks: [{ type: 'thinking', thinking: 'opaque', signature: 'sig' }, { type: 'text', text: 'partial' }] } },
    replayMarker: 'sig', reasoning: 'balanced',
  },
  {
    providerKind: 'deepseek', modelID: 'deepseek-fixture', transport: 'openai_chat', recipeRef: 'deepseek.chat.reasoning.v1',
    continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{ role: 'assistant', content: 'partial', reasoning_content: 'opaque-reasoning' }] } },
    replayMarker: 'opaque-reasoning', reasoning: 'deep',
  },
];

/** First send: the upstream stream hands out a replay-type continuation state. */
async function sendCapturingContinuation(store: ReturnType<typeof createAppStore>, continuation: ContinuationIntent) {
  const events: StreamEvent[] = [
    { type: 'delta', content: 'partial' } as StreamEvent,
    { type: 'continuation', continuation } as StreamEvent,
    { type: 'done' } as StreamEvent,
  ];
  mocks.sendStream.mockImplementationOnce(() => ({
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
    abort: () => undefined,
  }));
  const conv = conversationOf(store);
  await sendMessage(ctxOf(store), {
    text: 'question', prevMessages: conv.messages, conversation: conv, provider, model, reasoningMode: 'automatic',
  }).done;
  const assistant = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
  expect(assistant.text).toBe('partial');
  return assistant;
}

function repoFile(relative: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const next = path.dirname(current);
    if (next === current) throw new Error(relative);
    current = next;
  }
}

const CANONICAL_INTENTS = ['off', 'low', 'balanced', 'deep', 'max'];
/** The real recipe from the production capability runtime registry, delivered in the same shape as the Server (the reasoning control carries availableIntents). */
function replayMetadata(providerKind: string, modelID: string, transport: string, recipeRef: string): never {
  const registry = JSON.parse(readFileSync(repoFile('shared/capabilityrecipe/capability_runtime.v1.json'), 'utf8')) as { recipes: Record<string, { requestOps?: Array<{ intent?: string }> }> };
  const recipe = registry.recipes[recipeRef]!;
  const intents = new Set((recipe.requestOps ?? []).map((op) => op.intent).filter((intent): intent is string => typeof intent === 'string'));
  return {
    version: 2, updatedAt: '2026-10-15T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    capabilityRuntime: { schemaVersion: 2, revision: 'fixture', generatedAt: '2026-10-15T00:00:00Z', recipes: registry.recipes, controlDefinitions: {}, sourceIndex: {} },
    providers: { [providerKind]: { resolveMap: { [modelID]: modelID }, models: { [modelID]: {
      transport,
      capabilityControls: { reasoning: { state: 'auto_available', recipeRef, availableIntents: CANONICAL_INTENTS.filter((intent) => intents.has(intent)) } },
    } } } },
  } as never;
}

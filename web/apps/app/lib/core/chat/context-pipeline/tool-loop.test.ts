import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Library Agent tool loop: the assembler (purpose toolLoopLeg) produces the single system, identical byte for byte on every leg.
 * Assertions are on the per-leg requests the production path sendLibraryMessage -> runLibraryAgentLoop hands to sendLibraryAgentLeg.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamHandle } from '@oriveo/core/providers/types';
import type { ProxyMessage } from '@oriveo/core/providers/request-builders/runtime';
import { ContextAssembler, type ContextPlan } from '@oriveo/core/context/assemble';
import { MemoryItems } from '@oriveo/core/context/memory-items';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';

const mocks = vi.hoisted(() => ({
  legs: [] as Array<{ messages: ProxyMessage[]; options: unknown; toolChoice: unknown }>,
  store: null as unknown,
  /** Catalog window; the over-budget case makes it small so the first leg crosses the 0.90 line. */
  contextLength: 128_000,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../library/api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../library/api')>()),
  executeLibraryTool: vi.fn(async () => ({ result: { hits: [{ docId: 'doc-1', source: 'notion', title: 'Roadmap' }] } })),
}));
vi.mock('../../library/confirmation', () => ({
  requestLibraryConfirmation: vi.fn(),
  clearOwnLibraryConfirmation: vi.fn(),
}));
vi.mock('../stream-options', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../stream-options')>()),
  buildStreamOptionsFromIntent: vi.fn(() => ({})),
  buildProviderStreamOptions: vi.fn(() => ({})),
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  resolveGenerationProfileRef: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => undefined),
  getModelTransport: vi.fn(() => 'openai_chat'),
  getLibraryRuntimeConfig: vi.fn(() => ({
    version: 2,
    toolDescriptions: {},
    maxSteps: 4,
    toolTimeoutMs: 1000,
    maxEmptyHits: 2,
    maxSelfCorrections: 2,
    tokenBudget: 0,
    estimatedTokensPerStep: 2_000,
    highCostConfirmationUSD: 0.25,
    weakModelDenylist: [],
    sensitiveGateEnabled: true,
  })),
  hasCatalogModel: vi.fn(() => true),
  resolveCatalogModel: vi.fn(() => ({ contextLength: mocks.contextLength })),
  isMetadataSnapshotConfirmed: vi.fn(() => true),
  getProviderCatalogStatus: vi.fn(() => 'loaded'),
}));
vi.mock('../../providers/proxy-client', () => ({
  sendLibraryAgentLeg: vi.fn((_kind: unknown, _key: unknown, _model: unknown, messages: ProxyMessage[], _tools: unknown, _base: unknown, options: unknown, toolChoice: unknown) => {
    mocks.legs.push({ messages: structuredClone(messages), options: structuredClone(options), toolChoice });
    return mocks.legs.length === 1
      ? streamLeg([{
          type: 'tool_calls',
          toolCalls: [{ index: 0, id: 'call_1', type: 'function', name: 'library_search', arguments: '{"query":"roadmap"}' }],
        } as StreamEvent])
      : streamLeg([{ type: 'delta', content: 'Grounded answer.' } as StreamEvent]);
  }),
}));

import { createAppStore } from '../../store/app-store';
import { LIBRARY_TOOL_SAFETY_PROMPT, sendLibraryMessage } from '../operations-library-send';
import { prepareToolLoopContext } from '../agent-send-shared';
import { createAssistantMessage, createUserMessage } from '../message-factory';
import { putContextCheckpoint } from '../../../infra/storage/context-checkpoint-store';

function streamLeg(events: StreamEvent[]): StreamHandle {
  return {
    abort: () => undefined,
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
  };
}

const MEMORY = 'I prefer green tea';
const CONV_ID = 'conv-tool-loop';
/** Local memory entries (injection reads store.memoryItems, no longer memoryText). */
const MEMORY_ITEM = MemoryItems.canonical({
  id: 'item-memory', kind: 'fact', content: MEMORY, mutationId: 'item-memory-m', deviceId: 'device-test',
  createdAt: '2026-10-01T00:00:00.000Z',
});
const model = {
  id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'], toolCall: true, reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '$', promptPrice: 0, completionPrice: 0,
} as AIModel;
const provider = {
  id: 'provider-1', kind: 'openAI', status: { kind: 'connected' }, models: [model], catalogModels: [model],
  apiKey: 'sk-test', apiKeyPreview: 'sk-...test',
} as Provider;

function newStore(history: ChatMessage[] = []) {
  const conv: Conversation = {
    id: CONV_ID, title: 'T', hasCustomTitle: false, providerID: provider.id, providerKind: 'openAI', modelID: model.id,
    previewText: '', estimatedCost: 0, isDraft: false, messages: history, draftText: '',
    createdAt: '2026-10-15T00:00:00.000Z', updatedAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({
    providers: [provider],
    conversations: [conv],
    libraryConnections: [{ id: 'notion-1', provider: 'notion', displayName: 'Notion', scopes: [], status: 'active' }],
  });
  store.setState({ preferences: { ...store.getState().preferences, memoryText: MEMORY }, memoryItems: [MEMORY_ITEM] });
  mocks.store = store;
  return { store, conv };
}

async function sendOnce(history: ChatMessage[] = []) {
  const { store, conv } = newStore(history);
  await sendLibraryMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
    text: 'Find the roadmap', prevMessages: history, conversation: conv, provider, model, reasoningMode: 'automatic',
    cancelledText: 'Cancelled', errorTitle: 'Failed', errorDetail: 'Try again',
  }).done;
  return store;
}

/** The toolLoopLeg system the assembler produces directly from the same input: the system in every leg's request body must equal it verbatim. */
function expectedToolLoopSystem(): string | null {
  return ContextAssembler.assemble({
    purpose: 'toolLoopLeg',
    window: { W: null, windowKind: 'total', maxOutput: {} },
    conversation: { id: CONV_ID, useMemory: true },
    memoryItems: [{ id: 'memory', kind: 'fact', content: MEMORY }],
    history: [],
    toolSafety: LIBRARY_TOOL_SAFETY_PROMPT,
  }).system;
}

/** A long history already answered: about 2k characters per turn, so with a small window the first leg always crosses the 0.90 line. */
function longHistory(rounds: number): ChatMessage[] {
  const messages: ChatMessage[] = [];
  for (let index = 0; index < rounds; index += 1) {
    const baseCreatedAt = new Date(Date.UTC(2026, 9, 15, 0, index)).toISOString();
    const user = { ...createUserMessage({ text: `Old question ${index} ${'q'.repeat(2_000)}`, provider, model }), createdAt: baseCreatedAt };
    const assistant = {
      ...createAssistantMessage({ provider, model, baseCreatedAt }),
      text: `Old answer ${index} ${'a'.repeat(2_000)}`,
      state: 'delivered',
    } as ChatMessage;
    messages.push(user, assistant);
  }
  return messages;
}

const CHECKPOINT_TAG = '<oriveo-context-checkpoint';

beforeEach(() => {
  localStorage.clear();
  mocks.legs.length = 0;
  mocks.contextLength = 128_000;
});

describe('context pipeline toolLoopLeg', () => {
  it('tool_loop_single_system_with_safety', async () => {
    const store = await sendOnce();
    const system = expectedToolLoopSystem();
    expect(system).toContain('<oriveo-memory>');
    expect(system?.endsWith(LIBRARY_TOOL_SAFETY_PROMPT)).toBe(true);
    const first = mocks.legs[0].messages;
    expect(first.filter((message) => message.role === 'system')).toEqual([{ role: 'system', content: system }]);
    expect(first[0]).toEqual({ role: 'system', content: system });
    expect(first.at(-1)).toEqual({ role: 'user', content: 'Find the roadmap' });
    const assistant = store.getState().conversations[0].messages.find((message) => message.role === 'assistant');
    expect(assistant).toMatchObject({ state: 'delivered', text: 'Grounded answer.' });
  });

  it('tool_loop_records_memory_ids', async () => {
    const store = await sendOnce();
    expect(mocks.legs).toHaveLength(2);
    expect(JSON.stringify(mocks.legs[0].messages)).toContain(MEMORY);
    const assistant = store.getState().conversations[0].messages.find((message) => message.role === 'assistant');
    expect(assistant).toMatchObject({ state: 'delivered', memoryItemIds: [MEMORY_ITEM.id] });
  });

  it('tool_loop_legs_same_system', async () => {
    await sendOnce();
    expect(mocks.legs).toHaveLength(2);
    const systems = mocks.legs.map((leg) => leg.messages.filter((message) => message.role === 'system'));
    expect(systems[0]).toHaveLength(1);
    expect(systems[1]).toEqual(systems[0]);
    // The host feed-back is a tool result, not a second system message.
    expect(mocks.legs[1].messages.slice(1).every((message) => message.role !== 'system')).toBe(true);
    expect(mocks.legs[1].messages.some((message) => message.role === 'tool')).toBe(true);
  });

  it('tool_leg_transport_carries_plan_system_and_dynamic', async () => {
    // The Web main path's toolLoopLeg does not produce [D] for now: a recall is added on the assembler input, measuring that the plan's [D] reaches the outbound request unchanged.
    const assemble = ContextAssembler.assemble.bind(ContextAssembler);
    const assembleSpy = vi.spyOn(ContextAssembler, 'assemble').mockImplementation((input) => assemble(
      input.purpose === 'toolLoopLeg' ? { ...input, dynamic: { recall: [{ id: 'r1', text: 'Prefers concise answers' }] } } : input,
    ));
    try {
      await sendOnce();
      const plan = assembleSpy.mock.results
        .map((result) => result.value as ContextPlan)
        .filter((candidate) => candidate.purpose === 'toolLoopLeg')
        .at(-1)!;
      const dynamic = plan.messages!.at(-1)!.blocks
        .filter((block) => block.kind === 'dynamic').map((block) => block.text).join('\n\n');
      expect(dynamic).toContain('<oriveo-recall>');
      const first = mocks.legs[0];
      expect(first.messages[0]).toEqual({ role: 'system', content: plan.system });
      expect(first.messages.filter((message) => message.role === 'system')).toHaveLength(1);
      expect((first.options as { dynamicText?: string }).dynamicText).toBe(dynamic);
      expect(first.messages.at(-1)).toEqual({ role: 'user', content: `Find the roadmap\n\n${dynamic}` });
    } finally {
      assembleSpy.mockRestore();
    }
  });

  it('tool_loop_first_leg_over_budget_uses_p2_fallback', async () => {
    mocks.contextLength = 8_000;
    const history = longHistory(12);
    await sendOnce(history);
    const first = mocks.legs[0].messages;
    const wire = JSON.stringify(first);
    // Fallback: the earlier history is folded into a checkpoint and only the tail is kept; this turn's user message stays unchanged at the end.
    expect(wire).toContain(CHECKPOINT_TAG);
    expect(wire).not.toContain('Old question 0 ');
    expect(first.filter((message) => message.role === 'system')).toHaveLength(1);
    expect(first.at(-1)).toMatchObject({ role: 'user', content: 'Find the roadmap' });
    // Later legs reuse the same projection after the fallback.
    expect(JSON.stringify(mocks.legs[1].messages)).toContain(CHECKPOINT_TAG);
  });

  it('tool_loop_degraded_reanswer_uses_p2_fallback', async () => {
    mocks.contextLength = 8_000;
    const history = longHistory(12);
    const { store, conv } = newStore(history);
    const current = createUserMessage({ text: 'Find the roadmap', provider, model });
    const context = await prepareToolLoopContext({ store } as never, {
      conversation: conv, conversationId: CONV_ID, provider, model,
      messages: [...history, current], latestUserText: 'Find the roadmap', toolSafety: LIBRARY_TOOL_SAFETY_PROMPT,
    });
    const reanswer = await context.chatRequest({});
    const wire = JSON.stringify(reanswer);
    expect(wire).toContain(CHECKPOINT_TAG);
    expect(wire).not.toContain('Old question 0 ');
    expect(reanswer.filter((message) => message.role === 'system')).toHaveLength(1);
    // The planned request of later legs is replaced by the one after the fallback.
    expect(JSON.stringify(context.planned.messages)).not.toContain('Old question 0 ');
  });

  it('tool_loop_first_leg_ignores_stored_checkpoint', async () => {
    mocks.contextLength = 8_000;
    const history = longHistory(12);
    await putContextCheckpoint({
      conversationId: CONV_ID, checkpointId: 'cp-stored', kind: 'summary',
      coversFrom: history[0].id, coversTo: history[history.length - 3].id, coversDigest: 'digest',
      messagesCovered: history.length - 2, userMessageIds: history.filter((m) => m.role === 'user').map((m) => m.id),
      text: 'STORED-CHECKPOINT-TEXT', summary: 'STORED-SUMMARY', language: 'en', model: model.id,
      packerVersion: '1', createdAt: Date.now(), cost: null,
    });
    await sendOnce(history);
    const wire = JSON.stringify(mocks.legs[0].messages);
    // The library row is not used as a prefix.
    expect(wire).not.toContain('STORED-CHECKPOINT-TEXT');
    expect(wire).toContain(CHECKPOINT_TAG);
  });

  it('tool_loop_fallback_keeps_latest_checkpoint_summary', async () => {
    mocks.contextLength = 8_000;
    const history = longHistory(12);
    await putContextCheckpoint({
      conversationId: CONV_ID, checkpointId: 'cp-summary', kind: 'summary',
      coversFrom: history[0].id, coversTo: history[history.length - 3].id,
      // Effective winner: only when the digest matches the current history does latestValid pick it.
      coversDigest: ContextCheckpoint.coversDigest(history.slice(0, -2).map((m) => ({ id: m.id, text: m.text ?? '' }))),
      messagesCovered: history.length - 2, userMessageIds: history.filter((m) => m.role === 'user').map((m) => m.id),
      text: 'STORED-CHECKPOINT-TEXT', summary: '  STORED-SUMMARY  ', language: 'en', model: model.id,
      packerVersion: '1', createdAt: Date.now(), cost: null,
    });
    await sendOnce(history);
    const wire = JSON.stringify(mocks.legs[0].messages);
    // The fallback carries the winner's summary, but does not use the library row as a prefix.
    expect(wire).toContain(CHECKPOINT_TAG);
    expect(wire).toContain('STORED-SUMMARY');
    expect(wire).not.toContain('STORED-CHECKPOINT-TEXT');
  });
});

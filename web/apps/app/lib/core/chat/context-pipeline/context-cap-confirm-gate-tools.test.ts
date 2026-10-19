import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Confirmation gate (Web only): the library agent and the first MCP leg go through the gate as well; cancel = rollback, and the first leg is never sent.
 * Goes through the production sendLibraryMessage (agent routing) and sendMcpToolMessage; the leg executor sendLibraryAgentLeg is a stand-in that only counts.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, Conversation, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  legs: 0,
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../library/api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../library/api')>()),
  executeLibraryTool: vi.fn(async () => ({ result: { hits: [] } })),
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
    version: 2, toolDescriptions: {}, maxSteps: 4, toolTimeoutMs: 1000, maxEmptyHits: 2, maxSelfCorrections: 2,
    tokenBudget: 0, estimatedTokensPerStep: 2_000, highCostConfirmationUSD: 0.25, weakModelDenylist: [], sensitiveGateEnabled: true,
  })),
  hasCatalogModel: vi.fn(() => true),
  resolveCatalogModel: vi.fn(() => ({ contextLength: 128_000 })),
  isMetadataSnapshotConfirmed: vi.fn(() => true),
  getProviderCatalogStatus: vi.fn(() => 'loaded'),
}));
vi.mock('../../providers/proxy-client', () => ({
  sendLibraryAgentLeg: vi.fn(() => {
    mocks.legs += 1;
    throw new Error('leg must not be sent after cancel');
  }),
}));
// MCP session stand-in: the gate sits before the first leg, so no tool is reached after a cancel.
vi.mock('../../mcp/mcp-chat', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../mcp/mcp-chat')>()),
  createMcpSendSession: vi.fn(() => ({ entries: [], steps: () => [] })),
}));

import { createAppStore, type AppStore } from '../../store/app-store';
import { sendLibraryMessage } from '../operations-library-send';
import { sendMcpToolMessage } from '../operations-mcp-send';
import { type CapConfirmRequest, resolveCapConfirmation } from '../context-visibility/cap-confirm-gate';

const CONV_ID = 'conv-gate-tools';
const model = {
  id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'], toolCall: true, reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '$', promptPrice: 0, completionPrice: 0,
} as AIModel;
const provider = {
  id: 'provider-1', kind: 'openAI', status: { kind: 'connected' }, models: [model], catalogModels: [model],
  apiKey: 'sk-test', apiKeyPreview: 'sk-...test',
} as Provider;

function longText(tokens: number): string {
  return 'The quick brown fox jumps over the lazy dog. '.repeat(Math.ceil(tokens / 10));
}

function newStore(): { store: StoreApi<AppStore>; conv: Conversation } {
  const conv: Conversation = {
    id: CONV_ID, title: 'T', hasCustomTitle: false, providerID: provider.id, providerKind: 'openAI', modelID: model.id,
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '', contextCap: 32000,
    createdAt: '2026-10-17T00:00:00.000Z', updatedAt: '2026-10-17T00:00:00.000Z',
  };
  const store = createAppStore({
    providers: [provider],
    conversations: [conv],
    libraryConnections: [{ id: 'notion-1', provider: 'notion', displayName: 'Notion', scopes: [], status: 'active' }],
  });
  mocks.store = store;
  return { store, conv };
}

function cancelEveryConfirm(store: StoreApi<AppStore>): CapConfirmRequest[] {
  const seen: CapConfirmRequest[] = [];
  store.subscribe((state, previous) => {
    for (const request of Object.values(state.contextCapConfirmations)) {
      if (Object.values(previous.contextCapConfirmations).includes(request)) continue;
      seen.push(request);
      queueMicrotask(() => resolveCapConfirmation(request.conversationId, { kind: 'cancel' }));
    }
  });
  return seen;
}

function expectRolledBack(store: StoreApi<AppStore>, asked: CapConfirmRequest[], outcome: unknown, text: string) {
  expect(asked).toHaveLength(1);
  expect(asked[0].decision.kind).toBe('overCap');
  expect(asked[0].B).toBe(32000);
  expect(mocks.legs).toBe(0);
  expect(store.getState().conversations.find((c) => c.id === CONV_ID)?.messages).toEqual([]);
  expect(outcome).toMatchObject({ rolledBack: { text } });
  expect(store.getState().contextCapConfirmations).toEqual({});
}

beforeEach(() => {
  localStorage.clear();
  mocks.legs = 0;
});

describe('context cap confirm gate (tool loop first leg)', () => {
  it('gate_over_cap_cancel_rolls_back_library_agent', async () => {
    const { store, conv } = newStore();
    const asked = cancelEveryConfirm(store);
    const text = longText(50000);
    const outcome = await sendLibraryMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      cancelledText: 'Cancelled', errorTitle: 'Failed', errorDetail: 'Try again',
    }).done;
    expectRolledBack(store, asked, outcome, text);
  });

  it('gate_over_cap_cancel_rolls_back_mcp', async () => {
    const { store, conv } = newStore();
    const asked = cancelEveryConfirm(store);
    const text = longText(50000);
    const outcome = await sendMcpToolMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      plan: { tools: [{ name: 'search' }] } as never,
    }).done;
    expectRolledBack(store, asked, outcome, text);
  });

  it('gate_not_asking_stop_interrupts_library_agent', async () => {
    const { store, conv } = newStore();
    const asked = cancelEveryConfirm(store);
    const handle = sendLibraryMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      cancelledText: 'Cancelled', errorTitle: 'Failed', errorDetail: 'Try again',
    });
    handle.abort();
    const outcome = await handle.done;
    expectInterruptedNotRolledBack(store, asked, outcome);
  });

  it('gate_not_asking_stop_interrupts_mcp', async () => {
    const { store, conv } = newStore();
    const asked = cancelEveryConfirm(store);
    const handle = sendMcpToolMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      plan: { tools: [{ name: 'search' }] } as never,
    });
    handle.abort();
    const outcome = await handle.done;
    expectInterruptedNotRolledBack(store, asked, outcome);
  });
});

// A stop when the gate did not ask (P̂ far below B) is not a cancel at the confirmation: the message pair stays, the assistant message ends as interrupted, and nothing is handed back to the draft.
function expectInterruptedNotRolledBack(store: StoreApi<AppStore>, asked: CapConfirmRequest[], outcome: unknown) {
  expect(asked).toHaveLength(0);
  expect(outcome).not.toMatchObject({ rolledBack: expect.anything() });
  const messages = store.getState().conversations.find((c) => c.id === CONV_ID)?.messages ?? [];
  expect(messages.map((m) => [m.role, m.state])).toEqual([['user', 'delivered'], ['assistant', 'interrupted']]);
}

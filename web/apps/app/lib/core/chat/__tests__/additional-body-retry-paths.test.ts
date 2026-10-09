// @vitest-environment jsdom
/**
 * "Retry without the additional request body" on the three paths library / continue answering / MCP:
 * the failure sets the exit through the production send function, and when retrying with the omit flag the
 * real outbound options carry no additional body while the stored record stays unchanged.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamHandle } from '../../providers/types';

const mocks = vi.hoisted(() => ({
  sendLibraryAgentLeg: vi.fn(),
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  mcpTools: [] as unknown[],
  mcpSteps: [] as unknown[],
}));

vi.mock('../../providers/proxy-client', async () => ({
  ...await vi.importActual<typeof import('../../providers/proxy-client')>('../../providers/proxy-client'),
  sendLibraryAgentLeg: (...args: unknown[]) => mocks.sendLibraryAgentLeg(...args),
}));
vi.mock('../../library/routing', async () => ({
  ...await vi.importActual<typeof import('../../library/routing')>('../../library/routing'),
  resolveLibraryResearchRouteNow: () => 'agent',
}));
vi.mock('../../mcp/mcp-chat', () => ({
  adoptMcpDraftServers: vi.fn(),
  createMcpSendSession: () => ({ entries: [], steps: () => mocks.mcpSteps }),
  prepareMcpSend: () => ({ tools: mocks.mcpTools }),
}));
vi.mock('../../mcp/mcp-store', async () => ({
  ...await vi.importActual<typeof import('../../mcp/mcp-store')>('../../mcp/mcp-store'),
  currentMcpRuntimeConfig: () => ({}),
}));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../../metadata/metadata-client', async () => ({
  ...await vi.importActual<typeof import('../../metadata/metadata-client')>('../../metadata/metadata-client'),
  getMetadataRevision: () => undefined,
  getCapabilityRuntime: () => null,
  resolveGenerationProfileRef: vi.fn(() => undefined),
  resolveCatalogModel: vi.fn(),
  getDeclaredReasoningLevels: vi.fn(() => []),
  getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => null),
}));

import { createAppStore } from '../../store/app-store';
import { retryLibraryMessage, sendLibraryMessage } from '../operations-library-send';
import { sendMcpToolMessage } from '../operations-mcp-send';
import { retryMessage } from '../operations';
import type { McpToolPlan } from '@oriveo/core/mcp/index';
import { additionalBodyScope, loadAdditionalBody, saveAdditionalBody } from '../additional-body-settings';

const provider = {
  id: 'p-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••test',
} as unknown as Provider;
const model = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: 'standard',
} as AIModel;
const presentation = { cancelledText: 'cancelled', errorTitle: 'library failed', errorDetail: 'library detail' };
const te = (key: string) => key;
const libraryConnections = [{ id: 'lc-1', provider: 'notion', displayName: 'Notion', scopes: [], status: 'active' }] as never;

function handleOf(events: StreamEvent[]): StreamHandle {
  return {
    stream: new ReadableStream<StreamEvent>({
      start(ctrl) { for (const event of events) ctrl.enqueue(event); ctrl.close(); },
    }),
    abort: vi.fn(),
  };
}
const frame: StreamEvent = { type: 'error', error: 'Unknown field: top_k', errorKind: 'upstream', source: 'provider', streamErrorFrame: true };

function conversation(): Conversation {
  return {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'gpt-4', previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
  } as Conversation;
}
const assistantOf = (store: ReturnType<typeof createAppStore>) =>
  store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
const optionsOfCall = (index: number) => mocks.sendLibraryAgentLeg.mock.calls[index][6] as { additionalBody?: { raw: string } } | undefined;

beforeEach(() => {
  localStorage.clear();
  mocks.sendLibraryAgentLeg.mockReset();
  mocks.mcpTools = [];
  mocks.mcpSteps = [];
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
});

describe('library agent path', () => {
  it('upstream rejection -> exit + title + raw frame; retrying with the omit flag sends no additional body while the stored one stays', async () => {
    const scope = additionalBodyScope(provider, model, 'conv-1');
    saveAdditionalBody(scope, { raw: '{"top_k":3}', enabled: true });
    mocks.sendLibraryAgentLeg.mockImplementation(() => handleOf([frame]));
    const store = createAppStore({ providers: [provider], conversations: [conversation()], libraryConnections });
    const ctx = { store, appendChunk: vi.fn(), te };
    await sendLibraryMessage(ctx, {
      text: 'hello', prevMessages: [], conversation: conversation(), provider, model, reasoningMode: 'automatic', ...presentation,
    }).done;
    expect(mocks.sendLibraryAgentLeg, JSON.stringify(assistantOf(store))).toHaveBeenCalled();
    expect(optionsOfCall(0)?.additionalBody?.raw).toBe('{"top_k":3}');
    const failed = assistantOf(store);
    expect(failed.state).toBe('failed');
    expect(failed.additionalBodyRetryEligible).toBe(true);
    expect(failed.errorTitle).toBe('additionalBodyRejected.upstreamTitle');
    expect(failed.errorTechnicalDetail).toBe('Unknown field: top_k');

    const calls = mocks.sendLibraryAgentLeg.mock.calls.length;
    const state = store.getState().conversations[0];
    await retryLibraryMessage(ctx, {
      messageId: failed.id, conversation: state, messages: state.messages, provider, model, reasoningMode: 'automatic',
      omitAdditionalBody: true, ...presentation,
    })?.done;
    expect(mocks.sendLibraryAgentLeg.mock.calls.length).toBeGreaterThan(calls);
    expect(optionsOfCall(calls)?.additionalBody).toBeUndefined();
    expect(loadAdditionalBody(scope)).toMatchObject({ raw: '{"top_k":3}', enabled: true });
  });

  it('failure after content was received -> no exit', async () => {
    saveAdditionalBody(additionalBodyScope(provider, model, 'conv-1'), { raw: '{"top_k":3}', enabled: true });
    mocks.sendLibraryAgentLeg.mockImplementation(() => handleOf([{ type: 'text', content: 'partial' } as StreamEvent, frame]));
    const store = createAppStore({ providers: [provider], conversations: [conversation()], libraryConnections });
    await sendLibraryMessage({ store, appendChunk: vi.fn(), te }, {
      text: 'hello', prevMessages: [], conversation: conversation(), provider, model, reasoningMode: 'automatic', ...presentation,
    }).done;
    const failed = assistantOf(store);
    expect(failed.state).toBe('failed');
    expect(failed.additionalBodyRetryEligible).toBeUndefined();
    expect(failed.errorTitle).toBe('library failed');
  });
});

describe('MCP path', () => {
  const upstream400: StreamEvent = { type: 'error', error: 'bad request', errorKind: 'unknown', source: 'provider', status: 400 };
  async function sendMcp() {
    saveAdditionalBody(additionalBodyScope(provider, model, 'conv-1'), { raw: '{"top_k":3}', enabled: true });
    mocks.sendLibraryAgentLeg.mockImplementation(() => handleOf([upstream400]));
    const store = createAppStore({ providers: [provider], conversations: [conversation()] });
    const ctx = { store, appendChunk: vi.fn(), te };
    await sendMcpToolMessage(ctx, {
      text: 'hello', prevMessages: [], conversation: conversation(), provider, model, reasoningMode: 'automatic',
      plan: { tools: [] } as unknown as McpToolPlan,
    }).done;
    return { store, ctx };
  }

  it('upstream 400 -> exit; retrying with the omit flag sends no additional body while the stored one stays', async () => {
    const { store, ctx } = await sendMcp();
    const failed = assistantOf(store);
    expect(failed.state).toBe('failed');
    expect(failed.additionalBodyRetryEligible).toBe(true);
    expect(failed.errorTitle).toBe('additionalBodyRejected.upstreamTitle');
    expect(optionsOfCall(0)?.additionalBody?.raw).toBe('{"top_k":3}');

    mocks.mcpTools = [{ name: 'tool' }];
    const calls = mocks.sendLibraryAgentLeg.mock.calls.length;
    const state = store.getState().conversations[0];
    await retryMessage(ctx, {
      messageId: failed.id, conversation: state, messages: state.messages, provider, model, reasoningMode: 'automatic', omitAdditionalBody: true,
    })?.done;
    expect(mocks.sendLibraryAgentLeg.mock.calls.length).toBeGreaterThan(calls);
    expect(optionsOfCall(calls)?.additionalBody).toBeUndefined();
    expect(loadAdditionalBody(additionalBodyScope(provider, model, 'conv-1'))).toMatchObject({ raw: '{"top_k":3}', enabled: true });
  });

  it('a turn in which tools already ran offers no exit', async () => {
    mocks.mcpSteps = [{ id: 'step-1' }];
    const { store } = await sendMcp();
    const failed = assistantOf(store);
    expect(failed.state).toBe('failed');
    expect(failed.additionalBodyRetryEligible).toBeUndefined();
  });
});

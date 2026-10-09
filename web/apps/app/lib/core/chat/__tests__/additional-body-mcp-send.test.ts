// @vitest-environment jsdom
/** The MCP send path also attaches the additional body to the outbound options of every model leg. */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  captureException: vi.fn(),
  sendLibraryAgentLeg: vi.fn(),
}));

vi.mock('../../providers/proxy-client', async () => ({
  ...await vi.importActual<typeof import('../../providers/proxy-client')>('../../providers/proxy-client'),
  sendLibraryAgentLeg: (...args: unknown[]) => mocks.sendLibraryAgentLeg(...args),
}));
vi.mock('../../mcp/mcp-chat', () => ({
  adoptMcpDraftServers: vi.fn(),
  createMcpSendSession: () => ({ entries: [], steps: () => [] }),
}));
vi.mock('../../mcp/mcp-store', () => ({ currentMcpRuntimeConfig: () => ({}) }));

vi.mock('@sentry/nextjs', () => ({ captureException: mocks.captureException, addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
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
import { sendMcpToolMessage } from '../operations-mcp-send';
import { additionalBodyScope, saveAdditionalBody } from '../additional-body-settings';
import type { McpToolPlan } from '@oriveo/core/mcp/index';

const provider = {
  id: 'p-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••test',
} as unknown as Provider;
const model = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: 'standard',
} as AIModel;

beforeEach(() => {
  localStorage.clear();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  mocks.sendLibraryAgentLeg.mockReset();
  mocks.sendLibraryAgentLeg.mockRejectedValue(new Error('stop after first leg'));
});

describe('MCP send', () => {
  it('the outbound options of a model leg carry the additional body', async () => {
    saveAdditionalBody(additionalBodyScope(provider, model, 'conv-1'), { raw: '{"top_k":3}', enabled: true });
    const conv = {
      id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'gpt-4', previewText: '', estimatedCost: 0,
      isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
    } as Conversation;
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    await sendMcpToolMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      plan: { tools: [] } as unknown as McpToolPlan,
    }).done;
    expect(mocks.sendLibraryAgentLeg).toHaveBeenCalled();
    const options = mocks.sendLibraryAgentLeg.mock.calls[0][6] as { additionalBody?: { raw: string } } | undefined;
    expect(options?.additionalBody?.raw).toBe('{"top_k":3}');
    const failed = store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(failed.state).toBe('failed');
  });
});

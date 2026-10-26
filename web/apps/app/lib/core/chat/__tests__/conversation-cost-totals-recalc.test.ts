// @vitest-environment jsdom
//
// Delete / retry / edit / send rollback / message patch are all conversation recalculation points, and each
// writes {estimatedCost, nonUsdCostTotals} back through recalculateConversationCostTotals. After a CNY message
// is deleted, the conversation's nonUsdCostTotals shrinks accordingly; once there is no non-USD part left the
// whole key disappears (no stale value). Assertions always read the conversation from the real store.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';

const mocks = vi.hoisted(() => ({
  sendMessage: vi.fn(),
}));

vi.mock('../../sync-port', () => ({ getSyncAdapter: () => undefined }));
vi.mock('../cleanup-attachments', () => ({ cleanupCloudAttachments: vi.fn() }));
vi.mock('../continuation-lifecycle', () => ({ deleteLocalMessageContinuation: vi.fn(async () => undefined) }));
vi.mock('../context-compaction/context-compaction-store', () => ({
  ContextCompactionStore: { invalidateAndSync: vi.fn(async () => undefined) },
}));
vi.mock('../operations-send', () => ({
  sendMessage: (...args: unknown[]) => mocks.sendMessage(...args),
}));
vi.mock('../../telemetry', async () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: (kind: string) => kind,
  telemetryModelID: (await vi.importActual<typeof import('../../telemetry')>('../../telemetry')).telemetryModelID,
}));

import { deleteMessage } from '../operations-delete';
import { retryMessageWithSender } from '../operations-retry';
import { editAndResend } from '../operations-edit';
import { rollbackSendStart } from '../send-start';
import { patchAssistantMessage } from '../agent-send-shared';

const provider: Provider = {
  id: 'provider-1', kind: 'openAI', status: { kind: 'connected' },
  models: [], catalogModels: [], apiKey: 'key', apiKeyPreview: 'key',
};
const model: AIModel = {
  id: 'model-1', name: 'GPT', capabilities: ['text'], reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '$', groupKey: 'gpt', groupName: 'GPT',
};

function message(id: string, role: ChatMessage['role'], overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id, role, text: id, providerKind: 'openAI', providerName: 'OpenAI', modelName: 'GPT',
    estimatedCost: 0, state: 'delivered', createdAt: `2026-10-20T00:00:0${id.slice(-1)}.000Z`,
    ...overrides,
  } as ChatMessage;
}

function cny(amount: number): ChatMessage['nonUsdCost'] {
  return { currencyCode: 'CNY', amount, costSource: 'localEstimate' };
}

/** Two turns: the first assistant reply costs USD 0.01 + CNY 1.5, the second assistant reply costs CNY 2. */
const u1 = message('u1', 'user');
const a1 = message('a2', 'assistant', { estimatedCost: 0.01, nonUsdCost: cny(1.5) });
const u2 = message('u3', 'user');
const a2 = message('a4', 'assistant', { nonUsdCost: cny(2) });

function seedStore(messages: ChatMessage[]) {
  const store = createAppStore();
  const conversation: Conversation = {
    id: 'c1', title: 'Chat', hasCustomTitle: false, providerID: provider.id, providerKind: provider.kind,
    modelID: model.id, previewText: '', estimatedCost: 0.01, nonUsdCostTotals: { CNY: 3.5 },
    isDraft: false, messages, draftText: '',
    updatedAt: '2026-10-20T00:00:04.000Z', createdAt: '2026-10-20T00:00:01.000Z',
  } as Conversation;
  store.setState({ conversations: [conversation] });
  return { store, conversation };
}

function storedConversation(store: ReturnType<typeof createAppStore>): Conversation {
  return store.getState().conversations.find((c) => c.id === 'c1')!;
}

function ctxOf(store: ReturnType<typeof createAppStore>) {
  return { store, appendChunk: vi.fn(), te: (key: string) => key } as never;
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.sendMessage.mockReturnValue({ convId: 'c1', msgId: 'next', abort: vi.fn(), done: Promise.resolve() });
});

describe('conversation recalculation points write back nonUsdCostTotals', () => {
  it('delete: after deleting a CNY message the CNY total drops, and once no non-USD part is left the whole key disappears', () => {
    const { store } = seedStore([u1, a1, u2, a2]);

    deleteMessage(store, 'c1', 'a4');
    expect(storedConversation(store).nonUsdCostTotals).toEqual({ CNY: 1.5 });
    expect(storedConversation(store).estimatedCost).toBeCloseTo(0.01);

    deleteMessage(store, 'c1', 'a2');
    const after = storedConversation(store);
    expect('nonUsdCostTotals' in after && after.nonUsdCostTotals !== undefined).toBe(false);
    expect(after.estimatedCost).toBe(0);
  });

  it('retry: after truncating the turn being retried, the CNY total only keeps the earlier turns', () => {
    const { store, conversation } = seedStore([u1, a1, u2, a2]);

    retryMessageWithSender(ctxOf(store), {
      messageId: 'a4', conversation, messages: conversation.messages,
      provider, model, reasoningMode: 'automatic',
    }, mocks.sendMessage);

    expect(storedConversation(store).nonUsdCostTotals).toEqual({ CNY: 1.5 });
  });

  it('edit and resend: once confirmed the truncated tail drops its CNY; when cancelled at the confirmation point the original tail is reattached and the CNY total is restored', async () => {
    const { store, conversation } = seedStore([u1, a1, u2, a2]);
    let resolveDone: (value: unknown) => void = () => undefined;
    mocks.sendMessage.mockReturnValue({
      convId: 'c1', msgId: 'next', abort: vi.fn(),
      done: new Promise((resolve) => { resolveDone = resolve; }),
    });

    const handle = editAndResend(ctxOf(store), {
      messageId: 'u1', newText: 'rewritten', conversation, messages: conversation.messages,
      provider, model, reasoningMode: 'automatic',
    });
    mocks.sendMessage.mock.calls[0][1].onSendConfirmed();
    expect(storedConversation(store).nonUsdCostTotals).toBeUndefined();

    resolveDone({ rolledBack: true });
    await handle?.done;
    expect(storedConversation(store).nonUsdCostTotals).toEqual({ CNY: 3.5 });
  });

  it('send rollback: after removing the CNY message this send put into the conversation, the total drops accordingly', () => {
    const { store } = seedStore([u1, a1, u2, a2]);

    rollbackSendStart(store, 'c1', ['u3', 'a4']);

    expect(storedConversation(store).nonUsdCostTotals).toEqual({ CNY: 1.5 });
  });

  it('message patch: after an assistant message\'s CNY cost is changed, the conversation total is recalculated', () => {
    const { store } = seedStore([u1, a1, u2, a2]);

    patchAssistantMessage(store, 'c1', 'a4', { nonUsdCost: undefined });

    expect(storedConversation(store).nonUsdCostTotals).toEqual({ CNY: 1.5 });
  });
});

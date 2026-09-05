// @vitest-environment jsdom
//
// Guards against cleared messages reappearing after a user without a subscription clears every
// message in a conversation.
// Root cause: deleteMessage did not converge remoteMessageCount, so once the list was empty the
// "messages.length===0 && remoteMessageCount>0" rule in
// putConversationPreservingHydratedMessages matched and wrote the old IDB messages back.
// These cases pin that deleteMessage converges remoteMessageCount to the delivered count after
// the deletion.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';

const mocks = vi.hoisted(() => ({
  syncAdapter: { didDeleteMessages: vi.fn() },
  cleanupCloudAttachments: vi.fn(),
  deleteLocalMessageContinuation: vi.fn(),
}));

vi.mock('../../sync-port', () => ({
  getSyncAdapter: () => mocks.syncAdapter,
}));

vi.mock('../cleanup-attachments', () => ({
  cleanupCloudAttachments: (...args: unknown[]) => mocks.cleanupCloudAttachments(...args),
}));
vi.mock('../continuation-lifecycle', () => ({
  deleteLocalMessageContinuation: (...args: unknown[]) => mocks.deleteLocalMessageContinuation(...args),
}));

import { deleteMessage } from '../operations-delete';

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: 'm1',
    role: 'user',
    text: 'hi',
    state: 'delivered',
    ...overrides,
  } as ChatMessage;
}

function makeConversation(messages: ChatMessage[], overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt: new Date().toISOString(),
    createdAt: new Date().toISOString(),
    remoteMessageCount: messages.filter((m) => m.state === 'delivered').length,
    ...overrides,
  } as Conversation;
}

describe('deleteMessage converges remoteMessageCount', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('converges remoteMessageCount to 0 after the last delivered message is deleted', () => {
    const store = createAppStore();
    const msg = makeMessage({ id: 'm1', state: 'delivered' });
    // remoteMessageCount starts at 1, simulating a hydrate backfill
    store.setState({ conversations: [makeConversation([msg], { remoteMessageCount: 1 })] });

    deleteMessage(store, 'c1', 'm1');

    expect(mocks.deleteLocalMessageContinuation).toHaveBeenCalledWith('c1', 'm1');

    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    expect(conv.messages).toHaveLength(0);
    // The important part: it is not greater than 0, which would make putConversationPreservingHydratedMessages resurrect the cleared messages
    expect(conv.remoteMessageCount).toBe(0);
  });

  it('converges remoteMessageCount to the remaining delivered count after one message is deleted', () => {
    const store = createAppStore();
    const m1 = makeMessage({ id: 'm1', state: 'delivered' });
    const m2 = makeMessage({ id: 'm2', state: 'delivered' });
    const m3 = makeMessage({ id: 'm3', state: 'delivered' });
    store.setState({ conversations: [makeConversation([m1, m2, m3], { remoteMessageCount: 3 })] });

    deleteMessage(store, 'c1', 'm2');

    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    expect(conv.messages.map((m) => m.id)).toEqual(['m1', 'm3']);
    expect(conv.remoteMessageCount).toBe(2);
  });

  it('does not count undelivered messages in remoteMessageCount', () => {
    const store = createAppStore();
    const delivered = makeMessage({ id: 'm1', state: 'delivered' });
    const generating = makeMessage({ id: 'm2', role: 'assistant', state: 'generating' });
    store.setState({ conversations: [makeConversation([delivered, generating], { remoteMessageCount: 1 })] });

    deleteMessage(store, 'c1', 'm1');

    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    // One generating message is left, but the delivered count is 0
    expect(conv.messages.map((m) => m.id)).toEqual(['m2']);
    expect(conv.remoteMessageCount).toBe(0);
  });

  it('reports a delete for a delivered message and reports nothing for an undelivered one', () => {
    const store = createAppStore();
    const delivered = makeMessage({ id: 'm1', state: 'delivered' });
    const generating = makeMessage({ id: 'm2', role: 'assistant', state: 'generating' });
    store.setState({ conversations: [makeConversation([delivered, generating], { remoteMessageCount: 1 })] });

    deleteMessage(store, 'c1', 'm2'); // undelivered
    expect(mocks.syncAdapter.didDeleteMessages).not.toHaveBeenCalled();

    deleteMessage(store, 'c1', 'm1'); // delivered
    expect(mocks.syncAdapter.didDeleteMessages).toHaveBeenCalledTimes(1);
  });
});

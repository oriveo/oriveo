import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { ChatMessage, Conversation } from '@oriveo/shared';

/**
 * Cascading deletion of step payloads: when a conversation or a message is deleted, the raw
 * arguments and results stored on this device go with it.
 *
 * A message can leave a conversation, and a conversation the store, in more ways than the delete
 * actions: truncating after an edit, or any other write to the store. Every case here goes through
 * the production path: payloads are read and written through the real `mcp-idb`, and the deletion is
 * triggered by the real subscriber that writes the store to IndexedDB.
 */

import { createAppStore, type AppStore } from '../../store/app-store';
import { subscribeConversations } from '../../store/persistence-subscribers';
import { deleteConversation, deleteConversations } from '../../conversation-ops';
import { deleteMessage } from '../../chat/operations-delete';
import { resetDBConnection } from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';
import { fetchMcpStepPayload, openMcpDB, saveMcpStepPayload } from '../mcp-idb';
import { useMcpStore } from '../mcp-store';

const SERVER_ID = '00000000-0000-4000-8000-0000000000aa';
// Conversation and message ids use the store's canonical form (uppercase UUID), the same form that
// ends up in the payload key in production.
const CONV_A = '00000000-0000-4000-8000-00000000C001';
const CONV_B = '00000000-0000-4000-8000-00000000C002';
const MSG_A1 = '00000000-0000-4000-8000-00000000A001';
const MSG_A2 = '00000000-0000-4000-8000-00000000A002';
const MSG_B1 = '00000000-0000-4000-8000-00000000B001';

function toolMessage(id: string): ChatMessage {
  return {
    id,
    role: 'assistant',
    text: 'done',
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'GPT',
    estimatedCost: 0,
    state: 'delivered',
    createdAt: '2026-10-01T10:00:00.000Z',
    toolSteps: [{
      id: 'step-1',
      scope: 'mcp',
      serverId: SERVER_ID,
      serverName: 'Example',
      toolName: 'create_issue',
      title: 'Create issue',
      argsSummary: 'a',
      status: 'done',
      step: 1,
    }],
  } as ChatMessage;
}

function conversation(id: string, messages: ChatMessage[]): Conversation {
  return {
    id,
    title: 'Chat',
    hasCustomTitle: true,
    providerID: 'p1',
    providerKind: 'openAI',
    modelID: 'm1',
    previewText: 'done',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    createdAt: '2026-10-01T10:00:00.000Z',
    updatedAt: '2026-10-01T10:00:00.000Z',
  };
}

let counter = 0;
let uid = '';
let store: StoreApi<AppStore>;
let unsubscribe: () => void;

async function payloadExists(messageId: string): Promise<boolean> {
  return (await fetchMcpStepPayload(uid, messageId, 'step-1')) !== null;
}

/** The subscriber debounces writing messages by 500ms, and the deletion follows that write. */
async function waitUntilGone(messageId: string): Promise<void> {
  await vi.waitFor(async () => expect(await payloadExists(messageId)).toBe(false), { timeout: 3000, interval: 50 });
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 800));
}

beforeEach(async () => {
  counter += 1;
  uid = `uid-step-cascade-${counter}`;
  resetDBConnection();
  await setActiveUID(uid);
  await useMcpStore.getState().hydrate(uid);

  store = createAppStore();
  store.setState({
    hydrationPhase: 'ready',
    conversations: [
      conversation(CONV_A, [toolMessage(MSG_A1), toolMessage(MSG_A2)]),
      conversation(CONV_B, [toolMessage(MSG_B1)]),
    ],
  });
  unsubscribe = subscribeConversations(store);

  for (const [conversationId, messageId] of [[CONV_A, MSG_A1], [CONV_A, MSG_A2], [CONV_B, MSG_B1]]) {
    await saveMcpStepPayload(uid, {
      messageId,
      stepId: 'step-1',
      serverId: SERVER_ID,
      conversationId,
      arguments: '{"title":"secret"}',
      resultPrefix: 'ok',
    });
  }
});

afterEach(() => {
  unsubscribe();
  useMcpStore.getState().reset();
});

describe('a write to the store that is not one of the delete actions', () => {
  it('a conversation that leaves the store takes its step payloads and its switches along, and other conversations keep theirs', async () => {
    const db = await openMcpDB(uid);
    await db.put('conversationSwitches', { conversationId: CONV_A, serverId: SERVER_ID, enabledAt: 1 });
    const switchKeys = () => db.getAllKeysFromIndex('conversationSwitches', 'by-conversation', CONV_A);
    expect(await switchKeys()).toHaveLength(1);

    store.setState({ conversations: store.getState().conversations.filter((c) => c.id !== CONV_A) });

    await waitUntilGone(MSG_A1);
    await waitUntilGone(MSG_A2);
    expect(await payloadExists(MSG_B1)).toBe(true);
    await vi.waitFor(async () => {
      expect(await switchKeys()).toHaveLength(0);
    }, { timeout: 3000, interval: 50 });
  });

  it('truncating a conversation, as editing a message does, deletes only the payloads of the messages cut off', async () => {
    const kept = store.getState().conversations.find((c) => c.id === CONV_A)!.messages.slice(0, 1);
    store.getState().updateConversation(CONV_A, { messages: kept });

    await waitUntilGone(MSG_A2);
    expect(await payloadExists(MSG_A1)).toBe(true);
    expect(await payloadExists(MSG_B1)).toBe(true);
  });

  it('changing a field of a conversation leaves its payloads alone', async () => {
    store.getState().updateConversation(CONV_A, { title: 'Renamed' });

    expect(store.getState().conversations.find((c) => c.id === CONV_A)?.title).toBe('Renamed');
    await settle();
    expect(await payloadExists(MSG_A1)).toBe(true);
    expect(await payloadExists(MSG_A2)).toBe(true);
  });
});

describe('the delete actions go through the same layer', () => {
  it('deleting a conversation, and deleting several at once', async () => {
    deleteConversation(store, CONV_A);
    await waitUntilGone(MSG_A1);
    await waitUntilGone(MSG_A2);
    expect(await payloadExists(MSG_B1)).toBe(true);

    deleteConversations(store, [CONV_B]);
    await waitUntilGone(MSG_B1);
  });

  it('deleting a message', async () => {
    deleteMessage(store, CONV_A, MSG_A1);
    await waitUntilGone(MSG_A1);
    expect(await payloadExists(MSG_A2)).toBe(true);
  });
});

describe('what is not a deletion', () => {
  it('a summary whose messages are not loaded (no messages, remoteMessageCount above zero) keeps the payloads', async () => {
    store.getState().updateConversation(CONV_A, { messages: [], remoteMessageCount: 2 });
    await settle();
    expect(await payloadExists(MSG_A1)).toBe(true);
    expect(await payloadExists(MSG_A2)).toBe(true);
  });

  it('emptying the store before hydration has finished keeps the payloads', async () => {
    store.setState({ hydrationPhase: 'booting', conversations: [] });
    store.setState({ hydrationPhase: 'ready' });
    await settle();
    expect(await payloadExists(MSG_A1)).toBe(true);
    expect(await payloadExists(MSG_B1)).toBe(true);
  });
});

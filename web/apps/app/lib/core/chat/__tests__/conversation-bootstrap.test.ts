// @vitest-environment jsdom

import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { putConversation, resetDBConnection } from '../../../infra/storage/idb';
import { resetImageDBConnection } from '../../../infra/storage/image-store';
import { setActiveUID } from '../../../infra/storage/partition';
import { warmConversationAnchorInStore, warmConversationInStore } from '../conversation-bootstrap';

const store = createAppStore();

vi.mock('../../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: () => store,
}));

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: '11111111-1111-4111-8111-111111111111',
    role: 'user',
    text: 'hello from idb',
    content: 'hello from idb',
    state: 'delivered',
    createdAt: '2026-06-04T00:00:00.000Z',
    ...overrides,
  } as ChatMessage;
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'E89683FC-24C2-4FEC-9CA6-BBBFFB8F8652',
    title: 'Existing conversation',
    hasCustomTitle: false,
    providerID: '22222222-2222-4222-8222-222222222222',
    providerKind: 'anthropic',
    modelID: 'claude-opus-4-7',
    previewText: 'hello from idb',
    estimatedCost: 0,
    isDraft: false,
    remoteMessageCount: 1,
    messages: [makeMessage()],
    draftText: '',
    updatedAt: '2026-06-04T00:00:00.000Z',
    ...overrides,
  } as Conversation;
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('warmConversationInStore', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
    store.setState({
      conversations: [],
      providers: [],
      hydrationPhase: 'ready',
    });
  });

  it('hydrates messages when the route id casing differs from the IndexedDB key', async () => {
    await putConversation(makeConversation());
    store.getState().addConversation({
      ...makeConversation(),
      messages: [],
    });

    await warmConversationInStore('e89683fc-24c2-4fec-9ca6-bbbffb8f8652');

    const conversation = store.getState().conversations.find((item) =>
      item.id === 'E89683FC-24C2-4FEC-9CA6-BBBFFB8F8652',
    );
    expect(conversation?.messages).toHaveLength(1);
    expect(conversation?.messages[0].text).toBe('hello from idb');
  });

  it('hydrates the source conversation when warming a message anchor', async () => {
    await putConversation(makeConversation());
    store.getState().addConversation({
      ...makeConversation(),
      messages: [],
    });

    await warmConversationAnchorInStore('e89683fc-24c2-4fec-9ca6-bbbffb8f8652', '11111111-1111-4111-8111-111111111111');

    const conversation = store.getState().conversations.find((item) =>
      item.id === 'E89683FC-24C2-4FEC-9CA6-BBBFFB8F8652',
    );
    expect(conversation?.messages).toHaveLength(1);
    expect(conversation?.messages[0].id).toBe('11111111-1111-4111-8111-111111111111');
  });
});

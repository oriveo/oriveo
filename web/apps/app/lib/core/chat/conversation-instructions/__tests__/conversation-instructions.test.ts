import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import type { Conversation } from '@oriveo/shared';

import { getConversationById, putConversation, resetDBConnection } from '../../../../infra/storage/idb';
import { setActiveUID } from '../../../../infra/storage/partition';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    providerKind: 'openAI',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-10-15T00:00:00.000Z',
    createdAt: '2026-10-15T00:00:00.000Z',
    ...overrides,
  };
}

describe('ConversationInstructions', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('instructions_persist_roundtrip', async () => {
    await putConversation(makeConversation({ id: 'c1', instructions: 'Reply in Arabic.' }));
    await putConversation(makeConversation({ id: 'c2' }));

    expect((await getConversationById('c1'))?.instructions).toBe('Reply in Arabic.');
    // Rows written before the field existed read back as "".
    expect((await getConversationById('c2'))?.instructions ?? '').toBe('');
  });
});

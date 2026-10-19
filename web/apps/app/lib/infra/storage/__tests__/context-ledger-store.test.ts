import 'fake-indexeddb/auto';
import { openDB } from 'idb';
import { describe, it, expect, beforeEach } from 'vitest';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import { RhoCalibration } from '@oriveo/core/context/calibration';
import type { ContextManifest } from '@oriveo/core/context/manifest';
import { StopReason } from '@oriveo/core/context/stop-reason';
import {
  DB_VERSION,
  clearAllConversations,
  deleteConversation,
  getConversationById,
  putConversation,
  replaceAllInOneTx,
  resetDBConnection,
} from '../idb';
import {
  appendContextManifest,
  getContextManifests,
  getRhoCalibration,
  getRhoCalibrationTable,
  putRhoCalibration,
} from '../context-ledger-store';
import { setActiveUID } from '../partition';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: 'm1',
    role: 'assistant',
    text: 'hello',
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'gpt',
    estimatedCost: 0,
    createdAt: new Date(0).toISOString(),
    ...overrides,
  } as ChatMessage;
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeManifest(overrides: Partial<ContextManifest> = {}): ContextManifest {
  return {
    requestId: 'r1',
    conversationId: 'c1',
    purpose: 'chat',
    transport: 't1',
    model: 'm1',
    W: 128000,
    O: 4096,
    B: 100000,
    basis: 'estimated',
    estimatedInput: 1000,
    segments: [{ kind: 'purposeSystem', tokens: 10 }],
    unansweredMerged: 0,
    reminder: false,
    createdAt: 1,
    ...overrides,
  } as ContextManifest;
}

describe('ContextLedgerStore', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('migration_adds_stop_reason_and_ledger', async () => {
    const legacy = await openDB('oriveo--guest', 10, {
      upgrade(database) {
        const conversations = database.createObjectStore('conversations', { keyPath: 'id' });
        conversations.createIndex('by-updated', 'updatedAt');
        database.createObjectStore('providers', { keyPath: 'id' });
        database.createObjectStore('session');
        conversations.put(makeConversation({ id: 'legacy', messages: [makeMessage({ id: 'legacy-m' })] }));
      },
    });
    legacy.close();

    expect(DB_VERSION).toBe(14);
    const migrated = await getConversationById('legacy');
    expect(migrated?.messages[0].id).toBe('legacy-m');
    expect(migrated?.messages[0].stopReason).toBeUndefined();

    resetDBConnection();
    const raw = await openDB('oriveo--guest');
    expect(raw.version).toBe(14);
    expect(raw.objectStoreNames.contains('contextRhoCalibration')).toBe(true);
    expect(raw.objectStoreNames.contains('contextManifests')).toBe(true);
    const tx = raw.transaction('contextManifests');
    expect(tx.store.indexNames.contains('by-conversation')).toBe(true);
    raw.close();
  });

  it('legacy_null_reads_null', async () => {
    await putConversation(makeConversation({
      messages: [
        makeMessage({ id: 'old' }),
        makeMessage({ id: 'weird', stopReason: 'mystery' as unknown as ChatMessage['stopReason'] }),
      ],
    }));
    const loaded = await getConversationById('c1');
    expect(StopReason.fromStored(loaded?.messages[0].stopReason)).toBeNull();
    expect(StopReason.fromStored(loaded?.messages[1].stopReason)).toBe('unknown');
  });

  it('stop_reason_roundtrip', async () => {
    await putConversation(makeConversation({
      messages: [makeMessage({ id: 'a', stopReason: 'length' }), makeMessage({ id: 'b', stopReason: 'interrupted' })],
    }));
    const loaded = await getConversationById('c1');
    expect(loaded?.messages.map((m) => m.stopReason)).toEqual(['length', 'interrupted']);
  });

  it('rho_table_roundtrip', async () => {
    const calibration = RhoCalibration.initial()
      .recordingSample(1200, 0, 4000)
      .recordingSample(1300, 0, 4000);
    await putRhoCalibration('relay-1', 'gpt-x', calibration);
    await putRhoCalibration('relay-1', 'gpt-y', RhoCalibration.initial().recordingOverflowMiss());

    const loaded = await getRhoCalibration('relay-1', 'gpt-x');
    expect(loaded.toJSON()).toEqual(calibration.toJSON());
    expect((await getRhoCalibration('relay-2', 'gpt-x')).toJSON()).toEqual(RhoCalibration.initial().toJSON());

    const table = await getRhoCalibrationTable();
    expect(table.get('relay-1', 'gpt-y').toJSON()).toEqual(RhoCalibration.initial().recordingOverflowMiss().toJSON());
    expect(table.toJSON().entries.map((e) => e.modelId)).toEqual(['gpt-x', 'gpt-y']);
  });

  it('manifest_keeps_latest_50', async () => {
    for (let i = 0; i < 55; i += 1) {
      await appendContextManifest(makeManifest({ requestId: `r${i}`, createdAt: 1000 + i }));
    }
    await appendContextManifest(makeManifest({ conversationId: 'c2', requestId: 'other', createdAt: 1 }));

    const list = await getContextManifests('c1');
    expect(list).toHaveLength(50);
    expect(list[0].requestId).toBe('r5');
    expect(list[49].requestId).toBe('r54');
    expect(await getContextManifests('c2')).toHaveLength(1);
  });

  it('manifest_deleted_with_conversation', async () => {
    await putConversation(makeConversation({ id: 'c1' }));
    await putConversation(makeConversation({ id: 'c2' }));
    await appendContextManifest(makeManifest({ conversationId: 'c1', requestId: 'a' }));
    await appendContextManifest(makeManifest({ conversationId: 'c1', requestId: 'b' }));
    await appendContextManifest(makeManifest({ conversationId: 'c2', requestId: 'c' }));

    await deleteConversation('c1');

    expect(await getConversationById('c1')).toBeUndefined();
    expect(await getContextManifests('c1')).toEqual([]);
    expect((await getContextManifests('c2')).map((m) => m.requestId)).toEqual(['c']);
  });

  it('manifest_cleared_with_all_conversations', async () => {
    await putRhoCalibration('relay-1', 'gpt-x', RhoCalibration.initial().recordingOverflowMiss());
    await appendContextManifest(makeManifest({ conversationId: 'c1', requestId: 'a' }));
    await appendContextManifest(makeManifest({ conversationId: 'c2', requestId: 'b' }));

    await clearAllConversations();
    expect(await getContextManifests('c1')).toEqual([]);
    expect(await getContextManifests('c2')).toEqual([]);

    await appendContextManifest(makeManifest({ conversationId: 'c3', requestId: 'c' }));
    await replaceAllInOneTx({
      conversations: [makeConversation({ id: 'c4' })],
      providers: [],
      folders: [],
      notes: [],
      noteFolders: [],
    });
    expect(await getContextManifests('c3')).toEqual([]);
    expect((await getConversationById('c4'))?.id).toBe('c4');

    // The rho calibration is independent of any conversation and is not cleared with it.
    expect((await getRhoCalibration('relay-1', 'gpt-x')).toJSON())
      .toEqual(RhoCalibration.initial().recordingOverflowMiss().toJSON());
  });
});

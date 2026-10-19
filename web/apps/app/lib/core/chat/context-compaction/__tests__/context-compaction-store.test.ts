import 'fake-indexeddb/auto';
import { openDB } from 'idb';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  adapter: { didDeleteCheckpoints: vi.fn(), didDeleteMessages: vi.fn(), updateConversationCost: vi.fn() },
  sendMessage: vi.fn(),
}));

vi.mock('../../../sync-port', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../sync-port')>()),
  getSyncAdapter: () => mocks.adapter,
}));
vi.mock('../../operations-send', () => ({
  sendMessage: (...args: unknown[]) => mocks.sendMessage(...args),
}));
vi.mock('../../cleanup-attachments', () => ({ cleanupCloudAttachments: vi.fn() }));
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import {
  DB_VERSION,
  deleteConversation,
  getConversationById,
  putConversation,
  resetDBConnection,
} from '../../../../infra/storage/idb';
import {
  type ContextCheckpointRow,
  CONTEXT_CHECKPOINT_KEEP_LIMIT,
  listContextCheckpoints,
  putContextCheckpoint,
} from '../../../../infra/storage/context-checkpoint-store';
import { ContextCompactionStore } from '../context-compaction-store';
import { setActiveUID } from '../../../../infra/storage/partition';
import { createAppStore } from '../../../store/app-store';
import { editAndResend } from '../../operations-edit';
import { retryMessageWithSender } from '../../operations-retry';
import JSZip from 'jszip';
import type { BackupFile, ImportMode } from '../../../../backup';
import { executeImport, exportBackup, generateImportPreview } from '../../../../backup';

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

const history = [
  { id: 'm1', text: 'one' },
  { id: 'm2', text: 'two' },
  { id: 'm3', text: 'three' },
  { id: 'm4', text: 'four' },
  { id: 'm5', text: 'five' },
  { id: 'm6', text: 'six' },
];

function digestThrough(coversTo: string, messages = history): string {
  const index = messages.findIndex((m) => m.id === coversTo);
  return ContextCheckpoint.coversDigest(messages.slice(0, index + 1));
}

function makeRow(overrides: Partial<ContextCheckpointRow> = {}): ContextCheckpointRow {
  const coversTo = overrides.coversTo ?? 'm2';
  return {
    conversationId: 'c1',
    checkpointId: `cp-${coversTo}`,
    kind: 'summary',
    coversFrom: 'm1',
    coversTo,
    coversDigest: digestThrough(coversTo),
    messagesCovered: history.findIndex((m) => m.id === coversTo) + 1,
    userMessageIds: ['m1'],
    text: '<oriveo-context-checkpoint v="1"></oriveo-context-checkpoint>',
    summary: '## Goal',
    language: 'en',
    model: 'gpt',
    packerVersion: '1',
    createdAt: 1000,
    cost: 0.01,
    ...overrides,
  };
}

const provider: Provider = {
  id: 'p1', kind: 'openAI', status: { kind: 'connected' },
  models: [], catalogModels: [], apiKey: 'key', apiKeyPreview: 'key',
};
const model: AIModel = {
  id: 'm1', name: 'GPT', capabilities: ['text'], reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '$', groupKey: 'gpt', groupName: 'GPT',
};

function chatHistory(): ChatMessage[] {
  return history.map((m, index) => ({
    id: m.id, role: index % 2 === 0 ? 'user' : 'assistant', text: m.text, providerKind: 'openAI',
    providerName: 'OpenAI', modelName: 'GPT', estimatedCost: 0, state: 'delivered',
    createdAt: new Date(1000 + index).toISOString(),
  }) as ChatMessage);
}

async function seedCoveringCheckpoints() {
  await putContextCheckpoint(makeRow({ coversTo: 'm2', createdAt: 1 }));
  await putContextCheckpoint(makeRow({ coversTo: 'm3', createdAt: 2 }));
  await putContextCheckpoint(makeRow({ coversTo: 'm5', createdAt: 3 }));
}

describe('ContextCompactionStore', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('migration_creates_checkpoint_table', async () => {
    const legacy = await openDB('oriveo--guest', 11, {
      upgrade(database) {
        const conversations = database.createObjectStore('conversations', { keyPath: 'id' });
        conversations.createIndex('by-updated', 'updatedAt');
        database.createObjectStore('providers', { keyPath: 'id' });
        database.createObjectStore('session');
        conversations.put(makeConversation({ id: 'legacy' }));
      },
    });
    legacy.close();

    expect(DB_VERSION).toBe(14);
    expect((await getConversationById('legacy'))?.id).toBe('legacy');

    resetDBConnection();
    const raw = await openDB('oriveo--guest');
    expect(raw.version).toBe(14);
    expect(raw.objectStoreNames.contains('contextCheckpoints')).toBe(true);
    const tx = raw.transaction('contextCheckpoints');
    expect(tx.store.keyPath).toEqual(['conversationId', 'checkpointId']);
    expect(tx.store.indexNames.contains('by-conversation')).toBe(true);
    raw.close();
  });

  it('save_and_list_roundtrip', async () => {
    const full = makeRow();
    const sparse = makeRow({
      checkpointId: 'cp-fallback',
      kind: 'fallback',
      coversTo: 'm3',
      coversDigest: digestThrough('m3'),
      summary: null,
      language: null,
      cost: null,
      createdAt: 2000,
    });
    await putContextCheckpoint(full);
    await putContextCheckpoint(sparse);

    const listed = await listContextCheckpoints('c1');
    expect(listed).toEqual([full, sparse]);
    expect(listed[1].summary).toBeNull();
    expect(listed[1].language).toBeNull();
    expect(listed[1].cost).toBeNull();
    expect(await listContextCheckpoints('other')).toEqual([]);
  });

  it('overwrite_same_checkpoint_id', async () => {
    await putContextCheckpoint(makeRow({ text: 'old', createdAt: 1 }));
    await putContextCheckpoint(makeRow({ text: 'new', createdAt: 2 }));
    const listed = await listContextCheckpoints('c1');
    expect(listed).toHaveLength(1);
    expect(listed[0].text).toBe('new');
  });

  it('trim_keeps_newest_8', async () => {
    expect(CONTEXT_CHECKPOINT_KEEP_LIMIT).toBe(8);
    // Write order differs from createdAt order: pruning goes by createdAt, not by write order
    const createdAts = [5, 1, 9, 3, 7, 2, 10, 4, 8, 6];
    for (const createdAt of createdAts) {
      await putContextCheckpoint(makeRow({ checkpointId: `cp-${createdAt}`, createdAt }));
    }
    await putContextCheckpoint(makeRow({ conversationId: 'c2', checkpointId: 'other', createdAt: 0 }));

    const listed = await listContextCheckpoints('c1');
    expect(listed.map((r) => r.createdAt)).toEqual([3, 4, 5, 6, 7, 8, 9, 10]);
    expect(await listContextCheckpoints('c2')).toHaveLength(1);
  });

  it('latest_valid_skips_stale', async () => {
    const valid = makeRow({ coversTo: 'm2', createdAt: 1 });
    await putContextCheckpoint(valid);
    // coversTo is not in history
    await putContextCheckpoint(makeRow({ checkpointId: 'cp-gone', coversTo: 'gone', coversDigest: 'x', createdAt: 2 }));
    // digest does not match the current prefix (m3 has been edited)
    const edited = history.map((m) => (m.id === 'm3' ? { ...m, text: 'edited' } : m));
    await putContextCheckpoint(makeRow({ coversTo: 'm4', coversDigest: digestThrough('m4', edited), createdAt: 3 }));

    const latest = await ContextCompactionStore.latestValid('c1', history);
    expect(latest).toEqual(valid);
    // skipped, not deleted
    expect(await listContextCheckpoints('c1')).toHaveLength(3);
    expect(await ContextCompactionStore.latestValid('c1', [])).toBeNull();
    expect(await ContextCompactionStore.latestValid('none', history)).toBeNull();
  });

  it('latest_valid_prefers_later_covers_to', async () => {
    await putContextCheckpoint(makeRow({ coversTo: 'm4', createdAt: 1 }));
    await putContextCheckpoint(makeRow({ coversTo: 'm2', createdAt: 5 }));
    await putContextCheckpoint(makeRow({ checkpointId: 'cp-m4-late', coversTo: 'm4', createdAt: 9 }));
    const latest = await ContextCompactionStore.latestValid('c1', history);
    expect(latest?.checkpointId).toBe('cp-m4');
  });

  it('invalidate_drops_covering_and_later', async () => {
    await putContextCheckpoint(makeRow({ coversTo: 'm2', createdAt: 1 }));
    await putContextCheckpoint(makeRow({ coversTo: 'm3', createdAt: 2 }));
    await putContextCheckpoint(makeRow({ coversTo: 'm5', createdAt: 3 }));
    await putContextCheckpoint(makeRow({ checkpointId: 'cp-gone', coversTo: 'gone', createdAt: 4 }));

    const ids = history.map((m) => m.id);
    const deleted = await ContextCompactionStore.invalidate('c1', ids, ['m5', 'm3']);
    expect([...deleted].sort()).toEqual(['cp-m3', 'cp-m5']);
    const remaining = (await listContextCheckpoints('c1')).map((r) => r.checkpointId);
    expect(remaining.sort()).toEqual(['cp-gone', 'cp-m2']);
  });

  it('invalidate_keeps_before_branch', async () => {
    await putContextCheckpoint(makeRow({ coversTo: 'm2', createdAt: 1 }));
    await putContextCheckpoint(makeRow({ coversTo: 'm3', createdAt: 2 }));
    const ids = history.map((m) => m.id);

    expect(await ContextCompactionStore.invalidate('c1', ids, ['m6'])).toEqual([]);
    expect(await ContextCompactionStore.invalidate('c1', ids, ['unknown'])).toEqual([]);
    expect(await ContextCompactionStore.invalidate('c1', ids, [])).toEqual([]);
    expect(await listContextCheckpoints('c1')).toHaveLength(2);

    expect(await ContextCompactionStore.invalidate('c1', ids, ['m4'])).toEqual([]);
    expect(await ContextCompactionStore.invalidate('c1', ids, ['m3'])).toEqual(['cp-m3']);
    expect((await listContextCheckpoints('c1')).map((r) => r.checkpointId)).toEqual(['cp-m2']);
  });

  it('edit_resend_invalidates_covering_checkpoints', async () => {
    await seedCoveringCheckpoints();
    const messages = chatHistory();
    const conversation = makeConversation({ messages });
    const store = createAppStore();
    store.setState({ conversations: [conversation] });
    // Tail deletion and checkpoint invalidation take effect only after the pre-send confirmation passes (onSendConfirmed)
    mocks.sendMessage.mockImplementationOnce((_ctx: unknown, params: { onSendConfirmed?: () => void }) => {
      params.onSendConfirmed?.();
      return { convId: 'c1', msgId: 'a-new', abort: vi.fn(), done: Promise.resolve(undefined) };
    });

    editAndResend({ store, appendChunk: vi.fn(), te: (key) => key }, {
      messageId: 'm3', newText: 'rewritten', conversation, messages, provider, model, reasoningMode: 'automatic',
    });

    await vi.waitFor(async () => {
      expect((await listContextCheckpoints('c1')).map((r) => r.checkpointId)).toEqual(['cp-m2']);
    });
  });

  it('in_place_retry_keeps_checkpoints', async () => {
    await seedCoveringCheckpoints();
    await putContextCheckpoint(makeRow({ coversTo: 'm6', createdAt: 4 }));
    const messages = chatHistory().map((m) => (m.id === 'm6' ? { ...m, state: 'failed' } as ChatMessage : m));
    const conversation = makeConversation({ messages });
    const store = createAppStore();
    store.setState({ conversations: [conversation] });

    retryMessageWithSender({ store, appendChunk: vi.fn(), te: (key: string) => key } as never, {
      messageId: 'm6', conversation, messages, provider, model, reasoningMode: 'automatic',
    } as never, mocks.sendMessage);

    expect(mocks.sendMessage).toHaveBeenCalledTimes(1);
    // A failed assistant message is reused in place with the same id: no message was really deleted, so no checkpoint is touched.
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect((await listContextCheckpoints('c1')).map((r) => r.checkpointId).sort())
      .toEqual(['cp-m2', 'cp-m3', 'cp-m5', 'cp-m6']);
  });

  it('delete_conversation_cascades', async () => {
    await putConversation(makeConversation({ id: 'c1' }));
    await putConversation(makeConversation({ id: 'c2' }));
    await putContextCheckpoint(makeRow({ conversationId: 'c1' }));
    await putContextCheckpoint(makeRow({ conversationId: 'c2' }));

    await deleteConversation('c1');
    expect(await getConversationById('c1')).toBeUndefined();
    expect(await listContextCheckpoints('c1')).toEqual([]);
    expect(await listContextCheckpoints('c2')).toHaveLength(1);
  });
});

describe('checkpoint backup', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  async function resetStorage() {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  }

  async function exportedFile(): Promise<BackupFile> {
    const blob = await exportBackup({ includeApiKeys: false });
    const zip = await JSZip.loadAsync(blob);
    return JSON.parse(await zip.file('data.json')!.async('string')) as BackupFile;
  }

  async function importFile(file: BackupFile, mode: ImportMode) {
    const preview = await generateImportPreview(file, new Map());
    return executeImport(preview, mode);
  }

  it('backup_roundtrip_includes_checkpoints', async () => {
    const row = makeRow({ conversationId: 'c1', summary: null, language: null, cost: null });
    const orphan = makeRow({ conversationId: 'c-gone', coversTo: 'm3' });
    await putConversation(makeConversation({ id: 'c1' }));
    await putContextCheckpoint(row);
    await putContextCheckpoint(orphan);

    const file = await exportedFile();
    expect(file.version).toBe(1);
    expect(file.data.checkpoints).toEqual(expect.arrayContaining([row, orphan]));
    expect(file.data.checkpoints).toHaveLength(2);

    for (const mode of ['importNew', 'merge', 'replaceAll'] as ImportMode[]) {
      await resetStorage();
      await importFile(file, mode);
      expect(await getConversationById('c1')).toBeDefined();
      expect(await listContextCheckpoints('c1')).toEqual([row]);
      // Rows whose conversation does not exist after the import are not accepted.
      expect(await listContextCheckpoints('c-gone')).toEqual([]);
    }
  });

  it('backup_import_drops_unknown_kind', async () => {
    const good = makeRow({ conversationId: 'c1', coversTo: 'm2' });
    await putConversation(makeConversation({ id: 'c1' }));
    const file = await exportedFile();
    const unknownKind = { ...makeRow({ conversationId: 'c1', coversTo: 'm3' }), kind: 'mystery' };
    const { coversDigest: _dropped, ...missingKey } = makeRow({ conversationId: 'c1', coversTo: 'm5' });
    file.data.checkpoints = [good, unknownKind, missingKey] as unknown as ContextCheckpointRow[];

    for (const mode of ['importNew', 'merge', 'replaceAll'] as ImportMode[]) {
      await resetStorage();
      await importFile(file, mode);
      expect(await listContextCheckpoints('c1')).toEqual([good]);
    }
  });

  it('legacy_backup_imports', async () => {
    await putConversation(makeConversation({ id: 'c1' }));
    const file = await exportedFile();
    delete file.data.checkpoints;

    await resetStorage();
    const result = await importFile(file, 'importNew');
    expect(result.conversationsImported).toBe(1);
    expect(await getConversationById('c1')).toBeDefined();
    expect(await listContextCheckpoints('c1')).toEqual([]);
  });
});

/**
 * Message merge algorithm tests.
 *
 * Core behavior of mergeMessages:
 * - global ordering by createdAt
 * - lexicographic UUID tie-break
 * - deduplication by UUID
 * - fallback ordering when createdAt is missing
 */
import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import type { Conversation, ChatMessage } from '@oriveo/shared';
import type { BackupFile } from '..';
import {
  resetDBConnection,
  putConversation,
  getAllConversations,
} from '../../infra/storage/idb';
import { setActiveUID } from '../../infra/storage/partition';
import { resetImageDBConnection } from '../../infra/storage/image-store';

/* ── crypto polyfill ──────────────────────────────────── */

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', {
    value: nodeCrypto.webcrypto,
    writable: true,
    configurable: true,
  });
}

const { generateImportPreview, executeImport } = await import('..');

/* ── Test helpers ─────────────────────────────────────────── */

function msg(id: string, createdAt?: string): ChatMessage {
  return {
    id,
    role: 'user',
    text: `Message ${id}`,
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'gpt-4o',
    estimatedCost: 0,
    state: 'delivered',
    createdAt,
  };
}

function makeConv(id: string, messages: ChatMessage[], updatedAt = '2026-03-01T00:00:00.000Z'): Conversation {
  return {
    id,
    title: 'Test',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt,
  };
}

function makeBackup(conversations: Conversation[]): BackupFile {
  return {
    version: 1,
    createdAt: new Date().toISOString(),
    appVersion: '1.0.0',
    platform: 'Web',
    checksum: '',
    containsKeys: false,
    data: { providers: [], conversations },
    encryptedKeys: null,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

/** Run the merge import and return the merged messages */
async function mergeAndGetMessages(
  localConv: Conversation,
  backupConv: Conversation,
): Promise<ChatMessage[]> {
  await putConversation(localConv);
  const preview = await generateImportPreview(makeBackup([backupConv]), new Map());
  await executeImport(preview, 'merge');
  const convs = await getAllConversations();
  return convs.find((c) => c.id === localConv.id)!.messages;
}

/* ======================================================== */

describe('message merge algorithm', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('keeps the valid snapshot from whichever side has it when the other is missing QuoteContext', async () => {
    const t1 = '2026-08-04T10:00:00Z';
    const quoteContext = {
      schemaVersion: 1 as const,
      sourceMessageId: 'source-1',
      sourceRole: 'assistant' as const,
      contentKind: 'code' as const,
      leadingText: 'const ', selectedText: 'value', trailingText: ' = 42;',
      contextTruncated: false,
    };
    const messages = await mergeAndGetMessages(
      makeConv('c-quote', [msg('M1', t1)]),
      makeConv('c-quote', [{ ...msg('M1', t1), quoteContext }]),
    );
    expect(messages).toHaveLength(1);
    expect(messages[0].quoteContext).toEqual(quoteContext);
  });

  /* ── Scenario 1: the backup is a subset of local ─────────── */

  it('local [M1,M2,M3,M4,M5] + backup [M1,M2,M3] -> [M1,M2,M3,M4,M5]', async () => {
    const t1 = '2026-03-01T10:00:00Z';
    const t2 = '2026-03-01T10:01:00Z';
    const t3 = '2026-03-01T10:02:00Z';
    const t4 = '2026-03-01T10:03:00Z';
    const t5 = '2026-03-01T10:04:00Z';

    const messages = await mergeAndGetMessages(
      makeConv('c1', [
        msg('M1', t1), msg('M2', t2), msg('M3', t3), msg('M4', t4), msg('M5', t5),
      ]),
      makeConv('c1', [
        msg('M1', t1), msg('M2', t2), msg('M3', t3),
      ]),
    );

    expect(messages.map((m) => m.id)).toEqual(['M1', 'M2', 'M3', 'M4', 'M5']);
  });

  /* ── Scenario 2: each side has unique messages ───────────── */

  it('local [M6,M7] + backup [M1,M2,M3,M4,M5] -> sorted by createdAt', async () => {
    const messages = await mergeAndGetMessages(
      makeConv('c1', [
        msg('M6', '2026-03-01T10:05:00Z'),
        msg('M7', '2026-03-01T10:06:00Z'),
      ]),
      makeConv('c1', [
        msg('M1', '2026-03-01T10:00:00Z'),
        msg('M2', '2026-03-01T10:01:00Z'),
        msg('M3', '2026-03-01T10:02:00Z'),
        msg('M4', '2026-03-01T10:03:00Z'),
        msg('M5', '2026-03-01T10:04:00Z'),
      ]),
    );

    expect(messages.map((m) => m.id)).toEqual(['M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'M7']);
  });

  /* ── Scenario 3: overlapping ranges ──────────────────────── */

  it('local [M1,M3,M5] + backup [M1,M2,M3,M4] -> [M1,M2,M3,M4,M5] with no duplicates', async () => {
    const messages = await mergeAndGetMessages(
      makeConv('c1', [
        msg('M1', '2026-03-01T10:00:00Z'),
        msg('M3', '2026-03-01T10:02:00Z'),
        msg('M5', '2026-03-01T10:04:00Z'),
      ]),
      makeConv('c1', [
        msg('M1', '2026-03-01T10:00:00Z'),
        msg('M2', '2026-03-01T10:01:00Z'),
        msg('M3', '2026-03-01T10:02:00Z'),
        msg('M4', '2026-03-01T10:03:00Z'),
      ]),
    );

    expect(messages.map((m) => m.id)).toEqual(['M1', 'M2', 'M3', 'M4', 'M5']);
  });

  /* ── Scenario 4: tie-break at the same timestamp ─────────── */

  it('messages sharing a createdAt are ordered by lexicographic UUID', async () => {
    const sameTime = '2026-03-01T10:00:00Z';

    const messages = await mergeAndGetMessages(
      makeConv('c1', [msg('Z-msg', sameTime)]),
      makeConv('c1', [msg('A-msg', sameTime)]),
    );

    // A-msg < Z-msg in lexicographic order
    expect(messages.map((m) => m.id)).toEqual(['A-msg', 'Z-msg']);
  });

  /* ── Scenario 5: identical data is deduplicated ──────────── */

  it('identical message lists are deduplicated', async () => {
    const t1 = '2026-03-01T10:00:00Z';
    const t2 = '2026-03-01T10:01:00Z';

    const messages = await mergeAndGetMessages(
      makeConv('c1', [msg('M1', t1), msg('M2', t2)]),
      makeConv('c1', [msg('M1', t1), msg('M2', t2)]),
    );

    expect(messages).toHaveLength(2);
    expect(messages.map((m) => m.id)).toEqual(['M1', 'M2']);
  });

  /* ── Scenario 6: empty arrays ────────────────────────────── */

  it('empty local + non-empty backup -> takes the backup', async () => {
    const messages = await mergeAndGetMessages(
      makeConv('c1', []),
      makeConv('c1', [
        msg('M1', '2026-03-01T10:00:00Z'),
        msg('M2', '2026-03-01T10:01:00Z'),
      ]),
    );

    expect(messages.map((m) => m.id)).toEqual(['M1', 'M2']);
  });

  it('both sides empty -> empty result', async () => {
    const messages = await mergeAndGetMessages(
      makeConv('c1', []),
      makeConv('c1', []),
    );

    expect(messages).toHaveLength(0);
  });

  /* ── Scenario 7: createdAt missing ───────────────────────── */

  it('messages missing createdAt are ordered by their original array position', async () => {
    const messages = await mergeAndGetMessages(
      makeConv('c1', [
        msg('local-1', undefined),
        msg('local-2', undefined),
      ]),
      makeConv('c1', [
        msg('backup-1', '2026-03-01T10:00:00Z'),
      ]),
    );

    // undefined falls back to 2000-01-01 + index, far earlier than 2026,
    // so the order is local-1(T0), local-2(T1), backup-1(2026)
    expect(messages).toHaveLength(3);
    expect(messages[messages.length - 1].id).toBe('backup-1');
  });

  /* ── Scenario 8: dedup performance with many messages ────── */

  it('merging 1000 messages deduplicates correctly', async () => {
    const localMsgs: ChatMessage[] = [];
    const backupMsgs: ChatMessage[] = [];

    for (let i = 0; i < 500; i++) {
      const time = new Date(2026, 2, 1, 10, 0, i).toISOString();
      localMsgs.push(msg(`shared-${i}`, time));
      backupMsgs.push(msg(`shared-${i}`, time));
    }

    // 250 messages unique to each side
    for (let i = 0; i < 250; i++) {
      localMsgs.push(msg(`local-only-${i}`, new Date(2026, 2, 1, 11, 0, i).toISOString()));
      backupMsgs.push(msg(`backup-only-${i}`, new Date(2026, 2, 1, 12, 0, i).toISOString()));
    }

    const messages = await mergeAndGetMessages(
      makeConv('c1', localMsgs),
      makeConv('c1', backupMsgs),
    );

    // 500 shared (deduplicated) + 250 local-only + 250 backup-only = 1000
    expect(messages).toHaveLength(1000);

    // Check that no ID is duplicated
    const ids = new Set(messages.map((m) => m.id));
    expect(ids.size).toBe(1000);
  });

  /* ── Scenario 9: keep the first occurrence when contents match ── */

  it('duplicate ids keep the version that appears first after sorting', async () => {
    const time = '2026-03-01T10:00:00Z';

    const messages = await mergeAndGetMessages(
      makeConv('c1', [msg('M1', time)]),
      makeConv('c1', [{
        ...msg('M1', time),
        text: 'Modified in backup',
      }]),
    );

    expect(messages).toHaveLength(1);
    // Both M1 entries sort to the same position and local comes first (spread order), so the local version is kept
    expect(messages[0].text).toBe('Message M1');
  });

  /* ── Scenario 10: case variants must be normalized before dedup ── */

  it('case variants of one UUID merge into a single message', async () => {
    // Local message ids have been rewritten to canonical uppercase by cloud sync, while the backup file keeps the lowercase form it was imported with
    const upper = '5B3A0C22-9A2C-4F8E-8B7D-1E2F3A4B5C6D';
    const lower = upper.toLowerCase();
    const time = '2026-03-01T10:00:00Z';

    const messages = await mergeAndGetMessages(
      makeConv('c1', [msg(upper, time)]),
      makeConv('c1', [{ ...msg(lower, time), text: 'Same message, lowercase id' }]),
    );

    // Keeping both would leave two ids that are literally identical after normalization, colliding on the key={msg.id} used by MessageList
    expect(messages).toHaveLength(1);
    const ids = messages.map((m) => m.id.toUpperCase());
    expect(new Set(ids).size).toBe(ids.length);
  });

  /* ── Scenario 11: case variants of a conversation id must not become two conversations ── */

  it('case variants of one conversation UUID merge into a single conversation', async () => {
    const upperConv = 'A1B2C3D4-1111-4222-8333-444455556666';
    const lowerConv = upperConv.toLowerCase();
    const t1 = '2026-03-01T10:00:00Z';
    const t2 = '2026-03-01T10:01:00Z';

    await putConversation(makeConv(upperConv, [msg('M1', t1)]));
    const preview = await generateImportPreview(
      makeBackup([makeConv(lowerConv, [msg('M2', t2)])]),
      new Map(),
    );
    await executeImport(preview, 'merge');

    const convs = await getAllConversations();
    expect(convs).toHaveLength(1);
    // Merged into the local conversation, keeping the local id, with messages from both sides present
    expect(convs[0].id).toBe(upperConv);
    expect(convs[0].messages.map((m) => m.id)).toEqual(['M1', 'M2']);
  });
});

import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  MEMORY_INTENT_CANDIDATE_TTL_MS,
  MEMORY_INTENT_CONFIDENCE_EXPLICIT,
  MEMORY_INTENT_CONFIDENCE_IMPLICIT,
} from '@oriveo/core/context/memory-intent-lexicon';
import { memoryIntentFingerprint } from '@oriveo/core/context/memory-intent';
import { resetDBConnection } from '../../../infra/storage/idb';
import {
  getAllMemoryCandidateRows,
  putMemoryCandidateRows,
  type MemoryCandidateRow,
} from '../../../infra/storage/memory-candidate-store';
import { getAllMemoryItemRows } from '../../../infra/storage/memory-item-store';
import { setActiveUID } from '../../../infra/storage/partition';
import { createAppStore } from '../../store/app-store';
import {
  createMemoryCandidateRepository,
  type MemoryCandidateGenerateInput,
  type MemoryCandidateProposeContext,
} from '../memory-candidate-repository';
import { createMemoryItemRepository } from '../memory-item-repository';

const UID = 'user-1';
// 2026-10-16T08:00:00.123Z: observedAt is truncated to the second.
const NOW_MS = 1792137600123;
const EXPLICIT = 'Remember that I prefer metric units.';
const EXPLICIT_CONTENT = 'I prefer metric units.';
const IMPLICIT = 'In all chats, always answer in Spanish.';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function setup(uid = UID) {
  const store = createAppStore();
  let counter = 0;
  const items = createMemoryItemRepository({
    store,
    uid,
    deviceId: 'device-a',
    now: () => new Date(NOW_MS),
    newId: () => `00000000-0000-4000-8000-${String(++counter).padStart(12, '0')}`,
    sync: () => null,
  });
  const candidates = createMemoryCandidateRepository({ uid, items, now: () => NOW_MS });
  return { items, candidates };
}

function input(overrides: Partial<MemoryCandidateGenerateInput> = {}): MemoryCandidateGenerateInput {
  return {
    text: EXPLICIT,
    messageId: 'message-1',
    conversationId: 'conversation-1',
    folderId: null,
    useMemory: true,
    nowMs: NOW_MS,
    ...overrides,
  };
}

describe('memory candidate repository', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    localStorage.clear();
    await setActiveUID(UID);
  });

  it('generate_creates_pending_for_explicit_remember', async () => {
    const { candidates } = setup();
    const created = await candidates.generate(input());

    expect(created).not.toBeNull();
    expect(created?.status).toBe('pending');
    expect(created?.content).toBe(EXPLICIT_CONTENT);
    expect(created?.scope).toEqual({ type: 'global', id: null });
    expect(created?.source).toEqual({
      type: 'conversation',
      conversationId: 'conversation-1',
      messageIds: ['message-1'],
      observedAtMs: NOW_MS,
    });
    expect(created?.confidence).toBe(MEMORY_INTENT_CONFIDENCE_EXPLICIT);
    expect(created?.expiresAtMs).toBe(NOW_MS + MEMORY_INTENT_CANDIDATE_TTL_MS);
    const rows = await getAllMemoryCandidateRows(UID);
    expect(rows).toEqual([{ id: created!.id, status: 'pending', candidate: created }]);
    expect(await candidates.pending(NOW_MS)).toEqual([created]);
  });

  it('generate_skips_no_suggestion', async () => {
    const { candidates } = setup();
    expect(await candidates.generate(input({ text: 'What is the weather like today?' }))).toBeNull();
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
  });

  it('generate_skips_when_use_memory_off', async () => {
    const { candidates } = setup();
    expect(await candidates.generate(input({ useMemory: false }))).toBeNull();
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
  });

  it('generate_skips_duplicate_active', async () => {
    const { items, candidates } = setup();
    const existing = await items.create({ kind: 'preference', content: EXPLICIT_CONTENT });
    // A paused item also counts as "existing".
    await items.setStatus(existing.id, 'paused');
    expect(await candidates.generate(input())).toBeNull();
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
  });

  it('generate_same_message_idempotent', async () => {
    const { candidates } = setup();
    const first = await candidates.generate(input());
    expect(first).not.toBeNull();
    expect(await candidates.generate(input({ nowMs: NOW_MS + 1000 }))).toBeNull();
    const rows = await getAllMemoryCandidateRows(UID);
    expect(rows.map((r) => r.candidate)).toEqual([first]);
  });

  it('generate_in_folder_scopes_folder', async () => {
    const { candidates } = setup();
    const created = await candidates.generate(input({ folderId: 'folder-1' }));
    expect(created?.scope).toEqual({ type: 'folder', id: 'folder-1' });
  });

  it('auto_suggest_pref_defaults_on_and_persists_per_account', async () => {
    const first = setup();
    expect(first.candidates.autoSuggestEnabled()).toBe(true);
    first.candidates.setAutoSuggestEnabled(false);
    expect(first.candidates.autoSuggestEnabled()).toBe(false);
    expect(localStorage.getItem(`oriveo.${UID}.memoryAutoSuggestEnabled`)).toBe('false');
    // A newly created repository instance reads back the same local preference.
    expect(setup().candidates.autoSuggestEnabled()).toBe(false);
    // Another account is unaffected and keeps the default (on).
    expect(setup('user-2').candidates.autoSuggestEnabled()).toBe(true);

    first.candidates.setAutoSuggestEnabled(true);
    expect(setup().candidates.autoSuggestEnabled()).toBe(true);
  });

  it('generate_skips_implicit_when_auto_suggest_off', async () => {
    const { candidates } = setup();
    const existing = await candidates.generate(input({ text: IMPLICIT, messageId: 'message-0' }));
    expect(existing?.confidence).toBe(MEMORY_INTENT_CONFIDENCE_IMPLICIT);

    candidates.setAutoSuggestEnabled(false);
    // Turning it off does not delete existing pending candidates.
    expect(await candidates.pending(NOW_MS)).toEqual([existing]);
    const implicitText = 'From now on, always use tabs for indentation.';
    expect(await candidates.generate(input({ text: implicitText, messageId: 'message-1' }))).toBeNull();
    expect((await getAllMemoryCandidateRows(UID)).map((r) => r.id)).toEqual([existing!.id]);

    // An explicit "remember" still creates a pending candidate.
    const explicit = await candidates.generate(input({ messageId: 'message-2' }));
    expect(explicit?.status).toBe('pending');
    expect(explicit?.content).toBe(EXPLICIT_CONTENT);
    expect(explicit?.confidence).toBe(MEMORY_INTENT_CONFIDENCE_EXPLICIT);
    const rows = await getAllMemoryCandidateRows(UID);
    expect(rows.find((r) => r.id === explicit!.id)).toEqual({ id: explicit!.id, status: 'pending', candidate: explicit });
    expect(rows).toHaveLength(2);
  });

  it('reject_keeps_fingerprint_only_and_blocks_regeneration', async () => {
    const { candidates } = setup();
    const created = await candidates.generate(input());
    const rejectedAt = NOW_MS + 5000;

    const result = await candidates.reject(created!.id, rejectedAt);

    expect('record' in result).toBe(true);
    const rows = await getAllMemoryCandidateRows(UID);
    expect(rows).toHaveLength(1);
    const [row] = rows;
    expect(row.status).toBe('rejected');
    expect(row.candidate.status).toBe('rejected');
    expect(row.candidate.content).toBe('');
    expect(row.candidate.source).toEqual({ type: 'conversation', conversationId: null, messageIds: [], observedAtMs: null });
    expect(row.candidate.fingerprint).toBe(memoryIntentFingerprint(EXPLICIT_CONTENT));
    expect(row.candidate.resolvedAtMs).toBe(rejectedAt);
    expect(row.candidate.expiresAtMs).toBe(rejectedAt + MEMORY_INTENT_CANDIDATE_TTL_MS);
    // Saying the same sentence again in another message: no new candidate while the rejection is in effect.
    expect(await candidates.generate(input({ messageId: 'message-2', nowMs: rejectedAt + 1000 }))).toBeNull();
    expect(await candidates.pending(rejectedAt + 1000)).toEqual([]);
    expect(await candidates.reject(created!.id, rejectedAt + 1000)).toEqual({ error: 'not_pending' });
    expect(await candidates.reject('missing', rejectedAt)).toEqual({ error: 'not_pending' });
  });

  it('accept_creates_item_and_removes_candidate', async () => {
    const { items, candidates } = setup();
    const created = await candidates.generate(input({ folderId: 'folder-1' }));

    const result = await candidates.accept(created!.id, null, NOW_MS + 10);

    expect('item' in result).toBe(true);
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
    const itemRows = await getAllMemoryItemRows(UID);
    expect(itemRows).toHaveLength(1);
    const [row] = itemRows;
    // The assertions use the item read back after createFromDraft wrote it.
    expect(row.syncState).toBe('pending');
    expect(row.item).toEqual('item' in result ? result.item : null);
    expect(row.item.status).toBe('active');
    expect(row.item.layer).toBe('semantic');
    expect(row.item.content).toBe(EXPLICIT_CONTENT);
    expect(row.item.kind).toBe(created!.proposedKind);
    expect(row.item.scope).toEqual({ type: 'folder', id: 'folder-1' });
    expect(row.item.source).toEqual({
      type: 'conversation',
      conversationId: 'conversation-1',
      messageIds: ['message-1'],
      observedAt: '2026-10-16T08:00:00Z',
    });
    expect(row.item.confidence).toBe(MEMORY_INTENT_CONFIDENCE_EXPLICIT);
    expect(row.item.sensitivity).toBe('normal');
    expect(row.item.revision).toBe(1);
    expect(row.item.baseRevision).toBe(0);
    expect(row.item.id).not.toBe(created!.id);
    expect((await items.list()).map((m) => m.id)).toEqual([row.item.id]);
    expect(await candidates.accept(created!.id, null, NOW_MS + 20)).toEqual({ error: 'not_pending' });
  });

  it('accept_rolls_back_when_candidate_delete_fails', async () => {
    const { items, candidates } = setup();
    const created = await candidates.generate(input());
    const [pendingRow] = await getAllMemoryCandidateRows(UID);
    const failDelete = vi.spyOn(IDBObjectStore.prototype, 'delete').mockImplementationOnce(() => {
      throw new DOMException('delete failed', 'UnknownError');
    });

    try {
      await expect(candidates.accept(created!.id, null, NOW_MS + 10)).rejects.toThrow('delete failed');
    } finally {
      failDelete.mockRestore();
    }

    // Deleting the candidate fails: the item write rolls back in the same transaction, and the candidate stays pending.
    expect(await getAllMemoryItemRows(UID)).toEqual([]);
    expect(await getAllMemoryCandidateRows(UID)).toEqual([pendingRow]);
    expect(await candidates.pending(NOW_MS + 10)).toEqual([created]);

    // A retry lands only one item.
    const retried = await candidates.accept(created!.id, null, NOW_MS + 20);
    expect('item' in retried).toBe(true);
    const itemRows = await getAllMemoryItemRows(UID);
    expect(itemRows).toHaveLength(1);
    expect(itemRows[0].item).toEqual('item' in retried ? retried.item : null);
    expect((await items.list()).map((m) => m.id)).toEqual([itemRows[0].id]);
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
  });

  it('accept_edited_content_confidence_one', async () => {
    const { candidates } = setup();
    const created = await candidates.generate(input({ text: IMPLICIT }));
    expect(created?.confidence).toBe(MEMORY_INTENT_CONFIDENCE_IMPLICIT);

    const result = await candidates.accept(created!.id, { content: '  Always answer in Mexican Spanish.  ' }, NOW_MS + 10);

    expect('item' in result).toBe(true);
    const [row] = await getAllMemoryItemRows(UID);
    expect(row.item.content).toBe('Always answer in Mexican Spanish.');
    expect(row.item.confidence).toBe(1);
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
  });

  it('accept_expired_errors_and_purges', async () => {
    const { candidates } = setup();
    const created = await candidates.generate(input());

    const result = await candidates.accept(created!.id, null, NOW_MS + MEMORY_INTENT_CANDIDATE_TTL_MS);

    expect(result).toEqual({ error: 'expired' });
    expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
    expect(await getAllMemoryItemRows(UID)).toEqual([]);
  });

  it('pending_sweeps_expired_and_superseded', async () => {
    const { items, candidates } = setup();
    const half = MEMORY_INTENT_CANDIDATE_TTL_MS / 2;
    const expired = await candidates.generate(input({ messageId: 'm-expired' }));
    const superseded = await candidates.generate(
      input({ text: 'Remember that my cat is called Miso.', messageId: 'm-superseded', nowMs: NOW_MS + half }),
    );
    const older = await candidates.generate(
      input({ text: 'Remember that I live in Lisbon.', messageId: 'm-older', nowMs: NOW_MS + half }),
    );
    const newer = await candidates.generate(
      input({ text: 'Remember that I work as a nurse.', messageId: 'm-newer', nowMs: NOW_MS + half + 1 }),
    );
    expect([expired, superseded, older, newer].every((c) => c !== null)).toBe(true);
    await items.create({ kind: 'fact', content: superseded!.content });

    const pending = await candidates.pending(NOW_MS + MEMORY_INTENT_CANDIDATE_TTL_MS);

    expect(pending.map((c) => c.id)).toEqual([newer!.id, older!.id]);
    const rows = await getAllMemoryCandidateRows(UID);
    expect(rows.map((r) => r.id).sort()).toEqual([newer!.id, older!.id].sort());
  });

  it('pending_same_created_at_orders_by_id', async () => {
    const { candidates } = setup();
    const a = await candidates.generate(input({ text: 'Remember that I live in Lisbon.', messageId: 'm-a' }));
    const b = await candidates.generate(input({ text: 'Remember that I work as a nurse.', messageId: 'm-b' }));
    const c = await candidates.generate(input({ text: 'Remember that my cat is called Miso.', messageId: 'm-c' }));
    const later = await candidates.generate(input({ messageId: 'm-later', nowMs: NOW_MS + 1 }));
    expect([a, b, c, later].every((x) => x !== null)).toBe(true);

    const pending = await candidates.pending(NOW_MS + 2);

    const sameTime = [a!.id, b!.id, c!.id].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
    expect(pending.map((x) => x.id)).toEqual([later!.id, ...sameTime]);
  });

  it('sweep_purges_unreadable_rows', async () => {
    const { candidates } = setup();
    const valid = await candidates.generate(input());
    expect(valid).not.toBeNull();
    const badRows = [
      { id: 'bad-missing-candidate', status: 'pending' },
      { id: 'bad-status', status: 'archived', candidate: { ...valid!, id: 'bad-status', status: 'archived' } },
      { id: 'bad-kind', status: 'pending', candidate: { ...valid!, id: 'bad-kind', proposedKind: 'mystery' } },
      { id: 'bad-scope', status: 'pending', candidate: { ...valid!, id: 'bad-scope', scope: { type: 'workspace', id: null } } },
      { id: 'bad-source', status: 'pending', candidate: { ...valid!, id: 'bad-source', source: null } },
    ] as unknown as MemoryCandidateRow[];
    await putMemoryCandidateRows(badRows, UID);

    const created = await candidates.generate(input({ text: IMPLICIT, messageId: 'message-2', nowMs: NOW_MS + 1 }));

    expect(created).not.toBeNull();
    expect((await getAllMemoryCandidateRows(UID)).map((r) => r.id).sort()).toEqual([valid!.id, created!.id].sort());
    await putMemoryCandidateRows(badRows, UID);
    const pending = await candidates.pending(NOW_MS + 2);
    expect(pending.map((x) => x.id)).toEqual([created!.id, valid!.id]);
    expect((await getAllMemoryCandidateRows(UID)).map((r) => r.id).sort()).toEqual([valid!.id, created!.id].sort());
  });

  it('candidates_partitioned_by_account', async () => {
    const first = setup();
    const created = await first.candidates.generate(input());
    expect(created).not.toBeNull();

    resetDBConnection();
    await setActiveUID('user-2');
    const second = setup('user-2');
    expect(await second.candidates.pending(NOW_MS)).toEqual([]);
    const other = await second.candidates.generate(input());
    expect(other?.id).toBe(created!.id);
    expect((await getAllMemoryCandidateRows('user-2')).map((r) => r.id)).toEqual([other!.id]);

    resetDBConnection();
    await setActiveUID(UID);
    expect((await getAllMemoryCandidateRows(UID)).map((r) => r.candidate)).toEqual([created]);
  });

  it('no_candidate_becomes_active_without_accept', async () => {
    const { items, candidates } = setup();
    const kept = await candidates.generate(input());
    const rejected = await candidates.generate(input({ text: IMPLICIT, messageId: 'message-2' }));
    expect(kept).not.toBeNull();
    expect(rejected).not.toBeNull();
    await candidates.reject(rejected!.id, NOW_MS + 1);
    await candidates.pending(NOW_MS + 2);

    expect(await items.list()).toEqual([]);
    expect(await getAllMemoryItemRows(UID)).toEqual([]);
  });
  describe('propose', () => {
    const USER_TEXT = 'By the way, I work as a pediatric nurse in Lyon.';
    const ARGS = JSON.stringify({
      proposition: 'The user works as a pediatric nurse in Lyon.',
      kind: 'identity',
      scope: 'unspecified',
      sourceQuote: 'I work as a pediatric nurse in Lyon',
    });

    function context(overrides: Partial<MemoryCandidateProposeContext> = {}): MemoryCandidateProposeContext {
      return {
        userText: USER_TEXT,
        messageId: 'message-1',
        conversationId: 'conversation-1',
        folderId: null,
        nowMs: NOW_MS,
        ...overrides,
      };
    }

    it('propose_creates_pending_from_tool_call', async () => {
      const { candidates } = setup();
      const created = await candidates.propose(ARGS, 0, context());

      expect(created).toMatchObject({
        status: 'pending',
        proposedKind: 'identity',
        content: 'The user works as a pediatric nurse in Lyon.',
        source: { type: 'conversation', conversationId: 'conversation-1', messageIds: ['message-1'], observedAtMs: NOW_MS },
      });
      const rows = await getAllMemoryCandidateRows(UID);
      expect(rows).toEqual([{ id: created!.id, status: 'pending', candidate: created }]);
      expect(await candidates.pending(NOW_MS)).toEqual([created]);
    });

    it('propose_episodic_survives_sweep', async () => {
      // decision / event candidates land as episodic; reading back must not sweep them away as bad rows
      const { candidates } = setup();
      const text = 'We decided to skip the Porto day trip.';
      const args = JSON.stringify({
        proposition: 'The user decided to skip the Porto day trip.',
        kind: 'decision',
        scope: 'unspecified',
        sourceQuote: 'We decided to skip the Porto day trip',
      });
      const created = await candidates.propose(args, 0, context({ userText: text }));

      expect(created).toMatchObject({ proposedLayer: 'episodic', proposedKind: 'decision' });
      expect(await candidates.pending(NOW_MS + 1)).toEqual([created]);
      expect((await getAllMemoryCandidateRows(UID)).map((r) => r.id)).toEqual([created!.id]);
    });

    it('propose_quote_not_in_message_writes_nothing', async () => {
      const { candidates } = setup();
      const args = JSON.stringify({ ...JSON.parse(ARGS), sourceQuote: 'I am a surgeon' });
      expect(await candidates.propose(args, 0, context())).toBeNull();
      expect(await candidates.propose('not json', 0, context())).toBeNull();
      expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
    });

    it('propose_turn_limit_writes_nothing', async () => {
      const { candidates } = setup();
      expect(await candidates.propose(ARGS, 3, context())).toBeNull();
      expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
    });

    it('propose_same_message_idempotent', async () => {
      const { items, candidates } = setup();
      const first = await candidates.propose(ARGS, 0, context());
      expect(first).not.toBeNull();
      expect(await candidates.propose(ARGS, 1, context({ nowMs: NOW_MS + 1000 }))).toBeNull();
      expect((await getAllMemoryCandidateRows(UID)).map((r) => r.candidate)).toEqual([first]);
      expect(await items.list()).toEqual([]);
    });

    it('propose_skips_duplicate_active', async () => {
      const { items, candidates } = setup();
      await items.create({ kind: 'identity', content: 'The user works as a pediatric nurse in Lyon.' });
      expect(await candidates.propose(ARGS, 0, context())).toBeNull();
      expect(await getAllMemoryCandidateRows(UID)).toEqual([]);
    });
  });
});

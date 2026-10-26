/**
 * Memory candidate repository: the read/write entry of the local memoryCandidates table.
 * - Stored only in this device's current partition database, never synced or backed up; only pending and unexpired rejected candidates are kept, and a sweep before every write / read deletes purged rows.
 * - generate: no candidate when useMemory=false; classify -> makeCandidate (records = all candidates of this partition,
 *   activeContents = body text of the active / paused / conflicted items of this partition) -> write only on create. The items table is untouched.
 * - accept: goes through the item repository's createFromDraft on the normal create path, and the item creation and the candidate row deletion share one IndexedDB transaction,
 *   so any failure rolls everything back (no item, candidate still pending); an expired candidate has its row deleted as well.
 * - reject: store the reject result (only the fingerprint is kept, for short-term de-duplication).
 * - Rows that cannot be understood (missing fields, wrong types, unknown enums) are deleted as purged during the sweep, so generate / pending never throw.
 * - Auto-suggest switch: a device-local preference partitioned by uid (memoryAutoSuggestEnabled, on by default), never synced or backed up;
 *   turning it off only stops implicit_persist from generating candidates, an explicit "remember" still works, and existing pending candidates are not deleted.
 * - propose: one model propose_memory call -> proposeMemoryCandidate, sharing storage and lock with generate;
 *   only create writes, and every other outcome (including exceeding the per-turn limit or a quote not in the user message) returns null.
 * - All times are in milliseconds; a method called without nowMs uses the injected now().
 */

import {
  acceptMemoryCandidate,
  classifyMemoryIntent,
  makeMemoryCandidate,
  rejectMemoryCandidate,
  sweepMemoryCandidates,
  type MemoryCandidateEdit,
  type MemoryCandidateRecord,
  type MemoryCandidateStatus,
  type MemoryCandidateTransitionError,
} from '@oriveo/core/context/memory-intent';
import { proposeMemoryCandidate } from '@oriveo/core/context/memory-propose';
import type { MemoryItem, MemoryKind, MemoryLayer, MemoryScopeType, MemoryStatus } from '@oriveo/core/context/memory-items';
import {
  deleteMemoryCandidateRows,
  getAllMemoryCandidateRows,
  getMemoryCandidateRow,
  putMemoryCandidateRows,
  type MemoryCandidateRow,
} from '../../infra/storage/memory-candidate-store';
import { getPreference, setPreference } from '../../infra/storage/preferences';
import type { MemoryItemRepository } from './memory-item-repository';

/** States that count as "existing items": items that are not deleted and still in use. */
const ACTIVE_CONTENT_STATUSES: ReadonlySet<MemoryStatus> = new Set(['active', 'paused', 'conflicted']);

/** Preference key of the auto-suggest switch (localStorage `oriveo.{uid}.memoryAutoSuggestEnabled`). */
const AUTO_SUGGEST_PREF_KEY = 'memoryAutoSuggestEnabled';

export interface MemoryCandidateRepositoryOptions {
  uid: string;
  /** Item repository of this partition: reads existing bodies and creates the item on accept. */
  items: Pick<MemoryItemRepository, 'list' | 'createFromDraft'>;
  /** Device clock (milliseconds); injected by tests. */
  now?: () => number;
}

export interface MemoryCandidateGenerateInput {
  text: string;
  messageId: string;
  conversationId: string;
  folderId: string | null;
  useMemory: boolean;
  nowMs?: number;
}

/** Context of one propose call: userText is the body of this turn's new user message and messageId is its id. */
export interface MemoryCandidateProposeContext {
  userText: string;
  messageId: string;
  conversationId: string;
  folderId: string | null;
  nowMs?: number;
  /** Earlier calls of this turn that yielded instruct (memory-propose.v3 rule 4). */
  priorInstructInTurn?: number;
  /** scope conversation (v3): the call yields a sentence for the conversation-instruction bar, no candidate. */
  onInstruct?: (sentence: string) => void;
}

export type MemoryCandidateAcceptOutcome = { item: MemoryItem } | { error: MemoryCandidateTransitionError };
export type MemoryCandidateRejectOutcome = { record: MemoryCandidateRecord } | { error: 'not_pending' };

export interface MemoryCandidateRepository {
  /** The new candidate; null when none is generated. */
  generate(input: MemoryCandidateGenerateInput): Promise<MemoryCandidateRecord | null>;
  /** One propose_memory call; priorInTurn = number of earlier calls this turn. Returns null when no candidate is created. */
  propose(
    argumentsJson: string,
    priorInTurn: number,
    context: MemoryCandidateProposeContext,
  ): Promise<MemoryCandidateRecord | null>;
  accept(id: string, edit?: MemoryCandidateEdit | null, nowMs?: number): Promise<MemoryCandidateAcceptOutcome>;
  reject(id: string, nowMs?: number): Promise<MemoryCandidateRejectOutcome>;
  /** Pending candidates after the sweep: createdAtMs descending, ties by id ascending. */
  pending(nowMs?: number): Promise<MemoryCandidateRecord[]>;
  /** The auto-suggest switch of this uid; on when never set. */
  autoSuggestEnabled(): boolean;
  /** Change the auto-suggest switch of this uid; existing candidates are untouched. */
  setAutoSuggestEnabled(on: boolean): void;
}

/** Candidate read-modify-write for the same uid shares one lock. */
const candidateLocks = new Map<string, <T>(op: () => Promise<T>) => Promise<T>>();

function lockFor(uid: string): <T>(op: () => Promise<T>) => Promise<T> {
  let lock = candidateLocks.get(uid);
  if (!lock) {
    let tail: Promise<unknown> = Promise.resolve();
    lock = <T>(op: () => Promise<T>) => {
      const run = tail.then(op, op);
      tail = run.catch(() => undefined);
      return run;
    };
    candidateLocks.set(uid, lock);
  }
  return lock;
}

/** List the full enum with a Record: adding a type member fails compilation here. */
const CANDIDATE_STATUSES: Record<MemoryCandidateStatus, true> = {
  pending: true,
  accepted: true,
  rejected: true,
  superseded: true,
  expired: true,
};
// decision / event candidates are episodic and both layers must be readable, otherwise the sweep would delete an L3 suggestion as a bad row
const CANDIDATE_LAYERS: Record<MemoryLayer, true> = { semantic: true, episodic: true };
const CANDIDATE_KINDS: Record<MemoryKind, true> = {
  identity: true,
  preference: true,
  instruction: true,
  constraint: true,
  project: true,
  goal: true,
  decision: true,
  fact: true,
  event: true,
};
const CANDIDATE_SCOPE_TYPES: Record<MemoryScopeType, true> = { global: true, folder: true, conversation: true };

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isNullableString(value: unknown): boolean {
  return value === null || typeof value === 'string';
}

function isEnumMember(table: Record<string, true>, value: unknown): boolean {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(table, value);
}

/** Return a candidate only if the row can be read as a MemoryCandidateRecord; otherwise null (left for the sweep to delete). */
function readableCandidate(row: unknown): MemoryCandidateRecord | null {
  if (!isObject(row) || !isObject(row.candidate)) return null;
  const c = row.candidate;
  const { scope, source } = c;
  const ok =
    typeof c.id === 'string' &&
    c.id === row.id &&
    isEnumMember(CANDIDATE_STATUSES, c.status) &&
    isEnumMember(CANDIDATE_LAYERS, c.proposedLayer) &&
    isEnumMember(CANDIDATE_KINDS, c.proposedKind) &&
    typeof c.content === 'string' &&
    isObject(scope) &&
    isEnumMember(CANDIDATE_SCOPE_TYPES, scope.type) &&
    isNullableString(scope.id) &&
    isObject(source) &&
    source.type === 'conversation' &&
    isNullableString(source.conversationId) &&
    Array.isArray(source.messageIds) &&
    source.messageIds.every((m) => typeof m === 'string') &&
    (source.observedAtMs === null || isFiniteNumber(source.observedAtMs)) &&
    c.sensitivity === 'normal' &&
    isFiniteNumber(c.confidence) &&
    typeof c.fingerprint === 'string' &&
    isFiniteNumber(c.createdAtMs) &&
    isFiniteNumber(c.expiresAtMs) &&
    (c.resolvedAtMs === null || isFiniteNumber(c.resolvedAtMs));
  return ok ? (c as unknown as MemoryCandidateRecord) : null;
}

/** The auto-suggest switch of this uid; on when never set. It is also read outside the repository (send-mode decision). */
export function memoryAutoSuggestEnabled(uid: string): boolean {
  return getPreference<unknown>(AUTO_SUGGEST_PREF_KEY, true, uid) !== false;
}

function rowOf(candidate: MemoryCandidateRecord): MemoryCandidateRow {
  return { id: candidate.id, status: candidate.status, candidate };
}

export function createMemoryCandidateRepository(options: MemoryCandidateRepositoryOptions): MemoryCandidateRepository {
  const { uid, items } = options;
  const now = options.now ?? (() => Date.now());
  const serial = lockFor(uid);

  async function activeContents(): Promise<string[]> {
    return (await items.list()).filter((m) => ACTIVE_CONTENT_STATUSES.has(m.status)).map((m) => m.content);
  }

  /** Run the sweep and delete purged rows (including unreadable ones), returning the candidates that remain. */
  async function sweptRecords(nowMs: number, contents: readonly string[]): Promise<MemoryCandidateRecord[]> {
    const records: MemoryCandidateRecord[] = [];
    const unreadableIds: string[] = [];
    for (const row of await getAllMemoryCandidateRows(uid)) {
      const record = readableCandidate(row);
      if (record) records.push(record);
      else if (isObject(row) && typeof row.id === 'string') unreadableIds.push(row.id);
    }
    const { purgedIds } = sweepMemoryCandidates(records, contents, nowMs);
    await deleteMemoryCandidateRows([...unreadableIds, ...purgedIds], uid);
    const purged = new Set(purgedIds);
    return records.filter((r) => !purged.has(r.id));
  }

  function autoSuggestEnabled(): boolean {
    return memoryAutoSuggestEnabled(uid);
  }

  async function findPending(id: string): Promise<MemoryCandidateRecord | null> {
    return readableCandidate(await getMemoryCandidateRow(id, uid));
  }

  return {
    autoSuggestEnabled,

    setAutoSuggestEnabled(on) {
      setPreference(AUTO_SUGGEST_PREF_KEY, on, uid);
    },

    generate(input) {
      if (!input.useMemory) return Promise.resolve(null);
      const nowMs = input.nowMs ?? now();
      return serial(async () => {
        const classification = classifyMemoryIntent(input.text);
        if (classification.suggestion !== 'memory') return null;
        const contents = await activeContents();
        const records = await sweptRecords(nowMs, contents);
        const outcome = makeMemoryCandidate(classification, {
          conversationId: input.conversationId,
          folderId: input.folderId,
          messageId: input.messageId,
          nowMs,
          activeContents: contents,
          records,
          autoSuggest: autoSuggestEnabled(),
        });
        if (outcome.action !== 'create') return null;
        await putMemoryCandidateRows([rowOf(outcome.candidate)], uid);
        return outcome.candidate;
      });
    },

    propose(argumentsJson, priorInTurn, context) {
      const nowMs = context.nowMs ?? now();
      return serial(async () => {
        const contents = await activeContents();
        const records = await sweptRecords(nowMs, contents);
        const outcome = proposeMemoryCandidate(
          argumentsJson,
          {
            conversationId: context.conversationId,
            folderId: context.folderId,
            messageId: context.messageId,
            userText: context.userText,
            nowMs,
            activeContents: contents,
            records,
          },
          priorInTurn,
          context.priorInstructInTurn ?? 0,
        );
        if (outcome.action === 'instruct') {
          context.onInstruct?.(outcome.sentence);
          return null;
        }
        if (outcome.action !== 'create') return null;
        await putMemoryCandidateRows([rowOf(outcome.candidate)], uid);
        return outcome.candidate;
      });
    },

    accept(id, edit, nowMs = now()) {
      return serial(async (): Promise<MemoryCandidateAcceptOutcome> => {
        const record = await findPending(id);
        if (!record) return { error: 'not_pending' };
        const result = acceptMemoryCandidate(record, edit, nowMs);
        if ('error' in result) {
          if (result.error === 'expired') await deleteMemoryCandidateRows([record.id], uid);
          return { error: result.error };
        }
        const item = await items.createFromDraft(result.item, { consumeCandidateId: record.id });
        return { item };
      });
    },

    reject(id, nowMs = now()) {
      return serial(async (): Promise<MemoryCandidateRejectOutcome> => {
        const record = await findPending(id);
        if (!record) return { error: 'not_pending' };
        const result = rejectMemoryCandidate(record, nowMs);
        if ('error' in result) return result;
        await putMemoryCandidateRows([rowOf(result.record)], uid);
        return result;
      });
    },

    pending(nowMs = now()) {
      return serial(async () => {
        const records = await sweptRecords(nowMs, await activeContents());
        return records
          .filter((r) => r.status === 'pending')
          .sort((a, b) => b.createdAtMs - a.createdAtMs || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
      });
    },
  };
}

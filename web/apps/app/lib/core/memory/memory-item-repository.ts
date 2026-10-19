/**
 * Memory item repository: the read/write entry of the local memoryItems table.
 * - Writes: a new mutationId (random, lowercase), baseRevision = current revision, this device's deviceId, syncState pending;
 *   deletion writes a tombstone and never hard-deletes.
 * - After items change, memoryText + memoryTextDigest are written together for older clients; a write happens only when the compiled result or the digest differs from prefs,
 *   and Anti-Forget fields are no longer written. Only when the compiled result != local memoryText are memoryUpdatedAt refreshed and the change pushed;
 *   filling in only the digest stays local (no push, so an empty / old text cannot overwrite the cloud).
 * - reconcileLegacy: runs legacySync when an account activates and when memoryText changes (first migration / older-client edits flowing back).
 * - After a write `onLocalChange` is called (a no-op by default); items stay pending until a sync backend, if one is installed, confirms them.
 * - After a write the store.memoryItems slice is refreshed, and injection reads it.
 * - resolveConflict(keepId): keep one item of the conflict group (turn it active, clear conflictGroupId) and tombstone the rest.
 * - createFromDraft: after a memory candidate is accepted, create the item from the draft on the same create path; observedAtMs becomes UTC RFC 3339 (truncated to the second, with Z).
 * - L3: a new episodic item without occurredAt takes now; saving runs memoryRecallConflict, and on a hit both the new and the old item turn
 *   conflicted with conflictGroupId = the old item's id; resolveL3Conflict writes locally using the two patches from resolveMemoryRecallConflict.
 */

import type { AppPreference } from '@oriveo/shared';
import type { MemoryCandidateItemDraft } from '@oriveo/core/context/memory-intent';
import {
  memoryRecallConflict,
  resolveMemoryRecallConflict,
  type MemoryRecallResolution,
} from '@oriveo/core/context/memory-recall';
import {
  MemoryItems,
  type MemoryItem,
  type MemoryItemInput,
  type MemoryKind,
  type MemoryLayer,
  type MemoryLegacyPrefsWrite,
  type MemoryLegacySyncPlan,
  type MemoryScope,
  type MemorySensitivity,
  type MemoryStatus,
} from '@oriveo/core/context/memory-items';
import type { MemoryItemRow } from '../../infra/storage/memory-item-store';
import { getPreference, setPreference } from '../../infra/storage/preferences';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { getSyncAdapter } from '../sync-port';
import { createIdbMemoryItemRowStore, type MemoryItemRowStore } from './memory-item-row-store';
import { refreshMemoryItemsSlice } from './memory-items-slice';

/** Per-account local "migrated" marker (partitioned localStorage, never goes to the cloud). */
export const MEMORY_ITEMS_MIGRATED_KEY = 'memoryItems.migrated';

/** The repository only uses the store's preference read/write; StoreApi<AppStore> satisfies this structurally. */
export interface MemoryPreferenceStore {
  getState(): {
    preferences: AppPreference;
    setPreferences: (patch: Partial<AppPreference>) => void;
    /** Memory item slice; not refreshed when absent. */
    setMemoryItems?: (items: MemoryItem[]) => void;
  };
}

export interface MemoryPreferenceSink {
  didUpdatePreferences(patch: Record<string, unknown>): void;
}

export interface MemoryItemRepositoryOptions {
  store: MemoryPreferenceStore;
  uid: string;
  deviceId: string;
  /** Device clock; injected by tests. */
  now?: () => Date;
  /** New id / mutationId; injected by tests. */
  newId?: () => string;
  /** Cloud preference outlet; defaults to getSyncAdapter(). */
  sync?: () => MemoryPreferenceSink | null;
  /** Local row storage; defaults to this account's partition IndexedDB (sharing one lock with any sync backend). */
  rows?: MemoryItemRowStore;
  /** Called after a local row write; a no-op by default. */
  onLocalChange?: () => void;
}

export interface MemoryItemCreateInput {
  kind: MemoryKind;
  content: string;
  layer?: MemoryLayer;
  scope?: MemoryScope;
  sensitivity?: MemorySensitivity;
  pinned?: boolean;
  /** L3 event time; defaults to now for episodic items. */
  occurredAt?: string | null;
}

export interface MemoryItemUpdateInput {
  kind?: MemoryKind;
  content?: string;
  /** L3 event time (date edited in the settings editor). */
  occurredAt?: string | null;
}

export interface MemoryItemRepository {
  /** Items that are not deleted, in list order. */
  list(): Promise<MemoryItem[]>;
  create(input: MemoryItemCreateInput): Promise<MemoryItem>;
  /**
   * Accept a memory candidate: the draft fields land unchanged as a new item (new id, pending, dual write, same notification as create).
   * When consumeCandidateId is given, the item write and the deletion of that candidate row share one transaction and succeed or fail together.
   */
  createFromDraft(draft: MemoryCandidateItemDraft, options?: { consumeCandidateId?: string }): Promise<MemoryItem>;
  update(id: string, patch: MemoryItemUpdateInput): Promise<MemoryItem | null>;
  remove(id: string): Promise<MemoryItem | null>;
  setPinned(id: string, pinned: boolean): Promise<MemoryItem | null>;
  setStatus(id: string, status: Exclude<MemoryStatus, 'deleted'>): Promise<MemoryItem | null>;
  reconcileLegacy(): Promise<MemoryLegacySyncPlan>;
  /** Keep the keepId item of a conflict group; returns null when it is not a conflict item. */
  resolveConflict(keepId: string): Promise<MemoryItem | null>;
  /** L3 conflict resolution: returns the two written items [newer, older]; returns null when either does not exist or is deleted. */
  resolveL3Conflict(newerId: string, olderId: string, resolution: MemoryRecallResolution): Promise<[MemoryItem, MemoryItem] | null>;
}

function randomLowercaseId(): string {
  return globalThis.crypto.randomUUID().toLowerCase();
}

/** Millisecond timestamp -> UTC RFC 3339 truncated to the second with Z (1792137600123 -> "2026-10-16T08:00:00Z"). */
export function observedAtFromMs(ms: number | null): string | null {
  if (ms === null) return null;
  return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function pendingRow(item: MemoryItem): MemoryItemRow {
  return { id: item.id, item, syncState: 'pending' };
}

export function createMemoryItemRepository(options: MemoryItemRepositoryOptions): MemoryItemRepository {
  const { store, uid, deviceId } = options;
  const now = options.now ?? (() => new Date());
  const newId = () => (options.newId ?? randomLowercaseId)().toLowerCase();
  const sync = options.sync ?? (() => getSyncAdapter());
  const rows = options.rows ?? createIdbMemoryItemRowStore(uid);
  const onLocalChange = options.onLocalChange ?? (() => undefined);

  // Read-modify-write is serialized (sharing one lock with any sync backend), so concurrent writes cannot overwrite each other's baseRevision / dual-write result.
  function serial<T>(op: () => Promise<T>): Promise<T> {
    return rows.exclusive(op);
  }

  async function loadItems(): Promise<MemoryItem[]> {
    return (await rows.all()).map((row) => row.item);
  }

  async function putPending(items: MemoryItem[], consumeCandidateIds: readonly string[] = []): Promise<void> {
    if (items.length === 0) return;
    if (consumeCandidateIds.length === 0) {
      await rows.put(items.map(pendingRow));
    } else {
      if (!rows.putConsumingCandidates) throw new Error('Memory row store cannot consume candidates atomically');
      await rows.putConsumingCandidates(items.map(pendingRow), consumeCandidateIds);
    }
    onLocalChange();
    // A failed slice refresh does not count as a failed write: the row is already stored and the next hydration fills it in.
    await refreshMemoryItemsSlice(store, uid, rows).catch(() => undefined);
  }

  function writePreferences(write: MemoryLegacyPrefsWrite): void {
    // The partition has switched away: do not write this account's compiled result into someone else's store.
    if (getActiveUIDSync() !== uid) return;
    if (!write.textChanged) {
      store.getState().setPreferences({ memoryText: write.memoryText, memoryTextDigest: write.memoryTextDigest });
      return;
    }
    const patch = {
      memoryText: write.memoryText,
      memoryTextDigest: write.memoryTextDigest,
      memoryUpdatedAt: now().toISOString(),
    };
    store.getState().setPreferences(patch);
    sync()?.didUpdatePreferences(patch);
  }

  function dualWrite(items: MemoryItem[]): void {
    const compiled = MemoryItems.compileLegacy({ uid, items });
    const prefs = store.getState().preferences;
    const textChanged = compiled.memoryText !== (prefs.memoryText ?? '');
    if (!textChanged && compiled.memoryTextDigest === prefs.memoryTextDigest) return;
    writePreferences({ ...compiled, textChanged });
  }

  async function writeItems(
    next: MemoryItem[],
    items: MemoryItem[],
    consumeCandidateIds: readonly string[] = [],
  ): Promise<void> {
    await putPending(next, consumeCandidateIds);
    const replaced = new Map(next.map((m) => [m.id, m]));
    const after = [...items.map((m) => replaced.get(m.id) ?? m), ...next.filter((m) => !items.some((i) => i.id === m.id))];
    dualWrite(after);
  }

  async function writeItem(
    next: MemoryItem,
    items: MemoryItem[],
    consumeCandidateIds: readonly string[] = [],
  ): Promise<MemoryItem> {
    await writeItems([next], items, consumeCandidateIds);
    return next;
  }

  function mutate(id: string, change: (item: MemoryItem) => MemoryItem): Promise<MemoryItem | null> {
    return serial(async () => {
      const items = await loadItems();
      const current = items.find((m) => m.id === id.toLowerCase());
      if (!current || current.status === 'deleted') return null;
      return writeItem(change(current), items);
    });
  }

  function edited(item: MemoryItem, fields: Partial<MemoryItem>): MemoryItem {
    return MemoryItems.canonical({
      ...item,
      ...fields,
      baseRevision: item.revision,
      mutationId: newId(),
      deviceId,
    });
  }

  /** The only path for creating an item: new id, revision 1, pending, dual write, notify. */
  function insert(
    fields: Omit<MemoryItemInput, 'id' | 'mutationId' | 'deviceId'>,
    consumeCandidateIds: readonly string[] = [],
  ): Promise<MemoryItem> {
    return serial(async () => {
      const items = await loadItems();
      const createdAt = now().toISOString();
      const item = MemoryItems.canonical({
        ...fields,
        ...(fields.layer === 'episodic' && !fields.occurredAt ? { occurredAt: createdAt } : {}),
        id: newId(),
        revision: 1,
        baseRevision: 0,
        mutationId: newId(),
        deviceId,
        createdAt,
      });
      const conflictId = item.layer === 'episodic' && item.status === 'active' ? memoryRecallConflict(item, items) : null;
      const older = conflictId === null ? undefined : items.find((m) => m.id === conflictId);
      if (!older) return writeItem(item, items, consumeCandidateIds);
      const saved = MemoryItems.canonical({ ...item, status: 'conflicted', conflictGroupId: older.id });
      await writeItems(
        [saved, edited(older, { status: 'conflicted', conflictGroupId: older.id })],
        items,
        consumeCandidateIds,
      );
      return saved;
    });
  }

  return {
    async list() {
      const items = await loadItems();
      return MemoryItems.listOrder(items).filter((m) => m.status !== 'deleted');
    },

    create(input) {
      return insert({
        kind: input.kind,
        content: input.content,
        layer: input.layer,
        occurredAt: input.occurredAt ?? null,
        scope: input.scope,
        sensitivity: input.sensitivity,
        pinned: input.pinned,
      });
    },

    createFromDraft(draft, options) {
      return insert({
        layer: draft.layer,
        kind: draft.kind,
        status: draft.status,
        content: draft.content,
        scope: { type: draft.scope.type, id: draft.scope.id },
        source: {
          type: draft.source.type,
          conversationId: draft.source.conversationId,
          messageIds: [...draft.source.messageIds],
          observedAt: observedAtFromMs(draft.source.observedAtMs),
        },
        sensitivity: draft.sensitivity,
        confidence: draft.confidence,
      }, options?.consumeCandidateId ? [options.consumeCandidateId] : []);
    },

    update(id, patch) {
      return mutate(id, (item) => edited(item, {
        ...(patch.kind !== undefined ? { kind: patch.kind } : {}),
        ...(patch.content !== undefined ? { content: patch.content } : {}),
        ...(patch.occurredAt !== undefined ? { occurredAt: patch.occurredAt } : {}),
      }));
    },

    remove(id) {
      return mutate(id, (item) => MemoryItems.tombstone({
        item,
        mutationId: newId(),
        deviceId,
        deletedAt: now().toISOString(),
      }));
    },

    setPinned(id, pinned) {
      return mutate(id, (item) => edited(item, { pinned }));
    },

    setStatus(id, status) {
      return mutate(id, (item) => edited(item, { status }));
    },

    reconcileLegacy() {
      return serial(async () => {
        const items = await loadItems();
        const prefs = store.getState().preferences;
        const plan = MemoryItems.legacySync({
          uid,
          migrated: getPreference<boolean>(MEMORY_ITEMS_MIGRATED_KEY, false, uid) === true,
          deviceId,
          items,
          prefs: {
            memoryText: prefs.memoryText ?? null,
            memoryTextDigest: prefs.memoryTextDigest ?? null,
            antiForgetEnabled: prefs.memoryAntiForgetEnabled ?? false,
            antiForgetText: prefs.memoryAntiForgetText ?? null,
            memoryUpdatedAt: prefs.memoryUpdatedAt ?? null,
          },
          now: now().toISOString(),
        });
        await putPending([...plan.create, ...plan.update]);
        if (plan.writePrefs) writePreferences(plan.writePrefs);
        setPreference(MEMORY_ITEMS_MIGRATED_KEY, true, uid);
        return plan;
      });
    },

    resolveConflict(keepId) {
      return serial(async () => {
        const items = await loadItems();
        const keep = items.find((m) => m.id === keepId.toLowerCase());
        if (!keep || keep.status !== 'conflicted' || keep.conflictGroupId === null) return null;
        const group = keep.conflictGroupId;
        const kept = edited(keep, { status: 'active', conflictGroupId: null });
        const dropped = items
          .filter((m) => m.id !== keep.id && m.conflictGroupId === group && m.status !== 'deleted')
          .map((m) => MemoryItems.tombstone({ item: m, mutationId: newId(), deviceId, deletedAt: now().toISOString() }));
        await writeItems([kept, ...dropped], items);
        return kept;
      });
    },

    resolveL3Conflict(newerId, olderId, resolution) {
      return serial(async () => {
        const items = await loadItems();
        const newer = items.find((m) => m.id === newerId.toLowerCase());
        const older = items.find((m) => m.id === olderId.toLowerCase());
        if (!newer || !older || newer.status === 'deleted' || older.status === 'deleted') return null;
        const [newerPatch, olderPatch] = resolveMemoryRecallConflict(newer, older, resolution);
        const apply = (m: MemoryItem, p: typeof newerPatch) =>
          edited(m, { status: p.status, conflictGroupId: p.conflictGroupId, supersedes: p.supersedes });
        const next: [MemoryItem, MemoryItem] = [apply(newer, newerPatch), apply(older, olderPatch)];
        await writeItems(next, items);
        return next;
      });
    },
  };
}

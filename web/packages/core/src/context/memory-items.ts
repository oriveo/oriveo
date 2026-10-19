/**
 * Memory item v2 pure functions (contract: context-contracts/memory-items.v2.json).
 * Canonical form, legacy migration, injection filter, list order, tombstone, sync merge / push,
 * conflict copy, legacy dual write, raw text view, organize and backup.
 * No I/O, no clock, no randomness: callers pass time and new ids in.
 */

import { ContextHash } from './hash';
import { trimWhiteSpace } from './white-space';

export type MemoryLayer = 'semantic' | 'episodic';
export type MemoryKind =
  | 'identity'
  | 'preference'
  | 'instruction'
  | 'constraint'
  | 'project'
  | 'goal'
  | 'decision'
  | 'fact'
  | 'event';
export type MemoryStatus = 'active' | 'paused' | 'superseded' | 'deleted' | 'expired' | 'conflicted';
export type MemoryScopeType = 'global' | 'folder' | 'conversation';
export type MemorySourceType = 'manual' | 'conversation' | 'import' | 'migration';
export type MemorySensitivity = 'normal' | 'sensitive' | 'restricted';

export interface MemoryScope {
  type: MemoryScopeType;
  id: string | null;
}

export interface MemorySource {
  type: MemorySourceType;
  conversationId: string | null;
  messageIds: string[];
  observedAt: string | null;
}

/** Key order follows the contract fieldOrder. Server-time fields hold RFC3339 (or null) locally. */
export interface MemoryItem {
  id: string;
  schemaVersion: 2;
  layer: MemoryLayer;
  kind: MemoryKind;
  status: MemoryStatus;
  content: string;
  scope: MemoryScope;
  source: MemorySource;
  sensitivity: MemorySensitivity;
  confidence: number;
  priority: number;
  pinned: boolean;
  revision: number;
  baseRevision: number;
  mutationId: string;
  deviceId: string;
  conflictGroupId: string | null;
  occurredAt: string | null;
  validFrom: string | null;
  lastConfirmedAt: string | null;
  createdAt: string | null;
  updatedAt: string | null;
  expiresAt: string | null;
  deletedAt: string | null;
  supersedes: string[];
}

/** Partial item accepted by canonical(); missing fields take the contract defaults. */
export type MemoryItemInput = Partial<Omit<MemoryItem, 'scope' | 'source'>> &
  Pick<MemoryItem, 'id' | 'kind' | 'content' | 'mutationId' | 'deviceId'> & {
    scope?: Partial<MemoryScope>;
    source?: Partial<MemorySource>;
  };

export const MEMORY_ITEM_CONSTANTS = {
  uuidNamespace: '7b430abd-757c-5561-bdc9-40d1e677748c',
  legacyKeys: { memoryText: 'legacy-memoryText', antiForget: 'legacy-antiforget' },
  migrationMutationSuffix: 'migration-1',
  conflictMutationSuffix: 'conflict-1',
  legacyMutationPrefix: 'legacy-',
  contentMaxCodePoints: 2000,
  organizeSystemPrompt:
    'Split the saved memory below into separate items. Each item states exactly one fact, preference, instruction, constraint or project. Keep the user\'s language and wording; do not add, infer, merge away or drop information. Reply with only a JSON array, no prose: [{"kind": "identity|preference|instruction|constraint|project|goal|decision|fact", "content": "..."}].',
  organizeMaxItems: 20,
  rawViewSeparator: '---',
  legacyCompileSeparator: '\n\n',
  schemaVersion: 2,
} as const;

const SEMANTIC_KINDS: ReadonlySet<string> = new Set([
  'identity',
  'preference',
  'instruction',
  'constraint',
  'project',
  'goal',
  'decision',
  'fact',
]);
const STANDING_KINDS: ReadonlySet<string> = new Set(['instruction', 'constraint']);
const EPISODIC_KINDS: ReadonlySet<string> = new Set(['decision', 'event']);

/** Layer of a new item: decision / event are L3, the rest L2. Fixed at creation, never re-derived. */
export function memoryLayerOfKind(kind: MemoryKind): MemoryLayer {
  return EPISODIC_KINDS.has(kind) ? 'episodic' : 'semantic';
}

function lower(id: string): string {
  return id.toLowerCase();
}

function uuid(name: string): string {
  return ContextHash.uuidV5(MEMORY_ITEM_CONSTANTS.uuidNamespace, name);
}

function codePoints(text: string): number {
  return [...text].length;
}

function isBlank(text: string | null | undefined): boolean {
  return trimWhiteSpace(text ?? '').length === 0;
}

/** Fills defaults and lowercases uuid fields; content is kept byte for byte. */
function canonical(input: MemoryItemInput): MemoryItem {
  const scope = input.scope ?? {};
  const source = input.source ?? {};
  return {
    id: lower(input.id),
    schemaVersion: 2,
    layer: input.layer ?? 'semantic',
    kind: input.kind,
    status: input.status ?? 'active',
    content: input.content,
    scope: { type: scope.type ?? 'global', id: scope.id ?? null },
    source: {
      type: source.type ?? 'manual',
      conversationId: source.conversationId ?? null,
      messageIds: [...(source.messageIds ?? [])],
      observedAt: source.observedAt ?? null,
    },
    sensitivity: input.sensitivity ?? 'normal',
    confidence: input.confidence ?? 1,
    priority: input.priority ?? 0,
    pinned: input.pinned ?? false,
    revision: input.revision ?? 1,
    baseRevision: input.baseRevision ?? 0,
    mutationId: lower(input.mutationId),
    deviceId: input.deviceId,
    conflictGroupId: input.conflictGroupId == null ? null : lower(input.conflictGroupId),
    occurredAt: input.occurredAt ?? null,
    validFrom: input.validFrom ?? null,
    lastConfirmedAt: input.lastConfirmedAt ?? null,
    createdAt: input.createdAt ?? null,
    updatedAt: input.updatedAt ?? null,
    expiresAt: input.expiresAt ?? null,
    deletedAt: input.deletedAt ?? null,
    supersedes: (input.supersedes ?? []).map(lower),
  };
}

// -- migration --

export interface MemoryLegacyPreferences {
  memoryText: string | null;
  antiForgetEnabled: boolean;
  antiForgetText: string | null;
  memoryUpdatedAt: string | null;
}

export interface MemoryMigrateInput extends MemoryLegacyPreferences {
  uid: string;
  deviceId: string;
}

function legacyItemId(uid: string, key: string): string {
  return uuid(`${uid}\n${key}`);
}

function memoryTextItemId(uid: string): string {
  return legacyItemId(uid, MEMORY_ITEM_CONSTANTS.legacyKeys.memoryText);
}

function antiForgetItemId(uid: string): string {
  return legacyItemId(uid, MEMORY_ITEM_CONSTANTS.legacyKeys.antiForget);
}

function migrationItem(
  id: string,
  kind: MemoryKind,
  status: MemoryStatus,
  content: string,
  deviceId: string,
  observedAt: string | null,
  mutationId: string,
): MemoryItem {
  return canonical({
    id,
    kind,
    status,
    content,
    source: { type: 'migration', observedAt },
    mutationId,
    deviceId,
  });
}

/** Legacy memoryText / Anti-Forget → v2 items (deterministic ids, written create-if-absent). */
function migrate(input: MemoryMigrateInput): MemoryItem[] {
  const items: MemoryItem[] = [];
  const memoryText = input.memoryText ?? '';
  const antiForgetText = input.antiForgetText ?? '';
  const migrationMutation = (id: string) => uuid(`${id}\n${MEMORY_ITEM_CONSTANTS.migrationMutationSuffix}`);
  if (!isBlank(memoryText)) {
    const id = memoryTextItemId(input.uid);
    items.push(
      migrationItem(id, 'fact', 'active', memoryText, input.deviceId, input.memoryUpdatedAt, migrationMutation(id)),
    );
  }
  if (!isBlank(antiForgetText) && trimWhiteSpace(antiForgetText) !== trimWhiteSpace(memoryText)) {
    const id = antiForgetItemId(input.uid);
    // With Anti-Forget off the text is kept but not injected.
    const status: MemoryStatus = input.antiForgetEnabled ? 'active' : 'paused';
    items.push(
      migrationItem(id, 'instruction', status, antiForgetText, input.deviceId, input.memoryUpdatedAt, migrationMutation(id)),
    );
  }
  return items;
}

// -- injection --

export interface MemoryInjectableInput {
  items: MemoryItem[];
  conversationId: string;
  folderId: string | null;
  /** RFC3339 instant. */
  now: string;
}

export interface MemoryInjection {
  standingInstructions: MemoryItem[];
  memory: MemoryItem[];
}

function instant(value: string): number {
  return Date.parse(value);
}

function pinnedFirst(items: MemoryItem[]): MemoryItem[] {
  return [...items.filter((m) => m.pinned), ...items.filter((m) => !m.pinned)];
}

/** Items that may enter the system prompt; input is expected in list order. */
function injectable(input: MemoryInjectableInput): MemoryInjection {
  const now = instant(input.now);
  const eligible = input.items.filter((m) => {
    if (m.layer !== 'semantic' || m.status !== 'active') return false;
    if (m.expiresAt !== null && !(instant(m.expiresAt) > now)) return false;
    switch (m.scope.type) {
      case 'global':
        return true;
      case 'conversation':
        // scope.id is case-insensitive: iOS conversation ids are upper-case UUIDs
        return m.scope.id !== null && m.scope.id.toLowerCase() === input.conversationId.toLowerCase();
      case 'folder':
        return input.folderId !== null && m.scope.id !== null && m.scope.id.toLowerCase() === input.folderId.toLowerCase();
      default:
        return false;
    }
  });
  return {
    standingInstructions: pinnedFirst(eligible.filter((m) => STANDING_KINDS.has(m.kind))),
    memory: pinnedFirst(eligible.filter((m) => !STANDING_KINDS.has(m.kind))),
  };
}

// -- list order --

function compareCreatedAt(a: string | null, b: string | null): number {
  if (a === null || b === null) return a === b ? 0 : a === null ? -1 : 1;
  const diff = instant(a) - instant(b);
  return diff < 0 ? -1 : diff > 0 ? 1 : 0;
}

/** Pinned first, then createdAt ascending (null first, compared as instants), then id ascending. */
function listOrder(items: MemoryItem[]): MemoryItem[] {
  return [...items].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    const created = compareCreatedAt(a.createdAt, b.createdAt);
    if (created !== 0) return created;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

// -- tombstone --

export interface MemoryTombstoneInput {
  item: MemoryItem;
  mutationId: string;
  deviceId: string;
  /** RFC3339 deletion time. */
  deletedAt: string;
}

/** Keeps identity and createdAt; drops body and source pointers; pending until pushed. */
function tombstone(input: MemoryTombstoneInput): MemoryItem {
  const item = input.item;
  return canonical({
    id: item.id,
    layer: item.layer,
    kind: item.kind,
    status: 'deleted',
    content: '',
    revision: item.revision,
    baseRevision: item.revision,
    mutationId: input.mutationId,
    deviceId: input.deviceId,
    createdAt: item.createdAt,
    deletedAt: input.deletedAt,
  });
}

// -- sync merge / push --

/** The revision head of an item as seen locally, remotely or in the pending queue. */
export interface MemoryRevisionHead {
  revision: number;
  mutationId: string;
  status: MemoryStatus;
  content: string;
  /** Absent means normal. */
  sensitivity?: MemorySensitivity;
}

export interface MemoryPendingHead {
  mutationId: string;
  baseRevision: number;
  status: MemoryStatus;
  content: string;
  /** Absent means normal. */
  sensitivity?: MemorySensitivity;
}

export interface MemoryMergeInput {
  local: MemoryRevisionHead | null;
  remote: MemoryRevisionHead;
  pending: MemoryPendingHead | null;
}

export type MemoryMergeResult = 'applyRemote' | 'noop' | 'ignoreRemote' | 'conflict' | 'pendingConfirmed' | 'keepPending';

export interface MemoryMergeDecision {
  result: MemoryMergeResult;
  /** mutationIds that survive the merge. */
  keep: string[];
  status: MemoryStatus;
}

/** Listener-side merge of one remote snapshot into the local item. */
function merge(input: MemoryMergeInput): MemoryMergeDecision {
  const { local, remote, pending } = input;
  const applyRemote: MemoryMergeDecision = { result: 'applyRemote', keep: [remote.mutationId], status: remote.status };
  // A local restricted item is never overwritten by any remote version (including the echo of a tombstone written by a local retract).
  if (local?.sensitivity === 'restricted' || pending?.sensitivity === 'restricted') {
    if (pending) return { result: 'keepPending', keep: [pending.mutationId], status: pending.status };
    if (local) return { result: 'ignoreRemote', keep: [local.mutationId], status: local.status };
  }
  if (pending) {
    if (remote.mutationId === pending.mutationId) {
      return { result: 'pendingConfirmed', keep: [pending.mutationId], status: pending.status };
    }
    // baseRevision 0 means create-if-absent: if the remote copy already exists, the remote wins.
    if (pending.baseRevision === 0) return applyRemote;
    const keepPending: MemoryMergeDecision = { result: 'keepPending', keep: [pending.mutationId], status: pending.status };
    if (remote.revision <= pending.baseRevision) return keepPending;
    if (pending.status === 'deleted') return keepPending;
    if (remote.status === 'deleted') return applyRemote;
    if (remote.content === pending.content && remote.status === pending.status) return applyRemote;
    return { result: 'conflict', keep: [remote.mutationId, pending.mutationId], status: 'conflicted' };
  }
  if (local === null || remote.revision > local.revision) return applyRemote;
  if (remote.revision === local.revision) {
    if (remote.mutationId === local.mutationId) {
      return { result: 'noop', keep: [local.mutationId], status: local.status };
    }
    // Same revision, different mutation: the server wins.
    return applyRemote;
  }
  return { result: 'ignoreRemote', keep: [local.mutationId], status: local.status };
}

export type MemoryPushDecision =
  | { action: 'write'; revision: number }
  | { action: 'confirmed' }
  | { action: 'dropPending' }
  | { action: 'conflict' }
  /** Restricted pending over a live remote: write this item's tombstone at `revision`. */
  | { action: 'retract'; revision: number }
  /** Restricted pending with no live remote: write nothing, keep local at `baseRevision`. */
  | { action: 'localOnly'; baseRevision: number };

export interface MemoryPushInput {
  remote: MemoryRevisionHead | null;
  pending: MemoryPendingHead;
}

/** Decision inside the Firestore transaction for one pending mutation. */
function push(input: MemoryPushInput): MemoryPushDecision {
  const { remote, pending } = input;
  // A restricted item itself never goes to the cloud: if a remote copy is alive it is retracted (a tombstone is written), otherwise it stays local only.
  if (pending.sensitivity === 'restricted') {
    if (remote === null) return { action: 'localOnly', baseRevision: 0 };
    if (remote.status === 'deleted') return { action: 'localOnly', baseRevision: remote.revision };
    return { action: 'retract', revision: remote.revision + 1 };
  }
  if (remote === null) return { action: 'write', revision: 1 };
  if (remote.mutationId === pending.mutationId) return { action: 'confirmed' };
  if (pending.baseRevision === 0) return { action: 'dropPending' };
  if (remote.revision === pending.baseRevision) return { action: 'write', revision: remote.revision + 1 };
  if (pending.status === 'deleted') return { action: 'write', revision: remote.revision + 1 };
  if (remote.status === 'deleted') return { action: 'dropPending' };
  if (remote.content === pending.content && remote.status === pending.status) return { action: 'dropPending' };
  return { action: 'conflict' };
}

// -- conflict --

export interface MemoryConflictInput {
  itemId: string;
  pending: MemoryItem;
  remote: MemoryItem;
  /** Fresh mutationId for the original item's local edit (supplied by the caller). */
  originalMutationId: string;
}

export interface MemoryConflictResolution {
  original: MemoryItem;
  copy: MemoryItem;
}

/** Splits a conflicting pending edit into the original (remote content) and a deterministic copy. */
function conflictCopy(input: MemoryConflictInput): MemoryConflictResolution {
  const itemId = lower(input.itemId);
  const pending = canonical(input.pending);
  const remote = canonical(input.remote);
  const original = canonical({
    ...remote,
    status: 'conflicted',
    conflictGroupId: itemId,
    baseRevision: remote.revision,
    mutationId: input.originalMutationId,
    deviceId: pending.deviceId,
  });
  const copyId = uuid(`${itemId}\n${pending.mutationId}`);
  const copy = canonical({
    ...pending,
    id: copyId,
    status: 'conflicted',
    conflictGroupId: itemId,
    revision: 1,
    baseRevision: 0,
    mutationId: uuid(`${copyId}\n${MEMORY_ITEM_CONSTANTS.conflictMutationSuffix}`),
    createdAt: null,
    updatedAt: null,
  });
  return { original, copy };
}

// -- legacy dual write --

export interface MemoryLegacyCompile {
  memoryText: string;
  memoryTextDigest: string;
}

export interface MemoryCompileInput {
  uid: string;
  items: MemoryItem[];
}

/** memoryText written for old clients: active global non-restricted semantic items, without Anti-Forget. */
function compileLegacy(input: MemoryCompileInput): MemoryLegacyCompile {
  const antiForgetId = antiForgetItemId(input.uid);
  const memoryText = listOrder(input.items)
    .filter(
      (m) =>
        m.layer === 'semantic' &&
        m.status === 'active' &&
        m.sensitivity !== 'restricted' &&
        m.scope.type === 'global' &&
        m.id !== antiForgetId,
    )
    .map((m) => m.content)
    .join(MEMORY_ITEM_CONSTANTS.legacyCompileSeparator);
  return { memoryText, memoryTextDigest: ContextHash.sha256Hex(memoryText) };
}

export interface MemoryLegacySyncPreferences extends MemoryLegacyPreferences {
  memoryTextDigest: string | null;
}

export interface MemoryLegacySyncInput {
  uid: string;
  /** Per-account local flag. */
  migrated: boolean;
  deviceId: string;
  items: MemoryItem[];
  prefs: Partial<MemoryLegacySyncPreferences> & Pick<MemoryLegacySyncPreferences, 'memoryText' | 'memoryTextDigest'>;
  /** RFC3339 time used as deletedAt when the legacy item is tombstoned. */
  now: string;
}

/** Preferences write planned by legacySync; textChanged = compiled text differs from the local memoryText. */
export interface MemoryLegacyPrefsWrite extends MemoryLegacyCompile {
  textChanged: boolean;
}

export interface MemoryLegacySyncPlan {
  create: MemoryItem[];
  update: MemoryItem[];
  writePrefs: MemoryLegacyPrefsWrite | null;
}

/** Reconciles legacy preferences (possibly edited by an old client) with v2 items. */
function legacySync(input: MemoryLegacySyncInput): MemoryLegacySyncPlan {
  const prefs = input.prefs;
  const memoryText = prefs.memoryText ?? '';
  const nothing: MemoryLegacySyncPlan = { create: [], update: [], writePrefs: null };
  const digestMatches = prefs.memoryTextDigest === ContextHash.sha256Hex(memoryText);
  const compileOf = (items: MemoryItem[]) => compileLegacy({ uid: input.uid, items });
  // memoryUpdatedAt is refreshed and pushed only when textChanged is true; filling in just the digest only writes locally.
  const prefsWrite = (items: MemoryItem[]): MemoryLegacyPrefsWrite | null => {
    const compiled = compileOf(items);
    const textChanged = compiled.memoryText !== memoryText;
    if (!textChanged && compiled.memoryTextDigest === prefs.memoryTextDigest) return null;
    return { ...compiled, textChanged };
  };

  if (digestMatches) return nothing;

  if (!input.migrated) {
    const existing = new Set(input.items.map((m) => m.id));
    const create = migrate({
      uid: input.uid,
      deviceId: input.deviceId,
      memoryText: prefs.memoryText,
      antiForgetEnabled: prefs.antiForgetEnabled ?? false,
      antiForgetText: prefs.antiForgetText ?? null,
      memoryUpdatedAt: prefs.memoryUpdatedAt ?? null,
    }).filter((m) => !existing.has(m.id));
    return { create, update: [], writePrefs: prefsWrite([...input.items, ...create]) };
  }

  // An older client edited memoryText: if it matches the compiled result, only the prefs are rewritten.
  if (memoryText === compileOf(input.items).memoryText) {
    return { create: [], update: [], writePrefs: prefsWrite(input.items) };
  }

  const itemId = memoryTextItemId(input.uid);
  const current = input.items.find((m) => m.id === itemId) ?? null;
  // Whitespace-only text is digested as "", so every device gets the same mutationId.
  const mutationText = isBlank(memoryText) ? '' : memoryText;
  const mutationId = uuid(`${itemId}\n${MEMORY_ITEM_CONSTANTS.legacyMutationPrefix}${ContextHash.sha256Hex(mutationText)}`);
  const create: MemoryItem[] = [];
  const update: MemoryItem[] = [];
  if (isBlank(memoryText)) {
    if (current && current.status !== 'deleted') {
      update.push(tombstone({ item: current, mutationId, deviceId: input.deviceId, deletedAt: input.now }));
    }
  } else if (current) {
    update.push(
      canonical({
        ...current,
        status: 'active',
        content: memoryText,
        baseRevision: current.revision,
        mutationId,
        deviceId: input.deviceId,
        deletedAt: null,
      }),
    );
  } else {
    create.push(
      migrationItem(itemId, 'fact', 'active', memoryText, input.deviceId, prefs.memoryUpdatedAt ?? null, mutationId),
    );
  }
  const replaced = new Map(update.map((m) => [m.id, m]));
  const after = [...input.items.map((m) => replaced.get(m.id) ?? m), ...create];
  return { create, update, writePrefs: prefsWrite(after) };
}

// -- raw text view --

function rawItems(items: MemoryItem[]): MemoryItem[] {
  return listOrder(items).filter((m) => m.layer === 'semantic' && m.status === 'active');
}

/** Active semantic items in list order joined by a line holding only the separator. */
function rawRender(items: MemoryItem[]): string {
  const separator = MEMORY_ITEM_CONSTANTS.rawViewSeparator;
  return rawItems(items)
    .map((m) => m.content)
    .join(`\n${separator}\n`);
}

export type MemoryRawOp =
  | { op: 'update'; id: string; content: string }
  | { op: 'create'; id: string; kind: 'fact'; content: string }
  | { op: 'delete'; id: string };

export interface MemoryRawApplyInput {
  items: MemoryItem[];
  text: string;
  /** Ids for created items, used in order. */
  newIds: string[];
}

export type MemoryRawApplyResult = { ops: MemoryRawOp[] } | { error: 'tooLong'; index: number };

function rawSegments(text: string): string[] {
  const separator = MEMORY_ITEM_CONSTANTS.rawViewSeparator;
  const segments: string[] = [];
  let lines: string[] = [];
  for (const line of text.split('\n')) {
    const bare = line.endsWith('\r') ? line.slice(0, -1) : line;
    if (bare === separator) {
      segments.push(lines.join('\n'));
      lines = [];
    } else {
      lines.push(line);
    }
  }
  segments.push(lines.join('\n'));
  return segments.map(trimWhiteSpace).filter((s) => s.length > 0);
}

/** Turns an edited raw view back into item operations (match equal segments first, then pair the rest). */
function rawApply(input: MemoryRawApplyInput): MemoryRawApplyResult {
  if (input.text === rawRender(input.items)) return { ops: [] };
  const segments = rawSegments(input.text);
  // index is the segment number after empty segments are removed.
  const tooLong = segments.findIndex((s) => codePoints(s) > MEMORY_ITEM_CONSTANTS.contentMaxCodePoints);
  if (tooLong >= 0) return { error: 'tooLong', index: tooLong };

  const items = rawItems(input.items);
  const matchedItem = new Array<boolean>(items.length).fill(false);
  const segmentItem = new Array<number>(segments.length).fill(-1);
  segments.forEach((segment, s) => {
    const i = items.findIndex((m, k) => !matchedItem[k] && trimWhiteSpace(m.content) === segment);
    if (i >= 0) {
      matchedItem[i] = true;
      segmentItem[s] = i;
    }
  });

  const ops: MemoryRawOp[] = [];
  const remaining = items.map((_, k) => k).filter((k) => !matchedItem[k]);
  let next = 0;
  let created = 0;
  segments.forEach((segment, s) => {
    if (segmentItem[s] >= 0) return;
    if (next < remaining.length) {
      const item = items[remaining[next]];
      next += 1;
      ops.push({ op: 'update', id: item.id, content: segment });
      return;
    }
    const id = input.newIds[created];
    if (id === undefined) throw new Error('rawApply: not enough newIds');
    created += 1;
    ops.push({ op: 'create', id, kind: 'fact', content: segment });
  });
  remaining.slice(next).forEach((k) => ops.push({ op: 'delete', id: items[k].id }));
  return { ops };
}

// -- organize --

export interface MemoryOrganizeRequest {
  system: string;
  messages: Array<{ role: 'user'; text: string }>;
}

export interface MemoryOrganizedEntry {
  kind: MemoryKind;
  content: string;
}

function organizeRequest(content: string): MemoryOrganizeRequest {
  return { system: MEMORY_ITEM_CONSTANTS.organizeSystemPrompt, messages: [{ role: 'user', text: content }] };
}

/** Parses the organize reply; anything unparseable yields []. */
function organizeParse(response: string): MemoryOrganizedEntry[] {
  const start = response.indexOf('[');
  const end = response.lastIndexOf(']');
  if (start < 0 || end < start) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(response.slice(start, end + 1));
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const entries: MemoryOrganizedEntry[] = [];
  const seen = new Set<string>();
  for (const raw of parsed) {
    if (entries.length >= MEMORY_ITEM_CONSTANTS.organizeMaxItems) break;
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) continue;
    const record = raw as Record<string, unknown>;
    if (typeof record.content !== 'string') continue;
    const content = trimWhiteSpace(record.content);
    if (content.length === 0 || codePoints(content) > MEMORY_ITEM_CONSTANTS.contentMaxCodePoints) continue;
    if (seen.has(content)) continue;
    seen.add(content);
    const kind = typeof record.kind === 'string' ? record.kind.toLowerCase() : '';
    entries.push({ kind: SEMANTIC_KINDS.has(kind) ? (kind as MemoryKind) : 'fact', content });
  }
  return entries;
}

// -- backup --

export interface MemoryBackupSection {
  memorySchemaVersion: 2;
  memoryItems: MemoryItem[];
}

/** Backup export: every local item (tombstones and conflicts included), canonical, in list order. */
function backupSection(items: MemoryItem[]): MemoryBackupSection {
  return { memorySchemaVersion: 2, memoryItems: listOrder(items.map(canonical)) };
}

export interface MemoryBackupMergeInput {
  mode: 'merge' | 'replace';
  local: MemoryItem[];
  backup: { memorySchemaVersion?: number; memoryItems?: MemoryItem[]; preferences?: MemoryLegacyPreferences };
  /** Needed only for a legacy backup without memoryItems. */
  uid?: string;
  deviceId?: string;
}

export interface MemoryBackupMergeResult {
  items: MemoryItem[];
  /** Replace only: live local items missing from the backup, to be tombstoned by the caller (id order). */
  tombstonedIds?: string[];
}

/** Backup import: merge per id by revision, or replace; legacy backups are migrated first. */
function backupMerge(input: MemoryBackupMergeInput): MemoryBackupMergeResult {
  let incoming: MemoryItem[];
  if (input.backup.memoryItems) {
    incoming = input.backup.memoryItems.map(canonical);
  } else {
    const prefs = input.backup.preferences;
    if (!prefs) {
      incoming = [];
    } else {
      if (input.uid === undefined || input.deviceId === undefined) {
        throw new Error('backupMerge: uid and deviceId are required for a legacy backup');
      }
      incoming = migrate({ ...prefs, uid: input.uid, deviceId: input.deviceId });
    }
  }
  if (input.mode === 'replace') {
    // Live local items missing from the backup must be turned into tombstones and pushed out, otherwise other devices would sync them back; existing tombstones are kept as they are.
    const inBackup = new Set(incoming.map((m) => m.id));
    const tombstonedIds = input.local.map(canonical)
      .filter((m) => m.status !== 'deleted' && !inBackup.has(m.id))
      .map((m) => m.id)
      .sort();
    return { items: listOrder(incoming), tombstonedIds };
  }
  const byId = new Map(input.local.map((m) => [m.id, canonical(m)]));
  // Legacy backups migrate as create-if-absent; new backups take the higher revision.
  const legacy = !input.backup.memoryItems;
  for (const item of incoming) {
    const local = byId.get(item.id);
    if (!local || (!legacy && item.revision > local.revision)) byId.set(item.id, item);
  }
  return { items: listOrder([...byId.values()]) };
}

export const MemoryItems = {
  constants: MEMORY_ITEM_CONSTANTS,
  canonical,
  memoryTextItemId,
  antiForgetItemId,
  migrate,
  injectable,
  listOrder,
  tombstone,
  merge,
  push,
  conflictCopy,
  compileLegacy,
  legacySync,
  rawRender,
  rawApply,
  organizeRequest,
  organizeParse,
  backupSection,
  backupMerge,
};

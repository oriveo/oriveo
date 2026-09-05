/** R3 typed, syncable capability intent. Raw/custom values never enter this store or cloud sync. */
import { resolveLayers, type ScopeLayer } from '@oriveo/core/providers/request-preference/preference-resolution';
import type { ReasoningIntent, ScopeId } from '@oriveo/core/providers/request-preference/types';
import type { AIModel, Provider } from '@oriveo/shared';
import { getCapabilityRuntime, resolveCatalogModel } from '../metadata/metadata-client';
import { normalizeUUID } from '../../utils/id-utils';
import { hasLegacyBareStore, readPartitionedStore, writePartitionedStore } from '../../infra/storage/partitioned-local-store';
import { compareWireId } from './sync-wire-order';

/**
 * Local keys are partitioned per UID (`oriveo.{uid}.*`, see `partitioned-local-store`): this table
 * is pushed to the cloud wholesale by `exportCapabilityPreferenceSyncPayload`, so without
 * partitioning the records a signed-out account A leaves behind would sync into account B's cloud.
 * Partitioning only changes the local key prefix; the sync envelope is byte-for-byte unchanged.
 */
const KEY = 'capability-preference-settings.v2';
const LEGACY_KEY = 'capability-preference-settings.v1';
const DRAFT_KEY = 'capability-preference-drafts.v2';
const LEGACY_DRAFT_KEY = 'capability-preference-drafts.v1';
const WEBS = new Set(['off', 'automatic', 'force']);
const REASONING = new Set(['off', 'low', 'balanced', 'deep', 'max']);
const RUNTIME_IDENTITY_VERSION = 'r1';
/** Wire capacity limits. Every client applies the same cut so the emitted arrays match. */
const MAX_RECORDS = 200;
const MAX_TOMBSTONES = 300;

export type CapabilityWebPreference = 'off' | 'automatic' | 'force';
export type CapabilityPreferences = { web: CapabilityWebPreference; reasoningIntent?: ReasoningIntent };
export type CapabilityPreferenceScope = 'connection' | 'connection_model' | 'conversation_connection_model' | 'skill_agent';
export type CapabilityRuntimeIdentity = {
  providerId: string;
  canonicalModelId: string;
  finalTransport: string;
  runtimeRevision: string;
  transportIdentity: string;
};
export type CapabilityPreferenceSyncRecord = {
  recordId: string;
  scope: CapabilityPreferenceScope;
  providerId: string;
  canonicalModelId: string;
  conversationId?: string;
  skillId?: string;
  transportIdentity: string;
  web: CapabilityWebPreference;
  reasoningIntent?: ReasoningIntent | null;
  /** LWW mutation revision. It is never the Server runtime revision. */
  revision: number;
  mutationId: string;
};
export type CapabilityPreferenceTombstone = { recordId: string; revision: number; mutationId: string };
export type CapabilityPreferenceSyncPayload = { schemaVersion: 2; records: CapabilityPreferenceSyncRecord[]; tombstones: CapabilityPreferenceTombstone[] };
export type CapabilityPreferenceInput = CapabilityRuntimeIdentity & {
  scope: CapabilityPreferenceScope;
  conversationId?: string;
  skillId?: string;
};

type Stored = Omit<CapabilityPreferenceSyncPayload, 'schemaVersion'>;
type Draft = CapabilityRuntimeIdentity & { values: CapabilityPreferences; updatedAt?: number };
/** A draft is a one-off local intermediate state: once a draft conversation has gone this long without sending a first message, it is no longer an edit in progress. */
const DRAFT_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const DRAFT_SLOT_KEY_SEPARATOR = '\u0000';
const empty = (): Stored => ({ records: [], tombstones: [] });
const uid = () => globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
const norm = (id: string | undefined) => id ? normalizeUUID(id).toLowerCase() : undefined;
const validIntent = (value: unknown): value is ReasoningIntent => typeof value === 'string' && REASONING.has(value);
const clean = (value: string | undefined): string | undefined => value?.trim() || undefined;

/**
 * Identity version dimension for the subscription path.
 *
 * It is not a recipe revision (the subscription path has no recipe), just a stable constant that
 * gives identity a second encodable dimension. When upstream renames its tiers, invalidation
 * falls out of `availableIntents` changing - a stored intent that is no longer offered simply
 * stops appearing - so no revision flip is needed.
 */
const SUBSCRIPTION_RUNTIME_REVISION = 'subscription';

/** Production subscription dispatch is provider-owned and never catalog-inferred. */
export function subscriptionFinalTransport(
  provider: Pick<Provider, 'kind' | 'authMode'>,
  model?: Pick<AIModel, 'upstreamApiBackend'>,
): 'openai_responses' | 'openai_chat' | undefined {
  if (provider.authMode !== 'subscription') return undefined;
  if (provider.kind === 'openAI') return 'openai_responses';
  if (provider.kind === 'grok') {
    const backend = model?.upstreamApiBackend?.trim().toLowerCase();
    if (backend === 'chat' || backend === 'chat_completions' || backend === 'chat.completions') {
      return 'openai_chat';
    }
    return 'openai_responses';
  }
  return undefined;
}

/** Builds the only active preference identity. Missing runtime/transport means no automatic configuration. */
export function capabilityRuntimeIdentity(
  provider: Pick<Provider, 'id' | 'kind' | 'authMode' | 'relayResolvedTransport' | 'relayResolvedBaseURLText' | 'baseURLText' | 'relayRequested'>,
  model: Pick<AIModel, 'id' | 'canonicalModelId' | 'transport' | 'upstreamApiBackend'>,
  finalTransport?: string,
): CapabilityRuntimeIdentity | null {
  const runtimeRevision = clean(getCapabilityRuntime()?.revision);
  // Subscription path: the model is not in the catalog, so no transport resolves and identity
  // would always be null - capability-panel choices could then neither be stored nor read back
  // (`capabilityPreferenceReadIsPermitted` and friends fail closed). But the transport here is
  // deterministic: Codex uses /responses, Grok splits on the upstream api_backend declaration and
  // falls back to /responses when it is missing, so the catalog is not needed. runtimeRevision
  // does not apply either (no recipe runtime), so a fixed dimension stands in.
  if (provider.authMode === 'subscription') {
    const providerId = norm(provider.id);
    const canonicalModelId = clean(model.id);
    if (!providerId || !canonicalModelId) return null;
    const transport = subscriptionFinalTransport(provider, model);
    if (!transport) return null;
    return {
      providerId,
      canonicalModelId,
      finalTransport: transport,
      runtimeRevision: SUBSCRIPTION_RUNTIME_REVISION,
      transportIdentity: encodeCapabilityTransportIdentity(transport, SUBSCRIPTION_RUNTIME_REVISION),
    };
  }
  const catalog = provider.kind === 'relay' ? null : resolveCatalogModel(model.id, provider.kind);
  const relayTransportIsExact = provider.kind === 'relay'
    && (clean(provider.relayResolvedTransport) != null
      || (provider.relayRequested?.transport != null && provider.relayRequested.transport !== 'auto'));
  const dispatchTransport = provider.kind === 'relay'
    ? (relayTransportIsExact ? clean(finalTransport) ?? clean(provider.relayResolvedTransport) ?? clean(provider.relayRequested?.transport) : undefined)
    : catalog?.transport;
  const transport = canonicalFinalTransport(provider.kind === 'relay' ? clean(finalTransport) ?? clean(dispatchTransport) : clean(dispatchTransport));
  if (provider.kind !== 'relay' && clean(finalTransport)
    && canonicalFinalTransport(clean(finalTransport)) !== transport) return null;
  const canonicalModelId = provider.kind === 'relay'
    ? clean(model.canonicalModelId) ?? clean(model.id)
    : clean(catalog?.canonicalModelId);
  const providerId = norm(provider.id);
  if (!providerId || !canonicalModelId || !transport || !runtimeRevision) return null;
  return {
    providerId,
    canonicalModelId,
    finalTransport: transport,
    runtimeRevision,
    transportIdentity: encodeCapabilityTransportIdentity(transport, runtimeRevision),
  };
}

/** Canonicalizes only explicit production transport aliases, never model ids/provider kinds. */
export function canonicalFinalTransport(value: string | undefined): string | undefined {
  if (value === 'openai_chat_completions') return 'openai_chat';
  if (value === 'gemini_generate') return 'gemini_generate_content';
  return value;
}

export function encodeCapabilityTransportIdentity(finalTransport: string, runtimeRevision: string): string {
  const transport = clean(finalTransport);
  const runtime = clean(runtimeRevision);
  if (!transport || !runtime) throw new TypeError('finalTransport and runtimeRevision are required');
  return `${RUNTIME_IDENTITY_VERSION}.${base64Url(transport)}.${base64Url(runtime)}`;
}

export function decodeCapabilityTransportIdentity(value: string): { finalTransport: string; runtimeRevision: string } | null {
  const match = /^r1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(value);
  if (!match) return null;
  try {
    const finalTransport = fromBase64Url(match[1]!);
    const runtimeRevision = fromBase64Url(match[2]!);
    return clean(finalTransport) && clean(runtimeRevision) ? { finalTransport, runtimeRevision } : null;
  } catch {
    return null;
  }
}

function base64Url(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function fromBase64Url(value: string): string {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
}

export function withCapabilityReasoningIntent(
  current: CapabilityPreferences,
  reasoningIntent: ReasoningIntent | undefined,
): CapabilityPreferences {
  const { reasoningIntent: _previous, ...withoutReasoning } = current;
  return reasoningIntent ? { ...withoutReasoning, reasoningIntent } : withoutReasoning;
}

function validRecord(value: unknown): value is CapabilityPreferenceSyncRecord {
  const v = value as Partial<CapabilityPreferenceSyncRecord>;
  return !!v && typeof v === 'object' && typeof v.recordId === 'string'
    && (v.scope === 'connection' || v.scope === 'connection_model' || v.scope === 'conversation_connection_model' || v.scope === 'skill_agent')
    && typeof v.providerId === 'string' && typeof v.canonicalModelId === 'string' && v.canonicalModelId.length > 0
    && typeof v.transportIdentity === 'string' && decodeCapabilityTransportIdentity(v.transportIdentity) !== null
    && WEBS.has(v.web ?? '') && (v.reasoningIntent === undefined || v.reasoningIntent === null || validIntent(v.reasoningIntent))
    && typeof v.revision === 'number' && Number.isSafeInteger(v.revision) && v.revision > 0
    && typeof v.mutationId === 'string' && v.mutationId.length > 0 && canonicalRecordId(v) === v.recordId;
}

function validTombstone(value: unknown): value is CapabilityPreferenceTombstone {
  const v = value as Partial<CapabilityPreferenceTombstone>;
  return !!v && typeof v === 'object' && typeof v.recordId === 'string' && isCanonicalPreferenceRecordId(v.recordId)
    && typeof v.revision === 'number' && Number.isSafeInteger(v.revision) && v.revision > 0
    && typeof v.mutationId === 'string' && v.mutationId.length > 0;
}

/**
 * Known trade-off: the whole-table read-modify-write takes no lock and does not listen for
 * `storage` events. If two tabs change a preference in the same millisecond, the later write wins
 * and the earlier record is lost.
 *
 * Why no listener or lock: writes are discrete human actions (one toggle click), so the collision
 * window is a single JSON serialization. A `storage` listener would require an "external change"
 * replay path in every subscriber - a whole cross-tab state machine whose own failure surface is
 * larger than the problem. The sync envelope's LWW (revision + mutationId) already covers real
 * conflicts across devices, and same-origin multi-tab is a degenerate case of that.
 */
function read(): Stored {
  try {
    const value = JSON.parse(readPartitionedStore(KEY) ?? '{}');
    return {
      records: Array.isArray(value.records) ? value.records.filter(validRecord) : [],
      tombstones: Array.isArray(value.tombstones) ? value.tombstones.filter(validTombstone) : [],
    };
  } catch {
    return empty();
  }
}

function write(value: Stored): void {
  writePartitionedStore(KEY, JSON.stringify(value));
}

function readDrafts(): Record<string, Draft> {
  try {
    const value = JSON.parse(readPartitionedStore(DRAFT_KEY) ?? '{}');
    return value && typeof value === 'object' ? pruneExpiredDrafts(value as Record<string, Draft>) : {};
  } catch {
    return {};
  }
}
function writeDrafts(value: Record<string, Draft>): void {
  writePartitionedStore(DRAFT_KEY, JSON.stringify(value));
}
function newer(a: CapabilityPreferenceTombstone, b: CapabilityPreferenceTombstone): boolean {
  return a.revision !== b.revision ? a.revision > b.revision : a.mutationId > b.mutationId;
}
/**
 * Inbound/outbound normalization. A remote envelope may carry optional fields as explicit `null`
 * (the Android client at 1.2.6 and earlier serializes them that way) or carry unknown keys.
 * Decoders on the other clients flatten both to "absent", so passing the raw object through would
 * leave this the only client that keeps nulls and equality checks would never match. Records and
 * tombstones are collapsed to one shape: fixed field set, nulls omitted.
 */
function normalizedRecord(value: CapabilityPreferenceSyncRecord): CapabilityPreferenceSyncRecord {
  return {
    recordId: value.recordId,
    scope: value.scope,
    providerId: value.providerId,
    canonicalModelId: value.canonicalModelId,
    ...(value.conversationId ? { conversationId: value.conversationId } : {}),
    ...(value.skillId ? { skillId: value.skillId } : {}),
    transportIdentity: value.transportIdentity,
    web: value.web,
    ...(value.reasoningIntent ? { reasoningIntent: value.reasoningIntent } : {}),
    revision: value.revision,
    mutationId: value.mutationId,
  };
}

function normalizedTombstone(value: CapabilityPreferenceTombstone): CapabilityPreferenceTombstone {
  return { recordId: value.recordId, revision: value.revision, mutationId: value.mutationId };
}

function compact(input: Stored): Stored {
  const winners = new Map<string, CapabilityPreferenceSyncRecord | CapabilityPreferenceTombstone>();
  for (const item of [...input.records, ...input.tombstones]) {
    const prior = winners.get(item.recordId);
    if (!prior || newer(item, prior)) winners.set(item.recordId, item);
  }
  const values = [...winners.values()];
  // Sort order and capacity limits are part of the cross-client wire contract: every client must
  // emit the same array, otherwise the write-back check (ordered array comparison) never matches
  // and the two sides ping-pong ordering forever.
  return {
    records: values.filter(validRecord).map(normalizedRecord)
      .sort((a, b) => compareWireId(a.recordId, b.recordId)).slice(0, MAX_RECORDS),
    tombstones: values.filter(validTombstone).filter((item): item is CapabilityPreferenceTombstone => !validRecord(item))
      .map(normalizedTombstone).sort((a, b) => compareWireId(a.recordId, b.recordId)).slice(-MAX_TOMBSTONES),
  };
}

export function capabilityPreferenceRecordId(scope: CapabilityPreferenceInput): string {
  const providerId = norm(scope.providerId);
  const decoded = decodeCapabilityTransportIdentity(scope.transportIdentity);
  if (!providerId || !clean(scope.canonicalModelId) || !decoded
    || decoded.finalTransport !== canonicalFinalTransport(scope.finalTransport)
    || decoded.runtimeRevision !== scope.runtimeRevision) {
    throw new TypeError('complete runtime identity is required');
  }
  const prefix = scope.scope === 'connection' ? 'connection'
    : scope.scope === 'connection_model' ? 'model'
      : scope.scope === 'conversation_connection_model' ? 'conversation' : 'skill';
  const base = `scope:${prefix}:${providerId}:${scope.canonicalModelId}:${scope.transportIdentity}`;
  if (scope.scope === 'connection' || scope.scope === 'connection_model') return base;
  if (scope.scope === 'conversation_connection_model' && norm(scope.conversationId)) return `${base}:${norm(scope.conversationId)}`;
  if (scope.scope === 'skill_agent' && norm(scope.skillId)) return `${base}:${norm(scope.skillId)}`;
  throw new TypeError(`${scope.scope} requires its scoped id`);
}

function canonicalRecordId(scope: Partial<CapabilityPreferenceInput>): string | null {
  const decoded = typeof scope.transportIdentity === 'string' ? decodeCapabilityTransportIdentity(scope.transportIdentity) : null;
  try { return capabilityPreferenceRecordId({ ...scope, ...decoded } as CapabilityPreferenceInput); } catch { return null; }
}
function isCanonicalPreferenceRecordId(recordId: string): boolean {
  const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  const parsed = new RegExp(`^scope:(connection|model|conversation|skill):(${uuid}):(.+):(r1\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+)(?::(${uuid}))?$`).exec(recordId);
  if (!parsed || decodeCapabilityTransportIdentity(parsed[4]!) === null) return false;
  const scopedId = parsed[5];
  return (parsed[1] === 'conversation' || parsed[1] === 'skill') ? scopedId !== undefined : scopedId === undefined;
}

export function saveCapabilityPreferences(input: CapabilityPreferenceInput, value: CapabilityPreferences): void {
  if (!WEBS.has(value.web) || (value.reasoningIntent !== undefined && !validIntent(value.reasoningIntent))) throw new TypeError('Invalid typed capability intent');
  const recordId = capabilityPreferenceRecordId(input);
  const current = read();
  const latest = [...current.records, ...current.tombstones].filter((item) => item.recordId === recordId).sort((a, b) => newer(a, b) ? -1 : 1)[0];
  const record: CapabilityPreferenceSyncRecord = {
    recordId,
    scope: input.scope,
    providerId: norm(input.providerId)!,
    canonicalModelId: input.canonicalModelId,
    ...(input.conversationId ? { conversationId: norm(input.conversationId)! } : {}),
    ...(input.skillId ? { skillId: norm(input.skillId)! } : {}),
    transportIdentity: input.transportIdentity,
    web: value.web,
    ...(value.reasoningIntent ? { reasoningIntent: value.reasoningIntent } : {}),
    revision: (latest?.revision ?? 0) + 1,
    mutationId: uid(),
  };
  write(compact({ records: [...current.records.filter((item) => item.recordId !== recordId), record], tombstones: current.tombstones.filter((item) => item.recordId !== recordId) }));
  publish();
}

/** Skill records can only be written by this explicit re-confirm action. */
export function confirmSkillCapabilityPreferences(input: Omit<CapabilityPreferenceInput, 'scope'>, value: CapabilityPreferences): void {
  saveCapabilityPreferences({ ...input, scope: 'skill_agent' }, value);
}
export function deleteCapabilityPreferences(input: CapabilityPreferenceInput): void {
  const recordId = capabilityPreferenceRecordId(input);
  const current = read();
  const latest = [...current.records, ...current.tombstones].filter((item) => item.recordId === recordId).sort((a, b) => newer(a, b) ? -1 : 1)[0];
  const tombstone = { recordId, revision: (latest?.revision ?? 0) + 1, mutationId: uid() };
  write(compact({ records: current.records.filter((item) => item.recordId !== recordId), tombstones: [...current.tombstones.filter((item) => item.recordId !== recordId), tombstone] }));
  publish();
}

/** Connection deletion tombstones every model/transport/runtime variant so stale sync cannot resurrect one. */
export function deleteAllCapabilityPreferencesForConnection(providerId: string): void {
  const normalized = norm(providerId);
  if (!normalized) return;
  const current = read();
  const keys = new Set([
    ...current.records.filter((item) => item.providerId === normalized).map((item) => item.recordId),
    ...current.tombstones.filter((item) => item.recordId.includes(`:${normalized}:`)).map((item) => item.recordId),
  ]);
  if (keys.size === 0) return;
  const tombstones = [...keys].map((recordId) => {
    const latest = [...current.records, ...current.tombstones].filter((item) => item.recordId === recordId).sort((a, b) => newer(a, b) ? -1 : 1)[0];
    return { recordId, revision: (latest?.revision ?? 0) + 1, mutationId: uid() };
  });
  write(compact({ records: current.records.filter((item) => item.providerId !== normalized), tombstones: [...current.tombstones.filter((item) => !keys.has(item.recordId)), ...tombstones] }));
  publish();
}

/**
 * Draft slot key = draft conversation x full runtime identity.
 *
 * With one slot per `draftId`, picking deep reasoning for model A and then another tier for model
 * B overwrote A's choice on the spot, and switching back to A showed it as never set. A draft
 * conversation is exactly the stretch where the model is still undecided, so switching models is
 * the most common thing that happens in it; a single slot structurally loses that.
 *
 * The key carries providerId / canonicalModelId as well as transportIdentity because the three
 * parts of identity are one unit: keying on transport alone would let two models on the same
 * protocol overwrite each other, and `sameIdentity` would then read the result as absent.
 */
function draftSlotKey(draftId: string, input: CapabilityRuntimeIdentity): string {
  // The separator must be a character that cannot appear in an id (model ids have contained both
  // colons and slashes). Always write it as an escape - a raw NUL byte in the file makes git treat
  // the whole file as binary, which kills diffs and hides it from grep.
  return [draftId, norm(input.providerId), input.canonicalModelId, input.transportIdentity]
    .join(DRAFT_SLOT_KEY_SEPARATOR);
}

/** Drafts stored under a bare draftId: honoured while the identity still matches, but never written back to that key. */
function readDraftSlot(all: Record<string, Draft>, draftId: string, input: CapabilityRuntimeIdentity): Draft | undefined {
  const exact = all[draftSlotKey(draftId, input)];
  if (exact) return exact;
  const legacy = all[draftId];
  return legacy && sameIdentity(legacy, input) ? legacy : undefined;
}

/** Expired-draft reclamation. Older entries have no `updatedAt`; with no age to judge, they are kept. */
function pruneExpiredDrafts(all: Record<string, Draft>): Record<string, Draft> {
  const cutoff = Date.now() - DRAFT_TTL_MS;
  return Object.fromEntries(
    Object.entries(all).filter(([, draft]) => !draft || typeof draft.updatedAt !== 'number' || draft.updatedAt >= cutoff),
  );
}

/**
 * Hard slot cap. A TTL bounds age but not count: `draftId` is a fresh UUID minted on every
 * ChatView mount, so a heavy user accumulates thousands of slots inside the TTL window (each a few
 * hundred characters of identity + values), which adds up to 1-2MB of localStorage - exactly the
 * kind of unbounded first-party key that storage-pressure monitoring watches for. Over the cap,
 * entries without `updatedAt` are evicted first (they are at least as old as that field), then the
 * oldest. Drafts are a convenience cache; eviction only sends that draft back to the defaults.
 */
const MAX_DRAFT_SLOTS = 200;

function capDraftSlots(all: Record<string, Draft>): Record<string, Draft> {
  const entries = Object.entries(all);
  if (entries.length <= MAX_DRAFT_SLOTS) return all;
  entries.sort(([, a], [, b]) => (a?.updatedAt ?? 0) - (b?.updatedAt ?? 0));
  return Object.fromEntries(entries.slice(entries.length - MAX_DRAFT_SLOTS));
}

/** Draft ids are local-only and never enter the sync envelope. */
export function loadCapabilityPreferenceDraft(draftId: string | undefined, input: CapabilityRuntimeIdentity): CapabilityPreferences | undefined {
  if (!draftId) return undefined;
  return readDraftSlot(readDrafts(), draftId, input)?.values;
}
export function saveCapabilityPreferenceDraft(draftId: string, input: CapabilityRuntimeIdentity, values: CapabilityPreferences): void {
  const all = readDrafts();
  all[draftSlotKey(draftId, input)] = { ...input, providerId: norm(input.providerId)!, values, updatedAt: Date.now() };
  writeDrafts(capDraftSlots(all));
}
export function migrateCapabilityPreferenceDraft(draftId: string | undefined, input: Omit<CapabilityPreferenceInput, 'scope'>): void {
  if (!draftId) return;
  const all = readDrafts();
  // Only the entry for the current identity moves: slots left for other models in this draft
  // conversation are unrelated to this send and stay put, so switching back still shows what the
  // user set there. The TTL reclaims them.
  const draft = readDraftSlot(all, draftId, input);
  if (!draft) return;
  delete all[draftSlotKey(draftId, input)];
  // The bare-draftId slot is deleted only when it is the very entry just moved: it may hold a draft for a different model.
  if (all[draftId] === draft) delete all[draftId];
  writeDrafts(all);
  saveCapabilityPreferences({ ...input, scope: 'conversation_connection_model' }, draft.values);
}

export function exportCapabilityPreferenceSyncPayload(): CapabilityPreferenceSyncPayload {
  const value = compact(read());
  return { schemaVersion: 2, records: value.records, tombstones: value.tombstones };
}
export function mergeCapabilityPreferenceSyncPayload(remote: unknown): CapabilityPreferenceSyncPayload {
  // The Android client at 1.2.6 and earlier omits schemaVersion when it equals the default, so
  // cloud documents written there have no such key. Rejecting on `!== 2` discarded those envelopes
  // and overwrote them from local state, so capability preferences never crossed devices and the
  // two sides overwrote each other in a loop. Missing means v2 (this envelope only has v2); an
  // explicit other version is still rejected.
  const remoteVersion = (remote as { schemaVersion?: unknown } | null)?.schemaVersion;
  if (!remote || typeof remote !== 'object' || (remoteVersion !== undefined && remoteVersion !== 2)) {
    return exportCapabilityPreferenceSyncPayload();
  }
  const payload = remote as Partial<CapabilityPreferenceSyncPayload>;
  const local = read();
  const merged = compact({
    records: [...local.records, ...(Array.isArray(payload.records) ? payload.records.filter(validRecord) : [])],
    tombstones: [...local.tombstones, ...(Array.isArray(payload.tombstones) ? payload.tombstones.filter(validTombstone) : [])],
  });
  write(merged);
  return { schemaVersion: 2, ...merged };
}

export type CapabilityPreferenceScopeQuery = CapabilityRuntimeIdentity & {
  conversationId?: string;
  skillId?: string;
};

/**
 * The four record layers that can actually be stored locally, shared by the read path and the send
 * path so that neither re-implements the query.
 *
 * The order is the local part of the full ladder and matches the scope ids consumed by
 * `resolveLayers`. Both `displayCapabilityPreferences` and `resolveCapabilityPreferences` read
 * from here; they differ only in the final fold (see `displayCapabilityPreferences`).
 *
 * Lazy forward-porting hangs off this function: every read path goes through it, so "the server
 * shipped a new recipe revision and the user's preferences silently reset" is structurally a
 * one-place fix. Callers are all discrete events and send paths (effects, callbacks, operations),
 * not the React render hot path - rendering only reads already-computed state.
 */
function capabilityScopeValues(input: CapabilityPreferenceScopeQuery): {
  conversation?: CapabilityPreferences;
  skill?: CapabilityPreferences;
  connectionModel?: CapabilityPreferences;
  connection?: CapabilityPreferences;
} {
  forwardPortCapabilityPreferencesIfNeeded(input);
  const records = read().records;
  const match = (scope: CapabilityPreferenceScope) => records.find((record) => record.scope === scope
    && sameIdentity(record, input)
    && (scope !== 'conversation_connection_model' || record.conversationId === norm(input.conversationId))
    && (scope !== 'skill_agent' || record.skillId === norm(input.skillId)));
  return {
    conversation: toValueOrUndefined(match('conversation_connection_model')),
    skill: toValueOrUndefined(match('skill_agent')),
    connectionModel: toValueOrUndefined(match('connection_model')),
    connection: toValueOrUndefined(match('connection')),
  };
}

export function resolveCapabilityPreferences(input: CapabilityPreferenceScopeQuery & {
  singleSend?: CapabilityPreferences;
  providerRecipe?: CapabilityPreferences;
  providerDefault?: CapabilityPreferences;
}): CapabilityPreferences {
  const scopes = capabilityScopeValues(input);
  const field = <T>(key: keyof CapabilityPreferences, fallback: T): T => {
    const layer = (scope: ScopeId, value: CapabilityPreferences | undefined): ScopeLayer => ({ scope, override: value && key in value ? { state: 'value', value: value[key] } : { state: 'inherit' } });
    const result = resolveLayers([
      layer('single_send', input.singleSend),
      layer('conversation_connection_model', scopes.conversation),
      layer('skill_agent', scopes.skill),
      layer('connection_model', scopes.connectionModel),
      layer('connection', scopes.connection),
      layer('provider_recipe', input.providerRecipe),
      layer('provider_default', input.providerDefault ?? { web: 'off' }),
    ]);
    return result.state === 'value' ? result.value as T : fallback;
  };
  const reasoningIntent = field<ReasoningIntent | undefined>('reasoningIntent', undefined);
  return { web: field<CapabilityWebPreference>('web', 'off'), ...(reasoningIntent ? { reasoningIntent } : {}) };
}

/**
 * UI read entry point: the same ladder over the same records as `resolveCapabilityPreferences`,
 * differing only in the final fold.
 *
 * What `resolve` produces feeds the outbound compiler, where "never set" and "chose automatic"
 * both mean "inject nothing", so it collapses the `provider_default` layer to `web: 'off'` and
 * accepts layers such as `singleSend` / `providerRecipe` that only hold for a single send. The UI
 * must not copy that result: a value pushed on temporarily for one send would render as the user's
 * own choice. This answers exactly one question - which layer first actually stored a value. web
 * takes the first layer with a stored record (otherwise `off`); reasoningIntent takes the first
 * layer that actually stored a tier (otherwise undefined, which renders as "automatic" selected
 * rather than "off" selected).
 *
 * That keeps the three states distinguishable: never set -> undefined; explicitly chose automatic
 * -> the record carries no reasoningIntent, also undefined (they are the same thing); explicitly
 * chose off -> `'off'` read back as-is.
 */
export function displayCapabilityPreferences(input: CapabilityPreferenceScopeQuery): CapabilityPreferences {
  const scopes = capabilityScopeValues(input);
  const ordered = [scopes.conversation, scopes.skill, scopes.connectionModel, scopes.connection]
    .filter((values): values is CapabilityPreferences => values !== undefined);
  const reasoningIntent = ordered.find((values) => values.reasoningIntent != null)?.reasoningIntent;
  return {
    web: ordered.find((values) => values.web !== undefined)?.web ?? 'off',
    ...(reasoningIntent ? { reasoningIntent } : {}),
  };
}

// -- Lazy forward-porting across recipe revisions -----------------------------

/**
 * Whether two identities are different recipe revisions of the same line.
 *
 * The wire value encodes `finalTransport` plus `runtimeRevision`, so one new recipe from the server
 * changes the revision and every identity-keyed record goes dormant at once - everything the user
 * configured last week renders as never set. Only one relation counts here: identical transport,
 * revision alone changed.
 *
 * A protocol change is not migrated (`openai_chat` -> `openai_responses` and the like): that is a
 * genuinely different request contract with different field names, tiers and schema, and carrying
 * old values across would be guessing on the user's behalf. Reset to current state instead.
 */
function isSameCapabilityTransportLineage(current: string, candidate: string): boolean {
  if (current === candidate) return false;
  const left = decodeCapabilityTransportIdentity(current);
  const right = decodeCapabilityTransportIdentity(candidate);
  return left !== null && right !== null
    && left.finalTransport === right.finalTransport
    && left.runtimeRevision !== right.runtimeRevision;
}

/** Forward-porting writes through the versioned path, which never re-triggers it; this flag just makes same-tick reentrancy explicit. */
let forwardPortingCapabilityPreferences = false;

/** Each of the four scopes forward-ports independently. Scopes never stand in for one another: an old conversation-level value can only fill a conversation-level slot. */
function forwardPortCapabilityPreferencesIfNeeded(input: CapabilityPreferenceScopeQuery): void {
  if (typeof window === 'undefined' || forwardPortingCapabilityPreferences) return;
  if (decodeCapabilityTransportIdentity(input.transportIdentity) === null) return;
  forwardPortingCapabilityPreferences = true;
  try {
    if (norm(input.conversationId)) forwardPortCapabilityScope('conversation_connection_model', input);
    if (norm(input.skillId)) forwardPortCapabilityScope('skill_agent', input);
    forwardPortCapabilityScope('connection_model', input);
    forwardPortCapabilityScope('connection', input);
  } finally {
    forwardPortingCapabilityPreferences = false;
  }
}

/**
 * Forward-porting one scope.
 *
 * The write must go through the existing versioned entry point `saveCapabilityPreferences`: it
 * bumps revision to `max(record, tombstone) + 1` and clears the tombstone with the same id, which
 * is exactly the LWW protection of sync envelope v2. Editing the localStorage table directly
 * bypasses all of that, and other devices would drop the forward-port as a stale write.
 *
 * The old record stays in place: forward-porting is idempotent (it stops firing once the target
 * exists), and keeping the old value lets a server rollback to the previous recipe revision pick
 * up exactly where it left off.
 *
 * The candidate is the user's last expression. `runtimeRevision` is an opaque server token (hashes,
 * dates and sequence numbers have all shown up), so string-comparing it guesses at its encoding.
 * Sync envelope v2 is a frozen schema with no `updatedAt` and no room for a new field, so ordering
 * uses the LWW `newer()` (revision, then mutationId) - the only ordering signal this table has, and
 * one that rises on every user edit. Known trade-off: an older record edited many times can outrank
 * a newer record written once; in practice the candidates hold the same value (each revision bump
 * copies it forward), so the difference is not observable.
 */
function forwardPortCapabilityScope(
  scope: CapabilityPreferenceScope,
  input: CapabilityPreferenceScopeQuery,
): void {
  // Ids outside the scope never enter the record: putting conversationId on a connection-level
  // record writes a field recordId cannot account for, and syncing it produces a record no device
  // can explain.
  const scoped: CapabilityPreferenceInput = {
    providerId: input.providerId,
    canonicalModelId: input.canonicalModelId,
    finalTransport: input.finalTransport,
    runtimeRevision: input.runtimeRevision,
    transportIdentity: input.transportIdentity,
    scope,
    ...(scope === 'conversation_connection_model' && input.conversationId ? { conversationId: input.conversationId } : {}),
    ...(scope === 'skill_agent' && input.skillId ? { skillId: input.skillId } : {}),
  };
  let recordId: string;
  try { recordId = capabilityPreferenceRecordId(scoped); } catch { return; }
  const current = read();
  // Target already has a record -> idempotent short-circuit. A tombstone under the current revision means the user deleted it there, and forward-porting must not resurrect it.
  if (current.records.some((record) => record.recordId === recordId)) return;
  if (current.tombstones.some((tombstone) => tombstone.recordId === recordId)) return;
  const candidate = current.records
    .filter((record) => record.scope === scope
      && norm(record.providerId) === norm(input.providerId)
      && record.canonicalModelId === input.canonicalModelId
      && (scope !== 'conversation_connection_model' || record.conversationId === norm(input.conversationId))
      && (scope !== 'skill_agent' || record.skillId === norm(input.skillId))
      && isSameCapabilityTransportLineage(input.transportIdentity, record.transportIdentity))
    .sort((left, right) => (newer(left, right) ? -1 : 1))[0];
  if (!candidate) return;
  // Tier narrowing (a new recipe dropping a tier) is not handled here:
  // `clampModelControlWebPreference`, the stale-intent fallback for reasoning tiers and the
  // outbound compile gate each cover it. Forward-porting only carries the user's choice across the
  // revision boundary.
  saveCapabilityPreferences(scoped, toValue(candidate));
}

/** Old stores remain physically present and dormant; no field is guessed into the v2 identity. */
export function hasDormantLegacyCapabilityPreferences(): boolean {
  return hasLegacyBareStore(LEGACY_KEY) || hasLegacyBareStore(LEGACY_DRAFT_KEY);
}

function sameIdentity(left: Pick<CapabilityRuntimeIdentity, 'providerId' | 'canonicalModelId' | 'transportIdentity'>, right: Pick<CapabilityRuntimeIdentity, 'providerId' | 'canonicalModelId' | 'transportIdentity'>): boolean {
  return norm(left.providerId) === norm(right.providerId)
    && left.canonicalModelId === right.canonicalModelId
    && left.transportIdentity === right.transportIdentity;
}
function toValueOrUndefined(record: CapabilityPreferenceSyncRecord | undefined): CapabilityPreferences | undefined { return record ? toValue(record) : undefined; }
function toValue(record: CapabilityPreferenceSyncRecord): CapabilityPreferences { return { web: record.web, ...(record.reasoningIntent ? { reasoningIntent: record.reasoningIntent } : {}) }; }
let queued = false;
function publish(): void {
  if (typeof window === 'undefined' || queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    void import('../sync-port').then(({ getSyncAdapter }) => {
      const payload = exportCapabilityPreferenceSyncPayload();
      // An all-empty envelope carries no information and is harmful: a merging remote write
      // replaces array fields wholesale, so pushing empty arrays wipes that account's cloud
      // envelope. Publishing is microtask-deferred, and by the time it runs the local table may
      // already have been cleared by an account-boundary reset - the uid has not changed at that
      // moment, so the outbound uid assertion cannot catch it and this gate is the only one that
      // can. A legitimate "everything deleted" always carries tombstones and is never an all-empty
      // envelope, so no user intent is lost.
      if (payload.records.length === 0 && payload.tombstones.length === 0) return;
      getSyncAdapter()?.didUpdatePreferences({ capabilityPreferenceSettings: payload });
    }).catch(() => {});
  });
}

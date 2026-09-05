import type {
  GenerationParameterOverride,
  GenerationParameterOverrides,
  GenerationParameterValue,
} from '@oriveo/core/providers/request-builders/types';
import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { normalizeUUID, sameNormalizedID } from '../../utils/id-utils';
import { readPartitionedStore, writePartitionedStore } from '../../infra/storage/partitioned-local-store';
import { compareWireId } from './sync-wire-order';

/**
 * Local keys are partitioned per UID (`oriveo.{uid}.<key>`, see `partitioned-local-store`).
 *
 * Same reason as typed capability preferences: this table stores user intent per connection x model
 * and connections follow the account, while the whole table is pushed to the cloud by
 * `exportGenerationParameterSyncPayload`. Without partitioning, account A's parameters would land in
 * account B's cloud copy. Partitioning only changes the local key prefix; the sync envelope
 * (schemaVersion / recordId composition) is unchanged.
 */
const STORAGE_KEY = 'generation-parameter-settings.v1';
const MAX_SCOPES = 200;
const SCOPE_TTL_MS = 180 * 24 * 60 * 60 * 1000;

type StoredScope = {
  scope?: 'connection_default' | 'model_default' | 'conversation_override';
  providerId: string;
  modelId?: string;
  conversationId?: string;
  profileFingerprint?: string;
  syncProfileKey?: string;
  values: GenerationParameterOverrides;
  updatedAt?: number;
  revision?: number;
  mutationId?: string;
};

export type GenerationParameterPreset = {
  id: string;
  name: string;
  providerId: string;
  modelId: string;
  profileFingerprint?: string;
  syncProfileKey?: string;
  values: GenerationParameterOverrides;
  createdAt: number;
  updatedAt: number;
  revision?: number;
  mutationId?: string;
};

type SyncTombstone = { recordId: string; revision: number; mutationId: string };

type StoredSettings = {
  scopes: StoredScope[];
  presets?: GenerationParameterPreset[];
  tombstones?: SyncTombstone[];
};

export type GenerationParameterScope = {
  providerId: string;
  modelId: string;
  conversationId?: string;
  profileFingerprint?: string;
};

export type GenerationParameterSyncRecord = {
  recordId: string;
  scope: 'connection_default' | 'model_default' | 'conversation_override';
  providerId: string;
  modelId?: string;
  conversationId?: string;
  profileKey?: string;
  values: GenerationParameterOverrides;
  revision: number;
  mutationId: string;
};

export type GenerationParameterSyncPreset = {
  id: string;
  name: string;
  providerId: string;
  modelId: string;
  profileKey: string;
  values: GenerationParameterOverrides;
  createdAt: string;
  revision: number;
  mutationId: string;
};

export type GenerationParameterSyncPayload = {
  schemaVersion: 1;
  records: GenerationParameterSyncRecord[];
  presets: GenerationParameterSyncPreset[];
  tombstones: SyncTombstone[];
};

function readRawSettings(): StoredSettings {
  try {
    const parsed = JSON.parse(readPartitionedStore(STORAGE_KEY) ?? '{}') as Partial<StoredSettings>;
    if (!Array.isArray(parsed.scopes)) return { scopes: [], presets: [], tombstones: [] };
    return {
      scopes: parsed.scopes
        .filter((scope): scope is StoredScope => Boolean(scope && typeof scope === 'object')),
      presets: Array.isArray(parsed.presets) ? parsed.presets.filter(isStoredPreset) : [],
      tombstones: Array.isArray(parsed.tombstones) ? parsed.tombstones.filter(isSyncTombstone) : [],
    };
  } catch {
    return { scopes: [], presets: [], tombstones: [] };
  }
}

function readSettings(): StoredSettings {
  const settings = readRawSettings();
  const cutoff = Date.now() - SCOPE_TTL_MS;
  return {
    ...settings,
    scopes: settings.scopes.filter((scope) => scope.updatedAt == null || scope.updatedAt >= cutoff),
  };
}

function writeSettings(settings: StoredSettings): void {
  // Partitioned: one profile's parameter settings must never surface under another.
  writePartitionedStore(STORAGE_KEY, JSON.stringify(settings));
}

function isStoredPreset(value: unknown): value is GenerationParameterPreset {
  if (!value || typeof value !== 'object') return false;
  const preset = value as Partial<GenerationParameterPreset>;
  return typeof preset.id === 'string' && typeof preset.name === 'string'
    && typeof preset.providerId === 'string' && typeof preset.modelId === 'string'
    && (preset.profileFingerprint == null || typeof preset.profileFingerprint === 'string')
    && Boolean(preset.values && typeof preset.values === 'object');
}

function isSyncTombstone(value: unknown): value is SyncTombstone {
  if (!value || typeof value !== 'object') return false;
  const item = value as Partial<SyncTombstone>;
  return typeof item.recordId === 'string' && Number.isInteger(item.revision) && (item.revision ?? 0) > 0
    && typeof item.mutationId === 'string';
}

function inferredScope(scope: StoredScope): GenerationParameterSyncRecord['scope'] {
  if (scope.scope) return scope.scope;
  return scope.conversationId ? 'conversation_override' : 'model_default';
}

function syncProfileKey(fingerprint: string | undefined): string | undefined {
  if (!fingerprint) return undefined;
  const segments = fingerprint.split('|');
  return segments.length > 1 ? segments.slice(1).join('|') : fingerprint;
}

const UUID_SEGMENT_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

/**
 * Wire-level canonical form: lowercase only the UUID segments between ':' separators.
 * A whole-string toLowerCase() would be wrong, because recordId embeds a case-sensitive modelId
 * (e.g. `Qwen/Qwen2.5-72B-Instruct`) and flattening it folds distinct models into one record.
 * Local provider.id is upper-case canonical while the wire side is uniformly lower-case, which is
 * what keeps recordId byte-identical across clients.
 */
function canonicalSyncId(raw: string): string {
  return raw.split(':').map((segment) => (UUID_SEGMENT_RE.test(segment) ? segment.toLowerCase() : segment)).join(':');
}

function scopeRecordId(scope: Pick<StoredScope, 'providerId' | 'modelId' | 'conversationId' | 'scope'>): string {
  const kind = inferredScope(scope as StoredScope);
  if (kind === 'connection_default') return canonicalSyncId(`scope:connection:${scope.providerId}`);
  if (kind === 'conversation_override') {
    return canonicalSyncId(`scope:conversation:${scope.providerId}:${scope.modelId ?? ''}:${scope.conversationId ?? ''}`);
  }
  return canonicalSyncId(`scope:model:${scope.providerId}:${scope.modelId ?? ''}`);
}

function presetRecordId(id: string): string { return canonicalSyncId(`preset:${id}`); }

function sameRecordId(left: string, right: string): boolean {
  return canonicalSyncId(left) === canonicalSyncId(right);
}

function mutationID(): string {
  return globalThis.crypto?.randomUUID?.() ?? `mutation_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

function versionOf(item: { revision?: number; mutationId?: string }): { revision: number; mutationId: string } {
  return { revision: item.revision ?? 1, mutationId: item.mutationId ?? 'legacy' };
}

function syncVersionKey(recordId: string, item: { revision?: number; mutationId?: string }): string {
  const version = versionOf(item);
  return `${canonicalSyncId(recordId)}\u0000${version.revision}\u0000${version.mutationId}`;
}

function isRemoteNewer(
  local: { revision?: number; mutationId?: string } | undefined,
  remote: { revision?: number; mutationId?: string },
): boolean {
  if (!local) return true;
  const left = versionOf(local);
  const right = versionOf(remote);
  return right.revision > left.revision
    || (right.revision === left.revision && right.mutationId > left.mutationId);
}

function nextVersion(recordId: string, settings: StoredSettings): { revision: number; mutationId: string } {
  const scope = settings.scopes.find((item) => scopeRecordId(item) === recordId);
  const preset = settings.presets?.find((item) => presetRecordId(item.id) === recordId);
  const tombstone = settings.tombstones?.find((item) => sameRecordId(item.recordId, recordId));
  const revision = Math.max(scope?.revision ?? 0, preset?.revision ?? 0, tombstone?.revision ?? 0) + 1;
  return { revision, mutationId: mutationID() };
}

/**
 * Scope identity is the logical scope (connection x model x conversation), field-for-field the same
 * as `scopeRecordId`.
 *
 * profileFingerprint is deliberately not part of the identity. When it took part in matching it
 * caused two problems: (1) after an endpoint or protocol change the whole record became unreadable,
 * whereas the rule is per-field revalidation with compatible values still applying, not record-level
 * all-or-nothing invalidation; (2) local reads were stricter than sync identity, so a record could
 * be exported and merged fine through `scopeRecordId` yet never read back on this device, an orphan
 * the user experiences as "but I did save it".
 *
 * The fingerprint is demoted to a record attribute: written alongside `...scope`, which is where a
 * scope migration lands, and on read handed to `generation-parameter-lifecycle` to judge each
 * parameter id active or dormant.
 *
 * providerId / conversationId compare through sameNormalizedID: records written back by sync are
 * lower-case wire form while locally written ones are upper-case canonical, and a strict === would
 * make cloud records unreadable as a group. modelId stays case-sensitive.
 */
function sameScope(left: StoredScope, right: GenerationParameterScope): boolean {
  return inferredScope(left) !== 'connection_default'
    && sameNormalizedID(left.providerId, right.providerId)
    && left.modelId === right.modelId
    && sameNormalizedID(left.conversationId, right.conversationId);
}

/**
 * Returns the most recent record for a logical scope. Records that an earlier storage layout split
 * by fingerprint converge here and are actually merged into one on the next
 * `saveGenerationParameterOverrides` (the filter uses the same predicate).
 */
function findScope(scopes: StoredScope[], scope: GenerationParameterScope): StoredScope | undefined {
  let best: StoredScope | undefined;
  for (const item of scopes) {
    if (!sameScope(item, scope)) continue;
    if (!best || (item.updatedAt ?? 0) > (best.updatedAt ?? 0)) best = item;
  }
  return best;
}

/** Local scope fingerprint: not reused after a Relay endpoint, protocol, or engine change. Excludes the key and never leaves the device. */
export function generationParameterProfileFingerprint(provider: Provider, model: AIModel): string {
  const endpoint = provider.kind === 'relay'
    ? (provider.relayRequested?.resolvedAPIBaseURL ?? provider.baseURLText ?? '')
    : '';
  const transport = provider.kind === 'relay'
    ? (provider.relayResolvedTransport ?? provider.relayRequested?.transport ?? '')
    : (model.generationProfile?.template ?? model.transport ?? '');
  const endpointHash = endpoint.trim() ? `ep_${fnv1a32(sanitizedEndpoint(endpoint))}` : '';
  return [endpointHash, transport, provider.relayRequested?.engineProfile ?? '', model.canonicalModelId ?? model.id].join('|');
}

function sanitizedEndpoint(raw: string): string {
  try {
    const parsed = new URL(raw);
    const path = parsed.pathname.replace(/\/+$/, '') || '/';
    return `${parsed.protocol}//${parsed.host}${path}`;
  } catch {
    return raw.trim().split(/[?#]/, 1)[0] ?? '';
  }
}

function fnv1a32(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function hasExplicitValue(values: GenerationParameterOverrides): boolean {
  return Object.values(values).some((item) => item?.state !== 'inherit');
}

/**
 * Stores the full value locally; the publisher only ever exports the redacted scalars the
 * cross-client contract allows.
 */
export function saveGenerationParameterOverrides(
  scope: GenerationParameterScope,
  values: GenerationParameterOverrides,
): void {
  const settings = readSettings();
  const scopes = settings.scopes.filter((item) => !sameScope(item, scope));
  const recordID = scopeRecordId({ ...scope, scope: scope.conversationId ? 'conversation_override' : 'model_default' });
  const version = nextVersion(recordID, settings);
  const tombstones = (settings.tombstones ?? []).filter((item) => !sameRecordId(item.recordId, recordID));
  if (hasExplicitValue(values)) {
    scopes.push({
      ...scope,
      scope: scope.conversationId ? 'conversation_override' : 'model_default',
      values,
      updatedAt: Date.now(),
      ...version,
    });
  } else {
    tombstones.push({ recordId: recordID, ...version });
  }
  scopes.sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0));
  writeSettings({ ...settings, scopes: scopes.slice(0, MAX_SCOPES), tombstones });
  publishGenerationParameterSyncPayload();
}

/**
 * Reads back every stored value for the scope, including the ones the current profile judges
 * dormant.
 *
 * Not filtering here is deliberate: the panel must see dormant values to render the
 * "kept, currently inactive" summary honestly, and filtering would turn that back into silent data
 * loss. Outbound filtering lives in `resolveGenerationParameterOverrides`.
 */
export function loadGenerationParameterOverrides(
  scope: GenerationParameterScope,
): GenerationParameterOverrides | undefined {
  return findScope(readSettings().scopes, scope)?.values;
}

export function loadConnectionGenerationParameterDefaults(providerId: string): GenerationParameterOverrides | undefined {
  return readSettings().scopes.find((item) => inferredScope(item) === 'connection_default'
    && sameNormalizedID(item.providerId, providerId))?.values;
}

/** Connection-level defaults only carry parameters the caller judged portable for the profile. */
export function saveConnectionGenerationParameterDefaults(
  providerId: string,
  values: GenerationParameterOverrides,
): void {
  const settings = readSettings();
  const recordID = canonicalSyncId(`scope:connection:${providerId}`);
  const version = nextVersion(recordID, settings);
  const scopes = settings.scopes.filter((item) => !(inferredScope(item) === 'connection_default'
    && sameNormalizedID(item.providerId, providerId)));
  const tombstones = (settings.tombstones ?? []).filter((item) => !sameRecordId(item.recordId, recordID));
  if (hasExplicitValue(values)) {
    scopes.push({ scope: 'connection_default', providerId, values: presetSafeValues(values), updatedAt: Date.now(), ...version });
  } else {
    tombstones.push({ recordId: recordID, ...version });
  }
  writeSettings({ ...settings, scopes: scopes.slice(0, MAX_SCOPES), tombstones });
  publishGenerationParameterSyncPayload();
}

function mergeFirstExplicit(
  target: GenerationParameterOverrides,
  source: GenerationParameterOverrides | undefined,
  options: { allowReasoning?: boolean; activeParameterIds?: ReadonlySet<string> } = {},
): void {
  if (!source) return;
  for (const [key, value] of Object.entries(source)) {
    // Dormant values take part in storage and sync but never go outbound. They are blocked here
    // rather than dropped downstream by applyGenerationParameters because the conflicts/requires
    // assertions run before that drop, so a stale value that cannot be sent would raise a conflict
    // and stop the user from sending at all.
    if (options.activeParameterIds && !options.activeParameterIds.has(key)) continue;
    // Conversation-level reasoning effort comes only from the chat page reasoning chip, to avoid a
    // second wire injection path. The connection scope is the exception: a connection-level
    // reasoning default must really go outbound, otherwise it is settable, storable and readable
    // back while injecting nothing.
    if (!options.allowReasoning && isReasoningParameterID(key)) continue;
    if (value && value.state !== 'inherit' && target[key] === undefined) target[key] = value;
  }
}

export function isReasoningParameterID(id: string): boolean {
  return id === 'reasoning_effort' || id === 'reasoning_budget' || id === 'reasoning_mode';
}

/**
 * Deterministic precedence: per-turn transient > conversation override > model default > connection
 * default. `inherit` does not override a lower layer; `omit` counts as an explicit value.
 *
 * Reasoning group precedence: an explicit conversation-level reasoning chip beats the
 * connection-level reasoning default, which beats the profile default. That is what
 * `allowConnectionReasoning` below implements: once the chip picks an explicit level (anything but
 * automatic) the whole connection-level reasoning group steps aside, and only while the chip sits at
 * Auto do connection defaults apply. It has to be resolved here because applyGenerationParameters in
 * the builder runs after the deepMerge of reasoningParams, so if both channels emitted a value the
 * generation parameters would overwrite the chip and invert the precedence.
 */
export function resolveGenerationParameterOverrides(input: {
  providerId: string;
  modelId: string;
  conversationId?: string;
  profileFingerprint?: string;
  transient?: GenerationParameterOverrides;
  /** Reasoning chip level for the current conversation; anything but automatic is an explicit user choice. */
  reasoningMode?: ReasoningMode;
  /**
   * Parameter ids that still go outbound under the current profile
   * (`activeGenerationParameterIds(provider, model)`). Passing it filters out dormant values; every
   * call site on the send path must pass it, and omitting it is only for storage unit tests that do
   * not involve a profile.
   */
  activeParameterIds?: ReadonlySet<string>;
}): GenerationParameterOverrides | undefined {
  const allowConnectionReasoning = !input.reasoningMode || input.reasoningMode === 'automatic';
  const activeParameterIds = input.activeParameterIds;
  const resolved: GenerationParameterOverrides = {};
  // Transient per-turn values deliberately skip the dormant filter: dormancy means a stored value is
  // invalid under the new profile, while a transient value was produced by the UI against the
  // current profile this turn and cannot be stale by definition. Filtering it would break the
  // highest-precedence scope for no reason. It is still subject to the outbound gate in
  // applyGenerationParameters.
  mergeFirstExplicit(resolved, input.transient);
  if (input.conversationId) {
    mergeFirstExplicit(resolved, loadGenerationParameterOverrides({
      providerId: input.providerId,
      modelId: input.modelId,
      conversationId: input.conversationId,
      profileFingerprint: input.profileFingerprint,
    }), { activeParameterIds });
  }
  // The connection scope is the panel on the provider detail page (connection x model defaults plus
  // connection defaults). Those two layers are the ones allowed to emit reasoning; the conversation
  // layers (transient / conversation) still honour only the reasoning chip.
  mergeFirstExplicit(
    resolved,
    loadGenerationParameterOverrides({
      providerId: input.providerId,
      modelId: input.modelId,
      profileFingerprint: input.profileFingerprint,
    }),
    { allowReasoning: allowConnectionReasoning, activeParameterIds },
  );
  mergeFirstExplicit(
    resolved,
    loadConnectionGenerationParameterDefaults(input.providerId),
    { allowReasoning: allowConnectionReasoning, activeParameterIds },
  );
  return Object.keys(resolved).length > 0 ? resolved : undefined;
}

/** Moves compose-state overrides onto the real conversation scope once the first message creates it. */
export function migrateGenerationParameterSession(input: {
  providerId: string;
  modelId: string;
  fromConversationId: string;
  toConversationId: string;
  profileFingerprint?: string;
}): void {
  if (input.fromConversationId === input.toConversationId) return;
  const source = loadGenerationParameterOverrides({
    providerId: input.providerId,
    modelId: input.modelId,
    conversationId: input.fromConversationId,
    profileFingerprint: input.profileFingerprint,
  });
  if (!source) return;
  saveGenerationParameterOverrides({
    providerId: input.providerId,
    modelId: input.modelId,
    conversationId: input.toConversationId,
    profileFingerprint: input.profileFingerprint,
  }, source);
  saveGenerationParameterOverrides({
    providerId: input.providerId,
    modelId: input.modelId,
    conversationId: input.fromConversationId,
    profileFingerprint: input.profileFingerprint,
  }, {});
}

export function removeGenerationParameterScopes(input: { providerId?: string; modelId?: string; conversationId?: string }): void {
  if (!input.providerId && !input.modelId && !input.conversationId) return;
  const settings = readSettings();
  const scopeMatches = (scope: StoredScope) => (!input.providerId || sameNormalizedID(scope.providerId, input.providerId))
    && (!input.modelId || scope.modelId === input.modelId)
    && (!input.conversationId || sameNormalizedID(scope.conversationId, input.conversationId));
  const presetMatches = (preset: GenerationParameterPreset) => (!input.providerId || sameNormalizedID(preset.providerId, input.providerId))
    && (!input.modelId || preset.modelId === input.modelId)
    && !input.conversationId;
  const removedScopes = settings.scopes.filter(scopeMatches);
  const removedPresets = (settings.presets ?? []).filter(presetMatches);
  const scopes = settings.scopes.filter((scope) => !scopeMatches(scope));
  const presets = (settings.presets ?? []).filter((preset) => !presetMatches(preset));
  const tombstones = [...(settings.tombstones ?? [])];
  for (const scope of removedScopes) {
    const recordId = scopeRecordId(scope);
    tombstones.push({ recordId, ...nextVersion(recordId, settings) });
  }
  for (const preset of removedPresets) {
    const recordId = presetRecordId(preset.id);
    tombstones.push({ recordId, ...nextVersion(recordId, settings) });
  }
  writeSettings({ ...settings, scopes, presets, tombstones });
  publishGenerationParameterSyncPayload();
}

const RUNTIME_PARAMETER_IDS = new Set([
  'context_length', 'keep_alive', 'speculative_decoding', 'prompt_cache', 'cache_reuse',
]);

function presetSafeValues(values: GenerationParameterOverrides): GenerationParameterOverrides {
  return Object.fromEntries(Object.entries(values).filter(([id]) => !RUNTIME_PARAMETER_IDS.has(id)));
}

/**
 * Preset identity is connection x model, same source as `sameScope`, without the profile
 * fingerprint.
 *
 * When the fingerprint took part in matching it produced the preset version of the same defect:
 * after an endpoint or protocol change (a relay `resolvedTransport` corrected at runtime is a common
 * case) the whole preset became unreadable while the record stayed on disk and kept syncing. The
 * fingerprint is a record attribute now, and whether each value applies is decided per field by
 * `generation-parameter-lifecycle`.
 *
 * Across models, only fields of the same provider that the target profile declares portable are
 * allowed.
 */
export function listGenerationParameterPresets(scope: {
  providerId: string;
  modelId: string;
  /** Kept for caller convenience only; not part of matching (see the comment above). */
  profileFingerprint?: string;
  portableParameterIds?: Iterable<string>;
}): GenerationParameterPreset[] {
  const portableIDs = new Set(scope.portableParameterIds ?? []);
  return (readSettings().presets ?? []).filter((preset) => {
    if (!sameNormalizedID(preset.providerId, scope.providerId)) return false;
    if (preset.modelId === scope.modelId) return true;
    return Object.keys(preset.values).some((id) => portableIDs.has(id));
  });
}

/**
 * A preset is a full snapshot of user intent, minus runtime resource entries, which never enter a
 * preset.
 *
 * It is deliberately not trimmed by this device's active/dormant judgement:
 * (1) dormancy is device-local derived state, so trimming a record that will be synced lets one
 *     device's profile disable a value another device can happily send, exactly the silent
 *     cross-device substitution the lifecycle rules forbid;
 * (2) before a profile has been probed at all every value reads as dormant, so trimming by active
 *     would store an empty preset, which the user sees as "I saved it and nothing was saved".
 * Storing everything and rendering "kept, currently inactive" in the panel loses no information and
 * recovers on its own.
 */
export function saveGenerationParameterPreset(input: {
  id?: string;
  name: string;
  providerId: string;
  modelId: string;
  profileFingerprint: string;
  values: GenerationParameterOverrides;
}): GenerationParameterPreset {
  const settings = readSettings();
  const now = Date.now();
  const existing = input.id ? settings.presets?.find((item) => item.id === input.id) : undefined;
  const presetID = existing?.id ?? createStablePresetID();
  const preset: GenerationParameterPreset = {
    id: presetID,
    name: input.name.trim(),
    providerId: input.providerId,
    modelId: input.modelId,
    profileFingerprint: input.profileFingerprint,
    values: presetSafeValues(input.values),
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    ...nextVersion(presetRecordId(presetID), settings),
  };
  const presets = (settings.presets ?? []).filter((item) => item.id !== preset.id);
  presets.push(preset);
  const tombstones = (settings.tombstones ?? []).filter((item) => !sameRecordId(item.recordId, presetRecordId(preset.id)));
  writeSettings({ ...settings, presets, tombstones });
  publishGenerationParameterSyncPayload();
  return preset;
}

export function removeGenerationParameterPreset(id: string): void {
  const settings = readSettings();
  const recordId = presetRecordId(id);
  writeSettings({
    ...settings,
    presets: (settings.presets ?? []).filter((item) => item.id !== id),
    tombstones: [...(settings.tombstones ?? []).filter((item) => !sameRecordId(item.recordId, recordId)), {
      recordId,
      ...nextVersion(recordId, settings),
    }],
  });
  publishGenerationParameterSyncPayload();
}

/**
 * Same connection and model: restore the whole preset (the fingerprint does not participate, as in
 * `listGenerationParameterPresets`). Once the scope record is written back, which values can
 * currently be sent is decided per field by `partitionGenerationParameterValues` and the outbound
 * gate. Nothing is trimmed here, because trimming would delete values from storage that are only
 * inactive on this one device.
 */
export function applyGenerationParameterPreset(
  preset: GenerationParameterPreset,
  target: { providerId: string; modelId: string; profileFingerprint?: string },
  semanticMapping?: Record<string, string>,
): GenerationParameterOverrides | undefined {
  if (!sameNormalizedID(preset.providerId, target.providerId)) return undefined;
  if (preset.modelId === target.modelId) return presetSafeValues(preset.values);
  // Cross-model apply is explicit only: every copied parameter needs a target-declared semantic mapping.
  if (!semanticMapping) return undefined;
  const mapped = Object.entries(preset.values).flatMap(([sourceID, value]) => {
    const targetID = semanticMapping[sourceID];
    return targetID ? [[targetID, value] as const] : [];
  });
  return mapped.length > 0 ? Object.fromEntries(mapped) : undefined;
}

function createStablePresetID(): string {
  return globalThis.crypto?.randomUUID?.() ?? `preset_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}

const SYNC_EXCLUDED_PARAMETER_IDS = new Set([
  ...RUNTIME_PARAMETER_IDS,
  // These can carry user-authored text or a schema, so a canonical key alone is not enough to treat them as non-sensitive.
  'stop', 'json_schema',
]);

function syncSafeValues(values: GenerationParameterOverrides): GenerationParameterOverrides {
  const safe: GenerationParameterOverrides = {};
  for (const [id, override] of Object.entries(values)) {
    if (!/^[a-z][a-z0-9_]{0,63}$/.test(id) || id.startsWith('custom_') || SYNC_EXCLUDED_PARAMETER_IDS.has(id)) continue;
    if (!override || (override.state !== 'inherit' && override.state !== 'omit' && override.state !== 'value')) continue;
    if (override.state !== 'value') {
      safe[id] = { state: override.state };
      continue;
    }
    const value = override.value;
    if (typeof value !== 'number' && typeof value !== 'boolean' && typeof value !== 'string') continue;
    if (typeof value === 'string' && (value.length > 64 || !/^[a-zA-Z0-9_.:-]+$/.test(value))) continue;
    safe[id] = { state: 'value', value };
  }
  return safe;
}

function normalizedSyncRecord(value: unknown): GenerationParameterSyncRecord | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const item = value as Partial<GenerationParameterSyncRecord>;
  if (typeof item.recordId !== 'string' || !['connection_default', 'model_default', 'conversation_override'].includes(item.scope ?? '')
    || typeof item.providerId !== 'string' || !Number.isInteger(item.revision) || (item.revision ?? 0) < 1
    || typeof item.mutationId !== 'string' || !item.values || typeof item.values !== 'object') return undefined;
  if (item.scope !== 'connection_default' && typeof item.modelId !== 'string') return undefined;
  if (item.scope === 'conversation_override' && typeof item.conversationId !== 'string') return undefined;
  return {
    recordId: canonicalSyncId(item.recordId),
    scope: item.scope!,
    providerId: item.providerId.toLowerCase(),
    ...(typeof item.modelId === 'string' ? { modelId: item.modelId } : {}),
    ...(typeof item.conversationId === 'string' ? { conversationId: item.conversationId.toLowerCase() } : {}),
    ...(typeof item.profileKey === 'string' ? { profileKey: item.profileKey } : {}),
    values: syncSafeValues(item.values),
    revision: item.revision!,
    mutationId: item.mutationId,
  };
}

function normalizedSyncPreset(value: unknown): GenerationParameterSyncPreset | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const item = value as Partial<GenerationParameterSyncPreset>;
  if (typeof item.id !== 'string' || typeof item.name !== 'string' || typeof item.providerId !== 'string'
    || typeof item.modelId !== 'string' || typeof item.profileKey !== 'string' || typeof item.createdAt !== 'string'
    || !Number.isInteger(item.revision) || (item.revision ?? 0) < 1 || typeof item.mutationId !== 'string'
    || !item.values || typeof item.values !== 'object') return undefined;
  return {
    id: item.id.toLowerCase(),
    name: item.name.trim().slice(0, 80),
    providerId: item.providerId.toLowerCase(),
    modelId: item.modelId,
    profileKey: item.profileKey,
    values: syncSafeValues(item.values),
    createdAt: item.createdAt,
    revision: item.revision!,
    mutationId: item.mutationId,
  };
}

export function exportGenerationParameterSyncPayload(): GenerationParameterSyncPayload {
  const settings = readSettings();
  const records = settings.scopes.map((scope): GenerationParameterSyncRecord => {
    const profileKey = scope.syncProfileKey ?? syncProfileKey(scope.profileFingerprint);
    return {
      recordId: scopeRecordId(scope),
      scope: inferredScope(scope),
      // The wire layer is lower-case canonical; the local upper-case canonical is converted at this boundary.
      providerId: scope.providerId.toLowerCase(),
      ...(scope.modelId ? { modelId: scope.modelId } : {}),
      ...(scope.conversationId ? { conversationId: scope.conversationId.toLowerCase() } : {}),
      ...(profileKey ? { profileKey } : {}),
      values: syncSafeValues(scope.values),
      ...versionOf(scope),
    };
  }).filter((record) => Object.keys(record.values).length > 0);
  const presets = (settings.presets ?? []).map((preset): GenerationParameterSyncPreset => ({
    id: preset.id.toLowerCase(),
    name: preset.name.slice(0, 80),
    providerId: preset.providerId.toLowerCase(),
    modelId: preset.modelId,
    profileKey: preset.syncProfileKey ?? syncProfileKey(preset.profileFingerprint) ?? '',
    values: syncSafeValues(preset.values),
    createdAt: new Date(preset.createdAt).toISOString(),
    ...versionOf(preset),
  })).filter((preset) => preset.profileKey && Object.keys(preset.values).length > 0);
  // Output order must match the merge output exactly (compareWireId): exporting in local
  // construction order would store an array that another client reorders and writes straight back.
  return {
    schemaVersion: 1,
    records: records.sort((a, b) => compareWireId(a.recordId, b.recordId)).slice(0, MAX_SCOPES),
    presets: presets.sort((a, b) => compareWireId(a.id, b.id)).slice(0, 100),
    tombstones: (settings.tombstones ?? []).map((item) => ({ ...item, recordId: canonicalSyncId(item.recordId) }))
      .sort((a, b) => compareWireId(a.recordId, b.recordId)).slice(-300),
  };
}

/**
 * Merges a cloud or imported payload with the local one by (revision, mutationId). Delete tombstones
 * take part in the same comparison so an offline device cannot resurrect a deleted preset or
 * default. Returns the merged, safe payload for the caller to write back.
 */
export function mergeGenerationParameterSyncPayload(raw: unknown): GenerationParameterSyncPayload {
  const remote = raw && typeof raw === 'object' ? raw as Partial<GenerationParameterSyncPayload> : {};
  // Expired records take no part in normal reads or exports, but must still be compared by timestamp
  // at the same revision; otherwise a cloud replay of the same revision/mutation looks like a new
  // fact, refreshes the 180-day TTL and brings expired settings back.
  const previous = readRawSettings();
  const previousScopeTimestamps = new Map(previous.scopes.map((scope) => [
    syncVersionKey(scopeRecordId(scope), scope),
    scope.updatedAt,
  ]));
  const previousPresetTimestamps = new Map((previous.presets ?? []).map((preset) => [
    syncVersionKey(presetRecordId(preset.id), preset),
    preset.updatedAt,
  ]));
  const local = exportGenerationParameterSyncPayload();
  const candidates = new Map<string, GenerationParameterSyncRecord | GenerationParameterSyncPreset | SyncTombstone>();
  // Both keyed competition and tombstone matching canonicalise first: a remote upper-case recordId
  // and a local lower-case one must collide on the same key to converge, otherwise one logical
  // record forks permanently into two.
  const put = (rawRecordId: string, item: GenerationParameterSyncRecord | GenerationParameterSyncPreset | SyncTombstone) => {
    const recordId = canonicalSyncId(rawRecordId);
    const existing = candidates.get(recordId);
    if (isRemoteNewer(existing, item)) candidates.set(recordId, item);
  };
  local.records.forEach((item) => put(item.recordId, item));
  local.presets.forEach((item) => put(presetRecordId(item.id), item));
  local.tombstones.forEach((item) => put(item.recordId, item));
  (Array.isArray(remote.records) ? remote.records : []).forEach((rawRecord) => {
    const item = normalizedSyncRecord(rawRecord); if (item) put(item.recordId, item);
  });
  (Array.isArray(remote.presets) ? remote.presets : []).forEach((rawPreset) => {
    const item = normalizedSyncPreset(rawPreset); if (item) put(presetRecordId(item.id), item);
  });
  (Array.isArray(remote.tombstones) ? remote.tombstones : []).forEach((rawTombstone) => {
    if (isSyncTombstone(rawTombstone)) {
      put(rawTombstone.recordId, { ...rawTombstone, recordId: canonicalSyncId(rawTombstone.recordId) });
    }
  });

  const records: GenerationParameterSyncRecord[] = [];
  const presets: GenerationParameterSyncPreset[] = [];
  const tombstones: SyncTombstone[] = [];
  for (const [recordId, item] of candidates) {
    if ('recordId' in item && !('scope' in item)) {
      tombstones.push(item);
    } else if (recordId.startsWith('preset:')) {
      presets.push(item as GenerationParameterSyncPreset);
    } else {
      records.push(item as GenerationParameterSyncRecord);
    }
  }
  const merged: GenerationParameterSyncPayload = {
    schemaVersion: 1,
    records: records.sort((a, b) => compareWireId(a.recordId, b.recordId)).slice(0, MAX_SCOPES),
    presets: presets.sort((a, b) => compareWireId(a.id, b.id)).slice(0, 100),
    tombstones: tombstones.sort((a, b) => compareWireId(a.recordId, b.recordId)).slice(-300),
  };
  const mergedAt = Date.now();
  const nextSettings: StoredSettings = {
    // Write back locally: the wire form is lower-case canonical and local storage restores the
    // upper-case canonical, otherwise sameScope (which uses the upper-case provider.id) cannot read
    // the records that were just merged in.
    scopes: merged.records.map((item) => ({
      scope: item.scope,
      providerId: normalizeUUID(item.providerId),
      modelId: item.modelId,
      conversationId: item.conversationId ? normalizeUUID(item.conversationId) : undefined,
      syncProfileKey: item.profileKey,
      values: item.values,
      updatedAt: previousScopeTimestamps.has(syncVersionKey(item.recordId, item))
        ? previousScopeTimestamps.get(syncVersionKey(item.recordId, item))
        : mergedAt,
      revision: item.revision,
      mutationId: item.mutationId,
    })),
    presets: merged.presets.map((item) => ({
      id: item.id,
      name: item.name,
      providerId: normalizeUUID(item.providerId),
      modelId: item.modelId,
      profileFingerprint: undefined,
      syncProfileKey: item.profileKey,
      values: item.values,
      createdAt: Date.parse(item.createdAt) || Date.now(),
      updatedAt: previousPresetTimestamps.get(syncVersionKey(presetRecordId(item.id), item)) ?? mergedAt,
      revision: item.revision,
      mutationId: item.mutationId,
    })),
    tombstones: merged.tombstones,
  };
  writeSettings(nextSettings);
  return merged;
}

export function exportGenerationParameterSettingsJSON(): string {
  return JSON.stringify(exportGenerationParameterSyncPayload(), null, 2);
}

export function importGenerationParameterSettingsJSON(raw: string): GenerationParameterSyncPayload {
  const parsed: unknown = JSON.parse(raw);
  if (!parsed || typeof parsed !== 'object' || (parsed as { schemaVersion?: unknown }).schemaVersion !== 1) {
    throw new TypeError('Unsupported generation parameter settings schema');
  }
  const merged = mergeGenerationParameterSyncPayload(parsed);
  publishGenerationParameterSyncPayload();
  return merged;
}

let publishQueued = false;
function publishGenerationParameterSyncPayload(): void {
  if (typeof window === 'undefined' || publishQueued) return;
  publishQueued = true;
  queueMicrotask(() => {
    publishQueued = false;
    void Promise.all([
      import('../sync-port'),
    ]).then(([{ getSyncAdapter }]) => {
      const payload = exportGenerationParameterSyncPayload();
      // A fully empty envelope carries no information and is harmful: a merging remote write
      // replaces array fields wholesale, so pushing empty arrays clears the account's cloud
      // envelope. One reachable path leads here: `removeGenerationParameterScopes` still calls
      // writeSettings + publish when nothing matched at all (deleting an official provider after an
      // account switch has exactly this shape). A legitimate "everything deleted" always carries
      // tombstones, so no user intent is lost.
      if (payload.records.length === 0 && payload.presets.length === 0 && payload.tombstones.length === 0) return;
      getSyncAdapter()?.didUpdatePreferences({ generationParameterSettings: payload });
    }).catch(() => {});
  });
}

export function valueOverride<T extends GenerationParameterValue>(value: T): GenerationParameterOverride<T> {
  return { state: 'value', value };
}

/**
 * Pure functions for relay multiple keys: list, effective key, binding, key operations, read model.
 * Contract fixture: `shared/test-fixtures/relay/key-binding.v1.json` (bindCases / opsCases / readCases).
 *
 * The connection-level `relayKeys` is ordered; the first is the primary key and its value is always `provider.apiKey` (the entry's own `apiKey` is stored empty);
 * the default = one implicit key `initial`. No network or storage here; fetching catalogs per key and send decisions live elsewhere.
 */

import type { AIModel, Provider, RelayKeyEntry, RelayKeyStatus, RelayKeyStatusState } from '../types/models';
import { formatApiKeyPreview } from '../utils/api-key-utils';

export const RELAY_IMPLICIT_KEY_ID = 'initial';

export const RELAY_KEY_STATUS_STATES: readonly RelayKeyStatusState[] = ['ok', 'invalid', 'denied', 'limited', 'failed'];

type KeyListSource = { relayKeys?: readonly RelayKeyEntry[] };
type ModelKeyRef = Pick<AIModel, 'id' | 'relayKeyID'>;
type CatalogKeyRef = Pick<AIModel, 'id' | 'relayListedByKeyIDs'>;

/** The key list of a connection; missing or an empty list = one implicit primary key (value in provider.apiKey). */
export function relayKeyList(provider: KeyListSource): RelayKeyEntry[] {
  const list = provider.relayKeys;
  if (!list || list.length === 0) return [{ id: RELAY_IMPLICIT_KEY_ID, apiKey: '' }];
  return [...list];
}

export function relayKeyIDs(provider: KeyListSource): string[] {
  return relayKeyList(provider).map((key) => key.id);
}

/** The value of a key: the primary key takes provider.apiKey, the others take the entry's own; not trimmed. Returns undefined if absent. */
export function relayKeySecret(
  provider: KeyListSource & { apiKey: string },
  keyID: string,
): string | undefined {
  const keys = relayKeyList(provider);
  const index = keys.findIndex((key) => key.id === keyID);
  if (index < 0) return undefined;
  return index === 0 ? provider.apiKey : keys[index]!.apiKey; // key-choke: stored-field
}

/** Values of all keys on the connection (for the redaction list). */
export function relayKeySecrets(provider: KeyListSource & { apiKey: string }): string[] {
  return relayKeyList(provider).map((key, index) => (index === 0 ? provider.apiKey : key.apiKey)); // key-choke: stored-field
}

function effectiveKeyOf(keys: readonly string[], model: ModelKeyRef | undefined): string {
  const bound = model?.relayKeyID;
  return bound && keys.includes(bound) ? bound : keys[0]!;
}

/**
 * Effective key of a model: if the enabled model's `relayKeyID` hits the list -> that key; otherwise (missing, dangling, model not enabled,
 * empty model id) -> the primary key.
 */
export function relayEffectiveKeyID(
  provider: KeyListSource & { models?: readonly ModelKeyRef[] },
  modelID: string | null | undefined,
): string {
  const keys = relayKeyIDs(provider);
  const model = modelID ? provider.models?.find((item) => item.id === modelID) : undefined;
  return effectiveKeyOf(keys, model);
}

/** Listers of a catalog entry (default = primary key), in key-list order; the model library key(id) filter and the per-key catalog count use the same criterion. */
export function listingKeysOf(keys: readonly string[], entry: CatalogKeyRef | undefined): string[] {
  if (!entry) return [];
  const listed = entry.relayListedByKeyIDs ?? [keys[0]!];
  return keys.filter((key) => listed.includes(key));
}

export interface RelayKeyBindInput {
  keys: readonly string[];
  catalog: readonly CatalogKeyRef[];
  enabled: readonly ModelKeyRef[];
  targetModelID: string;
  family: (modelID: string) => string | null | undefined;
}

/**
 * Pick a key for a model when enabling / adding manually (fixture bindCases). With only one key returns null (writes nothing).
 */
export function bindRelayKey(input: RelayKeyBindInput): string | null {
  const { keys } = input;
  if (keys.length <= 1) return null;
  const listers = listingKeysOf(keys, input.catalog.find((entry) => entry.id === input.targetModelID));
  if (listers.length === 1) return listers[0]!;
  const targetFamily = input.family(input.targetModelID) ?? null;
  const sameFamily = targetFamily === null
    ? []
    : input.enabled.filter((model) => (input.family(model.id) ?? null) === targetFamily);
  if (listers.length > 1) {
    for (const model of sameFamily) {
      const effective = effectiveKeyOf(keys, model);
      if (listers.includes(effective)) return effective;
    }
    return listers[0]!;
  }
  const first = sameFamily[0];
  return first ? effectiveKeyOf(keys, first) : keys[0]!;
}

/* -- Key operations (pure functions, no network; fixture opsCases) ------ */

export type RelayKeyOp =
  | { type: 'add'; id: string; name?: string; apiKey: string }
  | { type: 'rename'; id: string; name: string }
  | { type: 'replaceSecret'; id: string; apiKey: string }
  | { type: 'move'; id: string; toIndex: number }
  | { type: 'delete'; id: string }
  | { type: 'rebind'; modelID: string; keyID: string };

type KeyedProvider = Pick<Provider, 'apiKey' | 'apiKeyPreview' | 'relayKeys' | 'models' | 'catalogModels'>;

/** Expand the primary key's value onto the entries to make whole-list reordering easy; on the way back `collapseSecrets` folds it into provider.apiKey. */
function expandSecrets(provider: KeyedProvider): RelayKeyEntry[] {
  return relayKeyList(provider).map((key, index) => (
    index === 0 ? { ...key, apiKey: provider.apiKey } : { ...key } // key-choke: stored-field
  ));
}

function collapseSecrets<T extends KeyedProvider>(provider: T, expanded: RelayKeyEntry[]): T {
  const primarySecret = expanded[0]!.apiKey; // key-choke: stored-field
  const relayKeys = expanded.map((key, index) => (index === 0 ? { ...key, apiKey: '' } : key));
  const next = { ...provider, relayKeys };
  if (primarySecret !== provider.apiKey) { // key-choke: stored-field
    next.apiKey = primarySecret;
    next.apiKeyPreview = formatApiKeyPreview(primarySecret);
  }
  return next;
}

function withoutField<T extends object, K extends keyof T>(value: T, field: K): T {
  if (!(field in value)) return value;
  const next = { ...value };
  delete next[field];
  return next;
}

/**
 * Perform one key operation on a connection; a refusal (deleting the last key, id not found or duplicated) returns `'refused'`.
 * Invariant: after the operation `relayKeys[0].apiKey` is empty and `provider.apiKey` is the primary key value; once the list has two or more keys,
 * every enabled model carries an explicit `relayKeyID`, so reordering later never silently changes a model's key.
 */
export function applyRelayKeyOp<T extends KeyedProvider>(provider: T, op: RelayKeyOp): T | 'refused' {
  const ids = relayKeyIDs(provider);
  switch (op.type) {
    case 'add': {
      if (!op.id || ids.includes(op.id)) return 'refused';
      const primary = ids[0]!;
      const expanded = expandSecrets(provider);
      expanded.push({ id: op.id, ...(op.name !== undefined ? { name: op.name } : {}), apiKey: op.apiKey }); // key-choke: not-provider
      const pinned = collapseSecrets(provider, expanded);
      // When generating the list, pin all enabled models and fill in the listers of catalog entries.
      return {
        ...pinned,
        models: provider.models.map((model) => ({ ...model, relayKeyID: effectiveKeyOf(ids, model) })),
        catalogModels: provider.catalogModels.map((entry) => (
          entry.relayListedByKeyIDs ? entry : { ...entry, relayListedByKeyIDs: [primary] }
        )),
      };
    }
    case 'rename': {
      if (!provider.relayKeys || !ids.includes(op.id)) return 'refused';
      return {
        ...provider,
        relayKeys: provider.relayKeys.map((key) => (key.id === op.id ? { ...key, name: op.name } : key)),
      };
    }
    case 'replaceSecret': {
      const index = ids.indexOf(op.id);
      if (index < 0) return 'refused';
      // Changing the value means changing the key: clear its state and the no-access marks on models for it, but not the catalog.
      const models = provider.models.map((model) => (
        model.relayDeniedKeyID === op.id ? withoutField(model, 'relayDeniedKeyID') : model
      ));
      if (!provider.relayKeys) {
        return { ...provider, apiKey: op.apiKey, apiKeyPreview: formatApiKeyPreview(op.apiKey), models }; // key-choke: not-provider
      }
      const expanded = expandSecrets(provider).map((key) => (
        key.id === op.id ? withoutField({ ...key, apiKey: op.apiKey }, 'status') : key // key-choke: not-provider
      ));
      return { ...collapseSecrets(provider, expanded), models };
    }
    case 'move': {
      // With no key list (implicit single key) always refuse and write no field (same as iOS on all three clients).
      if (!provider.relayKeys) return 'refused';
      const from = ids.indexOf(op.id);
      if (from < 0) return 'refused';
      // A target position out of range is refused, not clamped (the same refusal table on all three clients, opsCases).
      if (!Number.isInteger(op.toIndex) || op.toIndex < 0 || op.toIndex >= ids.length) return 'refused';
      const expanded = expandSecrets(provider);
      const [moved] = expanded.splice(from, 1);
      expanded.splice(op.toIndex, 0, moved!);
      return collapseSecrets(provider, expanded);
    }
    case 'delete': {
      const index = ids.indexOf(op.id);
      if (index < 0 || ids.length <= 1) return 'refused';
      const oldPrimary = ids[0]!;
      const expanded = expandSecrets(provider).filter((key) => key.id !== op.id);
      const newPrimary = expanded[0]!.id;
      const prune = (listed: readonly string[] | undefined): string[] => (
        (listed ?? [oldPrimary]).filter((id) => id !== op.id)
      );
      const models = provider.models.map((model) => {
        let next = model;
        if (next.relayKeyID === op.id) next = { ...next, relayKeyID: newPrimary };
        if (next.relayDeniedKeyID === op.id) next = withoutField(next, 'relayDeniedKeyID');
        if (next.relayListedByKeyIDs) {
          const listed = prune(next.relayListedByKeyIDs);
          next = listed.length > 0 ? { ...next, relayListedByKeyIDs: listed } : withoutField(next, 'relayListedByKeyIDs');
        }
        return next;
      });
      // Catalog entries listed only by this key leave the catalog; enabled models are kept by the enabled list itself.
      const catalogModels = provider.catalogModels.flatMap((entry) => {
        const listed = prune(entry.relayListedByKeyIDs);
        return listed.length > 0 ? [{ ...entry, relayListedByKeyIDs: listed }] : [];
      });
      return { ...collapseSecrets(provider, expanded), models, catalogModels };
    }
    case 'rebind': {
      // An implicit single key has nothing to rebind: refuse, and do not write relayKeyID onto models (same as iOS).
      if (!provider.relayKeys) return 'refused';
      if (!ids.includes(op.keyID) || !provider.models.some((model) => model.id === op.modelID)) return 'refused';
      // Rebinding clears the no-access marks and reachable protocols (those were tested with the old key), keeping user / observed.
      const models = provider.models.map((model) => {
        if (model.id !== op.modelID) return model;
        let next: AIModel = withoutField({ ...model, relayKeyID: op.keyID }, 'relayDeniedKeyID');
        if (next.relayTransportSource === 'reachable') {
          next = withoutField(withoutField(next, 'relayTransport'), 'relayTransportSource');
        }
        return next;
      });
      return { ...provider, models };
    }
  }
}

/* -- Read model (used by the model library, fixture readCases) ------ */

export interface RelayKeyRow {
  id: string;
  name: string | null;
  isPrimary: boolean;
  status: RelayKeyStatusState | null;
  catalogCount: number;
  enabledCount: number;
  /** Mask, using this client's existing `formatApiKeyPreview`. */
  preview: string;
}

export interface RelayModelKeyState {
  boundKeyID: string;
  alternateKeyIDs: string[];
  deniedOnCurrentKey: boolean;
}

type ReadableProvider = Pick<Provider, 'apiKey' | 'relayKeys' | 'models' | 'catalogModels'>;

export function relayShowsKeyUI(provider: KeyListSource): boolean {
  return relayKeyList(provider).length >= 2;
}

export function relayKeyRows(provider: ReadableProvider): RelayKeyRow[] {
  const keys = relayKeyList(provider);
  const ids = keys.map((key) => key.id);
  return keys.map((key, index) => ({
    id: key.id,
    name: key.name ?? null,
    isPrimary: index === 0,
    status: key.status?.state ?? null,
    catalogCount: provider.catalogModels.filter((entry) => listingKeysOf(ids, entry).includes(key.id)).length,
    enabledCount: provider.models.filter((model) => effectiveKeyOf(ids, model) === key.id).length,
    preview: formatApiKeyPreview(index === 0 ? provider.apiKey : key.apiKey), // key-choke: stored-field
  }));
}

export function relayModelKeyState(provider: ReadableProvider, modelID: string): RelayModelKeyState {
  const ids = relayKeyIDs(provider);
  const model = provider.models.find((item) => item.id === modelID);
  const boundKeyID = effectiveKeyOf(ids, model);
  const listers = listingKeysOf(ids, provider.catalogModels.find((entry) => entry.id === modelID));
  return {
    boundKeyID,
    alternateKeyIDs: listers.filter((id) => id !== boundKeyID),
    deniedOnCurrentKey: model?.relayDeniedKeyID === boundKeyID,
  };
}

/* -- Read-time sanitization (read back from local storage) ------ */

function sanitizeKeyStatus(value: unknown): RelayKeyStatus | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  if (typeof raw.state !== 'string' || !(RELAY_KEY_STATUS_STATES as readonly string[]).includes(raw.state)) {
    return undefined;
  }
  const status: RelayKeyStatus = { state: raw.state as RelayKeyStatusState };
  if (typeof raw.httpStatus === 'number' && Number.isFinite(raw.httpStatus)) status.httpStatus = raw.httpStatus;
  if (typeof raw.checkedAt === 'string') status.checkedAt = raw.checkedAt;
  return status;
}

/**
 * `relayKeys` read-time sanitization: not an array drops the whole key; entries missing id / with a non-string value / with a duplicate id are dropped one by one, and if none remain the whole key is dropped;
 * a wrong state shape drops only the state; the first key's value is always stored empty (the primary key value lives only in provider.apiKey). Returns the input as is when the key is absent or nothing needs sanitizing.
 */
export function sanitizeProviderRelayKeys<T extends object>(provider: T): T {
  const source = provider as Record<string, unknown>;
  if (!('relayKeys' in source)) return provider;
  const raw = source.relayKeys;
  const kept: RelayKeyEntry[] = [];
  if (Array.isArray(raw)) {
    const seen = new Set<string>();
    for (const item of raw) {
      if (typeof item !== 'object' || item === null) continue;
      const entry = item as Record<string, unknown>;
      if (typeof entry.id !== 'string' || !entry.id || seen.has(entry.id) || typeof entry.apiKey !== 'string') continue; // key-choke: stored-field
      seen.add(entry.id);
      const next: RelayKeyEntry = { id: entry.id, apiKey: kept.length === 0 ? '' : entry.apiKey }; // key-choke: stored-field
      if (typeof entry.name === 'string') next.name = entry.name;
      const status = sanitizeKeyStatus(entry.status);
      if (status) next.status = status;
      kept.push(next);
    }
  }
  const cleaned: Record<string, unknown> = { ...source };
  delete cleaned.relayKeys;
  if (kept.length > 0) cleaned.relayKeys = kept;
  return JSON.stringify(cleaned.relayKeys) === JSON.stringify(raw) ? provider : (cleaned as T);
}

import type { CapabilityEvidenceQuery } from '@oriveo/core/providers/capability-evidence-facade';

const STORAGE_KEY = 'oriveo.capability-evidence-identity.v1';
const STORAGE_VERSION = 1 as const;

interface StoredIdentity {
  connectionGeneration: string;
  credentialEpoch: string;
}

interface StoredState {
  version: typeof STORAGE_VERSION;
  entries: Record<string, StoredIdentity>;
}

export type LocalCapabilityEvidenceIdentity = Pick<
  CapabilityEvidenceQuery,
  'partitionId' | 'connectionInstanceId' | 'connectionGeneration' | 'credentialEpoch'
>;

export interface CapabilityEvidenceIdentityAdvance {
  connectionGeneration?: boolean;
  credentialEpoch?: boolean;
}

function normalizedID(value: string): string | null {
  const normalized = value.trim();
  return normalized ? normalized : null;
}

function entryKey(partitionId: string, providerId: string): string | null {
  const partition = normalizedID(partitionId);
  const provider = normalizedID(providerId);
  if (!partition || !provider) return null;
  return `${encodeURIComponent(partition)}|${encodeURIComponent(provider)}`;
}

function localStorageOrNull(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

function isStoredIdentity(value: unknown): value is StoredIdentity {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<StoredIdentity>;
  return typeof candidate.connectionGeneration === 'string'
    && candidate.connectionGeneration.length > 0
    && typeof candidate.credentialEpoch === 'string'
    && candidate.credentialEpoch.length > 0;
}

function readState(storage: Storage): StoredState {
  try {
    const parsed = JSON.parse(storage.getItem(STORAGE_KEY) ?? '') as Partial<StoredState>;
    if (parsed.version !== STORAGE_VERSION || !parsed.entries || typeof parsed.entries !== 'object') {
      return { version: STORAGE_VERSION, entries: {} };
    }
    const entries = Object.fromEntries(
      Object.entries(parsed.entries).filter((entry): entry is [string, StoredIdentity] => (
        Boolean(entry[0]) && isStoredIdentity(entry[1])
      )),
    );
    return { version: STORAGE_VERSION, entries };
  } catch {
    return { version: STORAGE_VERSION, entries: {} };
  }
}

function writeState(storage: Storage, state: StoredState): boolean {
  try {
    storage.setItem(STORAGE_KEY, JSON.stringify(state));
    return true;
  } catch {
    return false;
  }
}

function opaqueToken(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  }
  throw new Error('Secure random identity generation is unavailable.');
}

function freshIdentity(): StoredIdentity {
  return {
    connectionGeneration: opaqueToken(),
    credentialEpoch: opaqueToken(),
  };
}

function publicIdentity(
  partitionId: string,
  providerId: string,
  stored: StoredIdentity,
): LocalCapabilityEvidenceIdentity {
  return {
    partitionId: partitionId.trim(),
    connectionInstanceId: providerId.trim(),
    connectionGeneration: stored.connectionGeneration,
    credentialEpoch: stored.credentialEpoch,
  };
}

/** Pure local read. Missing/corrupt state fails closed and never creates an entry. */
export function readCapabilityEvidenceIdentity(
  partitionId: string,
  providerId: string,
): LocalCapabilityEvidenceIdentity | null {
  const storage = localStorageOrNull();
  const key = entryKey(partitionId, providerId);
  if (!storage || !key) return null;
  const stored = readState(storage).entries[key];
  return stored ? publicIdentity(partitionId, providerId, stored) : null;
}

/**
 * Query adapter input for the pure capability facade. It deliberately contains only local identity
 * fields; transport, endpoint and metadata revisions still have to come from the current request.
 */
export function capabilityEvidenceIdentityForQuery(
  partitionId: string,
  providerId: string,
): LocalCapabilityEvidenceIdentity | null {
  return readCapabilityEvidenceIdentity(partitionId, providerId);
}

/** Explicit provider-loaded/create boundary. Unlike read/query, this operation may create state. */
export function beginCapabilityEvidenceIdentityIfAbsent(
  partitionId: string,
  providerId: string,
): LocalCapabilityEvidenceIdentity | null {
  const storage = localStorageOrNull();
  const key = entryKey(partitionId, providerId);
  if (!storage || !key) return null;
  const state = readState(storage);
  const existing = state.entries[key];
  if (existing) return publicIdentity(partitionId, providerId, existing);
  const created = freshIdentity();
  state.entries[key] = created;
  return writeState(storage, state) ? publicIdentity(partitionId, providerId, created) : null;
}

/** Hydration migration for providers that predate local capability identities. */
export function beginCapabilityEvidenceIdentitiesForLoadedProviders(
  partitionId: string,
  providerIds: readonly string[],
): void {
  for (const providerId of providerIds) {
    beginCapabilityEvidenceIdentityIfAbsent(partitionId, providerId);
  }
}

/**
 * Advances opaque epochs without reading a credential or deriving anything from key/hash/updatedAt.
 * A mutating provider write is an allowed creation boundary for legacy entries.
 */
export function advanceCapabilityEvidenceIdentity(
  partitionId: string,
  providerId: string,
  advance: CapabilityEvidenceIdentityAdvance,
): LocalCapabilityEvidenceIdentity | null {
  const storage = localStorageOrNull();
  const key = entryKey(partitionId, providerId);
  if (!storage || !key || (!advance.connectionGeneration && !advance.credentialEpoch)) return null;
  const state = readState(storage);
  const current = state.entries[key] ?? freshIdentity();
  const next: StoredIdentity = {
    connectionGeneration: advance.connectionGeneration ? opaqueToken() : current.connectionGeneration,
    credentialEpoch: advance.credentialEpoch ? opaqueToken() : current.credentialEpoch,
  };
  state.entries[key] = next;
  return writeState(storage, state) ? publicIdentity(partitionId, providerId, next) : null;
}

/** Delete tombstone: deterministic Provider IDs must never regain the deleted connection's epochs. */
export function tombstoneCapabilityEvidenceIdentity(
  partitionId: string,
  providerId: string,
): LocalCapabilityEvidenceIdentity | null {
  return advanceCapabilityEvidenceIdentity(partitionId, providerId, {
    connectionGeneration: true,
    credentialEpoch: true,
  });
}

export function resetCapabilityEvidenceIdentitiesForTesting(): void {
  localStorageOrNull()?.removeItem(STORAGE_KEY);
}

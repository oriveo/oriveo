/**
 * KeyVault IPC contract. A plaintext key travels one way to the main process on set, where it is
 * encrypted; there is deliberately no get, so plaintext never crosses IPC back to the renderer.
 */

const PARTITIONED_KEY_REF_PREFIX = 'oriveo-kv:1:';

/** Opaque routing capability for one account partition + one provider. Never key material or a key hash. */
export function createPartitionedKeyRef(partitionId: string, providerId: string): string {
  const partition = partitionId.trim();
  const provider = providerId.trim();
  if (!partition || !provider) {
    throw new Error('Desktop KeyVault requires a non-empty partition and provider ID.');
  }
  return `${PARTITIONED_KEY_REF_PREFIX}${encodeURIComponent(partition)}:${encodeURIComponent(provider)}`;
}

/** Main validates this before a KeyVault operation; bare legacy provider IDs fail closed. */
export function isPartitionedKeyRef(keyRef: string): boolean {
  if (!keyRef.startsWith(PARTITIONED_KEY_REF_PREFIX)) return false;
  const parts = keyRef.slice(PARTITIONED_KEY_REF_PREFIX.length).split(':');
  if (parts.length !== 2 || !parts[0] || !parts[1]) return false;
  try {
    return createPartitionedKeyRef(decodeURIComponent(parts[0]), decodeURIComponent(parts[1])) === keyRef;
  } catch {
    return false;
  }
}

export interface KeysSetRequest {
  /** Opaque, partition-scoped capability minted by the renderer from its active account + provider. */
  keyRef: string;
  key: string;
  owner: {
    providerKind: ProviderKind;
    /** Stored endpoint policy for this key. Empty means provider default only. */
    baseURL?: string;
  };
}

export interface KeysProviderRequest {
  /** Opaque, partition-scoped key reference. Never a bare provider ID. */
  keyRef: string;
}

/** The narrow keys interface preload exposes through contextBridge (window.oriveo.keys). */
export interface OriveoKeysBridge {
  /** Store or update an API key (plaintext travels one way to main, which encrypts it to disk). */
  set(keyRef: string, key: string, owner: KeysSetRequest['owner']): Promise<void>;
  /** Whether a key exists for this partition's keyRef. */
  has(keyRef: string): Promise<boolean>;
  /** Delete the key. */
  delete(keyRef: string): Promise<void>;
  /** Masked preview (first 3 and last 4 characters); null when no key is stored. */
  preview(keyRef: string): Promise<string | null>;
  // No get: a plaintext key never flows back to the renderer.
}
import type { ProviderKind } from '@oriveo/shared/pure-types';

/**
 * Storage for remote MCP credentials. Mirrors the iOS `McpCredentialStore.swift`.
 *
 * Access tokens, refresh tokens, expiry, issuer, the `client_id` obtained through DCR and tokens pasted by
 * the user all go through here; the DCR registration itself (keyed by `uid + issuer`, reused across servers)
 * lives on the same medium. **None of this ever leaves the device: it is not logged, sent to analytics or
 * attached to crash reports.**
 *
 * The medium is injected as `McpCredentialStorage`: the web production implementation keeps credentials the
 * way API keys are kept (browser-local IndexedDB, one database per profile partition); tests inject an
 * in-memory implementation, while key construction and cleanup semantics still run through the production
 * path in this file.
 *
 * Mitigations:
 * 1. Access and refresh tokens are **stored separately** (two records); only the access record stays in page memory.
 * 2. They are cleared when the server is removed (`delete`); entries left without a server record are
 *    swept on load (`deleteOrphans`).
 * 3. The refresh token is read only when a refresh is needed (`loadRefreshToken`); the value is not cached and
 *    the reference is dropped right after use.
 */

/** Credential medium. Write and delete failures must throw: callers rely on it to know whether a credential was really stored or removed. */
export interface McpCredentialStorage {
  read(key: string): Promise<string | null>;
  write(key: string, value: string): Promise<void>;
  /** An entry that is already absent counts as success. */
  delete(key: string): Promise<void>;
  keys(): Promise<string[]>;
}

/** All MCP credentials of one server. `expiresAt` is a millisecond timestamp. */
export interface McpCredentials {
  accessToken?: string | null;
  refreshToken?: string | null;
  expiresAt?: number | null;
  /** Issuer of the authorization server that issued these OAuth credentials. Client credentials are bound to the issuer and never reused across authorization servers. */
  issuer?: string | null;
  /** CIMD document URL, or the `client_id` obtained through DCR. Treated as a credential. */
  clientId?: string | null;
  /** Canonical URI of the MCP server these credentials may be sent to (RFC 8707). `resource` is mandatory on refresh. */
  resource?: string | null;
  /** Access token pasted by the user (the "access token" sign-in method). */
  pastedToken?: string | null;
}

/** The half that stays in memory: no refresh token, only a flag saying whether one exists. */
export type McpAccessCredentials = Omit<McpCredentials, 'refreshToken'> & { hasRefreshToken: boolean };

/** DCR registration cached on this device. Bound to the `issuer`. */
export interface McpStoredClientRegistration {
  clientId: string;
  issuer: string;
  /** Redirect URIs reported to the authorization server at registration; an old registration is unusable once a release changes them. */
  redirectUris: string[];
}

export class McpCredentialPersistenceError extends Error {
  constructor() {
    super('MCP credential storage failed');
    this.name = 'McpCredentialPersistenceError';
  }
}

/** Reports only which fields are present, never any secret value, so logging or reporting it cannot leak credentials. */
export function redactMcpCredentials(credentials: McpCredentials | McpAccessCredentials | null): string {
  if (!credentials) return 'McpCredentials(none)';
  const fields: string[] = [];
  if (credentials.accessToken) fields.push('accessToken=<redacted>');
  if ('refreshToken' in credentials ? credentials.refreshToken : (credentials as McpAccessCredentials).hasRefreshToken) {
    fields.push('refreshToken=<redacted>');
  }
  if (credentials.pastedToken) fields.push('pastedToken=<redacted>');
  if (credentials.clientId) fields.push('clientId=<redacted>');
  if (credentials.expiresAt) fields.push(`expiresAt=${credentials.expiresAt}`);
  if (credentials.issuer) fields.push(`issuer=${credentials.issuer}`);
  return `McpCredentials(${fields.join(', ')})`;
}

export class McpCredentialStore {
  private readonly storage: McpCredentialStorage;
  /** In-memory cache of the access half (keyed like the storage). Refresh tokens never enter the cache. */
  private readonly accessCache = new Map<string, McpAccessCredentials | null>();

  constructor(storage: McpCredentialStorage) {
    this.storage = storage;
  }

  /** Storage key: `uid:serverId`. The `uid` prefix keeps profile partitions apart. */
  static accessKey(serverId: string, uid: string): string {
    return `${uid}:${serverId}`;
  }

  static refreshKey(serverId: string, uid: string): string {
    return `${uid}:${serverId}:refresh`;
  }

  /** DCR registration: `uid:dcr:issuer`. */
  static registrationKey(issuer: string, uid: string): string {
    return `${uid}:dcr:${issuer}`;
  }

  /** Reads the access half (including issuer / clientId / resource / pastedToken), without the refresh token. */
  async load(serverId: string, uid: string): Promise<McpAccessCredentials | null> {
    const key = McpCredentialStore.accessKey(serverId, uid);
    if (this.accessCache.has(key)) return this.accessCache.get(key) ?? null;
    const raw = await this.storage.read(key);
    const parsed = raw ? parseAccess(raw) : null;
    this.accessCache.set(key, parsed);
    return parsed;
  }

  /**
   * Re-reads bypassing the memory cache (before refreshing a token, or after a change notification from
   * another tab). This page's cache cannot see a new token another tab wrote to storage.
   */
  async reload(serverId: string, uid: string): Promise<McpAccessCredentials | null> {
    this.accessCache.delete(McpCredentialStore.accessKey(serverId, uid));
    return this.load(serverId, uid);
  }

  /** Reads the refresh token only when a refresh is needed; the return value is not cached. */
  async loadRefreshToken(serverId: string, uid: string): Promise<string | null> {
    const raw = await this.storage.read(McpCredentialStore.refreshKey(serverId, uid));
    return raw && raw.length > 0 ? raw : null;
  }

  /**
   * Writes the whole set: one record for the access half and one for the refresh token (the old one is
   * deleted when there is no refresh token). Any failing step throws `McpCredentialPersistenceError`:
   * a token that was not stored must never be treated as persisted.
   */
  async save(credentials: McpCredentials, serverId: string, uid: string): Promise<void> {
    const key = McpCredentialStore.accessKey(serverId, uid);
    const refreshKey = McpCredentialStore.refreshKey(serverId, uid);
    const refreshToken = credentials.refreshToken ?? null;
    const access: McpAccessCredentials = {
      accessToken: credentials.accessToken ?? null,
      expiresAt: credentials.expiresAt ?? null,
      issuer: credentials.issuer ?? null,
      clientId: credentials.clientId ?? null,
      resource: credentials.resource ?? null,
      pastedToken: credentials.pastedToken ?? null,
      hasRefreshToken: Boolean(refreshToken),
    };
    this.accessCache.delete(key);
    try {
      if (refreshToken) await this.storage.write(refreshKey, refreshToken);
      else await this.storage.delete(refreshKey);
      await this.storage.write(key, JSON.stringify(access));
    } catch {
      throw new McpCredentialPersistenceError();
    }
    this.accessCache.set(key, access);
  }

  /** Deletes all credentials of a server when it is removed. Throws when deletion fails, so the caller can tell the user instead of silently leaving them behind. */
  async delete(serverId: string, uid: string): Promise<void> {
    const key = McpCredentialStore.accessKey(serverId, uid);
    this.accessCache.delete(key);
    try {
      await this.storage.delete(McpCredentialStore.refreshKey(serverId, uid));
      await this.storage.delete(key);
    } catch {
      throw new McpCredentialPersistenceError();
    }
  }

  async saveClientRegistration(registration: McpStoredClientRegistration, uid: string): Promise<void> {
    try {
      await this.storage.write(McpCredentialStore.registrationKey(registration.issuer, uid), JSON.stringify(registration));
    } catch {
      throw new McpCredentialPersistenceError();
    }
  }

  async loadClientRegistration(issuer: string, uid: string): Promise<McpStoredClientRegistration | null> {
    const raw = await this.storage.read(McpCredentialStore.registrationKey(issuer, uid));
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as Partial<McpStoredClientRegistration>;
      // Bound to the issuer: a record stored for a different issuer is not accepted.
      if (typeof parsed.clientId !== 'string' || parsed.issuer !== issuer || !Array.isArray(parsed.redirectUris)) return null;
      return { clientId: parsed.clientId, issuer: parsed.issuer, redirectUris: parsed.redirectUris.filter((u) => typeof u === 'string') };
    } catch {
      return null;
    }
  }

  /** Clears a registration the authorization server declared invalid. Does not throw on failure: a registration is not a token, the only consequence is one more rejection next time. */
  async deleteClientRegistration(issuer: string, uid: string): Promise<void> {
    try {
      await this.storage.delete(McpCredentialStore.registrationKey(issuer, uid));
    } catch {
      // See above.
    }
  }

  /**
   * Sweeps orphaned credentials: entries in storage whose server record no longer exists. The add flow
   * saves the record first and the credentials after, so credentials without a record can only be
   * leftovers (from a cleanup that did not finish, for example). DCR registrations are stored per issuer
   * and belong to no server, so they are left alone.
   *
   * **The credential keys are read first, the known servers second**: the other way round, a server that
   * another tab finishes adding between the two reads would have its fresh token deleted as an orphan.
   * An entry that cannot be deleted is left for next time rather than thrown. Returns the ids of the
   * servers that were cleared.
   */
  async deleteOrphans(uid: string, knownServerIds: () => Promise<Iterable<string>>): Promise<string[]> {
    const prefix = `${uid}:`;
    const candidates = new Set<string>();
    for (const key of await this.storage.keys()) {
      if (!key.startsWith(prefix)) continue;
      const rest = key.slice(prefix.length);
      if (rest.startsWith('dcr:')) continue;
      candidates.add(rest.endsWith(':refresh') ? rest.slice(0, -':refresh'.length) : rest);
    }
    if (candidates.size === 0) return [];
    const known = new Set(await knownServerIds());
    const removed: string[] = [];
    for (const serverId of candidates) {
      if (known.has(serverId)) continue;
      try {
        await this.delete(serverId, uid);
        removed.push(serverId);
      } catch {
        // Cleared on the next load.
      }
    }
    return removed;
  }

  /** Drops the memory cache (called when another tab has written to the same storage). */
  clearMemoryCache(): void {
    this.accessCache.clear();
  }
}

function parseAccess(raw: string): McpAccessCredentials | null {
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const str = (value: unknown) => (typeof value === 'string' && value.length > 0 ? value : null);
    return {
      accessToken: str(parsed.accessToken),
      expiresAt: typeof parsed.expiresAt === 'number' && Number.isFinite(parsed.expiresAt) ? parsed.expiresAt : null,
      issuer: str(parsed.issuer),
      clientId: str(parsed.clientId),
      resource: str(parsed.resource),
      pastedToken: str(parsed.pastedToken),
      hasRefreshToken: parsed.hasRefreshToken === true,
    };
  } catch {
    return null;
  }
}

/** In-memory medium for tests and for hosts without a persistence layer. */
export function createMemoryMcpCredentialStorage(): McpCredentialStorage & { snapshot(): Map<string, string> } {
  const map = new Map<string, string>();
  return {
    async read(key) {
      return map.get(key) ?? null;
    },
    async write(key, value) {
      map.set(key, value);
    },
    async delete(key) {
      map.delete(key);
    },
    async keys() {
      return [...map.keys()];
    },
    snapshot() {
      return new Map(map);
    },
  };
}

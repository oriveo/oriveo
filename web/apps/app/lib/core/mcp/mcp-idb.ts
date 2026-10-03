/**
 * Local persistence layer for remote MCP.
 *
 * Each profile partition has its own IndexedDB (`oriveo-mcp--<uid>`, the same approach as the image
 * store `oriveo-images--<uid>`), which leaves the main database's version untouched. It holds:
 * server records, tool snapshots, tool permissions, connection states, per-conversation switches,
 * per-step payloads and MCP credentials. Credentials are kept the way API keys are: local to the
 * browser, with the refresh token and the access token as two separate records (see
 * `McpCredentialStore` in `@oriveo/core/mcp`).
 *
 * Every function takes an explicit `uid` and never reads a "current partition", so a write that is
 * still in flight when the partition changes cannot land in another partition's database.
 */

import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import {
  McpServerLimitError,
  MCP_SERVER_SCHEMA_VERSION,
  uniqueSlug,
  type McpConnectionState,
  type McpCredentialStorage,
  type McpServerAddition,
  type McpServerRecord,
  type McpServerRepository,
  type McpToolPermission,
  type McpToolSnapshot,
} from '@oriveo/core/mcp/index';
import { getMcpDBName } from '../../infra/storage/partition';

export { getMcpDBName };

export const MCP_DB_VERSION = 1;

/** A server record as stored. */
export interface McpStoredServer extends McpServerRecord {
  /**
   * The add flow has persisted the record, but the user has not yet pressed "done" on the "review
   * default permissions" step. Such a record is half-finished and other tabs do not show it.
   * Pressing "done" clears this bit; abandoning the flow, or closing the page before that, removes
   * the whole record (a failed add never leaves half a server behind). Absent means confirmed.
   */
  pendingAdd?: boolean;
}

export interface McpStoredPermission {
  serverId: string;
  toolName: string;
  permission: McpToolPermission;
}

export interface McpConversationSwitch {
  conversationId: string;
  serverId: string;
  enabledAt: number;
}

export interface McpStepPayload {
  messageId: string;
  stepId: string;
  /** The server that executed this step and its conversation, used for cascading deletes. */
  serverId: string;
  conversationId: string;
  arguments: string | null;
  resultPrefix: string | null;
  createdAt: number;
}

interface McpDBSchema extends DBSchema {
  servers: { key: string; value: McpStoredServer };
  toolSnapshots: { key: [string, string]; value: McpToolSnapshot; indexes: { 'by-server': string } };
  toolPermissions: { key: [string, string]; value: McpStoredPermission; indexes: { 'by-server': string } };
  connectionStates: { key: string; value: McpConnectionState };
  conversationSwitches: {
    key: [string, string];
    value: McpConversationSwitch;
    indexes: { 'by-server': string; 'by-conversation': string };
  };
  stepPayloads: { key: [string, string]; value: McpStepPayload; indexes: { 'by-server': string; 'by-conversation': string } };
  credentials: { key: string; value: string };
}

type McpDB = IDBPDatabase<McpDBSchema>;

const connections = new Map<string, Promise<McpDB>>();

export function openMcpDB(uid: string): Promise<McpDB> {
  const cached = connections.get(uid);
  if (cached) return cached;
  const name = getMcpDBName(uid);
  let opened: McpDB | null = null;
  const promise = openDB<McpDBSchema>(name, MCP_DB_VERSION, {
    upgrade(db, oldVersion) {
      if (oldVersion < 1) {
        db.createObjectStore('servers', { keyPath: 'id' });
        db.createObjectStore('toolSnapshots', { keyPath: ['serverId', 'toolName'] }).createIndex('by-server', 'serverId');
        db.createObjectStore('toolPermissions', { keyPath: ['serverId', 'toolName'] }).createIndex('by-server', 'serverId');
        db.createObjectStore('connectionStates', { keyPath: 'serverId' });
        const switches = db.createObjectStore('conversationSwitches', { keyPath: ['conversationId', 'serverId'] });
        switches.createIndex('by-server', 'serverId');
        switches.createIndex('by-conversation', 'conversationId');
        const payloads = db.createObjectStore('stepPayloads', { keyPath: ['messageId', 'stepId'] });
        payloads.createIndex('by-server', 'serverId');
        payloads.createIndex('by-conversation', 'conversationId');
        db.createObjectStore('credentials');
      }
    },
    // Another tab wants to upgrade: get out of the way and drop the cache, reopening at the new version next time.
    blocking: () => {
      opened?.close();
      connections.delete(uid);
    },
  }).then((db) => {
    opened = db;
    return db;
  });
  promise.catch(() => connections.delete(uid));
  connections.set(uid, promise);
  return promise;
}

/** Closes and discards a partition's connection (called before deleting the database and between tests). */
export async function closeMcpDB(uid: string): Promise<void> {
  const cached = connections.get(uid);
  connections.delete(uid);
  if (cached) (await cached.catch(() => null))?.close();
}

function toRecord(stored: McpStoredServer): McpServerRecord {
  const { pendingAdd: _draft, ...record } = stored;
  return record;
}

const SERVER_STORES = ['servers', 'toolSnapshots', 'toolPermissions', 'connectionStates', 'conversationSwitches', 'stepPayloads'] as const;

// ── Reads ───────────────────────────────────────────────────────────────

export interface McpLocalSnapshot {
  servers: McpStoredServer[];
  snapshots: Record<string, McpToolSnapshot[]>;
  permissions: Record<string, Record<string, McpToolPermission>>;
  connections: Record<string, McpConnectionState>;
  switches: Record<string, string[]>;
}

/** Reads a partition's entire local MCP state in one go (for store hydration). */
export async function loadMcpLocalState(uid: string): Promise<McpLocalSnapshot> {
  const db = await openMcpDB(uid);
  const tx = db.transaction(['servers', 'toolSnapshots', 'toolPermissions', 'connectionStates', 'conversationSwitches'], 'readonly');
  const [servers, snapshots, permissions, connectionRows, switches] = await Promise.all([
    tx.objectStore('servers').getAll(),
    tx.objectStore('toolSnapshots').getAll(),
    tx.objectStore('toolPermissions').getAll(),
    tx.objectStore('connectionStates').getAll(),
    tx.objectStore('conversationSwitches').getAll(),
  ]);
  await tx.done;
  const result: McpLocalSnapshot = { servers: sortServers(servers), snapshots: {}, permissions: {}, connections: {}, switches: {} };
  for (const snapshot of snapshots) (result.snapshots[snapshot.serverId] ??= []).push(snapshot);
  for (const row of permissions) (result.permissions[row.serverId] ??= {})[row.toolName] = row.permission;
  for (const row of connectionRows) result.connections[row.serverId] = row;
  for (const row of switches.sort((a, b) => a.enabledAt - b.enabledAt)) (result.switches[row.conversationId] ??= []).push(row.serverId);
  return result;
}

function sortServers(servers: McpStoredServer[]): McpStoredServer[] {
  return servers.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
}

/** Half-finished additions not yet confirmed (hydration cleans up the abandoned ones). */
export async function pendingMcpServerAdds(uid: string): Promise<Array<{ id: string; createdAt: number }>> {
  return (await (await openMcpDB(uid)).getAll('servers'))
    .filter((server) => server.pendingAdd)
    .map((server) => ({ id: server.id, createdAt: server.createdAt }));
}

/** The user pressed "done": from now on the record is a regular server, visible to other tabs. Returns false when the row is gone. */
export async function confirmMcpServerAdded(uid: string, id: string): Promise<boolean> {
  const db = await openMcpDB(uid);
  const tx = db.transaction('servers', 'readwrite');
  const current = await tx.store.get(id);
  if (current?.pendingAdd) {
    const { pendingAdd: _draft, ...confirmed } = current;
    await tx.store.put(confirmed);
  }
  await tx.done;
  return current !== undefined;
}

// ── Add / update / remove (McpServerRepository) ─────────────────────────

/**
 * `awaitingConfirmation` is for the add flow: the persisted record carries `pendingAdd` and only
 * becomes a regular server once the user presses "done".
 */
export function createIdbMcpServerRepository(uid: string, options: { awaitingConfirmation?: boolean } = {}): McpServerRepository {
  return {
    async hasServer(id) {
      return (await (await openMcpDB(uid)).getKey('servers', id)) !== undefined;
    },
    async serverCount() {
      return (await openMcpDB(uid)).count('servers');
    },
    async addServer(addition: McpServerAddition, maxServers: number) {
      const db = await openMcpDB(uid);
      const tx = db.transaction(SERVER_STORES, 'readwrite');
      const servers = tx.objectStore('servers');
      try {
        if ((await servers.getKey(addition.id)) !== undefined) throw new Error('MCP server id already exists');
        const existing = await servers.getAll();
        if (existing.length >= maxServers) throw new McpServerLimitError(maxServers);
        const record: McpStoredServer = {
          id: addition.id,
          name: addition.name,
          // The uniqueness check and the insert share one write transaction.
          slug: uniqueSlug(addition.name, existing.map((server) => server.slug)),
          url: addition.url,
          authKind: addition.authKind,
          iconURL: addition.iconURL,
          createdAt: addition.createdAt,
          updatedAt: addition.createdAt,
          schemaVersion: MCP_SERVER_SCHEMA_VERSION,
          ...(options.awaitingConfirmation ? { pendingAdd: true } : {}),
        };
        await servers.add(record);
        for (const snapshot of addition.snapshots) await tx.objectStore('toolSnapshots').put(snapshot);
        for (const [toolName, permission] of Object.entries(addition.permissions)) {
          await tx.objectStore('toolPermissions').put({ serverId: addition.id, toolName, permission });
        }
        await tx.objectStore('connectionStates').put(addition.connectionState);
        await tx.done;
        return toRecord(record);
      } catch (error) {
        try {
          tx.abort();
        } catch {
          // A transaction that has already finished cannot be aborted.
        }
        await tx.done.catch(() => {});
        throw error;
      }
    },
    deleteServer: (id) => removeMcpServer(uid, id),
  };
}

/**
 * Deletes every local row of a server in one transaction: record, connection state, snapshots,
 * permissions, conversation switches, and the payloads of the steps it executed. Step summaries on
 * messages stay (tool records in existing conversations are kept); raw arguments and results are
 * this server's data and go with it. Credentials are deleted by the caller beforehand.
 */
export async function removeMcpServer(uid: string, id: string): Promise<void> {
  const db = await openMcpDB(uid);
  const tx = db.transaction(SERVER_STORES, 'readwrite');
  await tx.objectStore('servers').delete(id);
  await tx.objectStore('connectionStates').delete(id);
  for (const store of ['toolSnapshots', 'toolPermissions', 'conversationSwitches', 'stepPayloads'] as const) {
    const index = tx.objectStore(store).index('by-server');
    for (const key of await index.getAllKeys(id)) await tx.objectStore(store).delete(key);
  }
  await tx.done;
}

/** Edits a server record (name, sign-in method, icon). The slug and URL never change after creation. */
export async function updateMcpServer(
  uid: string,
  id: string,
  patch: Partial<Pick<McpServerRecord, 'name' | 'authKind' | 'iconURL'>>,
  now: number = Date.now(),
): Promise<McpStoredServer | null> {
  const db = await openMcpDB(uid);
  const tx = db.transaction('servers', 'readwrite');
  const current = await tx.store.get(id);
  if (!current) {
    await tx.done;
    return null;
  }
  const next: McpStoredServer = { ...current, ...patch, updatedAt: now };
  await tx.store.put(next);
  await tx.done;
  return next;
}

// ── Device-local state ──────────────────────────────────────────────────

export async function saveMcpConnectionState(uid: string, state: McpConnectionState): Promise<void> {
  const db = await openMcpDB(uid);
  // Do not resurrect an orphaned connection state for a server that has been removed.
  const tx = db.transaction(['servers', 'connectionStates'], 'readwrite');
  if ((await tx.objectStore('servers').getKey(state.serverId)) !== undefined) await tx.objectStore('connectionStates').put(state);
  await tx.done;
}

/** Replaces tool snapshots and permissions wholesale in one transaction (confirming changes, refreshing the tool list). */
export async function saveMcpToolCatalog(
  uid: string,
  serverId: string,
  snapshots: McpToolSnapshot[],
  permissions: Record<string, McpToolPermission>,
): Promise<void> {
  const db = await openMcpDB(uid);
  const tx = db.transaction(['servers', 'toolSnapshots', 'toolPermissions'], 'readwrite');
  if ((await tx.objectStore('servers').getKey(serverId)) === undefined) {
    await tx.done;
    return;
  }
  for (const store of ['toolSnapshots', 'toolPermissions'] as const) {
    const index = tx.objectStore(store).index('by-server');
    for (const key of await index.getAllKeys(serverId)) await tx.objectStore(store).delete(key);
  }
  for (const snapshot of snapshots) await tx.objectStore('toolSnapshots').put({ ...snapshot, serverId });
  for (const [toolName, permission] of Object.entries(permissions)) {
    await tx.objectStore('toolPermissions').put({ serverId, toolName, permission });
  }
  await tx.done;
}

export async function setMcpToolPermission(uid: string, serverId: string, toolName: string, permission: McpToolPermission): Promise<void> {
  const db = await openMcpDB(uid);
  const tx = db.transaction(['servers', 'toolPermissions'], 'readwrite');
  if ((await tx.objectStore('servers').getKey(serverId)) !== undefined) {
    await tx.objectStore('toolPermissions').put({ serverId, toolName, permission });
  }
  await tx.done;
}

export async function setMcpServerEnabled(uid: string, conversationId: string, serverId: string, enabled: boolean, now: number = Date.now()): Promise<void> {
  const db = await openMcpDB(uid);
  const tx = db.transaction(['servers', 'conversationSwitches'], 'readwrite');
  const switches = tx.objectStore('conversationSwitches');
  if (enabled) {
    if ((await tx.objectStore('servers').getKey(serverId)) !== undefined && !(await switches.getKey([conversationId, serverId]))) {
      await switches.put({ conversationId, serverId, enabledAt: now });
    }
  } else {
    await switches.delete([conversationId, serverId]);
  }
  await tx.done;
}

/** Clears a conversation's switches when it is deleted. */
export async function clearMcpConversationSwitches(uid: string, conversationId: string): Promise<void> {
  const db = await openMcpDB(uid);
  const tx = db.transaction('conversationSwitches', 'readwrite');
  for (const key of await tx.store.index('by-conversation').getAllKeys(conversationId)) await tx.store.delete(key);
  await tx.done;
}

/**
 * A new conversation sent its first message and got its real id: move the servers enabled under
 * the draft scope over to that conversation. Servers already enabled there are not added twice.
 * Returns the ids of the servers moved, in the order they were enabled.
 */
export async function moveMcpConversationSwitches(uid: string, fromConversationId: string, toConversationId: string, now: number = Date.now()): Promise<string[]> {
  if (fromConversationId === toConversationId) return [];
  const db = await openMcpDB(uid);
  const tx = db.transaction('conversationSwitches', 'readwrite');
  const index = tx.store.index('by-conversation');
  const rows = (await index.getAll(fromConversationId)).sort((a, b) => a.enabledAt - b.enabledAt);
  const moved: string[] = [];
  for (const [offset, row] of rows.entries()) {
    await tx.store.delete([fromConversationId, row.serverId]);
    if (await tx.store.getKey([toConversationId, row.serverId])) continue;
    // Keep the original order; timestamps are no earlier than existing ones, so these sort after what the target conversation already has enabled.
    await tx.store.put({ conversationId: toConversationId, serverId: row.serverId, enabledAt: Math.max(row.enabledAt, now) + offset });
    moved.push(row.serverId);
  }
  await tx.done;
  return moved;
}

// ── Step payloads (raw arguments up to 16 KB, first 2 KB of the result) ──

export const MCP_STEP_ARGUMENTS_MAX_BYTES = 16 * 1024;
export const MCP_STEP_RESULT_PREFIX_MAX_BYTES = 2 * 1024;

/** Truncates by UTF-8 bytes without splitting a multi-byte character. */
export function capUtf8(text: string | null, maxBytes: number): string | null {
  if (text === null) return null;
  const encoder = new TextEncoder();
  if (encoder.encode(text).length <= maxBytes) return text;
  let result = '';
  let bytes = 0;
  for (const char of text) {
    const size = encoder.encode(char).length;
    if (bytes + size > maxBytes) break;
    result += char;
    bytes += size;
  }
  return result;
}

export async function saveMcpStepPayload(
  uid: string,
  payload: { messageId: string; stepId: string; serverId: string; conversationId: string; arguments: string | null; resultPrefix: string | null },
  now: number = Date.now(),
): Promise<void> {
  await (await openMcpDB(uid)).put('stepPayloads', {
    messageId: payload.messageId,
    stepId: payload.stepId,
    serverId: payload.serverId,
    conversationId: payload.conversationId,
    arguments: capUtf8(payload.arguments, MCP_STEP_ARGUMENTS_MAX_BYTES),
    resultPrefix: capUtf8(payload.resultPrefix, MCP_STEP_RESULT_PREFIX_MAX_BYTES),
    createdAt: now,
  });
}

export async function fetchMcpStepPayload(uid: string, messageId: string, stepId: string): Promise<McpStepPayload | null> {
  return (await (await openMcpDB(uid)).get('stepPayloads', [messageId, stepId])) ?? null;
}

/** Clears a message's step payloads when it is deleted (the primary key is prefixed with the message id, so no index is needed). */
export async function deleteMcpStepPayloadsForMessage(uid: string, messageId: string): Promise<void> {
  // `[messageId]` is the lower bound of every `[messageId, stepId]` and `[messageId, []]` the upper bound (an array key sorts after any string).
  await (await openMcpDB(uid)).delete('stepPayloads', IDBKeyRange.bound([messageId], [messageId, []]));
}

/** Clears a conversation's step payloads when it is deleted. */
export async function deleteMcpStepPayloadsForConversation(uid: string, conversationId: string): Promise<void> {
  const db = await openMcpDB(uid);
  const tx = db.transaction('stepPayloads', 'readwrite');
  for (const key of await tx.store.index('by-conversation').getAllKeys(conversationId)) await tx.store.delete(key);
  await tx.done;
}

// ── Credential storage ──────────────────────────────────────────────────

/** Browser storage backend for `McpCredentialStore`: the `credentials` store of this partition's database. Write failures are thrown as usual. */
export function createIdbMcpCredentialStorage(uid: string): McpCredentialStorage {
  return {
    async read(key) {
      return (await (await openMcpDB(uid)).get('credentials', key)) ?? null;
    },
    async write(key, value) {
      await (await openMcpDB(uid)).put('credentials', value, key);
    },
    async delete(key) {
      await (await openMcpDB(uid)).delete('credentials', key);
    },
  };
}

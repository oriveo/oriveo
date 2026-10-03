/**
 * The application-layer store (Zustand) and runtime assembly for remote MCP. The UI and the chat
 * integration reach MCP only through here.
 *
 * - **Persistence**: one IndexedDB per profile partition (`mcp-idb.ts`). Writes go to the database
 *   first (multi-store writes in a single transaction) and only then update memory, so the
 *   in-memory state is always a projection of the database; switching partitions re-reads it all.
 * - **Credentials**: `McpCredentialStore` is backed by the `credentials` store of this partition's
 *   database, with access and refresh tokens as two records and only the access half cached in
 *   memory. Like API keys, they never leave the browser.
 */

import { create } from 'zustand';
import {
  MCP_RUNTIME_CONFIG_FALLBACK,
  McpAddCoordinator,
  McpAddProbe,
  McpAuthorizer,
  McpClient,
  McpCredentialStore,
  type McpAddProgress,
  type McpAddState,
  type McpAuthKind,
  type McpAuthorizationGate,
  type McpAuthorizationLauncher,
  type McpConnectionState,
  type McpRuntimeConfig,
  type McpServerRecord,
  type McpToolPermission,
  type McpToolSnapshot,
  type McpTransport,
} from '@oriveo/core/mcp/index';
import {
  browserMcpClientIdentity,
  browserMcpRandom,
  browserMcpRefreshLock,
  createBrowserMcpAuthorizationLauncher,
  createBrowserMcpTransport,
} from './browser-mcp-runtime';
import {
  confirmMcpServerAdded,
  createIdbMcpCredentialStorage,
  createIdbMcpServerRepository,
  clearMcpConversationSwitches,
  deleteMcpStepPayloadsForConversation,
  deleteMcpStepPayloadsForMessage,
  loadMcpLocalState,
  moveMcpConversationSwitches,
  pendingMcpServerAdds,
  removeMcpServer as removeMcpServerRows,
  saveMcpConnectionState,
  saveMcpToolCatalog,
  setMcpServerEnabled,
  setMcpToolPermission,
  updateMcpServer,
} from './mcp-idb';
import { getMcpRuntimeConfig } from '../metadata/metadata-client';
import { mcpConversationGrants } from './mcp-confirmation';

// ── Runtime assembly (cached per partition) ─────────────────────────────

let sharedTransport: McpTransport | null = null;
const credentialStores = new Map<string, McpCredentialStore>();

/** The browser transport (public servers via /api/mcp/forward, private ones directly). Tests can replace it with `__setMcpTransportForTests`. */
export function getMcpTransport(): McpTransport {
  sharedTransport ??= createBrowserMcpTransport();
  return sharedTransport;
}

export function __setMcpTransportForTests(transport: McpTransport | null): void {
  sharedTransport = transport;
  // Authorizers hold the transport, so replacing it means rebuilding them.
  authorizers.clear();
}

/** The credential store of this partition (one instance shared by the authorizer, the add flow and removal). */
export function getMcpCredentialStore(uid: string): McpCredentialStore {
  let store = credentialStores.get(uid);
  if (!store) {
    const storage = createIdbMcpCredentialStorage(uid);
    store = new McpCredentialStore({
      read: (key) => storage.read(key),
      keys: () => storage.keys(),
      // Credentials were written to the database: the half other tabs cache in memory is now stale, so tell them to drop it.
      async write(key, value) {
        await storage.write(key, value);
        announceMcpLocalWrite(uid);
      },
      async delete(key) {
        await storage.delete(key);
        announceMcpLocalWrite(uid);
      },
    });
    credentialStores.set(uid, store);
  }
  return store;
}

// ── Cross-tab invalidation ──────────────────────────────────────────────
//
// Several tabs of the same browser share one IndexedDB, yet each has its own in-memory
// projection (store) and credential cache. After one tab removes a server, changes a permission or
// signs in again, another tab would keep sending requests from its stale memory: tools of a removed
// server still handed to the model, a tool switched to "ask every time" still running on its own.
// So every database write is followed by a broadcast, and other tabs drop their credential cache
// and re-read from the database. Environments without BroadcastChannel do not broadcast (there,
// only the next load picks up the change).

export const MCP_STORE_CHANNEL = 'oriveo:mcp-store';

interface McpStoreChangedMessage {
  type: 'oriveo:mcp-store-changed';
  uid: string;
}

let storeChannel: BroadcastChannel | null | undefined;
const pendingAnnouncements = new Set<string>();

function mcpStoreChannel(): BroadcastChannel | null {
  if (storeChannel !== undefined) return storeChannel;
  if (typeof BroadcastChannel === 'undefined') {
    storeChannel = null;
    return storeChannel;
  }
  try {
    const channel = new BroadcastChannel(MCP_STORE_CHANNEL);
    channel.addEventListener('message', (event: MessageEvent) => {
      const data = event.data as Partial<McpStoreChangedMessage> | null;
      if (!data || data.type !== 'oriveo:mcp-store-changed' || typeof data.uid !== 'string') return;
      // Another tab wrote this partition's database: the cached access token may have been replaced or deleted.
      credentialStores.get(data.uid)?.clearMemoryCache();
      const before = useMcpStore.getState();
      if (before.uid !== data.uid) return;
      void before
        .reload()
        .then(() => revokeGrantsInvalidatedBy(before, useMcpStore.getState()))
        .catch(() => {});
    });
    storeChannel = channel;
  } catch {
    storeChannel = null;
  }
  return storeChannel;
}

/**
 * After another tab changes the database, this page's in-memory "allow for this conversation"
 * grants must be revoked accordingly: all of a server's grants when the server is gone, and a
 * single tool's grant when the tool is gone, back in quarantine, changed in content or title, or
 * has a different permission (the same rules as when this page makes the change itself).
 */
function revokeGrantsInvalidatedBy(
  before: Pick<McpStoreState, 'servers' | 'snapshots' | 'permissions'>,
  after: Pick<McpStoreState, 'servers' | 'snapshots' | 'permissions'>,
): void {
  const remaining = new Set(after.servers.map((server) => server.id));
  for (const server of before.servers) {
    if (!remaining.has(server.id)) {
      mcpConversationGrants.revokeServer(server.id);
      continue;
    }
    const incoming = new Map((after.snapshots[server.id] ?? []).map((snapshot) => [snapshot.toolName, snapshot]));
    for (const previous of before.snapshots[server.id] ?? []) {
      const next = incoming.get(previous.toolName);
      const unchanged =
        next !== undefined &&
        !next.pendingReview &&
        next.contentHash === previous.contentHash &&
        next.title === previous.title &&
        after.permissions[server.id]?.[previous.toolName] === before.permissions[server.id]?.[previous.toolName];
      if (!unchanged) mcpConversationGrants.revokeTool(server.id, previous.toolName);
    }
  }
}

/** This page wrote the MCP database of partition `uid`. Multiple writes in the same tick are merged into one broadcast. */
function announceMcpLocalWrite(uid: string): void {
  if (pendingAnnouncements.has(uid)) return;
  pendingAnnouncements.add(uid);
  queueMicrotask(() => {
    pendingAnnouncements.delete(uid);
    try {
      mcpStoreChannel()?.postMessage({ type: 'oriveo:mcp-store-changed', uid } satisfies McpStoreChangedMessage);
    } catch {
      // The channel is closed: other tabs read the new state on their next load anyway.
    }
  });
}

const authorizers = new Map<string, McpAuthorizer>();

/**
 * The authorizer of this partition, **one per partition**. The table that serializes concurrent
 * refreshes is an instance field of the authorizer: if every call site created its own, the chat
 * loop and the management page would each send a refresh when both notice the token expiring, a
 * server that rotates refresh tokens would answer the later one with `invalid_grant`, and a
 * perfectly good sign-in would be wiped. Across tabs, `browserMcpRefreshLock` continues the
 * serialization. The authorization window is not held here: each sign-in opens its own, passed per
 * call through `authorize(..., { launcher })`.
 */
export function getMcpAuthorizer(uid: string): McpAuthorizer {
  let authorizer = authorizers.get(uid);
  if (!authorizer) {
    authorizer = new McpAuthorizer({
      transport: getMcpTransport(),
      credentialStore: getMcpCredentialStore(uid),
      random: browserMcpRandom,
      identity: browserMcpClientIdentity(),
      refreshLock: browserMcpRefreshLock,
    });
    authorizers.set(uid, authorizer);
  }
  return authorizer;
}

/** Builds a protocol client for a saved server (for the chat integration); the caller gets the token through the authorizer. */
export function createMcpClient(endpoint: string, runtimeConfig: McpRuntimeConfig = getMcpRuntimeConfig()): McpClient {
  return new McpClient({ endpoint, transport: getMcpTransport(), runtimeConfig });
}

function randomServerId(): string {
  return globalThis.crypto.randomUUID().toLowerCase();
}

// ── Half-finished additions ─────────────────────────────────────────────
//
// The record is persisted as soon as the probe succeeds, but it only counts once the user presses
// "done" on the "review default permissions" step (`pendingAdd`). If the page is closed or reloaded
// before that, the dialog's cleanup code never runs and the record is left half-finished with
// nobody looking after it, so the next hydration removes it. Whether somebody still looks after it
// is decided with a Web Lock: the tab doing the add holds `mcp-add:<uid>:<serverId>` from the start
// of the flow, and the browser releases it the moment the page closes. Browsers without
// `navigator.locks` can only go by age.

type WebLocks = { request(name: string, options: { mode?: 'exclusive'; ifAvailable?: boolean }, callback: (lock: unknown) => Promise<unknown>): Promise<unknown> };

function webLocks(): WebLocks | null {
  const locks = typeof navigator !== 'undefined' ? (navigator as Navigator & { locks?: WebLocks }).locks : undefined;
  return locks?.request ? locks : null;
}

/** Without Web Locks, how old a half-finished addition must be before it counts as abandoned (another tab may be sitting on the permission review step). */
export const MCP_ABANDONED_ADD_GRACE_MS = 30 * 60_000;

/** Additions in progress on this page: `uid:serverId` -> release function. */
const addHolds = new Map<string, () => void>();
const addHoldKey = (uid: string, serverId: string) => `${uid}:${serverId}`;

function holdMcpAdd(uid: string, serverId: string): void {
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  const key = addHoldKey(uid, serverId);
  addHolds.set(key, () => {
    addHolds.delete(key);
    release();
  });
  void webLocks()?.request(`mcp-add:${uid}:${serverId}`, { mode: 'exclusive' }, () => held).catch(() => {});
}

function releaseMcpAdd(uid: string, serverId: string): void {
  addHolds.get(addHoldKey(uid, serverId))?.();
}

/** Removes abandoned half-finished additions: record, local state and credentials. Ones still being added by this page or another tab are left alone. */
async function discardAbandonedMcpAdds(uid: string, now: number = Date.now()): Promise<void> {
  for (const row of await pendingMcpServerAdds(uid)) {
    if (addHolds.has(addHoldKey(uid, row.id))) continue;
    const purge = async () => {
      await getMcpCredentialStore(uid).delete(row.id, uid);
      await removeMcpServerRows(uid, row.id);
    };
    const locks = webLocks();
    if (locks) {
      await locks.request(`mcp-add:${uid}:${row.id}`, { ifAvailable: true }, async (lock) => {
        if (lock) await purge();
      });
    } else if (now - row.createdAt >= MCP_ABANDONED_ADD_GRACE_MS) {
      await purge();
    }
  }
}

/**
 * Removes credentials that have no server record. The add flow saves the record first and the token
 * after, so normally there are none; this catches what an interrupted cleanup left behind. Additions
 * in progress (held by this page, or parked on the permission review step in another tab) already
 * have a record carrying `pendingAdd` and count as known servers.
 */
async function discardOrphanMcpCredentials(uid: string): Promise<void> {
  await getMcpCredentialStore(uid).deleteOrphans(uid, async () => {
    const ids = (await loadMcpLocalState(uid)).servers.map((server) => server.id);
    for (const key of addHolds.keys()) if (key.startsWith(`${uid}:`)) ids.push(key.slice(uid.length + 1));
    return ids;
  });
}

// ── store ────────────────────────────────────────────────────────────────

export interface McpAddServerInput {
  url: string;
  name?: string;
  authKind: McpAuthKind;
  token?: string | null;
  /** The pre-sign-in gate. Omitting it means the user did not consent. */
  confirmAuthorization?: McpAuthorizationGate;
  progress?: McpAddProgress;
  signal?: AbortSignal;
  /** Test injection; production uses a new window plus BroadcastChannel. */
  launcher?: McpAuthorizationLauncher;
}

export interface McpStoreState {
  /** The partition currently projected; null before hydration. */
  uid: string | null;
  hydrated: boolean;
  servers: McpServerRecord[];
  snapshots: Record<string, McpToolSnapshot[]>;
  permissions: Record<string, Record<string, McpToolPermission>>;
  connections: Record<string, McpConnectionState>;
  /** Conversation id -> ids of the enabled servers (in the order they were enabled). */
  conversationServers: Record<string, string[]>;

  hydrate(uid: string): Promise<void>;
  /** Re-reads the current partition from the database (called after another tab has written to it). */
  reload(): Promise<void>;
  reset(): void;
  /** The add flow (probe, persist, one terminal state). In-progress states are delivered through the `progress` callback. */
  addServer(input: McpAddServerInput): Promise<McpAddState>;
  /** The user pressed "done" on the default-permissions review: the half-finished record becomes a regular server. */
  confirmServerAdded(id: string): Promise<void>;
  updateServer(id: string, patch: Partial<Pick<McpServerRecord, 'name' | 'authKind' | 'iconURL'>>): Promise<void>;
  /** Removal: delete the credentials first (a failure throws and leaves the record as is), then delete the record and cascade its local state. */
  removeServer(id: string): Promise<void>;
  setToolPermission(serverId: string, toolName: string, permission: McpToolPermission): Promise<void>;
  saveToolCatalog(serverId: string, snapshots: McpToolSnapshot[], permissions: Record<string, McpToolPermission>): Promise<void>;
  saveConnectionState(state: McpConnectionState): Promise<void>;
  /**
   * Per-conversation switch. `conversationId` is the conversation id;
   * a new conversation that has no id yet uses the draft scope (`mcpDraftScope`), and
   * `adoptDraftServers` moves it under the real id once the first message is sent.
   */
  setServerEnabled(conversationId: string, serverId: string, enabled: boolean): Promise<void>;
  /** Moves the servers enabled under the draft scope to the newly created conversation. */
  adoptDraftServers(draftScope: string, conversationId: string): Promise<void>;
  /** Clears a conversation's switches when it is deleted. */
  clearConversation(conversationId: string): Promise<void>;
}

/** The switch scope of a new conversation that has no id yet. Uses the same draft session id as the generation-parameter draft. */
export function mcpDraftScope(draftSessionId: string): string {
  return `draft:${draftSessionId}`;
}

const EMPTY = {
  uid: null,
  hydrated: false,
  servers: [],
  snapshots: {},
  permissions: {},
  connections: {},
  conversationServers: {},
} satisfies Partial<McpStoreState>;

let hydrateGeneration = 0;

function requireUid(uid: string | null): string {
  if (!uid) throw new Error('MCP store is not hydrated');
  return uid;
}

export const useMcpStore = create<McpStoreState>((set, get) => {
  const project = async (uid: string) => {
    const generation = ++hydrateGeneration;
    const local = await loadMcpLocalState(uid);
    // A partition switch can outrun the database read: a stale result must not reach memory.
    if (generation !== hydrateGeneration) return;
    set({
      uid,
      hydrated: true,
      // Hide half-finished additions other tabs are working on, but show the one this page is adding
      // (the permission review step reads its tools).
      servers: local.servers
        .filter((server) => !server.pendingAdd || addHolds.has(addHoldKey(uid, server.id)))
        .map(({ pendingAdd: _draft, ...record }) => record),
      snapshots: local.snapshots,
      permissions: local.permissions,
      connections: local.connections,
      conversationServers: local.switches,
    });
  };

  return {
    ...EMPTY,

    async hydrate(uid) {
      if (get().uid !== uid) {
        set({ ...EMPTY });
        // The partition changed: "allow for this conversation" grants given under the previous one are not carried over.
        mcpConversationGrants.revokeAll();
      }
      // Start listening for change notifications from other tabs.
      mcpStoreChannel();
      // A failed cleanup does not block hydration: half-finished additions are left for next time.
      await discardAbandonedMcpAdds(uid).catch(() => {});
      await discardOrphanMcpCredentials(uid).catch(() => {});
      await project(uid);
    },

    async reload() {
      const uid = get().uid;
      if (uid) await project(uid);
    },

    reset() {
      hydrateGeneration += 1;
      set({ ...EMPTY });
    },

    async addServer(input) {
      const uid = requireUid(get().uid);
      const runtimeConfig = getMcpRuntimeConfig();
      const credentialStore = getMcpCredentialStore(uid);
      const transport = getMcpTransport();
      const authorizer = getMcpAuthorizer(uid);
      const coordinator = new McpAddCoordinator({
        probe: new McpAddProbe({ runtimeConfig, authorizer, credentialStore, transport }),
        repository: createIdbMcpServerRepository(uid, { awaitingConfirmation: true }),
        credentialStore,
        runtimeConfig,
      });
      const serverId = randomServerId();
      holdMcpAdd(uid, serverId);
      const state = await coordinator.add({
        url: input.url,
        name: input.name,
        authKind: input.authKind,
        token: input.token,
        uid,
        serverId,
        confirmAuthorization: input.confirmAuthorization,
        launcher: input.launcher ?? createBrowserMcpAuthorizationLauncher(),
        progress: input.progress,
        signal: input.signal,
      });
      // An outcome that persisted nothing no longer needs the hold; a persisted one keeps it until the
      // user presses "done" or abandons the flow.
      if (state.kind !== 'review') releaseMcpAdd(uid, serverId);
      else if (get().uid === uid) await project(uid);
      return state;
    },

    async confirmServerAdded(id) {
      const uid = requireUid(get().uid);
      const exists = await confirmMcpServerAdded(uid, id);
      releaseMcpAdd(uid, id);
      if (exists) announceMcpLocalWrite(uid);
    },

    async updateServer(id, patch) {
      const uid = requireUid(get().uid);
      const updated = await updateMcpServer(uid, id, patch);
      if (updated) announceMcpLocalWrite(uid);
      if (!updated || get().uid !== uid) return;
      set({ servers: get().servers.map((server) => (server.id === id ? { ...server, ...patch, updatedAt: updated.updatedAt } : server)) });
    },

    async removeServer(id) {
      const uid = requireUid(get().uid);
      // Credentials first, then the record: if the credentials cannot be deleted this throws and the
      // record stays so the user can retry. The other way round, with the record gone and the token
      // still there, nothing would be left to clear it from.
      await getMcpCredentialStore(uid).delete(id, uid);
      await removeMcpServerRows(uid, id);
      releaseMcpAdd(uid, id);
      announceMcpLocalWrite(uid);
      mcpConversationGrants.revokeServer(id);
      if (get().uid === uid) {
        const state = get();
        const omit = <T,>(record: Record<string, T>) => Object.fromEntries(Object.entries(record).filter(([key]) => key !== id));
        set({
          servers: state.servers.filter((server) => server.id !== id),
          snapshots: omit(state.snapshots),
          permissions: omit(state.permissions),
          connections: omit(state.connections),
          conversationServers: Object.fromEntries(
            Object.entries(state.conversationServers).map(([conversationId, ids]) => [conversationId, ids.filter((serverId) => serverId !== id)]),
          ),
        });
      }
    },

    async setToolPermission(serverId, toolName, permission) {
      const uid = requireUid(get().uid);
      await setMcpToolPermission(uid, serverId, toolName, permission);
      announceMcpLocalWrite(uid);
      // The user changed this tool's permission by hand, so earlier "allow for this conversation"
      // grants no longer hold (they live only in memory; without revoking, a conversation would
      // still not ask after the tool was switched to "ask every time").
      mcpConversationGrants.revokeTool(serverId, toolName);
      if (get().uid !== uid || !get().servers.some((server) => server.id === serverId)) return;
      const permissions = get().permissions;
      set({ permissions: { ...permissions, [serverId]: { ...(permissions[serverId] ?? {}), [toolName]: permission } } });
    },

    async saveToolCatalog(serverId, snapshots, permissions) {
      const uid = requireUid(get().uid);
      // The catalog changed: for tools that were removed, went back into quarantine, changed in
      // content or title, or got a different permission, earlier grants are revoked as well. What
      // the user allowed was the tool as it was back then.
      const before = get().uid === uid ? get() : null;
      const incoming = new Map(snapshots.map((snapshot) => [snapshot.toolName, snapshot]));
      for (const previous of before?.snapshots[serverId] ?? []) {
        const next = incoming.get(previous.toolName);
        const unchanged =
          next !== undefined &&
          !next.pendingReview &&
          next.contentHash === previous.contentHash &&
          next.title === previous.title &&
          permissions[previous.toolName] === before?.permissions[serverId]?.[previous.toolName];
        if (!unchanged) mcpConversationGrants.revokeTool(serverId, previous.toolName);
      }
      await saveMcpToolCatalog(uid, serverId, snapshots, permissions);
      announceMcpLocalWrite(uid);
      if (get().uid !== uid || !get().servers.some((server) => server.id === serverId)) return;
      set({ snapshots: { ...get().snapshots, [serverId]: snapshots }, permissions: { ...get().permissions, [serverId]: { ...permissions } } });
    },

    async saveConnectionState(state) {
      const uid = requireUid(get().uid);
      await saveMcpConnectionState(uid, state);
      announceMcpLocalWrite(uid);
      if (get().uid !== uid || !get().servers.some((server) => server.id === state.serverId)) return;
      set({ connections: { ...get().connections, [state.serverId]: state } });
    },

    async setServerEnabled(conversationId, serverId, enabled) {
      const uid = requireUid(get().uid);
      await setMcpServerEnabled(uid, conversationId, serverId, enabled);
      announceMcpLocalWrite(uid);
      if (get().uid !== uid) return;
      const current = get().conversationServers[conversationId] ?? [];
      const known = get().servers.some((server) => server.id === serverId);
      const next = enabled ? (known && !current.includes(serverId) ? [...current, serverId] : current) : current.filter((id) => id !== serverId);
      set({ conversationServers: { ...get().conversationServers, [conversationId]: next } });
    },

    async adoptDraftServers(draftScope, conversationId) {
      const uid = requireUid(get().uid);
      if (!(get().conversationServers[draftScope]?.length)) return;
      // Update memory first: the send path is about to read this conversation's enabled servers under
      // the real id and cannot wait for the database write.
      const { [draftScope]: draft = [], ...rest } = get().conversationServers;
      const existing = rest[conversationId] ?? [];
      set({ conversationServers: { ...rest, [conversationId]: [...existing, ...draft.filter((id) => !existing.includes(id))] } });
      await moveMcpConversationSwitches(uid, draftScope, conversationId);
      announceMcpLocalWrite(uid);
    },

    async clearConversation(conversationId) {
      const uid = requireUid(get().uid);
      if (get().conversationServers[conversationId]) {
        const { [conversationId]: _removed, ...rest } = get().conversationServers;
        set({ conversationServers: rest });
      }
      await clearMcpConversationSwitches(uid, conversationId);
      announceMcpLocalWrite(uid);
      // The raw arguments and results of this conversation's steps are deleted with it.
      await deleteMcpStepPayloadsForConversation(uid, conversationId);
    },
  };
});

/** The MCP runtime configuration currently in effect (read from the model catalog, with fallbacks for missing values and clamping for out-of-range ones). */
export function currentMcpRuntimeConfig(): McpRuntimeConfig {
  try {
    return getMcpRuntimeConfig();
  } catch {
    return { ...MCP_RUNTIME_CONFIG_FALLBACK };
  }
}

/** Called at startup and on a partition switch: clears the previous partition's in-memory state and reads the new one. */
export function hydrateMcpStore(uid: string): Promise<void> {
  return useMcpStore.getState().hydrate(uid).catch((error: unknown) => {
    console.warn('[mcp] hydrate failed', error);
  });
}

/** Called when a message is deleted: clears its step payloads. An unhydrated store or a failed cleanup does not affect the deletion itself. */
export function forgetMcpMessage(messageId: string): void {
  const uid = useMcpStore.getState().uid;
  if (!uid) return;
  void deleteMcpStepPayloadsForMessage(uid, messageId).catch(() => {});
}

/** Called when a conversation is deleted: clears its MCP switches and step payloads. An unhydrated store or a failed cleanup does not affect the deletion itself. */
export function forgetMcpConversation(conversationId: string): void {
  const store = useMcpStore.getState();
  if (!store.hydrated) return;
  void store.clearConversation(conversationId).catch(() => {});
}

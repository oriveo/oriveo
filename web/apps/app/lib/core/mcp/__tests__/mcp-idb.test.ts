import 'fake-indexeddb/auto';
import { describe, expect, it } from 'vitest';
import {
  McpCredentialStore,
  McpServerLimitError,
  type McpServerAddition,
  type McpToolSnapshot,
} from '@oriveo/core/mcp/index';
import { deletePartitionData } from '../../../infra/storage/partition';
import {
  MCP_STEP_ARGUMENTS_MAX_BYTES,
  MCP_STEP_RESULT_PREFIX_MAX_BYTES,
  capUtf8,
  clearMcpConversationSwitches,
  createIdbMcpCredentialStorage,
  createIdbMcpServerRepository,
  fetchMcpStepPayload,
  getMcpDBName,
  loadMcpLocalState,
  openMcpDB,
  removeMcpServer,
  saveMcpConnectionState,
  saveMcpStepPayload,
  saveMcpToolCatalog,
  setMcpServerEnabled,
  setMcpToolPermission,
  updateMcpServer,
} from '../mcp-idb';

let counter = 0;
/** A fresh partition per case, so cases do not affect each other. */
function freshUid(): string {
  counter += 1;
  return `uid-idb-${counter}`;
}

function uuid(n: number): string {
  return `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

function snapshot(serverId: string, toolName: string): McpToolSnapshot {
  return {
    serverId,
    toolName,
    title: toolName,
    description: null,
    inputSchema: { type: 'object' },
    annotations: {},
    contentHash: `hash-${toolName}`,
    readOnly: false,
    pendingReview: false,
    oversized: false,
    updatedAt: 1,
  };
}

function addition(n: number, overrides: Partial<McpServerAddition> = {}): McpServerAddition {
  const id = uuid(n);
  return {
    id,
    name: 'Linear',
    url: `https://mcp${n}.example.com/mcp`,
    authKind: 'auto',
    iconURL: null,
    createdAt: 1_000 + n,
    snapshots: [snapshot(id, 'search'), snapshot(id, 'create')],
    permissions: { search: 'auto', create: 'ask' },
    connectionState: { serverId: id, status: 'connected', lastSuccessAt: 5, negotiatedVersion: '2026-07-28', generation: 'stateless', sessionId: null },
    ...overrides,
  };
}

describe('mcp-idb: add / update / remove', () => {
  it('persists record, snapshots, permissions and connection state in one transaction on add, checking slug uniqueness in that same transaction', async () => {
    const uid = freshUid();
    const repo = createIdbMcpServerRepository(uid);
    const first = await repo.addServer(addition(1), 20);
    const second = await repo.addServer(addition(2), 20);
    expect(first.slug).toBe('linear');
    expect(second.slug).toBe('linear2');

    const local = await loadMcpLocalState(uid);
    expect(local.servers.map((server) => server.id)).toEqual([uuid(1), uuid(2)]);
    expect(local.snapshots[uuid(1)].map((row) => row.toolName).sort()).toEqual(['create', 'search']);
    expect(local.permissions[uuid(1)]).toEqual({ search: 'auto', create: 'ask' });
    expect(local.connections[uuid(1)].status).toBe('connected');
    expect(await repo.serverCount()).toBe(2);
    expect(await repo.hasServer(uuid(2))).toBe(true);
  });

  it('throws McpServerLimitError at the limit and leaves no partial record', async () => {
    const uid = freshUid();
    const repo = createIdbMcpServerRepository(uid);
    await repo.addServer(addition(1), 1);
    await expect(repo.addServer(addition(2), 1)).rejects.toBeInstanceOf(McpServerLimitError);
    const local = await loadMcpLocalState(uid);
    expect(local.servers).toHaveLength(1);
    expect(local.snapshots[uuid(2)]).toBeUndefined();
    expect(local.connections[uuid(2)]).toBeUndefined();
  });

  it('updates the editable fields and the modification time, leaving the slug and address as they were', async () => {
    const uid = freshUid();
    await createIdbMcpServerRepository(uid).addServer(addition(1), 20);
    const updated = await updateMcpServer(uid, uuid(1), { name: 'Renamed' }, 9_000);
    expect(updated).toMatchObject({ name: 'Renamed', slug: 'linear', url: 'https://mcp1.example.com/mcp', updatedAt: 9_000 });
    expect((await loadMcpLocalState(uid)).servers[0]).toMatchObject({ name: 'Renamed', updatedAt: 9_000 });
    expect(await updateMcpServer(uid, uuid(2), { name: 'Missing' })).toBeNull();
  });

  it('removes the record together with its snapshots, permissions, connection state, conversation switches and step payloads', async () => {
    const uid = freshUid();
    const repo = createIdbMcpServerRepository(uid);
    await repo.addServer(addition(1), 20);
    await repo.addServer(addition(2), 20);
    await setMcpServerEnabled(uid, 'conv-1', uuid(1), true);
    await saveMcpStepPayload(uid, { messageId: 'm1', stepId: 's1', serverId: uuid(1), conversationId: 'conv-1', arguments: '{}', resultPrefix: 'ok' });
    await saveMcpStepPayload(uid, { messageId: 'm1', stepId: 's2', serverId: uuid(2), conversationId: 'conv-1', arguments: '{}', resultPrefix: 'ok' });
    await removeMcpServer(uid, uuid(1));

    const local = await loadMcpLocalState(uid);
    expect(local.servers.map((server) => server.id)).toEqual([uuid(2)]);
    expect(Object.keys(local.snapshots)).toEqual([uuid(2)]);
    expect(Object.keys(local.permissions)).toEqual([uuid(2)]);
    expect(Object.keys(local.connections)).toEqual([uuid(2)]);
    expect(local.switches).toEqual({});
    expect(await fetchMcpStepPayload(uid, 'm1', 's1')).toBeNull();
    // The other server's payload on the same message is untouched.
    expect(await fetchMcpStepPayload(uid, 'm1', 's2')).not.toBeNull();
  });
});

describe('mcp-idb: device-local state', () => {
  it('does not resurrect orphan rows when connection state, permissions, snapshots or conversation switches are written after the server was removed', async () => {
    const uid = freshUid();
    const gone = uuid(7);
    await saveMcpConnectionState(uid, { serverId: gone, status: 'connected', lastSuccessAt: 1, negotiatedVersion: null, generation: null, sessionId: null });
    await setMcpToolPermission(uid, gone, 'search', 'auto');
    await saveMcpToolCatalog(uid, gone, [snapshot(gone, 'search')], { search: 'auto' });
    await setMcpServerEnabled(uid, 'conv-1', gone, true);
    const local = await loadMcpLocalState(uid);
    expect(local).toMatchObject({ connections: {}, permissions: {}, snapshots: {}, switches: {} });
  });

  it('replaces the tool catalog as a whole, orders conversation switches by when they were turned on, and clears them when the conversation is deleted', async () => {
    const uid = freshUid();
    const repo = createIdbMcpServerRepository(uid);
    await repo.addServer(addition(1), 20);
    await repo.addServer(addition(2), 20);
    await saveMcpToolCatalog(uid, uuid(1), [snapshot(uuid(1), 'only')], { only: 'off' });
    await setMcpServerEnabled(uid, 'conv-1', uuid(2), true, 10);
    await setMcpServerEnabled(uid, 'conv-1', uuid(1), true, 20);
    await setMcpServerEnabled(uid, 'conv-2', uuid(1), true, 30);

    let local = await loadMcpLocalState(uid);
    expect(local.snapshots[uuid(1)].map((row) => row.toolName)).toEqual(['only']);
    expect(local.permissions[uuid(1)]).toEqual({ only: 'off' });
    expect(local.switches).toEqual({ 'conv-1': [uuid(2), uuid(1)], 'conv-2': [uuid(1)] });

    await setMcpServerEnabled(uid, 'conv-1', uuid(2), false);
    await clearMcpConversationSwitches(uid, 'conv-2');
    local = await loadMcpLocalState(uid);
    expect(local.switches).toEqual({ 'conv-1': [uuid(1)] });
  });

  it('caps a step payload at 16 KB of raw arguments and the first 2 KB of the result, truncating on UTF-8 boundaries without splitting a character', async () => {
    const uid = freshUid();
    const args = 'あ'.repeat(10_000); // 30000 bytes
    await saveMcpStepPayload(uid, { messageId: 'm1', stepId: 's1', serverId: uuid(1), conversationId: 'c1', arguments: args, resultPrefix: 'r'.repeat(5_000) }, 9);
    const stored = await fetchMcpStepPayload(uid, 'm1', 's1');
    const bytes = (text: string) => new TextEncoder().encode(text).length;
    expect(bytes(stored!.arguments!)).toBeLessThanOrEqual(MCP_STEP_ARGUMENTS_MAX_BYTES);
    expect(stored!.arguments!.endsWith('あ')).toBe(true);
    expect(bytes(stored!.resultPrefix!)).toBe(MCP_STEP_RESULT_PREFIX_MAX_BYTES);
    expect(await fetchMcpStepPayload(uid, 'm1', 'missing')).toBeNull();
    expect(capUtf8(null, 10)).toBeNull();
    expect(capUtf8('ab', 10)).toBe('ab');
  });
});

describe('mcp-idb: credentials and partitions', () => {
  it('isolates credentials by partition so that the credentials of A cannot be read from another partition', async () => {
    const a = freshUid();
    const b = freshUid();
    const storeA = new McpCredentialStore(createIdbMcpCredentialStorage(a));
    await storeA.save({ accessToken: 'access-a', refreshToken: 'refresh-a' }, uuid(1), a);

    // A new instance (no in-memory cache) reads back from storage
    expect(await new McpCredentialStore(createIdbMcpCredentialStorage(a)).load(uuid(1), a)).toMatchObject({ accessToken: 'access-a', hasRefreshToken: true });
    expect(await new McpCredentialStore(createIdbMcpCredentialStorage(a)).loadRefreshToken(uuid(1), a)).toBe('refresh-a');
    expect(await new McpCredentialStore(createIdbMcpCredentialStorage(b)).load(uuid(1), a)).toBeNull();
    expect(await new McpCredentialStore(createIdbMcpCredentialStorage('guest')).load(uuid(1), a)).toBeNull();
    // Access and refresh tokens are two separate records
    expect((await (await openMcpDB(a)).getAllKeys('credentials')).map(String).sort()).toEqual([`${a}:${uuid(1)}`, `${a}:${uuid(1)}:refresh`]);
  });

  it('deletes the MCP database along with the partition, credentials and records included, even while a database connection is still open', async () => {
    const uid = freshUid();
    await createIdbMcpServerRepository(uid).addServer(addition(1), 20);
    await new McpCredentialStore(createIdbMcpCredentialStorage(uid)).save({ accessToken: 'secret' }, uuid(1), uid);
    await openMcpDB(uid); // the connection stays open

    await deletePartitionData(uid);

    const databases = await indexedDB.databases();
    expect(databases.some((database) => database.name === getMcpDBName(uid))).toBe(false);
    expect(await new McpCredentialStore(createIdbMcpCredentialStorage(uid)).load(uuid(1), uid)).toBeNull();
    expect((await loadMcpLocalState(uid)).servers).toEqual([]);
  });
});

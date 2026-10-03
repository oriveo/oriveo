import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { McpCredentialStore, type McpHttpRequest, type McpServerAddition, type McpTransport } from '@oriveo/core/mcp/index';

/**
 * Token refresh is serialized on the **production wiring**. Authorization servers rotate refresh
 * tokens: each one is single-use, and presenting it a second time yields `invalid_grant`. The
 * assertions look at the token requests actually sent through the production entry points of
 * `mcp-store` and at the credentials that actually land in IndexedDB.
 */

const ISSUER = 'https://auth.example.com';
const ENDPOINT = 'https://mcp.example.com/mcp';
const SERVER_ID = '00000000-0000-4000-8000-000000000001';

function rotatingBackend() {
  let generation = 1;
  const valid = new Set(['rt_1']);
  const tokenRequests: string[] = [];
  const json = (status: number, body: unknown) => ({ status, headers: new Headers({ 'content-type': 'application/json' }), body: new Response(JSON.stringify(body)).body });
  const transport: McpTransport = {
    async send(request: McpHttpRequest) {
      if (request.url === `${ISSUER}/.well-known/oauth-authorization-server`) {
        return json(200, { issuer: ISSUER, authorization_endpoint: `${ISSUER}/authorize`, token_endpoint: `${ISSUER}/token`, code_challenge_methods_supported: ['S256'] });
      }
      if (request.url === `${ISSUER}/token`) {
        const presented = new URLSearchParams(request.body).get('refresh_token') ?? '';
        tokenRequests.push(presented);
        // Give concurrent callers a chance to send their own request before the first response arrives.
        await new Promise((resolve) => setTimeout(resolve, 5));
        if (!valid.delete(presented)) return json(400, { error: 'invalid_grant' });
        generation += 1;
        valid.add(`rt_${generation}`);
        return json(200, { access_token: `at_${generation}`, token_type: 'Bearer', expires_in: 3600, refresh_token: `rt_${generation}` });
      }
      if (request.url === ENDPOINT) {
        const id = (JSON.parse(request.body ?? '{}') as { id?: unknown }).id ?? null;
        return json(200, { jsonrpc: '2.0', id, result: { resultType: 'complete', tools: [] } });
      }
      return json(404, {});
    },
  };
  return { transport, tokenRequests };
}

function addition(id: string): McpServerAddition {
  return {
    id,
    name: 'Example',
    url: ENDPOINT,
    authKind: 'auto',
    iconURL: null,
    createdAt: 1,
    snapshots: [],
    permissions: {},
    connectionState: { serverId: id, status: 'connected', lastSuccessAt: 1, negotiatedVersion: '2026-07-28', generation: 'stateless', sessionId: null },
  };
}

let counter = 0;
const freshUid = () => `uid-refresh-${++counter}`;

/** One "tab": fresh module instances (own authorizer table, credential cache and store) over the same IndexedDB. */
async function openTab(uid: string, transport: McpTransport) {
  vi.resetModules();
  const store = await import('../mcp-store');
  const actions = await import('../mcp-server-actions');
  const idb = await import('../mcp-idb');
  store.__setMcpTransportForTests(transport);
  await store.useMcpStore.getState().hydrate(uid);
  return { store, actions, idb };
}

async function seed(uid: string, idb: Awaited<ReturnType<typeof openTab>>['idb']) {
  await idb.createIdbMcpServerRepository(uid).addServer(addition(SERVER_ID), 20);
  await new McpCredentialStore(idb.createIdbMcpCredentialStorage(uid)).save(
    // Expires in 30 seconds, so every call site refreshes before using the token.
    { accessToken: 'at_1', refreshToken: 'rt_1', expiresAt: Date.now() + 30_000, issuer: ISSUER, clientId: 'client', resource: ENDPOINT, pastedToken: null },
    SERVER_ID,
    uid,
  );
}

async function storedCredentials(uid: string, idb: Awaited<ReturnType<typeof openTab>>['idb']) {
  const storage = idb.createIdbMcpCredentialStorage(uid);
  return {
    access: JSON.parse((await storage.read(McpCredentialStore.accessKey(SERVER_ID, uid))) ?? 'null') as { accessToken: string | null; hasRefreshToken: boolean } | null,
    refresh: await storage.read(McpCredentialStore.refreshKey(SERVER_ID, uid)),
  };
}

/** Same semantics as `navigator.locks`: tasks with the same name queue up. Shared by both "tabs", as it is per origin in a browser. */
function installWebLocks() {
  const tails = new Map<string, Promise<unknown>>();
  const requested: string[] = [];
  vi.stubGlobal('navigator', {
    ...globalThis.navigator,
    locks: {
      request: <T,>(name: string, _options: unknown, task: () => Promise<T>): Promise<T> => {
        requested.push(name);
        const run = (tails.get(name) ?? Promise.resolve()).then(task, task);
        tails.set(name, run.catch(() => {}));
        return run;
      },
    },
  });
  return requested;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('token refresh serialization (production wiring)', () => {
  it('sends a single refresh when two call sites in one page see the token expiring, and stays signed in', async () => {
    const uid = freshUid();
    const backend = rotatingBackend();
    const tab = await openTab(uid, backend.transport);
    await seed(uid, tab.idb);
    await tab.store.useMcpStore.getState().reload();

    // The two management-page entry points each fetch the authorizer (the same `getMcpAuthorizer` the chat loop uses).
    const [probe, refreshed, chatToken] = await Promise.all([
      tab.actions.probeMcpServer(SERVER_ID),
      tab.actions.refreshMcpServerTools(SERVER_ID),
      tab.store.getMcpAuthorizer(uid).validAccessToken(SERVER_ID, uid),
    ]);

    expect(backend.tokenRequests).toEqual(['rt_1']);
    expect(probe).toBe('connected');
    expect(refreshed.status).toBe('connected');
    expect(chatToken).toBe('at_2');
    expect(await storedCredentials(uid, tab.idb)).toEqual({ access: expect.objectContaining({ accessToken: 'at_2', hasRefreshToken: true }), refresh: 'rt_2' });
  });

  it('queues two tabs refreshing at once through navigator.locks: the later one sends no request and uses the new token', async () => {
    const uid = freshUid();
    const requested = installWebLocks();
    const backend = rotatingBackend();
    const first = await openTab(uid, backend.transport);
    await seed(uid, first.idb);
    await first.store.useMcpStore.getState().reload();
    const second = await openTab(uid, backend.transport);
    // Both tabs hold the old token in their in-memory cache.
    await first.store.getMcpCredentialStore(uid).load(SERVER_ID, uid);
    await second.store.getMcpCredentialStore(uid).load(SERVER_ID, uid);
    expect(first.store.getMcpAuthorizer(uid)).not.toBe(second.store.getMcpAuthorizer(uid));

    const [a, b] = await Promise.all([
      first.actions.probeMcpServer(SERVER_ID),
      second.actions.probeMcpServer(SERVER_ID),
    ]);

    expect([a, b]).toEqual(['connected', 'connected']);
    expect(backend.tokenRequests).toEqual(['rt_1']);
    expect(requested).toEqual([`mcp-refresh:${uid}:${SERVER_ID}`, `mcp-refresh:${uid}:${SERVER_ID}`]);
    expect(await second.store.getMcpAuthorizer(uid).validAccessToken(SERVER_ID, uid)).toBe('at_2');
    expect(await storedCredentials(uid, second.idb)).toEqual({ access: expect.objectContaining({ accessToken: 'at_2', hasRefreshToken: true }), refresh: 'rt_2' });
  });

  it('without navigator.locks each tab sends one refresh, and the late invalid_grant does not wipe the new token', async () => {
    const uid = freshUid();
    const backend = rotatingBackend();
    const first = await openTab(uid, backend.transport);
    await seed(uid, first.idb);
    await first.store.useMcpStore.getState().reload();
    const second = await openTab(uid, backend.transport);

    const [a, b] = await Promise.all([
      first.store.getMcpAuthorizer(uid).validAccessToken(SERVER_ID, uid),
      second.store.getMcpAuthorizer(uid).validAccessToken(SERVER_ID, uid),
    ]);

    expect(backend.tokenRequests).toEqual(['rt_1', 'rt_1']);
    expect([a, b]).toEqual(['at_2', 'at_2']);
    expect(await storedCredentials(uid, second.idb)).toEqual({ access: expect.objectContaining({ accessToken: 'at_2', hasRefreshToken: true }), refresh: 'rt_2' });
  });
});

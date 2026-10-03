import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { McpCredentialStore, type McpHttpRequest, type McpTransport } from '@oriveo/core/mcp/index';

/**
 * Half-finished adds (a failed add must not leave half a server behind): after a successful probe the
 * record is already persisted, but the user has not yet clicked Done on the confirm-default-permissions
 * step. If the page is closed before that, no cleanup code gets to run, so the record is cleaned up on
 * the next hydration. Everything goes through the production entry points of `mcp-store`.
 */

const ENDPOINT = 'https://mcp.example.com/mcp';

/** An MCP server that requires a token: the tool list is returned only with the right token. */
const transport: McpTransport = {
  async send(request: McpHttpRequest) {
    const json = (status: number, body: unknown, headers: Record<string, string> = {}) => ({
      status,
      headers: new Headers({ 'content-type': 'application/json', ...headers }),
      body: new Response(JSON.stringify(body)).body,
    });
    if (request.url !== ENDPOINT) return json(404, {});
    if (request.credential !== 'good-token') return json(401, {}, { 'www-authenticate': 'Bearer' });
    const id = (JSON.parse(request.body ?? '{}') as { id?: unknown }).id ?? null;
    return json(200, {
      jsonrpc: '2.0',
      id,
      result: { resultType: 'complete', tools: [{ name: 'search', description: 'Search', inputSchema: { type: 'object' }, annotations: { readOnlyHint: true } }] },
    });
  },
};

let counter = 0;
const freshUid = () => `uid-pending-add-${++counter}`;

/** One "tab": a fresh module instance on top of the same IndexedDB. */
async function openTab(uid: string) {
  vi.resetModules();
  const store = await import('../mcp-store');
  const actions = await import('../mcp-server-actions');
  const idb = await import('../mcp-idb');
  store.__setMcpTransportForTests(transport);
  await store.useMcpStore.getState().hydrate(uid);
  return { store, actions, idb };
}
type Tab = Awaited<ReturnType<typeof openTab>>;

async function addToReview(tab: Tab): Promise<string> {
  const state = await tab.store.useMcpStore.getState().addServer({ url: ENDPOINT, authKind: 'token', token: 'good-token' });
  if (state.kind !== 'review') throw new Error(`add failed: ${state.kind}`);
  return state.review.serverId;
}

async function rows(uid: string, tab: Tab) {
  const local = await tab.idb.loadMcpLocalState(uid);
  return {
    servers: local.servers.map((server) => server.id),
    snapshots: Object.keys(local.snapshots),
    connections: Object.keys(local.connections),
    credentials: (await (await tab.idb.openMcpDB(uid)).getAllKeys('credentials')).map(String),
  };
}

/** Stand-in for `navigator.locks` (shared by same-origin tabs). `pageClosed()` is the browser releasing all of a page's locks when it closes. */
function installWebLocks() {
  const held = new Set<string>();
  vi.stubGlobal('navigator', {
    ...globalThis.navigator,
    locks: {
      request: async (name: string, options: { ifAvailable?: boolean }, task: (lock: unknown) => Promise<unknown>) => {
        if (held.has(name)) {
          if (options.ifAvailable) return task(null);
          throw new Error(`lock ${name} is contended in this test`);
        }
        held.add(name);
        try {
          return await task({ name });
        } finally {
          held.delete(name);
        }
      },
    },
  });
  return { held, pageClosed: () => held.clear() };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('half-finished adds', () => {
  it('persists the record with the marker and holds the lock while on the confirm-permissions step, and other tabs neither see nor clean it', async () => {
    const uid = freshUid();
    const locks = installWebLocks();
    const first = await openTab(uid);
    const serverId = await addToReview(first);

    expect(first.store.useMcpStore.getState().servers.map((server) => server.id)).toEqual([serverId]);
    expect((await first.idb.loadMcpLocalState(uid)).servers[0]).toMatchObject({ id: serverId, pendingAdd: true });
    expect([...locks.held]).toEqual([`mcp-add:${uid}:${serverId}`]);

    const second = await openTab(uid);
    expect(second.store.useMcpStore.getState().servers).toEqual([]);
    expect((await rows(uid, second)).servers).toEqual([serverId]);
  });

  it('cleans up record, snapshots, connection state and credentials on the next load when the page closed before Done', async () => {
    const uid = freshUid();
    const locks = installWebLocks();
    const first = await openTab(uid);
    const serverId = await addToReview(first);
    expect((await rows(uid, first)).credentials).toEqual([McpCredentialStore.accessKey(serverId, uid)]);

    locks.pageClosed();
    const next = await openTab(uid);

    expect(next.store.useMcpStore.getState().servers).toEqual([]);
    expect(await rows(uid, next)).toEqual({ servers: [], snapshots: [], connections: [], credentials: [] });
  });

  it('clears the marker and releases the lock on Done, and the server is still there after a reload', async () => {
    const uid = freshUid();
    const locks = installWebLocks();
    const first = await openTab(uid);
    const serverId = await addToReview(first);
    await first.actions.acceptMcpAddedTools(serverId, { search: 'auto' });

    expect((await first.idb.loadMcpLocalState(uid)).servers[0]).not.toHaveProperty('pendingAdd');
    await vi.waitFor(() => expect([...locks.held]).toEqual([]));

    locks.pageClosed();
    const next = await openTab(uid);
    expect(next.store.useMcpStore.getState().servers.map((server) => server.id)).toEqual([serverId]);
    expect(next.store.useMcpStore.getState().permissions[serverId]).toEqual({ search: 'auto' });
    expect((await rows(uid, next)).credentials).toEqual([McpCredentialStore.accessKey(serverId, uid)]);
  });

  it('releases the lock and leaves nothing behind when the add is abandoned (half-finished record removed)', async () => {
    const uid = freshUid();
    const locks = installWebLocks();
    const tab = await openTab(uid);
    const serverId = await addToReview(tab);
    await tab.store.useMcpStore.getState().removeServer(serverId);
    expect(await rows(uid, tab)).toEqual({ servers: [], snapshots: [], connections: [], credentials: [] });
    await vi.waitFor(() => expect([...locks.held]).toEqual([]));
  });

  it('keeps a recent half-finished record in browsers without navigator.locks (another tab may be confirming it) and cleans it only once it is old', async () => {
    const uid = freshUid();
    const first = await openTab(uid);
    const serverId = await addToReview(first);

    const soon = await openTab(uid);
    expect(soon.store.useMcpStore.getState().servers).toEqual([]);
    expect((await rows(uid, soon)).servers).toEqual([serverId]);

    const realNow = Date.now();
    vi.spyOn(Date, 'now').mockReturnValue(realNow + first.store.MCP_ABANDONED_ADD_GRACE_MS);
    const later = await openTab(uid);
    expect(await rows(uid, later)).toEqual({ servers: [], snapshots: [], connections: [], credentials: [] });
  });
});

/** An MCP server that requires a browser sign-in; the second authorized tools/list (the step that reads the tool list) can hang without answering. */
function oauthBackend() {
  const AUTH = 'https://auth.example.com';
  const json = (status: number, body: unknown, headers: Record<string, string> = {}) => ({
    status,
    headers: new Headers({ 'content-type': 'application/json', ...headers }),
    body: new Response(JSON.stringify(body)).body,
  });
  let authorizedLists = 0;
  let reachedHang!: () => void;
  const hanging = new Promise<void>((resolve) => (reachedHang = resolve));
  const backend: McpTransport = {
    async send(request: McpHttpRequest) {
      const url = new URL(request.url);
      if (request.url === ENDPOINT) {
        if (request.credential !== 'at_1') return json(401, {}, { 'www-authenticate': 'Bearer' });
        const body = JSON.parse(request.body ?? '{}') as { id?: unknown; method?: string };
        if (body.method !== 'tools/list') return json(202, {});
        authorizedLists += 1;
        if (authorizedLists === 2) {
          reachedHang();
          await new Promise(() => {});
        }
        return json(200, { jsonrpc: '2.0', id: body.id ?? null, result: { resultType: 'complete', tools: [] } });
      }
      if (url.pathname.startsWith('/.well-known/oauth-protected-resource')) return json(200, { resource: ENDPOINT, authorization_servers: [AUTH] });
      if (url.pathname === '/.well-known/oauth-authorization-server') {
        return json(200, {
          issuer: AUTH,
          authorization_endpoint: `${AUTH}/authorize`,
          token_endpoint: `${AUTH}/token`,
          registration_endpoint: `${AUTH}/register`,
          code_challenge_methods_supported: ['S256'],
        });
      }
      if (url.pathname === '/register') return json(201, { client_id: 'dcr_1' });
      if (url.pathname === '/token') return json(200, { access_token: 'at_1', token_type: 'Bearer', refresh_token: 'rt_1', expires_in: 3600 });
      return json(404, {});
    },
  };
  return { backend, hanging };
}

describe('orphaned tokens from a browser sign-in', () => {
  it('leaves no token from this sign-in in the credential store when the tab closes after the token was obtained but before the record was saved', async () => {
    const uid = freshUid();
    installWebLocks();
    const tab = await openTab(uid);
    const { backend, hanging } = oauthBackend();
    tab.store.__setMcpTransportForTests(backend);

    const states: string[] = [];
    void tab.store.useMcpStore.getState().addServer({
      url: ENDPOINT,
      authKind: 'auto',
      confirmAuthorization: async () => true,
      launcher: { open: async (request) => ({ params: { code: 'c', state: request.state } }) },
      progress: (state) => void states.push(state.kind),
    });
    // Reaches "reading the tool list" and hangs there: the token has been obtained, the record is not written yet.
    await hanging;
    expect(states).toEqual(['connecting', 'authPrompt', 'browser', 'finishing']);

    // The tab is closed at this point: storage holds only the DCR registration kept per issuer, and no server's token.
    const dcrOnly = [McpCredentialStore.registrationKey('https://auth.example.com', uid)];
    expect((await rows(uid, tab)).servers).toEqual([]);
    expect((await rows(uid, tab)).credentials).toEqual(dcrOnly);
  });

  it('sweeps credentials without a server record on load, and leaves saved servers, an add parked on the permission review and DCR registrations alone', async () => {
    const uid = freshUid();
    installWebLocks();
    const first = await openTab(uid);
    const saved = await addToReview(first);
    await first.actions.acceptMcpAddedTools(saved, { search: 'auto' });
    const reviewing = await addToReview(first);

    // A leftover: the credentials exist, the server record was never saved.
    const orphan = '00000000-0000-4000-8000-00000000dead';
    const seeded = new McpCredentialStore(first.idb.createIdbMcpCredentialStorage(uid));
    await seeded.save({ accessToken: 'orphan-at', refreshToken: 'orphan-rt', issuer: 'https://auth.example.com', clientId: 'c', resource: ENDPOINT }, orphan, uid);
    await seeded.saveClientRegistration({ clientId: 'dcr_1', issuer: 'https://auth.example.com', redirectUris: [] }, uid);
    expect((await rows(uid, first)).credentials).toContain(McpCredentialStore.refreshKey(orphan, uid));

    // The first tab is still open (holding the lock of the server awaiting confirmation) while another tab loads.
    const second = await openTab(uid);
    expect((await rows(uid, second)).credentials.sort()).toEqual(
      [
        McpCredentialStore.accessKey(saved, uid),
        McpCredentialStore.accessKey(reviewing, uid),
        McpCredentialStore.registrationKey('https://auth.example.com', uid),
      ].sort(),
    );
    expect((await rows(uid, second)).servers.sort()).toEqual([saved, reviewing].sort());
  });
});

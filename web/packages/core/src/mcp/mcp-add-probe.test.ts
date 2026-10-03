import { describe, expect, it } from 'vitest';
import { McpAuthorizer, type McpAuthorizationLauncher } from './mcp-auth';
import { McpAddCoordinator, McpAddProbe, McpServerLimitError, capServerName, checkMcpEndpoint, type McpAddState } from './mcp-add-probe';
import { McpCredentialStore, createMemoryMcpCredentialStorage } from './mcp-credentials';
import { MCP_FIXTURE_CLIENT_IDENTITY } from './mcp-fixture-identity';
import { createMemoryMcpServerRepository } from './mcp-memory-repository';
import type { McpHttpRequest, McpTransport } from './mcp-transport';
import { MCP_RUNTIME_CONFIG_FALLBACK } from './mcp-types';

/**
 * Add-flow state machine. The server, the authorization server and the authorization page are all
 * fakes; assertions target what production code actually writes to storage and the credential medium.
 */

const UID = 'u1';
const SERVER_ID = '0f8e7d6c-0000-4000-8000-0000000000aa';
const ENDPOINT = 'https://mcp.example.com/mcp';

interface FakeServerOptions {
  requireToken?: string | null;
  oauth?: 'cimd' | 'dcr' | 'none' | null;
  listStatus?: number;
  legacyName?: string;
}

/** A fake server that answers by request content, covering the MCP endpoint, protected resource metadata, the authorization server and the token endpoint. */
function fakeServer(options: FakeServerOptions = {}): McpTransport & { sent: McpHttpRequest[]; issued: string[] } {
  const sent: McpHttpRequest[] = [];
  const issued: string[] = [];
  let authorizedLists = 0;
  const json = (status: number, body: unknown, headers: Record<string, string> = {}) => ({
    status,
    headers: new Headers({ 'content-type': 'application/json', ...headers }),
    body: new Response(JSON.stringify(body)).body,
  });
  return {
    sent,
    issued,
    async send(request) {
      sent.push(request);
      const url = new URL(request.url);
      if (url.pathname === '/mcp') {
        const body = JSON.parse(request.body ?? '{}');
        const token = request.credential ?? null;
        const accepted = options.requireToken !== undefined && options.requireToken !== null
          ? token === options.requireToken
          : options.oauth
            ? token !== null && issued.includes(token)
            : true;
        if (!accepted) {
          return { status: 401, headers: new Headers({ 'www-authenticate': 'Bearer scope="files:read"' }), body: new Response('').body };
        }
        if (options.legacyName) {
          if (body.method === 'initialize') {
            return json(200, { jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-11-25', serverInfo: { name: options.legacyName } } }, { 'mcp-session-id': 's' });
          }
          if (!request.headers['mcp-session-id']) return json(400, { jsonrpc: '2.0', id: body.id, error: { code: -32000, message: 'no session' } });
        }
        if (body.method === 'tools/list') {
          // The first tools/list carrying a token is the probe; the second one actually reads the tool list.
          if (token) authorizedLists += 1;
          if (options.listStatus && authorizedLists === 2) return json(options.listStatus, { error: 'x' });
          return json(200, {
            jsonrpc: '2.0',
            id: body.id,
            result: { tools: [{ name: 'get', inputSchema: { type: 'object' }, annotations: { readOnlyHint: true } }, { name: 'put', inputSchema: { type: 'object' } }] },
          });
        }
        return json(202, {});
      }
      if (url.pathname === '/.well-known/oauth-protected-resource/mcp' || url.pathname === '/.well-known/oauth-protected-resource') {
        if (!options.oauth) return json(404, {});
        return json(200, { resource: ENDPOINT, authorization_servers: ['https://auth.example.com'] });
      }
      if (url.pathname === '/.well-known/oauth-authorization-server') {
        return json(200, {
          issuer: 'https://auth.example.com',
          authorization_endpoint: 'https://auth.example.com/authorize',
          token_endpoint: 'https://auth.example.com/token',
          code_challenge_methods_supported: ['S256'],
          ...(options.oauth === 'cimd' ? { client_id_metadata_document_supported: true } : {}),
          ...(options.oauth === 'dcr' ? { registration_endpoint: 'https://auth.example.com/register' } : {}),
        });
      }
      if (url.pathname === '/register') return json(201, { client_id: 'dcr_1' });
      if (url.pathname === '/token') {
        const token = `at_${issued.length + 1}`;
        issued.push(token);
        return json(200, { access_token: token, token_type: 'Bearer', refresh_token: `rt_${issued.length}`, expires_in: 3600 });
      }
      return json(404, {});
    },
  };
}

function setup(server: ReturnType<typeof fakeServer>, launcher?: McpAuthorizationLauncher, maxServers = 20) {
  const storage = createMemoryMcpCredentialStorage();
  const credentialStore = new McpCredentialStore(storage);
  const repository = createMemoryMcpServerRepository();
  const runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, maxServers };
  const authorizer = new McpAuthorizer({
    transport: server,
    launcher: launcher ?? { open: async (request) => ({ params: { code: 'c', state: request.state } }) },
    credentialStore,
    random: { randomBytes: (n) => new Uint8Array(n).fill(7) },
    identity: MCP_FIXTURE_CLIENT_IDENTITY,
  });
  const probe = new McpAddProbe({ runtimeConfig, authorizer, credentialStore, transport: server });
  const coordinator = new McpAddCoordinator({ probe, repository, credentialStore, runtimeConfig });
  const states: McpAddState['kind'][] = [];
  return { storage, credentialStore, repository, coordinator, states, progress: (state: McpAddState) => void states.push(state.kind) };
}

/** After a failed terminal state, neither storage nor the credential medium holds any trace of this add. */
function expectNoTrace(env: ReturnType<typeof setup>) {
  expect(env.repository.records.size).toBe(0);
  expect(env.repository.snapshots.size).toBe(0);
  expect(env.repository.permissions.size).toBe(0);
  expect(env.repository.connectionStates.size).toBe(0);
  expect([...env.storage.snapshot().keys()].filter((key) => key.includes(SERVER_ID))).toEqual([]);
}

describe('add flow', () => {
  it('no sign-in: saves only after the tool list is read; progress states arrive in order and the terminal state is emitted once', async () => {
    const env = setup(fakeServer());
    const state = await env.coordinator.add({ url: ENDPOINT, name: '', authKind: 'auto', uid: UID, serverId: SERVER_ID, progress: env.progress, now: 42 });
    expect(state.kind).toBe('review');
    expect(env.states).toEqual(['connecting', 'finishing', 'review']);
    const record = env.repository.records.get(SERVER_ID)!;
    expect(record).toMatchObject({ name: 'mcp.example.com', slug: 'mcpexamplecom', url: ENDPOINT, createdAt: 42, schemaVersion: 1 });
    expect(env.repository.permissions.get(SERVER_ID)).toEqual({ get: 'auto', put: 'ask' });
    expect(env.repository.snapshots.get(SERVER_ID)!.every((s) => s.pendingReview)).toBe(true);
    expect(env.repository.connectionStates.get(SERVER_ID)).toMatchObject({ status: 'connected', generation: 'stateless', negotiatedVersion: '2026-07-28' });
  });

  it('uses the name a legacy server reports when the name is left empty; caps long names at 64 UTF-16 code units without splitting a grapheme cluster', async () => {
    const env = setup(fakeServer({ legacyName: 'Legacy Server' }));
    await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID });
    expect(env.repository.records.get(SERVER_ID)).toMatchObject({ name: 'Legacy Server', slug: 'legacyserver' });
    expect(env.repository.connectionStates.get(SERVER_ID)).toMatchObject({ generation: 'session', sessionId: 's' });
    const capped = capServerName(`${'a'.repeat(63)}👍🏽`);
    expect(capped).toBe('a'.repeat(63));
  });

  it('non-https URL -> invalid URL, and not a single request is sent', async () => {
    const server = fakeServer();
    const env = setup(server);
    expect((await env.coordinator.add({ url: 'http://mcp.example.com/mcp', authKind: 'auto', uid: UID, serverId: SERVER_ID, progress: env.progress })).kind).toBe('invalidURL');
    expect(server.sent).toHaveLength(0);
    expect(env.states).toEqual(['invalidURL']);
  });

  it('a URL with a userinfo part is rejected at validation (reason hasUserinfo): no request, no credential left behind', async () => {
    const server = fakeServer();
    const env = setup(server);
    for (const url of ['https://user:pass@mcp.example.com/mcp', 'https://token@mcp.example.com/mcp', 'https://:secret@mcp.example.com/mcp']) {
      expect(await env.coordinator.add({ url, authKind: 'auto', uid: UID, serverId: SERVER_ID }), url).toEqual({ kind: 'invalidURL', reason: 'hasUserinfo' });
      expect(checkMcpEndpoint(url)).toEqual({ ok: false, reason: 'hasUserinfo' });
    }
    expect(server.sent).toHaveLength(0);
    expect(env.repository.records.size).toBe(0);
    // Every other non-compliant URL reports the reason malformed.
    for (const url of ['', 'http://mcp.example.com/mcp', 'mcp.example.com', 'https://', `https://mcp.example.com/${'a'.repeat(2100)}`]) {
      expect(checkMcpEndpoint(url), url).toEqual({ ok: false, reason: 'malformed' });
    }
    expect(checkMcpEndpoint(' HTTPS://MCP.example.com/mcp#frag ')).toEqual({ ok: true, url: 'https://mcp.example.com/mcp' });
  });

  it('limit already reached: rejected before the probe starts', async () => {
    const server = fakeServer();
    const env = setup(server, undefined, 1);
    await env.repository.addServer({ id: 'other', name: 'x', url: ENDPOINT, authKind: 'auto', iconURL: null, createdAt: 0, snapshots: [], permissions: {}, connectionState: { serverId: 'other', status: 'connected', lastSuccessAt: null, negotiatedVersion: null, generation: null, sessionId: null } }, 1);
    expect(await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID })).toEqual({ kind: 'limitReached', max: 1 });
    expect(server.sent).toHaveLength(0);
  });

  it('serverId collides with an existing server -> saveFailed, and that server credentials are untouched', async () => {
    const server = fakeServer();
    const env = setup(server);
    await env.repository.addServer({ id: SERVER_ID, name: 'x', url: ENDPOINT, authKind: 'auto', iconURL: null, createdAt: 0, snapshots: [], permissions: {}, connectionState: { serverId: SERVER_ID, status: 'connected', lastSuccessAt: null, negotiatedVersion: null, generation: null, sessionId: null } }, 20);
    await env.credentialStore.save({ pastedToken: 'keep-me' }, SERVER_ID, UID);
    expect((await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID })).kind).toBe('saveFailed');
    expect((await env.credentialStore.load(SERVER_ID, UID))?.pastedToken).toBe('keep-me');
    expect(server.sent).toHaveLength(0);
  });

  it('access token: a wrong token -> token field error and no trace; a correct token is stored in credentials only after the record is saved', async () => {
    const wrong = setup(fakeServer({ requireToken: 'right' }));
    expect((await wrong.coordinator.add({ url: ENDPOINT, authKind: 'token', token: 'wrong', uid: UID, serverId: SERVER_ID })).kind).toBe('tokenRejected');
    expectNoTrace(wrong);

    const right = setup(fakeServer({ requireToken: 'right' }));
    expect((await right.coordinator.add({ url: ENDPOINT, authKind: 'token', token: 'right', uid: UID, serverId: SERVER_ID })).kind).toBe('review');
    expect((await right.credentialStore.load(SERVER_ID, UID))?.pastedToken).toBe('right');
    expect(right.repository.records.get(SERVER_ID)!.authKind).toBe('token');
  });

  it('token cannot be stored in credentials -> saveFailed, and the record just written is removed', async () => {
    const env = setup(fakeServer({ requireToken: 'right' }));
    env.storage.write = async () => {
      throw new Error('quota');
    };
    expect((await env.coordinator.add({ url: ENDPOINT, authKind: 'token', token: 'right', uid: UID, serverId: SERVER_ID })).kind).toBe('saveFailed');
    expectNoTrace(env);
  });

  it('sign-in required but no authorization server can be discovered -> needs an access token', async () => {
    const env = setup(fakeServer({ requireToken: 'right' }));
    expect((await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID })).kind).toBe('needsToken');
    expectNoTrace(env);
  });

  it('the pre-sign-in prompt is a gate: without consent no client is registered and no browser is opened', async () => {
    const server = fakeServer({ oauth: 'dcr' });
    let opened = 0;
    const env = setup(server, { open: async () => ((opened += 1), { params: {} }) });
    const prompts: string[] = [];
    const state = await env.coordinator.add({
      url: ENDPOINT,
      authKind: 'auto',
      uid: UID,
      serverId: SERVER_ID,
      progress: env.progress,
      confirmAuthorization: async (prompt) => (prompts.push(prompt.authorizationHost), false),
    });
    expect(state.kind).toBe('authCancelled');
    expect(prompts).toEqual(['auth.example.com']);
    expect(env.states).toEqual(['connecting', 'authPrompt', 'authCancelled']);
    expect(server.sent.filter((r) => r.method === 'POST' && !r.url.endsWith('/mcp'))).toEqual([]);
    expect(opened).toBe(0);
    expectNoTrace(env);
  });

  it('reading the tool list fails after a successful browser sign-in -> unreachable, and the token stored by this sign-in is deleted', async () => {
    const env = setup(fakeServer({ oauth: 'cimd', listStatus: 500 }));
    const state = await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID, confirmAuthorization: async () => true });
    expect(state.kind).toBe('unreachable');
    expectNoTrace(env);
  });

  it('full browser sign-in flow: 19 -> 20 -> 21 -> 22, and the token stays in credentials', async () => {
    const env = setup(fakeServer({ oauth: 'cimd' }));
    const state = await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID, progress: env.progress, confirmAuthorization: async () => true });
    expect(state.kind).toBe('review');
    expect(env.states).toEqual(['connecting', 'authPrompt', 'browser', 'finishing', 'review']);
    expect(await env.credentialStore.load(SERVER_ID, UID)).toMatchObject({ accessToken: 'at_1', hasRefreshToken: true });
  });

  it('user closes the authorization page -> sign-in not completed, no trace', async () => {
    const env = setup(fakeServer({ oauth: 'cimd' }), { open: async () => Promise.reject(new Error('closed')) });
    expect((await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID, confirmAuthorization: async () => true })).kind).toBe('authCancelled');
    expectNoTrace(env);
  });

  it('cancelled midway through the add -> cancelled, no trace', async () => {
    const env = setup(fakeServer({ oauth: 'cimd' }));
    const controller = new AbortController();
    const state = await env.coordinator.add({
      url: ENDPOINT,
      authKind: 'auto',
      uid: UID,
      serverId: SERVER_ID,
      signal: controller.signal,
      confirmAuthorization: async () => {
        controller.abort();
        return true;
      },
    });
    expect(state.kind).toBe('cancelled');
    expectNoTrace(env);
  });

  it('hits the limit while saving (filled up elsewhere during the probe) -> limitReached, and the token is deleted', async () => {
    const env = setup(fakeServer({ oauth: 'cimd' }));
    env.repository.addServer = async () => {
      throw new McpServerLimitError(20);
    };
    expect(await env.coordinator.add({ url: ENDPOINT, authKind: 'auto', uid: UID, serverId: SERVER_ID, confirmAuthorization: async () => true })).toEqual({ kind: 'limitReached', max: 20 });
    expectNoTrace(env);
  });
});

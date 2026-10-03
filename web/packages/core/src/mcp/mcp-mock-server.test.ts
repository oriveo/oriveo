import { spawn, type ChildProcess } from 'node:child_process';
import { resolve } from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import { McpAddCoordinator, McpAddProbe, type McpAddState } from './mcp-add-probe';
import { McpAuthorizer, type McpAuthorizationLauncher } from './mcp-auth';
import { MCP_FIXTURE_CLIENT_ID, MCP_FIXTURE_CLIENT_IDENTITY } from './mcp-fixture-identity';
import { buildToolSnapshots, confirmToolSnapshots, diffToolSnapshots, outboundToolSnapshots } from './mcp-catalog';
import { McpClient } from './mcp-client';
import { McpCredentialStore, createMemoryMcpCredentialStorage } from './mcp-credentials';
import { createMemoryMcpServerRepository } from './mcp-memory-repository';
import { createDirectMcpTransport, type McpFetch } from './mcp-transport';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig } from './mcp-types';

/**
 * Core modules against the frozen mock server (`shared/test-fixtures/mcp/mock-server.mjs`) over a real
 * connection. This is the only place in the repository that connects to the mock server for real, and it
 * runs the whole flow end to end.
 *
 * Each mode starts a real child process (`--port=0` for a random port, loopback only); both `afterAll` and
 * the process exit hook kill them.
 *
 * The mock server speaks http only, while the client accepts https only (that gate must not be opened for
 * tests). So the test transport plays a TLS-terminating proxy at the fetch layer: the client sees
 * `https://127.0.0.1:<port>` and the request goes out as http; URLs coming back from the server
 * (`resource_metadata` in `WWW-Authenticate`, issuer / endpoints in metadata, the authorization redirect
 * `Location`) are rewritten back to https.
 * Apart from that, requests and responses pass unchanged through the production direct transport, client,
 * authorizer and add-server flow.
 */

const MOCK = resolve(__dirname, '../../../../../shared/test-fixtures/mcp/mock-server.mjs');
const UID = 'mock-user';
const children = new Set<ChildProcess>();

function killAll() {
  for (const child of children) {
    if (child.exitCode === null) child.kill('SIGKILL');
  }
  children.clear();
}
process.once('exit', killAll);
afterAll(killAll);

interface Mock {
  port: number;
  httpOrigin: string;
  httpsOrigin: string;
  endpoint: string;
  state(): Promise<Record<string, unknown>>;
  stop(): void;
}

async function startMock(...flags: string[]): Promise<Mock> {
  const child = spawn(process.execPath, [MOCK, '--port=0', ...flags], { stdio: ['ignore', 'pipe', 'pipe'] });
  children.add(child);
  const port = await new Promise<number>((resolvePort, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error(`mock server did not start: ${buffer}`)), 10_000);
    child.stdout!.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8');
      const match = /listening http:\/\/127\.0\.0\.1:(\d+)\/mcp/.exec(buffer);
      if (match) {
        clearTimeout(timer);
        resolvePort(Number(match[1]));
      }
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`mock server exited early (${code}): ${buffer}`));
    });
  });
  const httpOrigin = `http://127.0.0.1:${port}`;
  const httpsOrigin = `https://127.0.0.1:${port}`;
  return {
    port,
    httpOrigin,
    httpsOrigin,
    endpoint: `${httpsOrigin}/mcp`,
    async state() {
      return (await (await fetch(`${httpOrigin}/__mock/state`)).json()) as Record<string, unknown>;
    },
    stop() {
      child.kill('SIGKILL');
      children.delete(child);
    },
  };
}

/** TLS-terminating proxy for tests (see the file header). Only this mock server's origin is let through; any other URL is unreachable. */
function loopbackTls(mock: Mock): McpFetch {
  const toHttps = (text: string) => text.split(mock.httpOrigin).join(mock.httpsOrigin);
  return async (url, init) => {
    if (!url.startsWith(mock.httpsOrigin)) throw new TypeError('fetch failed');
    const response = await fetch(mock.httpOrigin + url.slice(mock.httpsOrigin.length), {
      method: init.method,
      headers: init.headers,
      body: init.body,
      signal: init.signal,
      redirect: 'manual',
    });
    const headers = new Headers();
    response.headers.forEach((value, key) => {
      if (key !== 'content-length') headers.set(key, toHttps(value));
    });
    if ((response.headers.get('content-type') ?? '').includes('text/event-stream')) {
      return { status: response.status, headers, body: response.body };
    }
    const text = toHttps(await response.text());
    return { status: response.status, headers, body: new Response(text).body };
  };
}

/** Plays the browser: opens the authorization URL, takes the 302 Location and hands back the redirect parameters (the same result as the BroadcastChannel handoff). */
function browserFor(mock: Mock): McpAuthorizationLauncher & { opened: string[] } {
  const opened: string[] = [];
  const fetchPort = loopbackTls(mock);
  return {
    opened,
    async open(request) {
      opened.push(request.url);
      const response = await fetchPort(request.url, { method: 'GET', headers: {}, redirect: 'manual' });
      const location = response.headers.get('location');
      if (response.status !== 302 || !location) throw new Error(`authorization refused: ${response.status}`);
      const callback = new URL(location);
      const params: Record<string, string> = {};
      for (const [key, value] of callback.searchParams) params[key] = value.split(mock.httpOrigin).join(mock.httpsOrigin);
      return { params, callbackUrl: `${callback.origin}${callback.pathname}` };
    },
  };
}

function environment(mock: Mock, config: Partial<McpRuntimeConfig> = {}) {
  const runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, ...config };
  const transport = createDirectMcpTransport(loopbackTls(mock));
  const storage = createMemoryMcpCredentialStorage();
  const credentialStore = new McpCredentialStore(storage);
  const browser = browserFor(mock);
  let seed = 1;
  const authorizer = new McpAuthorizer({
    transport,
    launcher: browser,
    credentialStore,
    random: { randomBytes: (n) => Uint8Array.from({ length: n }, () => (seed = (seed * 48271) % 2147483647) & 0xff) },
    identity: MCP_FIXTURE_CLIENT_IDENTITY,
  });
  const repository = createMemoryMcpServerRepository();
  const probe = new McpAddProbe({ runtimeConfig, authorizer, credentialStore, transport });
  const coordinator = new McpAddCoordinator({ probe, repository, credentialStore, runtimeConfig });
  const client = (endpoint = mock.endpoint) => new McpClient({ endpoint, transport, runtimeConfig });
  return { runtimeConfig, transport, storage, credentialStore, browser, authorizer, repository, coordinator, client };
}

let serial = 0;
function newServerId(): string {
  serial += 1;
  return `00000000-0000-4000-8000-${String(serial).padStart(12, '0')}`;
}

async function add(env: ReturnType<typeof environment>, mock: Mock, extra: Partial<Parameters<McpAddCoordinator['add']>[0]> = {}) {
  const serverId = newServerId();
  const states: McpAddState['kind'][] = [];
  const state = await env.coordinator.add({
    url: mock.endpoint,
    authKind: 'auto',
    uid: UID,
    serverId,
    confirmAuthorization: async () => true,
    progress: (s) => void states.push(s.kind),
    ...extra,
  });
  return { serverId, state, states };
}

// ── Both protocol generations × no sign-in (JSON and SSE response forms) ──

describe.each([
  ['stateless', []],
  ['stateless', ['--sse']],
  ['session', []],
  ['session', ['--sse']],
] as const)('no sign-in: %s %j', (mode, flags) => {
  it('add → read tools → call; the detected generation matches the server', async () => {
    const mock = await startMock(`--mode=${mode}`, ...flags);
    try {
      const env = environment(mock);
      const { serverId, state, states } = await add(env, mock);
      expect(state.kind).toBe('review');
      expect(states).toEqual(['connecting', 'finishing', 'review']);
      const expectedGeneration = mode === 'stateless' ? 'stateless' : 'session';
      const connection = env.repository.connectionStates.get(serverId)!;
      expect(connection).toMatchObject({ status: 'connected', generation: expectedGeneration, negotiatedVersion: mode === 'stateless' ? '2026-07-28' : '2025-11-25' });
      if (mode === 'session') {
        expect(connection.sessionId).toMatch(/^sess_/);
        expect(env.repository.records.get(serverId)!.name).toBe('OriveoMockServer');
      } else {
        expect(env.repository.records.get(serverId)!.name).toBe('127.0.0.1');
      }
      expect(env.repository.permissions.get(serverId)).toEqual({ get_weather: 'auto', create_issue: 'ask' });

      // Call directly with the same negotiation result: modern relies on per-request _meta and Mcp-* headers
      // (the mock server answers -32020 without them),
      // legacy relies on the session header (400 without it).
      const client = env.client();
      client.restoreSession({ generation: connection.generation!, protocolVersion: connection.negotiatedVersion!, sessionId: connection.sessionId, serverName: null });
      const result = await client.callTool('get_weather', { location: 'Berlin' });
      expect(result).toMatchObject({ isError: false, errorCode: null });
      expect(result.text).toContain('Current weather in Berlin');

      const calls = (await mock.state()).calls as Record<string, number>;
      expect(calls.toolsCall).toBe(1);
      if (mode === 'session') expect(calls.initialize).toBeGreaterThanOrEqual(1);
      else expect(calls.initialize).toBe(0);
    } finally {
      mock.stop();
    }
  });
});

describe('tool call outcomes (real connection)', () => {
  it('isError → tool_error; input_required → needs_input_unsupported; unknown tool → tool_error without retry', async () => {
    const mock = await startMock('--mode=stateless');
    try {
      const env = environment(mock);
      const client = env.client();
      expect((await client.connect()).kind).toBe('connected');
      expect(await client.callTool('failing_tool', {})).toMatchObject({ isError: true, errorCode: 'tool_error' });
      expect(await client.callTool('ask_for_input', {})).toMatchObject({ errorCode: 'needs_input_unsupported', text: '' });
      await expect(client.callTool('no_such_tool', {})).rejects.toMatchObject({ code: 'tool_error' });
      expect(((await mock.state()).calls as Record<string, number>).toolsCall).toBe(3);
    } finally {
      mock.stop();
    }
  });

  it('legacy session forgotten by the server (unknown session → 404) → one new handshake, then tools are fetched', async () => {
    const mock = await startMock('--mode=session');
    try {
      const env = environment(mock);
      const client = env.client();
      client.restoreSession({ generation: 'session', protocolVersion: '2025-11-25', sessionId: 'sess_forgotten', serverName: null });
      const tools = await client.listTools();
      expect(tools.map((t) => t.name)).toEqual(['get_weather', 'create_issue']);
      expect(client.session?.sessionId).toMatch(/^sess_(?!forgotten)/);
      expect(((await mock.state()).calls as Record<string, number>).initialize).toBe(1);
    } finally {
      mock.stop();
    }
  });
});

// ── Access token ─────────────────────────────────────────────────────────

describe('access token (real connection, token mode)', () => {
  it('right token: add succeeds, token is stored, call with it succeeds; wrong token: token field error and nothing left behind', async () => {
    const mock = await startMock('--mode=token', '--token=mock_secret');
    try {
      const env = environment(mock);
      const ok = await add(env, mock, { authKind: 'token', token: 'mock_secret' });
      expect(ok.state.kind).toBe('review');
      const stored = await env.credentialStore.load(ok.serverId, UID);
      expect(stored?.pastedToken).toBe('mock_secret');

      const client = env.client();
      expect((await client.connect({ bearerToken: await env.authorizer.validAccessToken(ok.serverId, UID) })).kind).toBe('connected');
      expect((await client.callTool('list_issues', { repo: 'o/r' })).text).toBe('Issues in o/r: #1, #2');

      const bad = await add(env, mock, { authKind: 'token', token: 'wrong' });
      expect(bad.state.kind).toBe('tokenRejected');
      expect(env.repository.records.has(bad.serverId)).toBe(false);
      expect([...env.storage.snapshot().keys()].some((key) => key.includes(bad.serverId))).toBe(false);
    } finally {
      mock.stop();
    }
  });

  it('automatic sign-in hitting a 401 with no authorization server → access token required', async () => {
    const mock = await startMock('--mode=token');
    try {
      const env = environment(mock);
      const result = await add(env, mock, { authKind: 'auto' });
      expect(result.state.kind).toBe('needsToken');
      expect(env.repository.records.size).toBe(0);
    } finally {
      mock.stop();
    }
  });
});

// ── Full OAuth (CIMD / DCR) ──────────────────────────────────────────────

describe('browser sign-in (real connection, oauth-cimd)', () => {
  it('discovery → pre-sign-in prompt → authorization page → token exchange → read tools; a later refresh yields a new, working token', async () => {
    const mock = await startMock('--mode=oauth-cimd');
    try {
      const env = environment(mock);
      const prompts: string[] = [];
      const result = await add(env, mock, { confirmAuthorization: async (prompt) => (prompts.push(prompt.authorizationHost), true) });
      expect(result.state.kind).toBe('review');
      expect(result.states).toEqual(['connecting', 'authPrompt', 'browser', 'finishing', 'review']);
      expect(prompts).toEqual(['127.0.0.1']);

      const opened = new URL(env.browser.opened[0]!);
      expect(opened.searchParams.get('client_id')).toBe(MCP_FIXTURE_CLIENT_ID);
      expect(opened.searchParams.get('code_challenge_method')).toBe('S256');
      expect(opened.searchParams.get('resource')).toBe(mock.endpoint);
      expect(opened.searchParams.get('scope')).toBe('files:read files:write offline_access');

      const before = await mock.state();
      expect(before).toMatchObject({ codesIssued: 1, tokensIssued: 1, clientsRegistered: 0 });
      const credentials = await env.credentialStore.load(result.serverId, UID);
      expect(credentials).toMatchObject({ hasRefreshToken: true, clientId: MCP_FIXTURE_CLIENT_ID, resource: mock.endpoint });

      const refreshed = await env.authorizer.refresh(result.serverId, UID);
      expect(refreshed.accessToken).not.toBe(credentials!.accessToken);
      expect((await mock.state()).tokensIssued).toBe(2);
      const client = env.client();
      expect((await client.connect({ bearerToken: refreshed.accessToken })).kind).toBe('connected');
      expect((await client.callTool('create_issue', { repo: 'o/r', title: 'T' })).text).toBe('Created issue T in o/r');
    } finally {
      mock.stop();
    }
  });

  it('keeps the token out of the credential medium until the record is saved: at that moment the authorization server has issued it and the medium is still empty', async () => {
    const mock = await startMock('--mode=oauth-cimd');
    try {
      const env = environment(mock);
      const addServer = env.repository.addServer.bind(env.repository);
      let atCommit: { keys: string[]; tokensIssued: unknown } | null = null;
      env.repository.addServer = async (addition, max) => {
        atCommit = { keys: [...env.storage.snapshot().keys()], tokensIssued: (await mock.state()).tokensIssued };
        return addServer(addition, max);
      };
      const result = await add(env, mock);
      expect(result.state.kind).toBe('review');
      expect(atCommit).toEqual({ keys: [], tokensIssued: 1 });
      expect([...env.storage.snapshot().keys()].sort()).toEqual(
        [McpCredentialStore.accessKey(result.serverId, UID), McpCredentialStore.refreshKey(result.serverId, UID)].sort(),
      );
    } finally {
      mock.stop();
    }
  });

  it('declining the pre-sign-in prompt → sign-in not completed and nothing happened on the authorization server', async () => {
    const mock = await startMock('--mode=oauth-cimd');
    try {
      const env = environment(mock);
      const result = await add(env, mock, { confirmAuthorization: async () => false });
      expect(result.state.kind).toBe('authCancelled');
      expect(env.browser.opened).toEqual([]);
      expect(await mock.state()).toMatchObject({ codesIssued: 0, tokensIssued: 0 });
      expect(env.repository.records.size).toBe(0);
    } finally {
      mock.stop();
    }
  });
});

describe('browser sign-in (real connection, oauth-dcr)', () => {
  it('registers dynamically only after consent; a second server on the same authorization server reuses the registration', async () => {
    const mock = await startMock('--mode=oauth-dcr');
    try {
      const env = environment(mock);
      const first = await add(env, mock);
      expect(first.state.kind).toBe('review');
      expect(await mock.state()).toMatchObject({ clientsRegistered: 1, tokensIssued: 1 });
      const registration = await env.credentialStore.loadClientRegistration(mock.httpsOrigin, UID);
      expect(registration?.clientId).toMatch(/^dcr_/);

      const second = await add(env, mock);
      expect(second.state.kind).toBe('review');
      expect(await mock.state()).toMatchObject({ clientsRegistered: 1, tokensIssued: 2 });
      expect(env.repository.records.size).toBe(2);
      // Two servers with the same name: the slug is made unique when stored.
      expect([...env.repository.records.values()].map((r) => r.slug).sort()).toEqual(['127001', '1270012']);
    } finally {
      mock.stop();
    }
  });
});

// ── Errors ───────────────────────────────────────────────────────────────

describe('errors (real connection)', () => {
  it('server always answers 500 → connect fails with server_error, add reports unreachable and leaves nothing behind', async () => {
    const mock = await startMock('--mode=error');
    try {
      const env = environment(mock);
      expect(await env.client().connect()).toMatchObject({ kind: 'failed', error: { code: 'server_error' } });
      const result = await add(env, mock);
      expect(result.state.kind).toBe('unreachable');
      expect(env.repository.records.size).toBe(0);
    } finally {
      mock.stop();
    }
  });

  it('slow response beyond the call timeout → timeout; caller abort → cancelled', async () => {
    const mock = await startMock('--mode=slow', '--delay-ms=2000');
    try {
      const env = environment(mock, { callTimeoutSeconds: 0.3 });
      const started = Date.now();
      expect(await env.client().connect()).toMatchObject({ kind: 'failed', error: { code: 'timeout' } });
      expect(Date.now() - started).toBeLessThan(1_500);

      const controller = new AbortController();
      const pending = environment(mock, { callTimeoutSeconds: 30 }).client().connect({ signal: controller.signal });
      setTimeout(() => controller.abort(), 100);
      expect(await pending).toMatchObject({ kind: 'failed', error: { code: 'cancelled' } });

      const env2 = environment(mock, { callTimeoutSeconds: 0.3 });
      expect((await add(env2, mock)).state.kind).toBe('unreachable');
    } finally {
      mock.stop();
    }
  });

  it('a non-MCP URL (bare 404) → not an MCP server; nothing listening on the port → unreachable', async () => {
    const mock = await startMock('--mode=stateless');
    try {
      const env = environment(mock);
      expect((await add(env, mock, { url: `${mock.httpsOrigin}/not-mcp` })).state.kind).toBe('notMcp');
      mock.stop();
      expect((await add(env, mock)).state.kind).toBe('unreachable');
      expect(env.repository.records.size).toBe(0);
    } finally {
      mock.stop();
    }
  });
});

// ── Mutable tool list → quarantine ───────────────────────────────────────

describe('tool list changes → quarantine (real connection, --mutable-tools)', () => {
  it('added tools and tools with a changed description go back to quarantine and are not sent out; confirming releases them', async () => {
    const mock = await startMock('--mode=stateless', '--mutable-tools');
    try {
      const env = environment(mock);
      const client = env.client();
      expect((await client.connect()).kind).toBe('connected'); // the probe itself is a tools/list too (round 0)
      const serverId = newServerId();

      const round1 = await client.listTools(); // round 1: list_issues is added
      const initial = buildToolSnapshots({ serverId, definitions: round1, runtimeConfig: env.runtimeConfig }).map((s) => ({ ...s, pendingReview: false }));
      const permissions = { get_weather: 'auto', create_issue: 'ask', list_issues: 'auto' } as const;

      const round2 = await client.listTools(); // round 2: the description of get_weather changed
      const refreshed = buildToolSnapshots({ serverId, definitions: round2, runtimeConfig: env.runtimeConfig, existing: initial });
      expect(diffToolSnapshots(initial, refreshed)).toEqual([{ kind: 'changed', toolName: 'get_weather', title: 'Weather Information Provider' }]);
      expect(outboundToolSnapshots(refreshed, permissions).map((s) => s.toolName)).toEqual(['create_issue', 'list_issues']);

      const confirmed = confirmToolSnapshots({ snapshots: refreshed, definitions: round2, permissions, runtimeConfig: env.runtimeConfig });
      expect(confirmed.stillPending).toEqual([]);
      expect(outboundToolSnapshots(confirmed.snapshots, confirmed.permissions).map((s) => s.toolName)).toEqual(['get_weather', 'create_issue', 'list_issues']);

      // The tool set seen when first adding differs from later ones: round 0 has only two tools, list_issues appears from round 1.
      const first = buildToolSnapshots({ serverId, definitions: round1.slice(0, 2), runtimeConfig: env.runtimeConfig }).map((s) => ({ ...s, pendingReview: false }));
      const grown = buildToolSnapshots({ serverId, definitions: round1, runtimeConfig: env.runtimeConfig, existing: first });
      expect(diffToolSnapshots(first, grown)).toEqual([{ kind: 'added', toolName: 'list_issues', title: 'List Issues' }]);
      expect(grown.find((s) => s.toolName === 'list_issues')!.pendingReview).toBe(true);
    } finally {
      mock.stop();
    }
  });
});

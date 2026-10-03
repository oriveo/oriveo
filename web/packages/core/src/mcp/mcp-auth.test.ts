import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import {
  McpAuthorizer,
  McpAuthorizerError,
  authorizationServerMetadataCandidates,
  buildAuthorizationUrl,
  canonicalResourceUri,
  dcrRegistrationBody,
  mcpClientMetadataDocument,
  mcpWebClientIdentity,
  pkceChallenge,
  protectedResourceMetadataCandidates,
  resourceCoversEndpoint,
  tokenExchangeForm,
  validateAuthorizationCallback,
  type McpAuthorizationLauncher,
  type McpAuthorizationPlan,
} from './mcp-auth';
import { McpCredentialStore, createMemoryMcpCredentialStorage, type McpCredentialStorage } from './mcp-credentials';
import { MCP_FIXTURE_CLIENT_ID, MCP_FIXTURE_CLIENT_IDENTITY, MCP_FIXTURE_REDIRECT_URI } from './mcp-fixture-identity';
import { McpTransportError, type McpHttpRequest, type McpTransport } from './mcp-transport';
import { parseWwwAuthenticate } from './mcp-www-authenticate';

/**
 * The authorizer against the frozen `auth/` fixtures. The transport and the browser authorization page are
 * fakes; assertions target the requests the authorizer actually sends and what it actually writes to the credential medium.
 */
const FIXTURES = resolve(__dirname, '../../../../../shared/test-fixtures/mcp/auth');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (name: string): any => JSON.parse(readFileSync(resolve(FIXTURES, name), 'utf8'));

const ENDPOINT = 'https://mcp.example.com/mcp';
const UID = 'user-1';
const SERVER = '6f1c2d3e-0000-4000-8000-000000000001';

type Reply = { status: number; json?: unknown } | 'network' | 'blocked' | 'redirect';

function fakeTransport(routes: Record<string, Reply | ((request: McpHttpRequest) => Reply)>): McpTransport & { sent: McpHttpRequest[] } {
  const sent: McpHttpRequest[] = [];
  return {
    sent,
    async send(request) {
      sent.push(request);
      const route = routes[`${request.method} ${request.url}`];
      const reply = typeof route === 'function' ? route(request) : route ?? { status: 404, json: { error: 'not found' } };
      if (reply === 'network') throw new McpTransportError('network');
      if (reply === 'blocked') throw new McpTransportError('blocked');
      if (reply === 'redirect') throw new McpTransportError('redirect_rejected');
      return {
        status: reply.status,
        headers: new Headers({ 'content-type': 'application/json' }),
        body: new Response(reply.json === undefined ? '' : JSON.stringify(reply.json)).body,
      };
    },
  };
}

const PRM = load('protected-resource-metadata.json');
const AS_CIMD = load('authorization-server-metadata.cimd.json');
const AS_DCR = load('authorization-server-metadata.dcr.json');
const TOKEN = load('token.success.json');

function launcherReturning(build: (request: { url: string; state: string }) => Record<string, string>): McpAuthorizationLauncher & { opened: string[] } {
  const opened: string[] = [];
  return {
    opened,
    async open(request) {
      opened.push(request.url);
      return { params: build(request) };
    },
  };
}

function authorizer(transport: McpTransport, launcher: McpAuthorizationLauncher, storage: McpCredentialStorage = createMemoryMcpCredentialStorage(), now = () => 1_000_000) {
  const store = new McpCredentialStore(storage);
  let seed = 0;
  return {
    store,
    auth: new McpAuthorizer({
      transport,
      launcher,
      credentialStore: store,
      random: { randomBytes: (n) => Uint8Array.from({ length: n }, () => seed++ & 0xff) },
      now,
      identity: MCP_FIXTURE_CLIENT_IDENTITY,
    }),
  };
}

function cimdPlan(overrides: Partial<McpAuthorizationPlan> = {}): McpAuthorizationPlan {
  return {
    issuer: 'https://auth.example.com',
    authorizationEndpoint: 'https://auth.example.com/authorize',
    tokenEndpoint: 'https://auth.example.com/token',
    registrationKind: 'cimd',
    registrationEndpoint: null,
    scope: 'files:read files:write offline_access',
    resource: ENDPOINT,
    issParameterSupported: true,
    ...overrides,
  };
}

describe('pure functions against fixtures', () => {
  it('authorization request query parameters match the fixture (PKCE S256, resource always present, state mandatory)', () => {
    const fixture = load('authorization-request.json');
    const url = buildAuthorizationUrl({
      authorizationEndpoint: fixture.url,
      clientId: fixture.query.client_id,
      redirectUri: fixture.query.redirect_uri,
      state: fixture.perRequestRecord.state,
      codeChallenge: pkceChallenge(fixture.perRequestRecord.codeVerifier),
      resource: fixture.query.resource,
      scope: fixture.query.scope,
    });
    const parsed = new URL(url);
    expect(`${parsed.origin}${parsed.pathname}`).toBe(fixture.url);
    expect(Object.fromEntries(parsed.searchParams)).toEqual(fixture.query);
  });

  it('token exchange form matches the fixture', () => {
    const fixture = load('token.request.json');
    const form = tokenExchangeForm({
      code: fixture.form.code,
      clientId: fixture.form.client_id,
      redirectUri: fixture.form.redirect_uri,
      codeVerifier: fixture.form.code_verifier,
      resource: fixture.form.resource,
    });
    expect(Object.fromEntries(form)).toEqual(fixture.form);
  });

  it('DCR registration request body matches the fixture (application_type: native)', () => {
    const fixture = load('dcr.json');
    expect(dcrRegistrationBody(fixture.request.body.scope, MCP_FIXTURE_CLIENT_IDENTITY)).toEqual(fixture.request.body);
  });

  it('401 parsing and discovery order (fixtures 401.www-authenticate / 401.no-metadata)', () => {
    const withMetadata = load('401.www-authenticate.json');
    const challenge = parseWwwAuthenticate(withMetadata.headers['WWW-Authenticate']);
    expect(protectedResourceMetadataCandidates(challenge, ENDPOINT)).toEqual([
      withMetadata.expect.resourceMetadataURL,
      'https://mcp.example.com/.well-known/oauth-protected-resource/mcp',
    ]);
    const bare = load('401.no-metadata.json');
    expect(protectedResourceMetadataCandidates(parseWwwAuthenticate(bare.headers['WWW-Authenticate']), ENDPOINT)).toEqual(bare.expect.constructedURIs);
  });

  it('the well-known order for authorization server metadata depends on whether the issuer has a path', () => {
    expect(authorizationServerMetadataCandidates('https://auth.example.com')).toEqual(AS_CIMD.expect.wellKnownTried.concat([
      'https://auth.example.com/.well-known/openid-configuration',
    ]));
    expect(authorizationServerMetadataCandidates('https://auth.example.com/tenant1')).toEqual([
      'https://auth.example.com/.well-known/oauth-authorization-server/tenant1',
      'https://auth.example.com/.well-known/openid-configuration/tenant1',
      'https://auth.example.com/tenant1/.well-known/openid-configuration',
    ]);
  });

  it('canonical URI and resource binding (RFC 8707 / RFC 9728 section 3.3)', () => {
    expect(canonicalResourceUri('HTTPS://MCP.Example.com/mcp/#x')).toBe('https://mcp.example.com/mcp');
    expect(resourceCoversEndpoint('https://mcp.example.com/mcp', ENDPOINT)).toBe(true);
    expect(resourceCoversEndpoint('https://mcp.example.com', ENDPOINT)).toBe(true);
    expect(resourceCoversEndpoint('https://mcp.example.com/other', ENDPOINT)).toBe(false);
    expect(resourceCoversEndpoint('https://evil.example/mcp', ENDPOINT)).toBe(false);
    expect(resourceCoversEndpoint(null, ENDPOINT)).toBe(false);
  });

  describe('callback validation 2x2 table (fixture callback.params.json)', () => {
    const fixture = load('callback.params.json');
    for (const testCase of fixture.cases) {
      it(testCase.caseId, () => {
        const result = validateAuthorizationCallback({
          params: testCase.params,
          expectedState: fixture.expectedState,
          expectedIssuer: fixture.expectedIssuer,
          issParameterSupported: testCase.metadata.authorization_response_iss_parameter_supported === true,
        });
        expect(result.accepted).toBe(testCase.expect.accepted);
        if (!result.accepted) expect(result.reason).toBe(testCase.expect.reason);
      });
    }

    it('callback URL is not the one we registered -> rejected', () => {
      const result = validateAuthorizationCallback({
        params: { code: 'c', state: 's' },
        expectedState: 's',
        expectedIssuer: 'https://auth.example.com',
        issParameterSupported: false,
        callbackUrl: 'https://evil.example/mcp/oauth/callback?code=c&state=s',
        registeredRedirectUri: MCP_FIXTURE_REDIRECT_URI,
      });
      expect(result).toEqual({ accepted: false, reason: 'redirect_uri_mismatch' });
    });
  });
});

describe('discovery', () => {
  const challenge = parseWwwAuthenticate(load('401.www-authenticate.json').headers['WWW-Authenticate']);

  it('CIMD: sends GETs only, registers nothing and writes no storage', async () => {
    const storage = createMemoryMcpCredentialStorage();
    const transport = fakeTransport({
      'GET https://mcp.example.com/.well-known/oauth-protected-resource': { status: 200, json: PRM.body },
      'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: AS_CIMD.body },
    });
    const { auth } = authorizer(transport, launcherReturning(() => ({})), storage);
    const outcome = await auth.discover(challenge, ENDPOINT);
    expect(outcome).toEqual({ kind: 'ready', plan: cimdPlan() });
    // Discovery requests follow same-origin redirects; only token and registration requests do not.
    expect(transport.sent.every((r) => r.method === 'GET' && r.redirect === 'same-origin')).toBe(true);
    expect(storage.snapshot().size).toBe(0);
  });

  it('DCR: the plan carries the registration endpoint', async () => {
    const transport = fakeTransport({
      'GET https://mcp.example.com/.well-known/oauth-protected-resource': { status: 200, json: PRM.body },
      'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: AS_DCR.body },
    });
    const { auth } = authorizer(transport, launcherReturning(() => ({})));
    const outcome = await auth.discover(challenge, ENDPOINT);
    expect(outcome).toMatchObject({ kind: 'ready', plan: { registrationKind: 'dcr', registrationEndpoint: 'https://auth.example.com/register', issParameterSupported: false } });
  });

  for (const [name, body] of [
    ['no registration method supported', load('authorization-server-metadata.none.json').body],
    ['issuer mismatch', load('authorization-server-metadata.issuer-mismatch.json').body],
    ['S256 not declared', { ...AS_CIMD.body, code_challenge_methods_supported: ['plain'] }],
  ] as const) {
    it(`${name} → needsToken`, async () => {
      const transport = fakeTransport({
        'GET https://mcp.example.com/.well-known/oauth-protected-resource': { status: 200, json: PRM.body },
        'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: body },
      });
      const { auth } = authorizer(transport, launcherReturning(() => ({})));
      expect(await auth.discover(challenge, ENDPOINT)).toEqual({ kind: 'needsToken' });
    });
  }

  it('protected resource metadata whose resource points elsewhere is not used (all candidates unusable -> needsToken)', async () => {
    const transport = fakeTransport({
      'GET https://mcp.example.com/.well-known/oauth-protected-resource': { status: 200, json: { ...PRM.body, resource: 'https://other.example/mcp' } },
    });
    const { auth } = authorizer(transport, launcherReturning(() => ({})));
    expect(await auth.discover(challenge, ENDPOINT)).toEqual({ kind: 'needsToken' });
  });

  it('a refused redirect on a candidate URL (cross-origin etc.) counts as "nothing here": try the next candidate, not a transient error', async () => {
    // Every candidate's redirect is refused by the transport -> definitely no metadata -> needsToken (not temporarilyUnavailable).
    const allRedirect = fakeTransport(new Proxy({}, { get: () => 'redirect' as const }) as Record<string, Reply>);
    const first = authorizer(allRedirect, launcherReturning(() => ({})));
    expect(await first.auth.discover(challenge, ENDPOINT)).toEqual({ kind: 'needsToken' });
    expect(allRedirect.sent.length).toBeGreaterThan(0);
    expect(allRedirect.sent.every((r) => r.redirect === 'same-origin')).toBe(true);
  });

  it('token and registration requests still do not follow redirects', async () => {
    const transport = fakeTransport({
      'GET https://mcp.example.com/.well-known/oauth-protected-resource': { status: 200, json: PRM.body },
      'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: AS_DCR.body },
      'POST https://auth.example.com/register': { status: 201, json: { client_id: 'dcr-client' } },
      'POST https://auth.example.com/token': { status: 200, json: TOKEN.body },
    });
    const { auth } = authorizer(transport, launcherReturning((request) => ({ code: 'ac-1', state: request.state })));
    const outcome = await auth.discover(challenge, ENDPOINT);
    if (outcome.kind !== 'ready') throw new Error('expected ready');
    await auth.authorize(outcome.plan, SERVER, UID).catch(() => undefined);
    const posts = transport.sent.filter((r) => r.method === 'POST');
    expect(posts.length).toBeGreaterThan(0);
    expect(posts.every((r) => r.redirect === 'never')).toBe(true);
    expect(transport.sent.filter((r) => r.method === 'GET').every((r) => r.redirect === 'same-origin')).toBe(true);
  });

  it('transient error (5xx / network) -> temporarilyUnavailable, not a "needs token" verdict', async () => {
    for (const reply of [{ status: 503 }, 'network'] as const) {
      const transport = fakeTransport({
        'GET https://mcp.example.com/.well-known/oauth-protected-resource': { status: 200, json: PRM.body },
        'GET https://auth.example.com/.well-known/oauth-authorization-server': reply,
        'GET https://auth.example.com/.well-known/openid-configuration': { status: 404 },
      });
      const { auth } = authorizer(transport, launcherReturning(() => ({})));
      expect(await auth.discover(challenge, ENDPOINT)).toEqual({ kind: 'temporarilyUnavailable' });
    }
  });

  it('resource_metadata refused by this site policy (outside .well-known) -> falls back to the constructed well-known URLs', async () => {
    const transport = fakeTransport({
      'GET https://mcp.example.com/meta': 'blocked',
      'GET https://mcp.example.com/.well-known/oauth-protected-resource/mcp': { status: 200, json: PRM.body },
      'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: AS_CIMD.body },
    });
    const { auth } = authorizer(transport, launcherReturning(() => ({})));
    const outcome = await auth.discover(parseWwwAuthenticate('Bearer resource_metadata="https://mcp.example.com/meta"'), ENDPOINT);
    expect(outcome.kind).toBe('ready');
  });
});

describe('authorization and token exchange', () => {
  function tokenRoutes(onToken: (request: McpHttpRequest) => Reply = () => ({ status: 200, json: TOKEN.body })) {
    return { 'POST https://auth.example.com/token': onToken };
  }

  it('full CIMD flow: authorization page URL, token exchange form, token persistence; the refresh token is stored separately', async () => {
    const storage = createMemoryMcpCredentialStorage();
    const transport = fakeTransport(tokenRoutes());
    const launcher = launcherReturning((request) => ({ code: 'ac_123', state: request.state, iss: 'https://auth.example.com' }));
    const { auth, store } = authorizer(transport, launcher, storage);
    const credentials = await auth.authorize(cimdPlan(), SERVER, UID);

    const opened = new URL(launcher.opened[0]!);
    expect(opened.searchParams.get('client_id')).toBe(MCP_FIXTURE_CLIENT_ID);
    expect(opened.searchParams.get('redirect_uri')).toBe(MCP_FIXTURE_REDIRECT_URI);
    expect(opened.searchParams.get('code_challenge_method')).toBe('S256');
    expect(opened.searchParams.get('resource')).toBe(ENDPOINT);

    const tokenRequest = transport.sent.find((r) => r.url === 'https://auth.example.com/token')!;
    expect(tokenRequest.redirect).toBe('never');
    const form = Object.fromEntries(new URLSearchParams(tokenRequest.body));
    expect(form).toMatchObject({ grant_type: 'authorization_code', code: 'ac_123', resource: ENDPOINT, client_id: MCP_FIXTURE_CLIENT_ID });
    expect(pkceChallenge(form.code_verifier!)).toBe(opened.searchParams.get('code_challenge'));
    // Tokens and authorization codes never appear in any URL.
    expect(transport.sent.every((r) => !r.url.includes('ac_123') && !r.url.includes(TOKEN.body.access_token))).toBe(true);

    expect(credentials).toMatchObject({ accessToken: TOKEN.body.access_token, refreshToken: TOKEN.body.refresh_token, expiresAt: 1_000_000 + 3600_000 });
    const raw = storage.snapshot();
    const access = raw.get(McpCredentialStore.accessKey(SERVER, UID))!;
    expect(access).toContain(TOKEN.body.access_token);
    expect(access).not.toContain(TOKEN.body.refresh_token);
    expect(raw.get(McpCredentialStore.refreshKey(SERVER, UID))).toBe(TOKEN.body.refresh_token);
    expect(await store.load(SERVER, UID)).toMatchObject({ hasRefreshToken: true, issuer: 'https://auth.example.com' });
  });

  it('state / iss mismatch: no token exchange and no token saved', async () => {
    const cases: Array<Record<string, string>> = [
      { code: 'ac_123', state: 'forged', iss: 'https://auth.example.com' },
      { code: 'ac_123', iss: 'https://evil.example' },
      { error: 'access_denied', error_description: 'secret text', iss: 'https://evil.example' },
    ];
    for (const params of cases) {
      const storage = createMemoryMcpCredentialStorage();
      const transport = fakeTransport(tokenRoutes());
      const launcher = launcherReturning((request) => ({ state: request.state, ...params }));
      const { auth } = authorizer(transport, launcher, storage);
      const error = await auth.authorize(cimdPlan(), SERVER, UID).catch((e: unknown) => e);
      expect(error).toBeInstanceOf(McpAuthorizerError);
      expect((error as McpAuthorizerError).kind).toBe('callback_rejected');
      expect(String(error)).not.toContain('secret text');
      expect(transport.sent).toHaveLength(0);
      expect(storage.snapshot().size).toBe(0);
    }
  });

  it('user closes the authorization page -> cancelled', async () => {
    const { auth } = authorizer(fakeTransport({}), {
      async open() {
        throw new Error('closed');
      },
    });
    await expect(auth.authorize(cimdPlan(), SERVER, UID)).rejects.toMatchObject({ kind: 'cancelled' });
  });

  it('DCR: registers once and reuses the cache keyed by uid + issuer; a rejected registration is cleared and redone once', async () => {
    const storage = createMemoryMcpCredentialStorage();
    let registrations = 0;
    let tokenCalls = 0;
    const transport = fakeTransport({
      'POST https://auth.example.com/register': (request) => {
        registrations++;
        expect(JSON.parse(request.body!)).toMatchObject({ application_type: 'native' });
        expect(request.redirect).toBe('never');
        return { status: 201, json: { client_id: `dcr_${registrations}` } };
      },
      'POST https://auth.example.com/token': () => {
        tokenCalls++;
        return tokenCalls === 1 ? { status: 400, json: { error: 'invalid_client' } } : { status: 200, json: TOKEN.body };
      },
    });
    const launcher = launcherReturning((request) => ({ code: 'c', state: request.state }));
    const { auth, store } = authorizer(transport, launcher, storage);
    const plan = cimdPlan({ registrationKind: 'dcr', registrationEndpoint: 'https://auth.example.com/register', issParameterSupported: false });
    const credentials = await auth.authorize(plan, SERVER, UID);
    expect(registrations).toBe(2);
    expect(credentials.clientId).toBe('dcr_2');
    expect(await store.loadClientRegistration('https://auth.example.com', UID)).toMatchObject({ clientId: 'dcr_2' });

    // A second server on the same authorization server reuses the registration instead of registering again.
    await auth.authorize(plan, '6f1c2d3e-0000-4000-8000-000000000002', UID);
    expect(registrations).toBe(2);
  });

  it('credentials cannot be written to storage -> credential_persistence_failed', async () => {
    const storage = createMemoryMcpCredentialStorage();
    storage.write = async () => {
      throw new Error('quota');
    };
    const transport = fakeTransport(tokenRoutes());
    const launcher = launcherReturning((request) => ({ code: 'c', state: request.state, iss: 'https://auth.example.com' }));
    const { auth } = authorizer(transport, launcher, storage);
    await expect(auth.authorize(cimdPlan(), SERVER, UID)).rejects.toMatchObject({ kind: 'credential_persistence_failed' });
  });
});

describe('refresh', () => {
  async function seeded(onToken: (request: McpHttpRequest) => Reply, now = 1_000_000) {
    const storage = createMemoryMcpCredentialStorage();
    const transport = fakeTransport({
      'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: AS_CIMD.body },
      'POST https://auth.example.com/token': onToken,
    });
    const { auth, store } = authorizer(transport, launcherReturning(() => ({})), storage, () => now);
    await store.save(
      {
        accessToken: 'mcp_at_example',
        refreshToken: 'mcp_rt_example',
        expiresAt: now + 30_000,
        issuer: 'https://auth.example.com',
        clientId: MCP_FIXTURE_CLIENT_ID,
        resource: ENDPOINT,
        pastedToken: null,
      },
      SERVER,
      UID,
    );
    return { auth, store, storage, transport };
  }

  it('refreshes first when about to expire; the refresh form matches the fixture; concurrent refreshes send one request', async () => {
    const fixture = load('token.refresh.success.json');
    let calls = 0;
    const { auth, transport } = await seeded(() => {
      calls++;
      return { status: 200, json: fixture.body };
    });
    const [a, b] = await Promise.all([auth.validAccessToken(SERVER, UID), auth.validAccessToken(SERVER, UID)]);
    expect(a).toBe(fixture.body.access_token);
    expect(b).toBe(fixture.body.access_token);
    expect(calls).toBe(1);
    const post = transport.sent.find((r) => r.method === 'POST')!;
    expect(Object.fromEntries(new URLSearchParams(post.body))).toEqual(fixture.request.form);
  });

  it('invalid_grant: drops the tokens, keeps the client registration, and a new sign-in is required afterwards', async () => {
    const { auth, store, storage } = await seeded(() => ({ status: 400, json: load('token.error.json').cases[0].body }));
    await expect(auth.refresh(SERVER, UID)).rejects.toMatchObject({ kind: 'token_request_failed' });
    expect(await store.load(SERVER, UID)).toMatchObject({ accessToken: null, hasRefreshToken: false, issuer: 'https://auth.example.com', clientId: MCP_FIXTURE_CLIENT_ID });
    expect(storage.snapshot().has(McpCredentialStore.refreshKey(SERVER, UID))).toBe(false);
    await expect(auth.refresh(SERVER, UID)).rejects.toMatchObject({ kind: 'no_refresh_token' });
  });

  it('transient error with an unexpired token -> keeps using the current token; expired -> throws the transient error', async () => {
    const { auth } = await seeded(() => ({ status: 503 }));
    expect(await auth.validAccessToken(SERVER, UID)).toBe('mcp_at_example');

    const expired = await seeded(() => 'network', 1_000_000);
    await expired.store.save({ ...(await expired.store.load(SERVER, UID)), refreshToken: 'mcp_rt_example', expiresAt: 999_000 }, SERVER, UID);
    await expect(expired.auth.validAccessToken(SERVER, UID)).rejects.toMatchObject({ kind: 'temporarily_unavailable' });
  });

  it('pasted token: returned as the access token when there is no OAuth token; signing in again does not wipe it', async () => {
    const { auth, store } = await seeded(() => ({ status: 200, json: TOKEN.body }));
    await store.delete(SERVER, UID);
    await auth.storePastedToken('pasted', SERVER, UID);
    expect(await auth.validAccessToken(SERVER, UID)).toBe('pasted');
  });

  it('pasting a token over a set of OAuth credentials clears the OAuth fields, and the pasted token is used from then on', async () => {
    const { auth, store, storage } = await seeded(() => ({ status: 200, json: TOKEN.body }), 1_000_000);
    // The access token is far from expiring: without clearing the OAuth fields, validAccessToken would keep returning it.
    await store.save({ ...(await store.load(SERVER, UID)), refreshToken: 'mcp_rt_example', expiresAt: 1_000_000 + 3600_000 }, SERVER, UID);
    await auth.storePastedToken('pasted', SERVER, UID);
    expect(await auth.validAccessToken(SERVER, UID)).toBe('pasted');
    expect(await store.load(SERVER, UID)).toEqual({
      accessToken: null,
      expiresAt: null,
      issuer: null,
      clientId: null,
      resource: null,
      pastedToken: 'pasted',
      hasRefreshToken: false,
    });
    expect(storage.snapshot().has(McpCredentialStore.refreshKey(SERVER, UID))).toBe(false);
  });
});

describe('refresh across execution contexts (concurrent refreshes for the same server MUST be serialized)', () => {
  const ISSUER = 'https://auth.example.com';

  /** An authorization server that rotates refresh tokens: each one works once, and using it again yields invalid_grant. */
  function rotatingServer() {
    let generation = 1;
    const valid = new Set(['rt_1']);
    const tokenRequests: string[] = [];
    const gates: Array<() => void> = [];
    let hold = false;
    const reply = (request: McpHttpRequest): Reply => {
      const presented = new URLSearchParams(request.body).get('refresh_token') ?? '';
      if (!valid.delete(presented)) return { status: 400, json: { error: 'invalid_grant' } };
      generation += 1;
      valid.add(`rt_${generation}`);
      return { status: 200, json: { access_token: `at_${generation}`, token_type: 'Bearer', expires_in: 3600, refresh_token: `rt_${generation}` } };
    };
    const transport: McpTransport = {
      async send(request) {
        if (request.method === 'GET') {
          return { status: 200, headers: new Headers(), body: new Response(JSON.stringify(AS_CIMD.body)).body };
        }
        tokenRequests.push(new URLSearchParams(request.body).get('refresh_token') ?? '');
        // With `hold`, every token request first parks at "sent but not yet at the server", and the test releases them in order.
        if (hold) await new Promise<void>((resolve) => gates.push(resolve));
        const result = reply(request) as { status: number; json?: unknown };
        return { status: result.status, headers: new Headers(), body: new Response(JSON.stringify(result.json)).body };
      },
    };
    return { transport, tokenRequests, gates, holdRequests: () => (hold = true) };
  }

  /** One "tab": its own authorizer and credential cache on top of the same storage. */
  function tab(storage: McpCredentialStorage, transport: McpTransport, refreshLock?: ConstructorParameters<typeof McpAuthorizer>[0]['refreshLock']) {
    const store = new McpCredentialStore(storage);
    return { store, auth: new McpAuthorizer({ transport, credentialStore: store, random: { randomBytes: (n) => new Uint8Array(n) }, now: () => 1_000_000, identity: MCP_FIXTURE_CLIENT_IDENTITY, refreshLock }) };
  }

  async function seedExpiring(storage: McpCredentialStorage) {
    await new McpCredentialStore(storage).save(
      { accessToken: 'at_1', refreshToken: 'rt_1', expiresAt: 1_000_000 + 30_000, issuer: ISSUER, clientId: MCP_FIXTURE_CLIENT_ID, resource: ENDPOINT, pastedToken: null },
      SERVER,
      UID,
    );
  }

  /** A mutex with `navigator.locks` semantics: tasks under the same name queue up, and the next starts only when the previous one is done. */
  function sharedLock() {
    const tails = new Map<string, Promise<unknown>>();
    const names: string[] = [];
    const lock = <T,>(name: string, task: () => Promise<T>): Promise<T> => {
      names.push(name);
      const run = (tails.get(name) ?? Promise.resolve()).then(task, task);
      tails.set(name, run.catch(() => {}));
      return run;
    };
    return { lock, names };
  }

  it('two tabs notice the token is about to expire at the same time: one refresh, and the latecomer uses the new token directly', async () => {
    const storage = createMemoryMcpCredentialStorage();
    await seedExpiring(storage);
    const server = rotatingServer();
    const { lock, names } = sharedLock();
    const a = tab(storage, server.transport, lock);
    const b = tab(storage, server.transport, lock);
    // Both caches hold the old token.
    await a.store.load(SERVER, UID);
    await b.store.load(SERVER, UID);

    const tokens = await Promise.all([a.auth.validAccessToken(SERVER, UID), b.auth.validAccessToken(SERVER, UID)]);
    expect(tokens).toEqual(['at_2', 'at_2']);
    expect(server.tokenRequests).toEqual(['rt_1']);
    expect(names).toEqual([`mcp-refresh:${UID}:${SERVER}`, `mcp-refresh:${UID}:${SERVER}`]);
    expect(storage.snapshot().get(McpCredentialStore.refreshKey(SERVER, UID))).toBe('rt_2');
  });

  it('with no lock available, a late invalid_grant does not wipe the new token just obtained elsewhere', async () => {
    const storage = createMemoryMcpCredentialStorage();
    await seedExpiring(storage);
    const server = rotatingServer();
    server.holdRequests();
    const a = tab(storage, server.transport);
    const b = tab(storage, server.transport);

    const first = a.auth.refresh(SERVER, UID);
    const second = b.auth.refresh(SERVER, UID);
    await vi.waitFor(() => expect(server.gates).toHaveLength(2));
    // Both requests left carrying the same old refresh token. A arrives first: rotation succeeds and is persisted.
    server.gates[0]!();
    await expect(first).resolves.toMatchObject({ accessToken: 'at_2' });
    // B arrives later: the server declares the old token it holds void.
    server.gates[1]!();
    await expect(second).resolves.toMatchObject({ accessToken: 'at_2' });

    expect(server.tokenRequests).toEqual(['rt_1', 'rt_1']);
    const raw = storage.snapshot();
    expect(raw.get(McpCredentialStore.refreshKey(SERVER, UID))).toBe('rt_2');
    expect(JSON.parse(raw.get(McpCredentialStore.accessKey(SERVER, UID))!)).toMatchObject({ accessToken: 'at_2', hasRefreshToken: true });
    // Afterwards it works as usual and can be refreshed again.
    expect(await b.auth.validAccessToken(SERVER, UID)).toBe('at_2');
  });

  it('refresh token really void (storage still holds the one we sent) -> tokens are dropped as before', async () => {
    const storage = createMemoryMcpCredentialStorage();
    await seedExpiring(storage);
    await storage.write(McpCredentialStore.refreshKey(SERVER, UID), 'rt_revoked');
    const server = rotatingServer();
    const a = tab(storage, server.transport);
    await expect(a.auth.refresh(SERVER, UID)).rejects.toMatchObject({ kind: 'token_request_failed' });
    expect(storage.snapshot().has(McpCredentialStore.refreshKey(SERVER, UID))).toBe(false);
  });
});

describe('the web identity derives from the current origin', () => {
  function discoveryRoutes(as: { body: Record<string, unknown> }) {
    return {
      'GET https://mcp.example.com/.well-known/oauth-protected-resource/mcp': { status: 200, json: PRM.body },
      'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, json: as.body },
    } as const;
  }
  function webAuthorizer(origin: string, publiclyReachable: boolean, routes: Record<string, Reply | ((request: McpHttpRequest) => Reply)>) {
    const transport = fakeTransport(routes);
    const store = new McpCredentialStore(createMemoryMcpCredentialStorage());
    const auth = new McpAuthorizer({
      transport,
      credentialStore: store,
      random: { randomBytes: (n) => new Uint8Array(n) },
      identity: mcpWebClientIdentity(origin, { publiclyReachable }),
    });
    return { auth, transport, store };
  }

  it('public https origin: the CIMD client_id and the redirect URI both live under the current origin', async () => {
    const { auth } = webAuthorizer('https://chat.selfhosted.example', true, discoveryRoutes(AS_CIMD));
    const outcome = await auth.discover(null, ENDPOINT);
    if (outcome.kind !== 'ready') throw new Error(`unexpected ${outcome.kind}`);
    expect(outcome.plan.registrationKind).toBe('cimd');
    const attempt = await auth.beginAuthorization(outcome.plan, UID);
    const query = new URL(attempt.url).searchParams;
    expect(query.get('client_id')).toBe('https://chat.selfhosted.example/oauth/mcp-client.json');
    expect(query.get('redirect_uri')).toBe('https://chat.selfhosted.example/mcp/oauth/callback');
    expect(mcpClientMetadataDocument('https://chat.selfhosted.example')).toMatchObject({
      client_id: query.get('client_id'),
      redirect_uris: expect.arrayContaining([query.get('redirect_uri')]),
    });
  });

  it('localhost / private origin: authorization server supports CIMD only -> needs an access token; DCR also supported -> uses DCR and registers the current origin redirect', async () => {
    const { registration_endpoint: _dcr, ...cimdOnlyMetadata } = AS_CIMD.body;
    const cimdOnly = webAuthorizer('http://localhost:3001', false, discoveryRoutes({ body: cimdOnlyMetadata }));
    expect(await cimdOnly.auth.discover(null, ENDPOINT)).toEqual({ kind: 'needsToken' });

    let registered: Record<string, unknown> | null = null;
    const both = webAuthorizer('http://localhost:3001', false, {
      ...discoveryRoutes({ body: { ...cimdOnlyMetadata, registration_endpoint: 'https://auth.example.com/register' } }),
      'POST https://auth.example.com/register': (request) => {
        registered = JSON.parse(request.body!);
        return { status: 201, json: { client_id: 'dcr-local' } };
      },
    });
    const outcome = await both.auth.discover(null, ENDPOINT);
    if (outcome.kind !== 'ready') throw new Error(`unexpected ${outcome.kind}`);
    expect(outcome.plan.registrationKind).toBe('dcr');
    const attempt = await both.auth.beginAuthorization(outcome.plan, UID);
    expect(registered).toMatchObject({ redirect_uris: ['http://localhost:3001/mcp/oauth/callback'], application_type: 'native' });
    expect(new URL(attempt.url).searchParams.get('redirect_uri')).toBe('http://localhost:3001/mcp/oauth/callback');
    expect(attempt.clientId).toBe('dcr-local');
    // Opened from another origin: the redirect URI reported by the old registration no longer matches, so register again.
    expect(await both.store.loadClientRegistration('https://auth.example.com', UID)).toMatchObject({ redirectUris: ['http://localhost:3001/mcp/oauth/callback'] });
  });

  it('DCR on a public https origin reports application_type: web', () => {
    const identity = mcpWebClientIdentity('https://chat.selfhosted.example/', { publiclyReachable: true });
    expect(dcrRegistrationBody(null, identity)).toMatchObject({ redirect_uris: ['https://chat.selfhosted.example/mcp/oauth/callback'], application_type: 'web' });
  });
});

describe('credential storage', () => {
  it('removing a server deletes all of its credentials and leaves other partitions and the client registration alone', async () => {
    const storage = createMemoryMcpCredentialStorage();
    const store = new McpCredentialStore(storage);
    await store.save({ accessToken: 'a', refreshToken: 'r' }, SERVER, UID);
    await store.save({ accessToken: 'b' }, SERVER, 'user-2');
    await store.saveClientRegistration({ clientId: 'dcr', issuer: 'https://auth.example.com', redirectUris: [] }, UID);
    await store.delete(SERVER, UID);
    expect([...storage.snapshot().keys()].sort()).toEqual([`${UID}:dcr:https://auth.example.com`, `user-2:${SERVER}`]);
    expect(await store.load(SERVER, UID)).toBeNull();
    expect(await store.load(SERVER, 'user-2')).toMatchObject({ accessToken: 'b' });
  });

  it('throws when a delete fails, because the caller has to know', async () => {
    const storage = createMemoryMcpCredentialStorage();
    storage.delete = async () => {
      throw new Error('locked');
    };
    await expect(new McpCredentialStore(storage).delete(SERVER, UID)).rejects.toThrow();
  });
});

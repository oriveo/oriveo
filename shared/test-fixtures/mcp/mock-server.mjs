#!/usr/bin/env node
// Local MCP mock server (the common target of every client's integration tests)
//
// A single Node file with zero dependencies that listens on the loopback address only. Command-line
// arguments select the mode, covering the behaviour that can only be verified over a real
// connection: both protocol generations, token-protected servers, full OAuth (with both CIMD and
// DCR registration), errors, slow responses and a tool list that changes.
//
// Usage:
//   node mock-server.mjs --mode=<mode> [--port=<port>] [--token=<token>]
//                        [--sse] [--delay-ms=<n>] [--mutable-tools]
//
// mode:
//   stateless    2026-07-28 stateless server. Validates the per-request _meta and the Mcp-* headers:
//                a missing header or a header/body mismatch returns 400 + -32020, a missing required
//                _meta field returns 400 + -32602, an unsupported version returns 400 + -32022 and
//                an unknown method returns 404 + -32601.
//   session      2025-11-25 legacy server. initialize comes first (the response header carries
//                MCP-Session-Id) and every later request must carry the session header; without it
//                the answer is 400 + -32000 (**not** a recognisable modern error code, so a client
//                should fall back to initialize).
//   token        Every request needs Authorization: Bearer <token>, otherwise 401 + WWW-Authenticate.
//   oauth-cimd   As above, plus a minimal built-in authorization server: protected resource metadata,
//                authorization server metadata (client_id_metadata_document_supported: true),
//                /authorize and /token.
//   oauth-dcr    As above, but the authorization server metadata only offers registration_endpoint
//                (dynamic registration).
//   error        Every request returns 500 + JSON-RPC -32603.
//   slow         Sleeps delay-ms (3000 by default when --delay-ms is not given), then answers like
//                stateless.
//
// Helper endpoints (not part of MCP):
//   GET /__mock/state                 current internal state (call counters, tokens issued, ...)
//   POST /__mock/mutate               advances the tool list by one change under --mutable-tools
//
// Exit: SIGINT / SIGTERM shut it down cleanly.

import { createHash, randomBytes } from 'node:crypto';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const MODERN_VERSION = '2026-07-28';
const LEGACY_VERSION = '2025-11-25';

// Recognisable "modern JSON-RPC errors": a client that sees one of these codes must not fall back to initialize.
const MODERN_ERROR_CODES = new Set([-32020, -32021, -32022]);

function parseArgs(argv) {
  const args = { mode: 'stateless', port: 0, token: 'mcp_test_token', sse: false, delayMs: 0, delayMsSet: false, mutableTools: false };
  for (const raw of argv.slice(2)) {
    if (raw === '--help' || raw === '-h') args.help = true;
    else if (raw === '--sse') args.sse = true;
    else if (raw === '--mutable-tools') args.mutableTools = true;
    else if (raw.startsWith('--mode=')) args.mode = raw.slice('--mode='.length);
    else if (raw.startsWith('--port=')) args.port = Number(raw.slice('--port='.length));
    else if (raw.startsWith('--token=')) args.token = raw.slice('--token='.length);
    else if (raw.startsWith('--delay-ms=')) {
      args.delayMs = Number(raw.slice('--delay-ms='.length));
      args.delayMsSet = true;
    } else unknown(raw);
  }
  const modes = ['stateless', 'session', 'token', 'oauth-cimd', 'oauth-dcr', 'error', 'slow'];
  if (!modes.includes(args.mode)) {
    throw new Error(`unknown --mode=${args.mode}; expected one of ${modes.join(', ')}`);
  }
  // --mode=slow must really be slow without --delay-ms too: give it an observable default, otherwise the mode is a no-op.
  if (args.mode === 'slow' && !args.delayMsSet) args.delayMs = 3000;
  return args;
}

function unknown(raw) {
  throw new Error(`unknown argument ${raw}`);
}

const USAGE = `usage: node mock-server.mjs --mode=<stateless|session|token|oauth-cimd|oauth-dcr|error|slow> [--port=<n>] [--token=<s>] [--sse] [--delay-ms=<n>] [--mutable-tools]`;

function base64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function header(req, name) {
  const value = req.headers[name.toLowerCase()];
  return Array.isArray(value) ? value[0] : value;
}

function send(res, status, payload, extraHeaders = {}) {
  const body = typeof payload === 'string' ? payload : JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function sendSse(res, chunks) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  for (const chunk of chunks) {
    res.write(`event: message\ndata: ${JSON.stringify(chunk)}\n\n`);
  }
  res.end();
}

function jsonRpcError(id, code, message, data) {
  return { jsonrpc: '2.0', id: id ?? null, error: data ? { code, message, data } : { code, message } };
}

function jsonRpcResult(id, result) {
  return { jsonrpc: '2.0', id: id ?? null, result };
}

// ── Tool definitions and the "mutable tool list" ─────────────────────────────
// Three successive tools/list calls return: the initial two tools → one tool added → the
// description of get_weather changed. That covers both kinds of change: an addition and a new description.
function toolsForRound(round) {
  const weather = {
    name: 'get_weather',
    title: 'Weather Information Provider',
    description: round >= 2 ? 'Get current weather for a location (updated)' : 'Get current weather for a location',
    inputSchema: {
      type: 'object',
      properties: { location: { type: 'string', description: 'City name or zip code' } },
      required: ['location'],
    },
    annotations: { readOnlyHint: true },
  };
  const create = {
    name: 'create_issue',
    title: 'Create Issue',
    description: 'Create a new issue in a repository',
    inputSchema: {
      type: 'object',
      properties: { repo: { type: 'string' }, title: { type: 'string' }, body: { type: 'string' } },
      required: ['repo', 'title'],
    },
    annotations: { readOnlyHint: false },
  };
  const list = [weather, create];
  if (round >= 1) {
    list.push({
      name: 'list_issues',
      title: 'List Issues',
      description: 'List issues in a repository',
      inputSchema: {
        type: 'object',
        properties: { repo: { type: 'string' } },
        required: ['repo'],
      },
      annotations: { readOnlyHint: true },
    });
  }
  return list;
}

class McpMockServer {
  constructor(args) {
    this.args = args;
    this.state = {
      mode: args.mode,
      calls: { toolsList: 0, toolsCall: 0, discover: 0, initialize: 0 },
      sessionsIssued: 0,
      unauthorizedResponses: 0,
      codesIssued: 0,
      tokensIssued: 0,
      clientsRegistered: 0,
      toolMutationRound: 0,
    };
    this.sessions = new Map();
    this.authorizationCodes = new Map();
    this.accessTokens = new Map();
    this.refreshTokens = new Map();
    this.registeredClients = new Map();
  }

  roundForToolsList() {
    // Constant mode always stays on round 0; under --mutable-tools every tools/list advances one round.
    return this.args.mutableTools ? this.state.toolMutationRound : 0;
  }

  origin(req) {
    return `http://${header(req, 'host') ?? '127.0.0.1'}`;
  }

  requiresAuth() {
    return ['token', 'oauth-cimd', 'oauth-dcr'].includes(this.args.mode);
  }

  isOAuth() {
    return ['oauth-cimd', 'oauth-dcr'].includes(this.args.mode);
  }

  // ── HTTP entry point ─────────────────────────────────────────────────────
  async handle(req, res) {
    const url = new URL(req.url, this.origin(req));
    const path = url.pathname;

    if (path === '/__mock/state') {
      send(res, 200, this.state);
      return;
    }
    if (path === '/__mock/mutate' && req.method === 'POST') {
      this.state.toolMutationRound += 1;
      send(res, 200, { toolMutationRound: this.state.toolMutationRound });
      return;
    }

    if (this.isOAuth() && this.handleOAuthDiscovery(req, res, path, url)) return;

    if (path === '/mcp' || path === '/') {
      if (req.method === 'GET' || req.method === 'DELETE') {
        // A modern server answers every GET / DELETE with 405.
        send(res, 405, { error: 'method not allowed' });
        return;
      }
      if (req.method !== 'POST') {
        send(res, 405, { error: 'method not allowed' });
        return;
      }
      this.handleMcp(req, res);
      return;
    }

    send(res, 404, { error: 'not found' });
  }

  // ── OAuth (minimal authorization server, for local tests only) ───────────
  handleOAuthDiscovery(req, res, path, url) {
    if (path === '/.well-known/oauth-protected-resource' || path === '/.well-known/oauth-protected-resource/mcp') {
      send(res, 200, {
        resource: `${this.origin(req)}/mcp`,
        authorization_servers: [this.origin(req)],
        scopes_supported: ['files:read', 'files:write'],
        bearer_methods_supported: ['header'],
      });
      return true;
    }
    if (path === '/.well-known/oauth-authorization-server') {
      const issuer = this.origin(req);
      const metadata = {
        issuer,
        authorization_endpoint: `${issuer}/authorize`,
        token_endpoint: `${issuer}/token`,
        response_types_supported: ['code'],
        grant_types_supported: ['authorization_code', 'refresh_token'],
        code_challenge_methods_supported: ['S256'],
        token_endpoint_auth_methods_supported: ['none'],
        scopes_supported: ['files:read', 'files:write', 'offline_access'],
        authorization_response_iss_parameter_supported: true,
      };
      if (this.args.mode === 'oauth-cimd') {
        metadata.client_id_metadata_document_supported = true;
        metadata.registration_endpoint = `${issuer}/register`;
      } else {
        metadata.registration_endpoint = `${issuer}/register`;
      }
      send(res, 200, metadata);
      return true;
    }
    if (path === '/authorize' && req.method === 'GET') {
      this.handleAuthorize(req, res, url);
      return true;
    }
    if (path === '/token' && req.method === 'POST') {
      this.handleToken(req, res);
      return true;
    }
    if (path === '/register' && req.method === 'POST' && this.args.mode === 'oauth-dcr') {
      this.handleRegister(req, res);
      return true;
    }
    return false;
  }

  handleAuthorize(req, res, url) {
    const q = url.searchParams;
    const clientId = q.get('client_id');
    const redirectUri = q.get('redirect_uri');
    const state = q.get('state');
    const challenge = q.get('code_challenge');
    const method = q.get('code_challenge_method');
    if (!clientId || !redirectUri) {
      send(res, 400, { error: 'invalid_request', error_description: 'client_id and redirect_uri are required' });
      return;
    }
    if (method && method !== 'S256') {
      send(res, 400, { error: 'invalid_request', error_description: 'only S256 is supported' });
      return;
    }
    if (this.args.mode === 'oauth-cimd' && !/^https:\/\/.+\/.+/.test(clientId)) {
      // In CIMD mode client_id must be an https URL with a path.
      send(res, 400, { error: 'invalid_client', error_description: 'client_id must be an https URL with a path' });
      return;
    }
    if (this.args.mode === 'oauth-dcr' && !this.registeredClients.has(clientId)) {
      send(res, 400, { error: 'invalid_client', error_description: 'client_id is not registered' });
      return;
    }
    const code = `code_${randomBytes(8).toString('hex')}`;
    this.authorizationCodes.set(code, {
      clientId,
      redirectUri,
      codeChallenge: challenge,
      resource: q.get('resource') ?? null,
      scope: q.get('scope') ?? null,
    });
    this.state.codesIssued += 1;
    const target = new URL(redirectUri);
    target.searchParams.set('code', code);
    if (state) target.searchParams.set('state', state);
    // RFC 9207: the authorization response carries iss.
    target.searchParams.set('iss', this.origin(req));
    res.writeHead(302, { Location: target.toString() });
    res.end();
  }

  async handleToken(req, res) {
    const form = await readBody(req);
    const params = new URLSearchParams(form);
    const grantType = params.get('grant_type');
    if (grantType === 'refresh_token') {
      const refresh = params.get('refresh_token');
      if (!refresh || !this.refreshTokens.has(refresh)) {
        send(res, 400, { error: 'invalid_grant', error_description: 'Refresh token expired' });
        return;
      }
      this.issueToken(res, this.refreshTokens.get(refresh));
      return;
    }
    if (grantType !== 'authorization_code') {
      send(res, 400, { error: 'unsupported_grant_type' });
      return;
    }
    const code = params.get('code');
    const record = code ? this.authorizationCodes.get(code) : undefined;
    if (!record) {
      send(res, 400, { error: 'invalid_grant', error_description: 'Unknown authorization code' });
      return;
    }
    const verifier = params.get('code_verifier');
    if (record.codeChallenge) {
      const computed = base64url(createHash('sha256').update(verifier ?? '', 'utf8').digest());
      if (computed !== record.codeChallenge) {
        send(res, 400, { error: 'invalid_grant', error_description: 'PKCE verification failed' });
        return;
      }
    }
    // RFC 8707: resource must be sent; it is only recorded here, not enforced (the server side may be lenient, for the client it is a MUST).
    this.authorizationCodes.delete(code);
    this.issueToken(res, { clientId: record.clientId, scope: record.scope, resource: record.resource });
  }

  issueToken(res, record) {
    const access = `at_${randomBytes(12).toString('hex')}`;
    const refresh = `rt_${randomBytes(12).toString('hex')}`;
    const expiresIn = 3600;
    this.accessTokens.set(access, { ...record, expiresAt: Date.now() + expiresIn * 1000 });
    this.refreshTokens.set(refresh, record);
    this.state.tokensIssued += 1;
    send(res, 200, {
      access_token: access,
      token_type: 'Bearer',
      expires_in: expiresIn,
      refresh_token: refresh,
      scope: record.scope,
    });
  }

  async handleRegister(req, res) {
    const raw = await readBody(req);
    let body = {};
    try {
      body = JSON.parse(raw || '{}');
    } catch {
      send(res, 400, { error: 'invalid_client_metadata' });
      return;
    }
    if (!Array.isArray(body.redirect_uris) || body.redirect_uris.length === 0) {
      send(res, 400, { error: 'invalid_redirect_uri' });
      return;
    }
    const clientId = `dcr_${randomBytes(6).toString('hex')}`;
    this.registeredClients.set(clientId, body);
    this.state.clientsRegistered += 1;
    send(res, 201, {
      client_id: clientId,
      client_name: body.client_name ?? 'Oriveo',
      redirect_uris: body.redirect_uris,
      grant_types: body.grant_types ?? ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
      application_type: body.application_type ?? 'native',
    });
  }

  // ── MCP endpoint ────────────────────────────────────────────────────────
  async handleMcp(req, res) {
    if (this.args.mode === 'error') {
      send(res, 500, jsonRpcError(null, -32603, 'Internal error'));
      return;
    }
    const raw = await readBody(req);
    if (this.args.delayMs > 0) await sleep(this.args.delayMs);

    let body;
    try {
      body = JSON.parse(raw || 'null');
    } catch {
      // Not JSON-RPC (HTML / plain text / some other JSON): a client should classify this as "not an MCP server".
      send(res, 400, 'not json-rpc', { 'Content-Type': 'text/plain' });
      return;
    }
    if (!body || body.jsonrpc !== '2.0') {
      send(res, 400, { error: 'not json-rpc' }, { 'Content-Type': 'application/json' });
      return;
    }

    if (this.requiresAuth() && !this.authorizationOk(req)) {
      this.state.unauthorizedResponses += 1;
      const challenge = ['Bearer'];
      if (this.isOAuth()) {
        challenge.push(`resource_metadata="${this.origin(req)}/.well-known/oauth-protected-resource"`);
      }
      challenge.push('scope="files:read files:write"');
      send(res, 401, '', {
        'WWW-Authenticate': challenge.join(', '),
        'Content-Type': 'text/plain',
      });
      return;
    }

    if (this.args.mode === 'session') return this.handleLegacy(req, res, body);
    return this.handleModern(req, res, body);
  }

  authorizationOk(req) {
    const auth = header(req, 'authorization');
    if (!auth) return false;
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!token) return false;
    if (this.args.mode === 'token') return token === this.args.token;
    return this.accessTokens.has(token);
  }

  // Legacy protocol: initialize first, then every request needs the session header.
  handleLegacy(req, res, body) {
    const id = body.id;
    const method = body.method;

    if (method === 'initialize') {
      const requested = body.params?.protocolVersion;
      const negotiated = requested === LEGACY_VERSION ? LEGACY_VERSION : LEGACY_VERSION;
      const sessionId = `sess_${randomBytes(8).toString('hex')}`;
      this.sessions.set(sessionId, { createdAt: Date.now() });
      this.state.sessionsIssued += 1;
      this.state.calls.initialize += 1;
      send(
        res,
        200,
        jsonRpcResult(id, {
          protocolVersion: negotiated,
          capabilities: { tools: { listChanged: true } },
          serverInfo: { name: 'OriveoMockServer', version: '1.0.0' },
        }),
        { 'MCP-Session-Id': sessionId },
      );
      return;
    }

    if (method === 'notifications/initialized') {
      res.writeHead(202, { 'Content-Length': 0 });
      res.end();
      return;
    }

    const sessionId = header(req, 'mcp-session-id');
    if (!sessionId) {
      // A legacy server has no session context: 400 + a JSON-RPC error whose code is **not** a modern one.
      // A client should fall back to initialize when it sees this.
      send(res, 400, jsonRpcError(id, -32000, 'Session not initialized'));
      return;
    }
    if (!this.sessions.has(sessionId)) {
      send(res, 404, jsonRpcError(id, -32000, 'Session not found'));
      return;
    }

    this.dispatchMethods(req, res, body, { legacy: true });
  }

  // Modern protocol: every request carries its own version and capabilities; validate the headers and _meta.
  handleModern(req, res, body) {
    const id = body.id;
    const method = body.method;
    const versionHeader = header(req, 'mcp-protocol-version');
    const meta = body.params?._meta ?? {};

    if (!versionHeader) {
      send(res, 400, jsonRpcError(id, -32020, 'Missing MCP-Protocol-Version header'));
      return;
    }
    if (versionHeader !== MODERN_VERSION) {
      send(
        res,
        400,
        jsonRpcError(id, -32022, 'Unsupported protocol version', {
          supported: [MODERN_VERSION],
          requested: versionHeader,
        }),
      );
      return;
    }
    if (!meta['io.modelcontextprotocol/protocolVersion'] || !meta['io.modelcontextprotocol/clientCapabilities']) {
      send(res, 400, jsonRpcError(id, -32602, 'Invalid params: missing required per-request _meta fields'));
      return;
    }
    const methodHeader = header(req, 'mcp-method');
    if (methodHeader !== method) {
      send(res, 400, jsonRpcError(id, -32020, `Header mismatch: Mcp-Method '${methodHeader ?? ''}' does not match body '${method}'`));
      return;
    }
    if (method === 'tools/call' && header(req, 'mcp-name') !== body.params?.name) {
      send(res, 400, jsonRpcError(id, -32020, 'Header mismatch: Mcp-Name does not match params.name'));
      return;
    }

    this.dispatchMethods(req, res, body, { legacy: false });
  }

  dispatchMethods(req, res, body, { legacy }) {
    const id = body.id;
    const method = body.method;
    const reply = (result) => {
      if (this.args.sse) {
        sendSse(res, [jsonRpcResult(id, result)]);
        return;
      }
      send(res, 200, jsonRpcResult(id, result));
    };

    if (method === 'server/discover') {
      this.state.calls.discover += 1;
      reply({
        resultType: 'complete',
        supportedVersions: legacy ? [LEGACY_VERSION] : [MODERN_VERSION],
        capabilities: { tools: {} },
        _meta: { 'io.modelcontextprotocol/serverInfo': { name: 'OriveoMockServer', version: '1.0.0' } },
        instructions: 'Mock server for Oriveo MCP client tests.',
      });
      return;
    }

    if (method === 'tools/list') {
      this.state.calls.toolsList += 1;
      const round = this.roundForToolsList();
      const tools = toolsForRound(round);
      // Answer with the current round first, then advance: the first tools/list must return the initial
      // two tools and each later call moves one step (one added → description changed), matching the comment on toolsForRound.
      if (this.args.mutableTools) this.state.toolMutationRound += 1;
      reply(legacy ? { tools } : { resultType: 'complete', tools });
      return;
    }

    if (method === 'tools/call') {
      this.state.calls.toolsCall += 1;
      const name = body.params?.name;
      const args = body.params?.arguments ?? {};
      if (name === 'get_weather') {
        reply({
          resultType: 'complete',
          content: [
            {
              type: 'text',
              text: `Current weather in ${args.location ?? 'unknown'}:\nTemperature: 72°F\nConditions: Partly cloudy`,
            },
          ],
          isError: false,
        });
        return;
      }
      if (name === 'create_issue') {
        reply({
          resultType: 'complete',
          content: [{ type: 'text', text: `Created issue ${args.title ?? 'untitled'} in ${args.repo ?? 'unknown'}` }],
          isError: false,
        });
        return;
      }
      if (name === 'list_issues') {
        reply({
          resultType: 'complete',
          content: [{ type: 'text', text: `Issues in ${args.repo ?? 'unknown'}: #1, #2` }],
          isError: false,
        });
        return;
      }
      if (name === 'ask_for_input') {
        // An MRTR input_required is a normal result, not an error.
        reply({
          resultType: 'input_required',
          inputRequests: {
            login: {
              method: 'elicitation/create',
              params: {
                mode: 'form',
                message: 'Please provide your username',
                requestedSchema: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] },
              },
            },
          },
          requestState: base64url(Buffer.from(JSON.stringify({ pending: true }))),
        });
        return;
      }
      if (name === 'failing_tool') {
        // Tool execution error: result.isError = true, not a JSON-RPC error.
        reply({
          resultType: 'complete',
          content: [{ type: 'text', text: 'Invalid departure date: must be in the future.' }],
          isError: true,
        });
        return;
      }
      send(res, 200, jsonRpcError(id, -32602, `Unknown tool: ${name ?? ''}`));
      return;
    }

    if (method === 'ping') {
      reply({});
      return;
    }

    // Unknown method: a modern server returns 404 + -32601 with a JSON-RPC body (which tells it apart from a bare 404).
    send(res, 404, jsonRpcError(id, -32601, 'Method not found'));
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 4 * 1024 * 1024) {
        reject(new Error('request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function createMockServer(args) {
  const server = new McpMockServer(args);
  return http.createServer((req, res) => {
    server.handle(req, res).catch((error) => {
      send(res, 500, jsonRpcError(null, -32603, String(error?.message ?? error)));
    });
  });
}

export { parseArgs, USAGE, MODERN_ERROR_CODES };

// import.meta.url percent-encodes non-ASCII paths, so a plain string comparison would fail; turn both sides back into real paths before comparing.
const invokedDirectly =
  Boolean(process.argv[1]) && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log(USAGE);
  } else {
  const server = createMockServer(args);
  // Loopback only: this process is a test fixture and must not be reachable from other machines on the network.
  server.listen(args.port, '127.0.0.1', () => {
    const { port } = server.address();
    process.stdout.write(`mcp-mock-server mode=${args.mode} sse=${args.sse} delayMs=${args.delayMs} mutableTools=${args.mutableTools}\n`);
    process.stdout.write(`listening http://127.0.0.1:${port}/mcp\n`);
  });
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => server.close(() => process.exit(0)));
  }
  }
}

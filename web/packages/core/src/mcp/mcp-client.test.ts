import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { McpClient, McpClientError, encodeHeaderValue } from './mcp-client';
import { McpTransportError, type McpHttpRequest, type McpHttpResponse, type McpTransport } from './mcp-transport';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig } from './mcp-types';

/**
 * The protocol client replayed against frozen fixtures. The transport is a scripted fake; assertions target
 * the requests the client **actually sends** (headers and bodies built by production code) and how it judges the fixture responses.
 */
const FIXTURES = resolve(__dirname, '../../../../../shared/test-fixtures/mcp/protocol');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (name: string): any => JSON.parse(readFileSync(resolve(FIXTURES, name), 'utf8'));
const loadText = (name: string): string => readFileSync(resolve(FIXTURES, name), 'utf8');

const ENDPOINT = 'https://mcp.example.com/mcp';

interface Sent {
  request: McpHttpRequest;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  body: any;
}

interface Reply {
  status: number;
  headers?: Record<string, string>;
  json?: unknown;
  raw?: string;
  stream?: ReadableStream<Uint8Array>;
}

type Script = (sent: Sent, index: number) => Reply | Promise<Reply> | 'network' | 'hang';

function scripted(script: Script): McpTransport & { sent: Sent[] } {
  const sent: Sent[] = [];
  return {
    sent,
    async send(request) {
      const entry: Sent = { request, body: request.body ? JSON.parse(request.body) : null };
      sent.push(entry);
      const reply = await script(entry, sent.length - 1);
      if (reply === 'network') throw new McpTransportError('network');
      if (reply === 'hang') {
        return new Promise<McpHttpResponse>((_, reject) => {
          request.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        });
      }
      const headers = new Headers(reply.headers ?? {});
      let body: ReadableStream<Uint8Array> | null = reply.stream ?? null;
      if (!body) {
        const text = reply.raw ?? (reply.json === undefined ? '' : JSON.stringify(reply.json));
        if (!headers.has('content-type')) headers.set('content-type', 'application/json');
        body = new Response(text).body;
      }
      return { status: reply.status, headers, body };
    },
  };
}

/** Swaps the id in a fixture response body for the id of this request (fixture ids are the values from recording time). */
function withId(fixtureBody: Record<string, unknown>, sent: Sent): Record<string, unknown> {
  return { ...fixtureBody, id: sent.body?.id ?? null };
}

function toolsListOk(sent: Sent, tools: unknown[] = [{ name: 'get_weather', inputSchema: { type: 'object' } }]): Reply {
  return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { resultType: 'complete', tools } } };
}

function client(transport: McpTransport, config: Partial<McpRuntimeConfig> = {}) {
  return new McpClient({ endpoint: ENDPOINT, transport, runtimeConfig: { ...MCP_RUNTIME_CONFIG_FALLBACK, ...config } });
}

function lowerHeaders(headers: Record<string, string>): Record<string, string> {
  return Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
}

describe('generation probe', () => {
  it('modern probe request headers and body match the fixture, and success means stateless', async () => {
    const fixture = load('stateless/tools-list.request.json');
    const transport = scripted((sent) => toolsListOk(sent));
    const outcome = await client(transport).connect();
    expect(outcome).toEqual({
      kind: 'connected',
      session: { generation: 'stateless', protocolVersion: '2026-07-28', sessionId: null, serverName: null },
    });
    const [probe] = transport.sent;
    expect(probe!.request.method).toBe('POST');
    expect(probe!.request.url).toBe(ENDPOINT);
    expect(probe!.request.headers).toEqual(lowerHeaders(fixture.headers));
    expect(probe!.body).toEqual({ ...fixture.body, id: probe!.body.id });
  });

  it('generic error from a legacy server before initialize -> falls back to the handshake (fixture error.legacy-before-initialize)', async () => {
    const legacy = load('shared/error.legacy-before-initialize.json');
    const init = load('session/initialize.response.json');
    const initRequest = load('session/initialize.request.json');
    const transport = scripted((sent, index) => {
      if (index === 0) return { status: legacy.status, json: withId(legacy.body, sent) };
      if (sent.body.method === 'initialize') return { status: 200, headers: init.headers, json: withId(init.body, sent) };
      return { status: 202, raw: '' };
    });
    const c = client(transport);
    const outcome = await c.connect();
    expect(outcome).toEqual({
      kind: 'connected',
      session: {
        generation: 'session',
        protocolVersion: '2025-11-25',
        sessionId: init.expect.sessionId,
        serverName: 'ExampleServer',
      },
    });
    const initialize = transport.sent[1]!;
    expect(initialize.body).toEqual({ ...initRequest.body, id: initialize.body.id });
    // initialize itself carries neither MCP-Protocol-Version nor the session header.
    expect(initialize.request.headers['mcp-protocol-version']).toBeUndefined();
    expect(initialize.request.headers['mcp-session-id']).toBeUndefined();
    const initialized = transport.sent[2]!;
    expect(initialized.body).toEqual({ jsonrpc: '2.0', method: 'notifications/initialized' });
    expect(initialized.request.headers['mcp-session-id']).toBe(init.expect.sessionId);
    expect(initialized.request.headers['mcp-protocol-version']).toBe('2025-11-25');
  });

  it('later requests of a legacy session carry the negotiated version and the session id, without the modern headers or _meta', async () => {
    const init = load('session/initialize.response.json');
    const expected = load('session/tools-list.request.json');
    const transport = scripted((sent, index) => {
      if (index === 0) return { status: 400, raw: 'Bad Request', headers: { 'content-type': 'text/plain' } };
      if (sent.body?.method === 'initialize') return { status: 200, headers: init.headers, json: withId(init.body, sent) };
      if (sent.body?.method === 'tools/list') return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { tools: [] } } };
      return { status: 202, raw: '' };
    });
    const c = client(transport);
    await c.connect();
    await c.listTools();
    // The first tools/list is the modern probe; only the last one is the fetch inside the session.
    const list = transport.sent.filter((s) => s.body?.method === 'tools/list').at(-1)!;
    expect(list.request.headers).toEqual(lowerHeaders(expected.headers));
    expect(list.body).toEqual({ ...expected.body, id: list.body.id });
  });

  it('-32022 listing a modern version -> retries the modern shape per data.supported, no fallback', async () => {
    const error = load('stateless/error.unsupported-protocol-version.json');
    const transport = scripted((sent, index) =>
      index === 0 ? { status: 400, json: withId(error.body, sent) } : toolsListOk(sent),
    );
    const outcome = await client(transport).connect();
    expect(outcome.kind).toBe('connected');
    expect(transport.sent.map((s) => s.body.method)).toEqual(['tools/list', 'tools/list']);
  });

  it('-32022 listing legacy versions only -> runs the handshake with the highest one we support', async () => {
    const transport = scripted((sent, index) => {
      if (index === 0) {
        return {
          status: 400,
          json: { jsonrpc: '2.0', id: sent.body.id, error: { code: -32022, message: 'x', data: { supported: ['2025-03-26', '2025-06-18'] } } },
        };
      }
      if (sent.body?.method === 'initialize') {
        return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { protocolVersion: '2025-06-18' } } };
      }
      return { status: 202, raw: '' };
    });
    const outcome = await client(transport).connect();
    expect(transport.sent[1]!.body.params.protocolVersion).toBe('2025-06-18');
    expect(outcome).toMatchObject({ kind: 'connected', session: { generation: 'session', protocolVersion: '2025-06-18' } });
  });

  for (const name of ['stateless/error.header-mismatch.json', 'stateless/error.missing-required-capability.json', 'shared/error.invalid-params.json']) {
    it(`a recognizable modern error does not fall back to initialize (${name})`, async () => {
      const fixture = load(name);
      const transport = scripted((sent) => ({ status: fixture.status ?? 400, json: withId(fixture.body, sent) }));
      const outcome = await client(transport).connect();
      expect(outcome).toMatchObject({ kind: 'failed', error: { code: 'server_error' } });
      expect(transport.sent.every((s) => s.body.method !== 'initialize')).toBe(true);
    });
  }

  it('an error message mentioning only Mcp-Session-Id / MCP-Protocol-Version is not a modern marker -> falls back', async () => {
    const transport = scripted((sent, index) => {
      if (index === 0) {
        return { status: 400, json: { jsonrpc: '2.0', id: sent.body.id, error: { code: -32000, message: 'Bad Request: Mcp-Session-Id header is required; Unsupported MCP-Protocol-Version' } } };
      }
      if (sent.body?.method === 'initialize') return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { protocolVersion: '2025-11-25' } } };
      return { status: 202, raw: '' };
    });
    const outcome = await client(transport).connect();
    expect(outcome).toMatchObject({ kind: 'connected', session: { generation: 'session' } });
  });

  it('an error message mentioning Mcp-Method (a modern-only header name) -> judged modern, no fallback', async () => {
    const transport = scripted((sent) => ({ status: 400, json: { jsonrpc: '2.0', id: sent.body.id, error: { code: -32000, message: 'Missing Mcp-Method header' } } }));
    const outcome = await client(transport).connect();
    expect(outcome.kind).toBe('failed');
    expect(transport.sent).toHaveLength(1);
  });

  it('200 + a generic JSON-RPC error falls back by the same criterion', async () => {
    const transport = scripted((sent, index) => {
      if (index === 0) return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, error: { code: -32600, message: 'Server not initialized' } } };
      if (sent.body?.method === 'initialize') return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { protocolVersion: '2025-11-25' } } };
      return { status: 202, raw: '' };
    });
    expect((await client(transport).connect()).kind).toBe('connected');
  });

  it('404 with a JSON-RPC body -> modern, no fallback (fixture error.method-not-found)', async () => {
    const fixture = load('shared/error.method-not-found.json');
    const transport = scripted((sent) => ({ status: 404, json: withId(fixture.body, sent) }));
    const outcome = await client(transport).connect();
    expect(outcome).toMatchObject({ kind: 'failed', error: { code: 'server_error' } });
    expect(transport.sent).toHaveLength(1);
  });

  for (const testCase of load('shared/not-mcp.responses.json').cases) {
    it(`non-MCP response: ${testCase.caseId}`, async () => {
      const transport = scripted((sent) => {
        if (sent.body?.method === 'initialize') {
          // The fallback handshake gets the same "not MCP" response.
          return { status: testCase.status, headers: testCase.headers, raw: testCase.raw ?? JSON.stringify(testCase.body) };
        }
        return { status: testCase.status, headers: testCase.headers, raw: testCase.raw ?? JSON.stringify(testCase.body) };
      });
      expect((await client(transport).connect()).kind).toBe('notMcp');
    });
  }

  it('401 -> needsAuth and the challenge is recorded; 403 insufficient_scope is needsAuth too', async () => {
    const fixture = JSON.parse(readFileSync(resolve(FIXTURES, '../auth/401.www-authenticate.json'), 'utf8'));
    const transport = scripted(() => ({ status: 401, headers: fixture.headers, raw: '' }));
    const c = client(transport);
    expect((await c.connect()).kind).toBe('needsAuth');
    expect(c.authChallenge).toEqual({
      resourceMetadata: fixture.expect.resourceMetadataURL,
      scope: fixture.expect.scope,
      error: null,
      errorDescription: null,
    });

    const scope = JSON.parse(readFileSync(resolve(FIXTURES, '../auth/403.insufficient-scope.json'), 'utf8'));
    const c2 = client(scripted(() => ({ status: 403, headers: scope.headers, raw: '' })));
    expect((await c2.connect()).kind).toBe('needsAuth');
    expect(c2.authChallenge?.error).toBe('insufficient_scope');
  });

  it('network-level failure -> unreachable, the generation probe is not retried', async () => {
    const transport = scripted(() => 'network');
    expect((await client(transport).connect()).kind).toBe('unreachable');
    expect(transport.sent).toHaveLength(1);
  });

  it('response id does not match -> server_error (the first message is not used as a fallback)', async () => {
    const transport = scripted((sent) => ({ status: 200, json: { jsonrpc: '2.0', id: sent.body.id + 100, result: { tools: [] } } }));
    expect(await client(transport).connect()).toMatchObject({ kind: 'failed', error: { code: 'server_error' } });
  });
});

describe('tools/list', () => {
  it('follows pagination to the end', async () => {
    const transport = scripted((sent) => {
      const cursor = sent.body.params.cursor;
      const page = cursor === undefined ? 0 : Number(cursor);
      return {
        status: 200,
        json: {
          jsonrpc: '2.0',
          id: sent.body.id,
          result: { tools: [{ name: `t${page}`, inputSchema: {} }, { title: 'no name' }], ...(page < 2 ? { nextCursor: String(page + 1) } : {}) },
        },
      };
    });
    const c = client(transport);
    await c.connect();
    const tools = await c.listTools();
    expect(tools.map((t) => t.name)).toEqual(['t0', 't1', 't2']);
  });

  it('more than 20 pages is treated as a failure', async () => {
    const transport = scripted((sent) => ({ status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { tools: [], nextCursor: 'again' } } }));
    const c = client(transport);
    await c.connect();
    await expect(c.listTools()).rejects.toMatchObject({ code: 'server_error' });
    expect(transport.sent.length).toBe(1 + 20);
  });

  it('retries once on a network error before the connection is established', async () => {
    let failures = 0;
    const transport = scripted((sent, index) => {
      if (index === 1 && failures === 0) {
        failures++;
        return 'network';
      }
      return toolsListOk(sent);
    });
    const c = client(transport);
    await c.connect();
    expect((await c.listTools()).map((t) => t.name)).toEqual(['get_weather']);
  });

  it('legacy session terminated (404) -> re-initializes once without the session header and fetches again (fixture error.session-terminated)', async () => {
    const terminated = load('session/error.session-terminated.json');
    let sessions = 0;
    let listCalls = 0;
    const transport = scripted((sent, index) => {
      if (index === 0) return { status: 400, raw: '' };
      if (sent.body?.method === 'initialize') {
        sessions++;
        return { status: 200, headers: { 'mcp-session-id': `s${sessions}` }, json: { jsonrpc: '2.0', id: sent.body.id, result: { protocolVersion: '2025-11-25' } } };
      }
      if (sent.body?.method === 'tools/list') {
        listCalls++;
        if (listCalls === 1) return { status: 404, json: withId(terminated.body, sent) };
        return { status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { tools: [{ name: 'a', inputSchema: {} }] } } };
      }
      return { status: 202, raw: '' };
    });
    const c = client(transport);
    await c.connect();
    expect((await c.listTools()).map((t) => t.name)).toEqual(['a']);
    const initializes = transport.sent.filter((s) => s.body?.method === 'initialize');
    expect(initializes).toHaveLength(2);
    expect(initializes[1]!.request.headers['mcp-session-id']).toBeUndefined();
    const lists = transport.sent.filter((s) => s.body?.method === 'tools/list');
    // lists[0] is the modern probe, lists[1] hits the terminated s1, lists[2] uses the s2 from the new handshake.
    expect(lists.map((l) => l.request.headers['mcp-session-id'])).toEqual([undefined, 's1', 's2']);
    expect(c.session?.sessionId).toBe('s2');
  });

  it('sign-in required -> needs_auth', async () => {
    const transport = scripted((sent, index) => (index === 0 ? toolsListOk(sent) : { status: 401, raw: '' }));
    const c = client(transport);
    await c.connect();
    await expect(c.listTools()).rejects.toMatchObject({ code: 'needs_auth' });
  });
});

describe('tools/call', () => {
  async function connected(script: Script, config: Partial<McpRuntimeConfig> = {}) {
    const transport = scripted((sent, index) => (index === 0 ? toolsListOk(sent) : script(sent, index)));
    const c = client(transport, config);
    await c.connect({ bearerToken: 'mcp_at_example' });
    return { c, transport };
  }

  it('request shape matches the fixture; the credential travels only via credential, never in the protocol headers', async () => {
    const fixture = load('stateless/tools-call.request.json');
    const response = load('stateless/tools-call.response.json');
    const { c, transport } = await connected((sent) => ({ status: 200, json: withId(response.body, sent) }));
    const result = await c.callTool('get_weather', { location: 'New York' });
    const call = transport.sent[1]!;
    const { authorization, ...protocolHeaders } = lowerHeaders(fixture.headers);
    expect(call.request.headers).toEqual(protocolHeaders);
    expect(call.request.credential).toBe(authorization!.replace('Bearer ', ''));
    expect(Object.keys(call.request.headers)).not.toContain('authorization');
    expect(call.body).toEqual({ ...fixture.body, id: call.body.id });
    expect(result).toMatchObject({ isError: false, errorCode: null, truncated: false });
    expect(result.text).toContain('Current weather in New York');
  });

  it('SSE form: skips interleaved notifications and takes the final response with the matching id', async () => {
    const sse = loadText('stateless/tools-call.sse.txt');
    const { c } = await connected((sent) => ({
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
      raw: sse.replace('"id":3', `"id":${sent.body.id}`),
    }));
    const result = await c.callTool('get_weather', { location: 'New York' });
    expect(result.text).toBe('Current weather in New York:\nTemperature: 72°F\nConditions: Partly cloudy');
  });

  it('SSE returns as soon as the final response arrives, without waiting for the server to close the stream', async () => {
    let cancelled = false;
    const { c } = await connected((sent) => ({
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
      stream: new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(
            `data: ${JSON.stringify({ jsonrpc: '2.0', id: sent.body.id, result: { content: [{ type: 'text', text: 'done' }] } })}\n`,
          ));
          // The stream is left open.
        },
        cancel() {
          cancelled = true;
        },
      }),
    }), { callTimeoutSeconds: 5 });
    const result = await c.callTool('w', {});
    expect(result.text).toBe('done');
    expect(cancelled).toBe(true);
  });

  it('isError: true -> tool_error (not a JSON-RPC error)', async () => {
    const fixture = load('shared/tools-call.is-error.response.json');
    const { c } = await connected((sent) => ({ status: 200, json: withId(fixture.body, sent) }));
    const result = await c.callTool('book', {});
    expect(result).toMatchObject({ isError: true, errorCode: 'tool_error' });
    expect(result.text.length).toBeGreaterThan(0);
  });

  it('resultType = input_required → needs_input_unsupported', async () => {
    const fixture = load('shared/tools-call.input-required.response.json');
    const { c } = await connected((sent) => ({ status: 200, json: withId(fixture.body, sent) }));
    expect(await c.callTool('x', {})).toMatchObject({ errorCode: fixture.expect.errorCode, text: '' });
  });

  it('falls back to the JSON text of structuredContent when content is empty', async () => {
    const fixture = load('shared/tools-call.structured-content.response.json');
    const body = withId(fixture.body, { body: {} } as Sent) as { result: Record<string, unknown> };
    const { c } = await connected((sent) => ({ status: 200, json: { ...body, id: sent.body.id, result: { ...body.result, content: [] } } }));
    const result = await c.callTool('x', {});
    expect(JSON.parse(result.text)).toEqual(fixture.body.result.structuredContent);
    expect(result.structuredContent).toEqual(fixture.body.result.structuredContent);
  });

  it('non-text items become placeholders; results over maxResultChars are truncated and marked', async () => {
    const { c } = await connected((sent) => ({
      status: 200,
      json: { jsonrpc: '2.0', id: sent.body.id, result: { content: [{ type: 'image', data: 'xx' }, { type: 'text', text: 'a'.repeat(5000) }] } },
    }), { maxResultChars: 1000 });
    const result = await c.callTool('x', {});
    expect(result.text.startsWith('[non-text content: image]')).toBe(true);
    expect(result.text.endsWith('[result truncated]')).toBe(true);
    expect(Array.from(result.text).length).toBe(1000);
    expect(result).toMatchObject({ truncated: true, errorCode: 'result_too_large' });
  });

  it('an oversized structuredContent is dropped entirely and recorded as result_too_large', async () => {
    const { c } = await connected((sent) => ({
      status: 200,
      json: { jsonrpc: '2.0', id: sent.body.id, result: { content: [{ type: 'text', text: 'short' }], structuredContent: { blob: 'b'.repeat(2000) } } },
    }), { maxResultChars: 1000 });
    expect(await c.callTool('x', {})).toMatchObject({ text: 'short', structuredContent: null, errorCode: 'result_too_large', truncated: false });
  });

  it('unknown tool (-32602) -> tool_error, detail truncated to 200 characters', async () => {
    const fixture = load('session/error.unknown-tool.json');
    const { c } = await connected((sent) => ({ status: 200, json: withId(fixture.body, sent) }));
    const error = await c.callTool('nope', {}).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(McpClientError);
    expect((error as McpClientError).code).toBe('tool_error');
    expect(String(error)).not.toContain(fixture.body.error.message);
  });

  it('a network failure after tools/call was sent is not retried automatically', async () => {
    const { c, transport } = await connected(() => 'network');
    await expect(c.callTool('create_issue', {})).rejects.toMatchObject({ code: 'unreachable' });
    expect(transport.sent.filter((s) => s.body.method === 'tools/call')).toHaveLength(1);
  });

  it('an error response with a null id still counts as the answer to this request', async () => {
    const { c } = await connected(() => ({ status: 200, json: { jsonrpc: '2.0', id: null, error: { code: -32603, message: 'boom' } } }));
    await expect(c.callTool('x', {})).rejects.toMatchObject({ code: 'server_error', detail: 'boom' });
  });

  it('exceeding callTimeoutSeconds -> timeout', async () => {
    const { c } = await connected(() => 'hang', { callTimeoutSeconds: 0.05 });
    await expect(c.callTool('x', {})).rejects.toMatchObject({ code: 'timeout' });
  });

  it('caller aborts -> cancelled; cancel() is cancelled as well', async () => {
    const { c } = await connected(() => 'hang');
    const controller = new AbortController();
    const pending = c.callTool('x', {}, { signal: controller.signal });
    setTimeout(() => controller.abort(), 10);
    await expect(pending).rejects.toMatchObject({ code: 'cancelled' });

    const pending2 = c.callTool('y', {});
    setTimeout(() => c.cancel(), 10);
    await expect(pending2).rejects.toMatchObject({ code: 'cancelled' });
  });

  it('a cancelled legacy-protocol call also sends notifications/cancelled (with the cancelled request id)', async () => {
    const transport = scripted((sent, index) => {
      if (index === 0) return { status: 400, raw: '' };
      if (sent.body?.method === 'initialize') return { status: 200, headers: { 'mcp-session-id': 'sx' }, json: { jsonrpc: '2.0', id: sent.body.id, result: { protocolVersion: '2025-11-25' } } };
      if (sent.body?.method === 'tools/call') return 'hang';
      return { status: 202, raw: '' };
    });
    const c = client(transport);
    await c.connect();
    const controller = new AbortController();
    const pending = c.callTool('x', {}, { signal: controller.signal });
    setTimeout(() => controller.abort(), 10);
    await expect(pending).rejects.toMatchObject({ code: 'cancelled' });
    await new Promise((r) => setTimeout(r, 10));
    const call = transport.sent.find((s) => s.body?.method === 'tools/call')!;
    const notice = transport.sent.find((s) => s.body?.method === 'notifications/cancelled')!;
    expect(notice.body.params.requestId).toBe(call.body.id);
    expect(notice.request.headers['mcp-session-id']).toBe('sx');
  });

  it('response body declared larger than 8 MB -> server_error', async () => {
    const { c } = await connected(() => ({ status: 200, headers: { 'content-length': String(9 * 1024 * 1024) }, raw: '{}' }));
    await expect(c.callTool('x', {})).rejects.toMatchObject({ code: 'server_error' });
  });

  it('JSON nested deeper than 64 levels is treated as a parse failure', async () => {
    const { c } = await connected(() => ({ status: 200, raw: `${'['.repeat(70)}${']'.repeat(70)}` }));
    await expect(c.callTool('x', {})).rejects.toMatchObject({ code: 'server_error' });
  });

  it('a non-ASCII tool name is encoded into Mcp-Name as =?base64?...?=', async () => {
    const { c, transport } = await connected((sent) => ({ status: 200, json: { jsonrpc: '2.0', id: sent.body.id, result: { content: [] } } }));
    await c.callTool('クエリ', {});
    expect(transport.sent[1]!.request.headers['mcp-name']).toBe(encodeHeaderValue('クエリ'));
    expect(encodeHeaderValue('クエリ')).toBe(`=?base64?${Buffer.from('クエリ', 'utf8').toString('base64')}?=`);
    expect(encodeHeaderValue(' padded')).toMatch(/^=\?base64\?/);
    expect(encodeHeaderValue('=?base64?abc?=')).toMatch(/^=\?base64\?PT9i/);
    expect(encodeHeaderValue('plain_name')).toBe('plain_name');
  });

  it('non-https endpoint: not a single byte is sent', async () => {
    const transport = scripted((sent) => toolsListOk(sent));
    const c = new McpClient({ endpoint: 'http://mcp.example.com/mcp', transport });
    expect((await c.connect()).kind).toBe('unreachable');
    expect(transport.sent).toHaveLength(0);
  });
});

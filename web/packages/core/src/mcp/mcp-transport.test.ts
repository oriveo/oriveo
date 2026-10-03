import { describe, expect, it } from 'vitest';
import { parseSseMessages, McpSseParser } from './mcp-sse';
import {
  McpTransportError,
  createDirectMcpTransport,
  createForwardMcpTransport,
  createRoutingMcpTransport,
  readBodyText,
  McpBodyTooLargeError,
  type McpFetch,
  type McpFetchInit,
} from './mcp-transport';

interface Call {
  url: string;
  init: McpFetchInit;
}

function fakeFetch(replies: Array<{ status: number; headers?: Record<string, string>; body?: string; type?: string }>): McpFetch & { calls: Call[] } {
  const calls: Call[] = [];
  const fn = (async (url: string, init: McpFetchInit) => {
    calls.push({ url, init });
    const reply = replies[Math.min(calls.length - 1, replies.length - 1)]!;
    return { status: reply.status, type: reply.type, headers: new Headers(reply.headers ?? {}), body: new Response(reply.body ?? '').body };
  }) as unknown as McpFetch & { calls: Call[] };
  fn.calls = calls;
  return fn;
}

const base = { method: 'POST' as const, headers: { 'content-type': 'application/json' }, body: '{}' };

describe('direct transport', () => {
  it('non-https URL or URL with userinfo: throws insecure without calling fetch', async () => {
    const fetch = fakeFetch([{ status: 200 }]);
    const transport = createDirectMcpTransport(fetch);
    for (const url of ['http://mcp.example.com/mcp', 'https://u:p@mcp.example.com/mcp', 'not a url']) {
      await expect(transport.send({ ...base, url, redirect: 'same-origin' })).rejects.toMatchObject({ kind: 'insecure' });
    }
    expect(fetch.calls).toHaveLength(0);
  });

  it('puts the credential in the Authorization header only, never in the URL', async () => {
    const fetch = fakeFetch([{ status: 200 }]);
    await createDirectMcpTransport(fetch).send({ ...base, url: 'https://mcp.example.com/mcp', credential: 'tok', redirect: 'same-origin' });
    expect(fetch.calls[0]!.init.headers.Authorization).toBe('Bearer tok');
    expect(fetch.calls[0]!.url).not.toContain('tok');
    expect(fetch.calls[0]!.init.redirect).toBe('manual');
  });

  it('follows a same-origin 307 and re-attaches the credential and the body', async () => {
    const fetch = fakeFetch([{ status: 307, headers: { location: '/v2/mcp' } }, { status: 200, body: 'ok' }]);
    const response = await createDirectMcpTransport(fetch).send({ ...base, url: 'https://mcp.example.com/mcp', credential: 'tok', redirect: 'same-origin' });
    expect(response.status).toBe(200);
    expect(fetch.calls[1]!.url).toBe('https://mcp.example.com/v2/mcp');
    expect(fetch.calls[1]!.init.headers.Authorization).toBe('Bearer tok');
    expect(fetch.calls[1]!.init.body).toBe('{}');
  });

  it('rejects cross-origin / downgrade to http / method-changing 302 / never policy / more than 5 hops, and the redirect target receives no request', async () => {
    const cases: Array<[Array<{ status: number; headers?: Record<string, string> }>, 'same-origin' | 'never']> = [
      [[{ status: 307, headers: { location: 'https://evil.example/mcp' } }], 'same-origin'],
      [[{ status: 308, headers: { location: 'http://mcp.example.com/mcp' } }], 'same-origin'],
      [[{ status: 302, headers: { location: '/other' } }], 'same-origin'],
      [[{ status: 307, headers: { location: '/other' } }], 'never'],
      [[{ status: 307 }], 'same-origin'],
    ];
    for (const [replies, redirect] of cases) {
      const fetch = fakeFetch(replies);
      await expect(
        createDirectMcpTransport(fetch).send({ ...base, url: 'https://mcp.example.com/mcp', credential: 'tok', redirect }),
      ).rejects.toMatchObject({ kind: 'redirect_rejected' });
      expect(fetch.calls).toHaveLength(1);
    }
    const loop = fakeFetch([{ status: 307, headers: { location: '/mcp' } }]);
    await expect(createDirectMcpTransport(loop).send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' })).rejects.toMatchObject({
      kind: 'redirect_rejected',
    });
    expect(loop.calls).toHaveLength(6);
  });

  it('treats a browser opaqueredirect as a rejected redirect', async () => {
    const fetch = fakeFetch([{ status: 0, type: 'opaqueredirect' }]);
    await expect(createDirectMcpTransport(fetch).send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' })).rejects.toMatchObject({
      kind: 'redirect_rejected',
    });
  });

  it('fetch throws → network; rethrows the abort as is when the caller already aborted', async () => {
    const failing: McpFetch = async () => {
      throw new TypeError('fetch failed');
    };
    await expect(createDirectMcpTransport(failing).send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' })).rejects.toMatchObject({
      kind: 'network',
    });
    const controller = new AbortController();
    controller.abort();
    const aborting: McpFetch = async () => {
      throw new DOMException('aborted', 'AbortError');
    };
    await expect(
      createDirectMcpTransport(aborting).send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin', signal: controller.signal }),
    ).rejects.toBeInstanceOf(DOMException);
  });
});

describe('forward transport', () => {
  it('sends target, method, protocol headers and credential in their own X-Mcp-* headers; the credential stays out of X-Mcp-Headers', async () => {
    const fetch = fakeFetch([{ status: 200, headers: { 'x-oriveo-error-source': 'provider' } }]);
    await createForwardMcpTransport({ fetch }).send({
      method: 'POST',
      url: 'https://mcp.example.com/mcp',
      headers: { Accept: 'application/json, text/event-stream', 'MCP-Protocol-Version': '2026-07-28', 'Mcp-Method': 'tools/list' },
      body: '{"jsonrpc":"2.0"}',
      credential: 'secret-token',
      redirect: 'same-origin',
    });
    const [call] = fetch.calls;
    expect(call!.url).toBe('/api/mcp/forward');
    expect(call!.init.method).toBe('POST');
    expect(call!.init.headers['X-Mcp-Target-Url']).toBe('https://mcp.example.com/mcp');
    expect(call!.init.headers['X-Mcp-Method']).toBe('POST');
    expect(call!.init.headers['X-Mcp-Credential']).toBe('secret-token');
    expect(JSON.parse(call!.init.headers['X-Mcp-Headers']!)).toEqual({
      accept: 'application/json, text/event-stream',
      'mcp-protocol-version': '2026-07-28',
      'mcp-method': 'tools/list',
    });
    expect(call!.init.headers['X-Mcp-Headers']).not.toContain('secret-token');
    expect(call!.init.body).toBe('{"jsonrpc":"2.0"}');
  });

  it('sends no body for GET and no X-Mcp-Credential without a credential', async () => {
    const fetch = fakeFetch([{ status: 200 }]);
    await createForwardMcpTransport({ fetch }).send({
      method: 'GET',
      url: 'https://auth.example.com/.well-known/oauth-authorization-server',
      headers: { accept: 'application/json' },
      redirect: 'same-origin',
    });
    expect(fetch.calls[0]!.init.body).toBeUndefined();
    expect(fetch.calls[0]!.init.headers['X-Mcp-Method']).toBe('GET');
    expect(fetch.calls[0]!.init.headers['X-Mcp-Credential']).toBeUndefined();
  });

  it('hands redirect never to the route via X-Mcp-Redirect; same-origin omits the header', async () => {
    const fetch = fakeFetch([{ status: 200 }, { status: 200 }]);
    const transport = createForwardMcpTransport({ fetch });
    await transport.send({ method: 'POST', url: 'https://auth.example.com/token', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'grant_type=refresh_token', redirect: 'never' });
    await transport.send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' });
    expect(fetch.calls[0]!.init.headers['X-Mcp-Redirect']).toBe('never');
    expect(fetch.calls[1]!.init.headers['X-Mcp-Redirect']).toBeUndefined();
  });

  it('restores the original names of the session id and auth challenge returned by the route', async () => {
    const fetch = fakeFetch([
      { status: 401, headers: { 'x-mcp-session-id': 'sess', 'x-mcp-www-authenticate': 'Bearer scope="a"', 'content-type': 'text/plain' } },
    ]);
    const response = await createForwardMcpTransport({ fetch }).send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' });
    expect(response.status).toBe(401);
    expect(response.headers.get('MCP-Session-Id')).toBe('sess');
    expect(response.headers.get('WWW-Authenticate')).toBe('Bearer scope="a"');
    expect(response.headers.get('content-type')).toBe('text/plain');
  });

  it('does not pass the route\'s own refusals off as upstream responses', async () => {
    const cases: Array<[number, string, string, string]> = [
      [403, 'oriveo', '{"code":"endpoint_forbidden"}', 'blocked'],
      [400, 'oriveo', '{"code":"mcp_request_not_allowed"}', 'blocked'],
      [502, 'oriveo', '{"code":"upstream_redirect_blocked"}', 'redirect_rejected'],
      [429, 'oriveo', '{"error":"Rate limit exceeded"}', 'network'],
      [502, 'network', '{"code":"mcp_upstream_timeout"}', 'timeout'],
      [502, 'network', '{"code":"mcp_upstream_connection_failed"}', 'network'],
    ];
    for (const [status, source, body, kind] of cases) {
      const fetch = fakeFetch([{ status, headers: { 'x-oriveo-error-source': source }, body }]);
      const error = await createForwardMcpTransport({ fetch }).send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' }).catch((e: unknown) => e);
      expect(error).toBeInstanceOf(McpTransportError);
      expect((error as McpTransportError).kind).toBe(kind);
    }
  });

  it('rejects a non-https target locally without sending it to the route', async () => {
    const fetch = fakeFetch([{ status: 200 }]);
    await expect(createForwardMcpTransport({ fetch }).send({ ...base, url: 'http://mcp.example.com/mcp', redirect: 'same-origin' })).rejects.toMatchObject({
      kind: 'insecure',
    });
    expect(fetch.calls).toHaveLength(0);
  });

  it('route selection: public goes through forwarding, private goes direct', async () => {
    const forwardFetch = fakeFetch([{ status: 200 }]);
    const directFetch = fakeFetch([{ status: 200 }]);
    const transport = createRoutingMcpTransport({
      shouldForward: (url) => !new URL(url).hostname.endsWith('.local'),
      forward: createForwardMcpTransport({ fetch: forwardFetch }),
      direct: createDirectMcpTransport(directFetch),
    });
    await transport.send({ ...base, url: 'https://mcp.example.com/mcp', redirect: 'same-origin' });
    await transport.send({ ...base, url: 'https://nas.local/mcp', redirect: 'same-origin' });
    expect(forwardFetch.calls.map((c) => c.init.headers['X-Mcp-Target-Url'])).toEqual(['https://mcp.example.com/mcp']);
    expect(directFetch.calls.map((c) => c.url)).toEqual(['https://nas.local/mcp']);
  });
});

describe('readBodyText', () => {
  it('stops as soon as the limit is exceeded', async () => {
    await expect(readBodyText(new Response('x'.repeat(100)).body, 10)).rejects.toBeInstanceOf(McpBodyTooLargeError);
    expect(await readBodyText(new Response('héllo').body, 10)).toBe('héllo');
  });
});

describe('SSE parsing', () => {
  it('LF / CRLF / CR line endings, BOM, comments, multi-line data, missing trailing blank line', () => {
    const text = '﻿: comment\r\nevent: message\r\ndata: {"a":1}\r\n\r\ndata: {"b":\rdata: 2}\r\rdata: {"c":3}';
    expect(parseSseMessages(text)).toEqual([{ a: 1 }, { b: 2 }, { c: 3 }]);
  });

  it('skips bad frames without stalling the stream; single-line events are not emitted twice', () => {
    expect(parseSseMessages('data: not json\n\ndata: {"ok":true}\n\n')).toEqual([{ ok: true }]);
  });

  it('feeds increments across chunks and emits single-line data immediately', () => {
    const parser = new McpSseParser();
    expect(parser.push('data: {"x"')).toEqual([]);
    expect(parser.push(':1}\n')).toEqual([{ x: 1 }]);
    expect(parser.push('\n')).toEqual([]);
    expect(parser.finish()).toEqual([]);
  });
});

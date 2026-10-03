/**
 * UI tests connect for real to the frozen mock server (`shared/test-fixtures/mcp/mock-server.mjs`).
 * Same approach as `packages/core/src/mcp/mcp-mock-server.test.ts`: each mode starts a real child
 * process (random port, loopback only), and the test transport plays a TLS-terminating proxy at the
 * fetch layer. The client sees `https://127.0.0.1:<port>` (the https-only gate gets no test
 * exemption); requests are rewritten to http on the way out and the addresses the server returns are
 * rewritten back to https.
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { resolve } from 'node:path';
import { createDirectMcpTransport, type McpAuthorizationLauncher, type McpFetch, type McpTransport } from '@oriveo/core/mcp/index';
import type { McpPreopenedAuthorization } from '../../../lib/core/mcp/browser-mcp-runtime';

const MOCK = resolve(__dirname, '../../../../../../shared/test-fixtures/mcp/mock-server.mjs');
const children = new Set<ChildProcess>();

export function killAllMockServers(): void {
  for (const child of children) {
    if (child.exitCode === null) child.kill('SIGKILL');
  }
  children.clear();
}
process.once('exit', killAllMockServers);

export interface MockServer {
  httpOrigin: string;
  httpsOrigin: string;
  endpoint: string;
  transport: McpTransport;
  state(): Promise<{ calls: Record<string, number>; clientsRegistered: number; codesIssued: number; tokensIssued: number; unauthorizedResponses: number }>;
  stop(): void;
}

export async function startMockServer(...flags: string[]): Promise<MockServer> {
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
  const mock: MockServer = {
    httpOrigin,
    httpsOrigin,
    endpoint: `${httpsOrigin}/mcp`,
    transport: null as unknown as McpTransport,
    async state() {
      return (await (await fetch(`${httpOrigin}/__mock/state`)).json()) as Awaited<ReturnType<MockServer['state']>>;
    },
    stop() {
      child.kill('SIGKILL');
      children.delete(child);
    },
  };
  mock.transport = createDirectMcpTransport(loopbackTls(mock));
  return mock;
}

/** TLS-terminating proxy for tests. Only this mock server's origin is let through; every other address is treated as unreachable. */
export function loopbackTls(mock: Pick<MockServer, 'httpOrigin' | 'httpsOrigin'>): McpFetch {
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

/**
 * Plays the "open first, navigate later" authorization window: `preopen` records whether it was
 * called synchronously inside the click. Once the authorization URL is known it opens it as a browser
 * would, takes the Location of the 302 and hands back the redirect parameters (equivalent to the
 * result of the BroadcastChannel hand-off).
 */
export function fakeAuthorizationWindow(mock: MockServer, behaviour: 'approve' | 'close' = 'approve'): McpPreopenedAuthorization & { preopened: number; opened: string[]; discarded: number } {
  const fetchPort = loopbackTls(mock);
  const window: McpPreopenedAuthorization & { preopened: number; opened: string[]; discarded: number } = {
    preopened: 0,
    opened: [],
    discarded: 0,
    preopen() {
      window.preopened += 1;
      return true;
    },
    discard() {
      window.discarded += 1;
    },
    launcher: {
      async open(request) {
        window.opened.push(request.url);
        if (behaviour === 'close') throw new Error('window closed');
        const response = await fetchPort(request.url, { method: 'GET', headers: {}, redirect: 'manual' });
        const location = response.headers.get('location');
        if (response.status !== 302 || !location) throw new Error(`authorization refused: ${response.status}`);
        const callback = new URL(location);
        const params: Record<string, string> = {};
        for (const [key, value] of callback.searchParams) params[key] = value.split(mock.httpOrigin).join(mock.httpsOrigin);
        return { params, callbackUrl: `${callback.origin}${callback.pathname}` };
      },
    } satisfies McpAuthorizationLauncher,
  };
  return window;
}

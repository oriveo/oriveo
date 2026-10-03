import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { McpFetch, McpFetchInit } from '@oriveo/core/mcp/index';
import {
  MCP_OAUTH_CALLBACK_ACK_TYPE,
  MCP_OAUTH_CALLBACK_MESSAGE_TYPE,
  type OauthCallbackChannel,
} from '../../../../app/mcp/oauth/callback/callback-handoff';
import { redactSentryBreadcrumb, redactSentryEvent, redactSentrySpan } from '../../../sentry/redact-url';
import { McpAuthorizationWindowError, browserMcpFetch, createBrowserMcpAuthorizationLauncher, createBrowserMcpTransport } from '../browser-mcp-runtime';

/** A pair of fake BroadcastChannels: the launcher opens the initiating-page end and the test posts messages from the redirect-page end. */
function fakeChannelPair() {
  const listeners = new Set<(event: MessageEvent) => void>();
  const posted: unknown[] = [];
  const channel: OauthCallbackChannel = {
    postMessage: (message) => posted.push(message),
    addEventListener: (_type, listener) => listeners.add(listener),
    removeEventListener: (_type, listener) => listeners.delete(listener),
    close: () => listeners.clear(),
  };
  return {
    channel,
    posted,
    deliver(params: Record<string, string>) {
      for (const listener of [...listeners]) listener(new MessageEvent('message', { data: { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params } }));
    },
  };
}

describe('browser transport', () => {
  it('routes public hosts through /api/mcp/forward and private hosts directly, without sending this site cookies', async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response('{}', { status: 200, headers: { 'x-oriveo-error-source': 'provider' } });
    }) as unknown as typeof fetch;
    const transport = createBrowserMcpTransport({ fetch: browserMcpFetch(fetchImpl) });
    await transport.send({ url: 'https://mcp.example.com/mcp', method: 'POST', headers: {}, body: '{}', redirect: 'same-origin', credential: 'tok' });
    await transport.send({ url: 'https://192.168.1.20/mcp', method: 'POST', headers: {}, body: '{}', redirect: 'same-origin', credential: 'tok' });
    expect(calls[0]!.url).toBe('/api/mcp/forward');
    expect((calls[0]!.init.headers as Record<string, string>)['X-Mcp-Target-Url']).toBe('https://mcp.example.com/mcp');
    expect(calls[1]!.url).toBe('https://192.168.1.20/mcp');
    expect((calls[1]!.init.headers as Record<string, string>).Authorization).toBe('Bearer tok');
    expect(calls.every((call) => call.init.credentials === 'omit' && call.init.redirect === 'manual')).toBe(true);
  });

  it('keeps directly connected server addresses out of Sentry by redacting the whole path and query string in breadcrumbs, spans and events', async () => {
    // Sentry's fetch instrumentation records exactly the URL passed to fetch, so take it from the call the
    // production transport actually made.
    const fetched: string[] = [];
    const fetchImpl = (async (url: string) => {
      fetched.push(url);
      return new Response('{}', { status: 200 });
    }) as unknown as typeof fetch;
    const transport = createBrowserMcpTransport({ fetch: browserMcpFetch(fetchImpl) });
    const endpoint = 'https://192.168.7.31:8443/mcp/sk-live-9f8e7d6c5b4a3210/tools?workspace=acme&sig=Zm9vYmFy';
    await transport.send({ url: endpoint, method: 'POST', headers: {}, body: '{}', redirect: 'same-origin', credential: 'tok' });
    expect(fetched).toEqual([endpoint]);

    const breadcrumb = redactSentryBreadcrumb({ category: 'fetch', data: { method: 'POST', url: fetched[0]!, status_code: 200 } });
    expect(breadcrumb.data.url).toBe('https://<mcp-direct>');
    const span = redactSentrySpan({ description: `POST ${fetched[0]!}`, data: { 'http.url': fetched[0]!, url: fetched[0]!, 'http.query': 'workspace=acme&sig=Zm9vYmFy' } });
    expect(span.description).toBe('POST https://<mcp-direct>');
    const event = redactSentryEvent({ request: { url: fetched[0]! } });
    const serialized = JSON.stringify([breadcrumb, span.description, span.data?.['http.url'], span.data?.url, event]);
    for (const secret of ['192.168.7.31', 'sk-live-9f8e7d6c5b4a3210', 'acme', 'Zm9vYmFy', '/mcp/']) {
      expect(serialized, secret).not.toContain(secret);
    }

    // Only registered origins are redacted: another port is another origin, and a different host sharing
    // the same prefix is unaffected too.
    expect(redactSentryBreadcrumb({ data: { url: 'https://192.168.7.31/health' } }).data.url).toBe('https://192.168.7.31/health');
    expect(redactSentryBreadcrumb({ data: { url: 'https://192.168.7.31:84430/x' } }).data.url).toBe('https://192.168.7.31:84430/x');
    // Public servers go through the forwarder, so the target address is only in request headers (`x-mcp-*`
    // is removed unconditionally by redactSentryEvent) and is not registered.
    await transport.send({ url: 'https://mcp.example.com/mcp/secret-path', method: 'POST', headers: {}, body: '{}', redirect: 'same-origin' });
    expect(fetched[1]).toBe('/api/mcp/forward');
  });

  it('passes the opaqueredirect response type through browserMcpFetch', async () => {
    const fetchImpl = (async () => ({ status: 0, type: 'opaqueredirect', headers: new Headers(), body: null })) as unknown as typeof fetch;
    const port: McpFetch = browserMcpFetch(fetchImpl);
    const init: McpFetchInit = { method: 'GET', headers: {}, redirect: 'manual' };
    expect((await port('https://x.example', init)).type).toBe('opaqueredirect');
  });
});

describe('authorization in a new window', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function setup(popup: { closed: boolean; close: () => void } | null = { closed: false, close: vi.fn() }) {
    const pair = fakeChannelPair();
    const opened: string[] = [];
    const launcher = createBrowserMcpAuthorizationLauncher({
      openWindow: (url) => {
        opened.push(url);
        return popup;
      },
      messageTarget: new EventTarget() as unknown as Window,
      origin: 'https://app.example.com',
      openChannel: () => pair.channel,
    });
    return { pair, opened, launcher, popup };
  }

  it('claims the parameters handed back by the redirect page by state and acknowledges them, ignoring other states', async () => {
    const { pair, opened, launcher } = setup();
    const pending = launcher.open({ url: 'https://auth.example.com/authorize?x=1', state: 'st_1', redirectUri: 'https://app.example.com/mcp/oauth/callback' });
    expect(opened).toEqual(['https://auth.example.com/authorize?x=1']);
    pair.deliver({ code: 'other', state: 'st_other' });
    pair.deliver({ code: 'ac_1', state: 'st_1', iss: 'https://auth.example.com' });
    await expect(pending).resolves.toEqual({ params: { code: 'ac_1', state: 'st_1', iss: 'https://auth.example.com' } });
    expect(pair.posted).toEqual([{ type: MCP_OAUTH_CALLBACK_ACK_TYPE, state: 'st_1' }]);
  });

  it('still succeeds when the broadcast arrives within the grace period after the window reports closed (a COOP group switch makes the handle report closed first)', async () => {
    const popup = { closed: false, close: vi.fn() };
    const { pair, launcher } = setup(popup);
    const pending = launcher.open({ url: 'https://auth.example.com/a', state: 's', redirectUri: 'r' });
    popup.closed = true;
    await vi.advanceTimersByTimeAsync(1_000);
    pair.deliver({ code: 'c', state: 's' });
    await expect(pending).resolves.toMatchObject({ params: { code: 'c' } });
  });

  it('treats a closed window with no broadcast within the grace period as a user cancel', async () => {
    const popup = { closed: false, close: vi.fn() };
    const { launcher } = setup(popup);
    const pending = launcher.open({ url: 'https://auth.example.com/a', state: 's', redirectUri: 'r' });
    const assertion = expect(pending).rejects.toMatchObject({ reason: 'closed' });
    popup.closed = true;
    await vi.advanceTimersByTimeAsync(4_000);
    await assertion;
  });

  it('reports blocked when the pop-up is blocked, and aborted with the window closed when the caller aborts', async () => {
    const blocked = setup(null);
    await expect(blocked.launcher.open({ url: 'https://a.example', state: 's', redirectUri: 'r' })).rejects.toBeInstanceOf(McpAuthorizationWindowError);

    const popup = { closed: false, close: vi.fn() };
    const { launcher } = setup(popup);
    const controller = new AbortController();
    const pending = launcher.open({ url: 'https://a.example', state: 's', redirectUri: 'r', signal: controller.signal });
    controller.abort();
    await expect(pending).rejects.toMatchObject({ reason: 'aborted' });
    expect(popup.close).toHaveBeenCalled();
  });
});

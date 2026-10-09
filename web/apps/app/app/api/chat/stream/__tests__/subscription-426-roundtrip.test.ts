import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { POST } from '../route';
import { __resetRuntimeMetadataCache } from '../runtime';
import { sendStreamProxy } from '../../../../../lib/core/providers/proxy-client';
import type { StreamEvent } from '../../../../../lib/core/providers/types';
import { __resetSubscriptionVersionRejectionGateForTest } from '../../../../../lib/core/providers/subscription-version-rejection';
import { shouldReportProviderError } from '../../../../../lib/core/chat/error-reporting';
import * as metadataClient from '../../../../../lib/core/metadata/metadata-client';

/**
 * End-to-end coverage of a subscription 426: browser-side `sendStreamProxy` -> the real
 * `/api/chat/stream` route -> an upstream 426.
 *
 * Other tests each cover one half (proxy-client.test builds the route's response headers itself,
 * and the route tests call the headers function directly). Here the response headers and the error
 * event all come from the production path: only three outgoing fetches are replaced (browser ->
 * route is wired to the real POST, route -> metadata, route -> upstream).
 */

// The same byte string is used on every platform. The code and message are what the upstream
// returns to an outdated client; the outer JSON key names follow the shape of the existing tests.
const XAI_426_BODY = '{"code":"ClientVersionRejected","error":"Your Grok CLI version (1.0.4) is outdated. Please update to version 1.0.13 or later via `grok update` or the installation documentation."}';

const UPSTREAM_ORIGIN = 'https://cli-chat-proxy.grok.com';

function metadata(clientVersion: string) {
  return {
    version: 1,
    providers: {},
    profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: { templates: {} } },
    providerConfigs: [{
      kind: 'grok',
      protocolFeatures: {
        subscriptionAuth: {
          enabled: true,
          flow: 'oauth_device_code',
          clientId: 'b1a00492-073a-47ea-816f-4c329264a828',
          scopes: 'openid profile email offline_access grok-cli:access api:access',
          deviceAuthorizationEndpoint: 'https://auth.x.ai/oauth2/device/code',
          tokenEndpoint: 'https://auth.x.ai/oauth2/token',
          trustedAuthHosts: ['auth.x.ai'],
          trustedVerificationHosts: ['accounts.x.ai', 'x.ai'],
          resourceBaseURL: `${UPSTREAM_ORIGIN}/v1`,
          requiredHeaders: { 'x-grok-client-version': clientVersion },
        },
      },
    }],
  };
}

const respond = (clientVersion: string) =>
  new Response(JSON.stringify({ data: metadata(clientVersion) }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: `"${clientVersion}"` },
  });

async function collectEvents(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const reader = stream.getReader();
  const events: StreamEvent[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  return events;
}

/** Same shape as the error object thrown by `collectStreamEvents` (chat-stream-utils): these are the fields the reporting check reads. */
function toThrownShape(event: StreamEvent | undefined) {
  if (event?.type !== 'error') throw new Error('expected an error event');
  return { kind: event.errorKind, source: event.source, ...(event.skipReport ? { skipReport: true } : {}) };
}

describe('subscription 426: browser -> real route -> upstream', () => {
  /** The version header currently served by metadata; a test can change it once the upstream has been hit to simulate a newer value being published. */
  let servedVersion: string;
  let onUpstreamHit: () => void;
  let sentVersions: Array<string | null>;

  const send = async () => {
    const events = await collectEvents(sendStreamProxy(
      'grok', 'access-token', 'grok-4.6', [{ role: 'user', content: 'hi' }], undefined, { grokSubscriptionAuth: true },
    ).stream);
    return events.find((event) => event.type === 'error');
  };

  beforeEach(() => {
    __resetRuntimeMetadataCache();
    __resetSubscriptionVersionRejectionGateForTest();
    servedVersion = '1.0.4';
    onUpstreamHit = () => {};
    sentVersions = [];
    // The background refresh of the browser's own metadata copy is not part of this path.
    vi.spyOn(metadataClient, 'refreshMetadata').mockResolvedValue(undefined);
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      if (url === '/api/chat/stream') {
        return POST(new Request('http://localhost/api/chat/stream', {
          method: 'POST',
          headers: init?.headers,
          body: init?.body as string,
        }) as never);
      }
      if (url.includes('/api/metadata')) return respond(servedVersion);
      if (url.startsWith(UPSTREAM_ORIGIN)) {
        sentVersions.push(new Headers(init?.headers).get('x-grok-client-version'));
        onUpstreamHit();
        return new Response(XAI_426_BODY, { status: 426, headers: { 'Content-Type': 'application/json' } });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    __resetRuntimeMetadataCache();
    __resetSubscriptionVersionRejectionGateForTest();
  });

  it('is classified as subscription unavailable from the app itself, without the upstream text addressed to CLI users', async () => {
    const error = await send();

    // Sanity check: the request really reached the subscription endpoint through the real route with the served version header.
    expect(sentVersions).toEqual(['1.0.4']);
    expect(error).toMatchObject({ errorKind: 'grokSubscriptionUnavailable', source: 'oriveo', status: 426 });
    expect(error?.type === 'error' && error.error).not.toContain('grok update');
  });

  it('reports the same configuration fingerprint only once', async () => {
    const first = await send();
    const second = await send();

    expect(sentVersions).toEqual(['1.0.4', '1.0.4']);
    expect(shouldReportProviderError(toThrownShape(first))).toBe(true);
    expect(shouldReportProviderError(toThrownShape(second))).toBe(false);
  });

  it('does not report when the refresh after a rejection finds a newer served version, and sends the new value next time', async () => {
    onUpstreamHit = () => { servedVersion = '1.0.46'; };

    const error = await send();

    expect(sentVersions).toEqual(['1.0.4']);
    expect(error).toMatchObject({ errorKind: 'grokSubscriptionUnavailable', source: 'oriveo' });
    expect(shouldReportProviderError(toThrownShape(error))).toBe(false);

    await send();
    expect(sentVersions).toEqual(['1.0.4', '1.0.46']);
  });
});

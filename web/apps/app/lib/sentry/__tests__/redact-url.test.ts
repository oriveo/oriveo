import { describe, expect, it } from 'vitest';
import {
  isCredentialRequestHeader,
  redactRegisteredRelayOrigins,
  redactSensitiveQuery,
  redactSentryBreadcrumb,
  redactSentryEvent,
  redactSentrySpan,
  registerMcpDirectRequestURL,
  registerRelayRequestURL,
} from '../redact-url';

describe('redactSensitiveQuery (F-0012)', () => {
  it('redacts gemini-style ?key= query', () => {
    const got = redactSensitiveQuery(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse&key=AIzaSyFAKE',
    );
    expect(got).toContain('key=<redacted>');
    expect(got).not.toContain('AIzaSyFAKE');
  });

  it('redacts multiple sensitive params at once', () => {
    const got = redactSensitiveQuery('https://example.com/x?token=abc&access_token=def&foo=bar');
    expect(got).toContain('token=<redacted>');
    expect(got).toContain('access_token=<redacted>');
    expect(got).toContain('foo=bar');
  });

  it('redacts inside description prefixed with HTTP method (Sentry span format)', () => {
    const got = redactSensitiveQuery('GET https://api.gemini.com/x?key=SECRET&foo=bar');
    expect(got).not.toContain('SECRET');
    expect(got).toContain('key=<redacted>');
    expect(got).toContain('foo=bar');
  });

  it('returns input unchanged when no sensitive params present', () => {
    const url = 'https://example.com/x?foo=bar&baz=qux';
    expect(redactSensitiveQuery(url)).toBe(url);
  });

  it('returns input unchanged for non-URL strings', () => {
    expect(redactSensitiveQuery('not a url')).toBe('not a url');
    expect(redactSensitiveQuery('')).toBe('');
  });

  it('handles relay query_key style ?apikey=', () => {
    const got = redactSensitiveQuery('https://relay.example.com/v1/chat?apikey=sk-RELAY');
    expect(got).not.toContain('sk-RELAY');
  });
});

describe('redactSentryEvent', () => {
  it('redacts request.url', () => {
    const event = { request: { url: 'https://api.example.com/x?key=SECRET' } };
    const redacted = redactSentryEvent(event);
    expect(redacted.request?.url).not.toContain('SECRET');
  });

  it('passes through events without request.url', () => {
    const event = { request: undefined };
    expect(redactSentryEvent(event)).toBe(event);
  });
});

describe('redactSentrySpan', () => {
  it('redacts description if it looks like a URL', () => {
    const span = {
      description: 'GET https://api.gemini.com/x?key=SECRET',
    };
    const redacted = redactSentrySpan(span);
    expect(redacted.description).not.toContain('SECRET');
  });

  it('redacts data["http.url"]', () => {
    const span = {
      data: { 'http.url': 'https://api.gemini.com/x?key=SECRET' },
    };
    const redacted = redactSentrySpan(span);
    expect(redacted.data?.['http.url']).not.toContain('SECRET');
  });

  it('preserves non-URL descriptions', () => {
    const span = { description: 'db.query SELECT *' };
    expect(redactSentrySpan(span).description).toBe('db.query SELECT *');
  });
});

describe('Relay direct URL privacy', () => {
  it('redacts a registered LAN/VPN Relay origin from spans and breadcrumbs', () => {
    registerRelayRequestURL('https://relay.corp.example:8443/v1/chat/completions?key=SECRET');

    expect(redactRegisteredRelayOrigins('POST https://relay.corp.example:8443/v1/chat/completions'))
      .toBe('POST https://<relay-direct>/v1/chat/completions');

    const breadcrumb = redactSentryBreadcrumb({
      data: { url: 'https://relay.corp.example:8443/v1/models?key=SECRET' },
    });
    expect(breadcrumb.data.url).toBe('https://<relay-direct>/v1/models?key=<redacted>');

    const span = redactSentrySpan({
      description: 'POST https://relay.corp.example:8443/v1/chat/completions?key=SECRET',
    });
    expect(span.description).toBe(
      'POST https://<relay-direct>/v1/chat/completions?key=<redacted>',
    );
  });
});

describe('credential request header redaction', () => {
  it('matches x-mcp-* / x-relay-* by prefix, in any case and with underscores', () => {
    for (const name of [
      'x-mcp-credential',
      'X-Mcp-Target-Url',
      'x-mcp-headers',
      'x-mcp-method',
      'x-mcp-anything-added-later',
      'x_mcp_credential',
      'x-relay-proxy-config',
      'X-Relay-Upstream-URL',
      'authorization',
      'Proxy-Authorization',
      'cookie',
      'x-openai-api-key',
      'x-openai-base-url',
      'x-api-key',
      'x-goog-api-key',
    ]) {
      expect(isCredentialRequestHeader(name), name).toBe(true);
    }
    for (const name of ['content-type', 'user-agent', 'accept', 'x-oriveo-error-source', 'mcp-protocol-version']) {
      expect(isCredentialRequestHeader(name), name).toBe(false);
    }
  });

  it('redactSentryEvent removes credential headers from request.headers and keeps the rest', () => {
    const event = redactSentryEvent({
      request: {
        url: 'https://app.example.com/api/mcp/forward',
        headers: {
          'X-Mcp-Credential': 'secret-token',
          'x-mcp-target-url': 'https://mcp.example.com/mcp',
          'x-relay-proxy-config': '{"apiKey":"sk-secret"}',
          Authorization: 'Bearer secret-token',
          'content-type': 'application/json',
        },
      },
    });
    expect(event.request.headers).toEqual({ 'content-type': 'application/json' });
  });

  it('redactSentryEvent does not throw when headers are missing or not an object', () => {
    expect(redactSentryEvent({ request: {} })).toEqual({ request: {} });
    expect(redactSentryEvent({ request: { headers: null } })).toEqual({ request: { headers: null } });
    expect(redactSentryEvent({})).toEqual({});
  });

  it('redactSentrySpan removes credential headers from span attributes (the SDK replaces - with _ in header names)', () => {
    const span = redactSentrySpan({
      description: 'POST /api/mcp/forward',
      data: {
        'http.request.header.x_mcp_credential': 'secret-token',
        'http.request.header.x_relay_proxy_config': '{"apiKey":"sk-secret"}',
        'http.request.header.cookie.session': 'abc',
        'http.request.header.accept': '*/*',
        'http.response.header.content_type': 'application/json',
      },
    });
    expect(span.data).toEqual({
      'http.request.header.accept': '*/*',
      'http.response.header.content_type': 'application/json',
    });
  });
});

describe('OAuth callback URL redaction', () => {
  const CALLBACK =
    'https://app.example.com/mcp/oauth/callback?code=AUTHCODE123&state=STATE456&iss=https%3A%2F%2Fauth.example.com';

  it('redacts code / state / iss in the event URL', () => {
    const event = redactSentryEvent({ request: { url: CALLBACK } });
    expect(event.request.url).toBe(
      'https://app.example.com/mcp/oauth/callback?code=<redacted>&state=<redacted>&iss=<redacted>',
    );
  });

  it('redacts token parameters as well', () => {
    const got = redactSensitiveQuery(
      'https://app.example.com/x?refresh_token=RT&id_token=IT&client_secret=CS&mode=signIn',
    );
    for (const secret of ['RT', 'IT', 'CS']) expect(got).not.toContain(`=${secret}`);
    expect(got).toContain('mode=signIn');
  });

  it('matches whole parameter names only: names like errorCode / statecode are left alone', () => {
    const url = 'https://app.example.com/x?errorCode=E42&statecode=CA&issue=7';
    expect(redactSensitiveQuery(url)).toBe(url);
  });

  it('redacts from / to in navigation breadcrumbs', () => {
    const breadcrumb = redactSentryBreadcrumb({
      category: 'navigation',
      data: { from: '/mcp/oauth/callback?code=AUTHCODE123&state=STATE456', to: '/chat?code=AUTHCODE123' },
    });
    expect(JSON.stringify(breadcrumb)).not.toContain('AUTHCODE123');
    expect(JSON.stringify(breadcrumb)).not.toContain('STATE456');
    expect(breadcrumb.data.to).toBe('/chat?code=<redacted>');
  });

  it('redacts url.full / url.query (a query string without the leading ?) on spans', () => {
    const span = redactSentrySpan({
      description: `GET ${CALLBACK}`,
      data: {
        'url.full': CALLBACK,
        'http.target': '/mcp/oauth/callback?code=AUTHCODE123',
        'url.query': 'code=AUTHCODE123&state=STATE456&plain=1',
        'http.query': '?code=AUTHCODE123',
      },
    });
    const serialized = JSON.stringify(span);
    expect(serialized).not.toContain('AUTHCODE123');
    expect(serialized).not.toContain('STATE456');
    expect(span.data['url.query']).toBe('code=<redacted>&state=<redacted>&plain=1');
    expect(span.data['http.query']).toBe('?code=<redacted>');
  });
});

describe('server-side http breadcrumbs: the query string and fragment are stored apart from the URL', () => {
  // The shape follows `addOutgoingRequestBreadcrumb` in @sentry/core 10.72: `url` has no query string,
  // and `http.query` / `http.fragment` keep their leading `?` / `#`. For a test that runs objects
  // actually produced by the SDK through the real hooks, see
  // `app/api/mcp/forward/upstream-sentry.test.ts`.
  it('redacts sensitive parameters in http.query and http.fragment and keeps the rest', () => {
    const breadcrumb = redactSentryBreadcrumb({
      category: 'http',
      type: 'http',
      data: {
        status_code: 200,
        url: 'https://api.example.com/v1/models',
        'http.method': 'GET',
        'http.query': '?api_key=SECRETKEY123&page=2',
        'http.fragment': '#access_token=SECRETTOKEN456&view=list',
      },
    });
    expect(JSON.stringify(breadcrumb)).not.toContain('SECRETKEY123');
    expect(JSON.stringify(breadcrumb)).not.toContain('SECRETTOKEN456');
    expect(breadcrumb.data['http.query']).toBe('?api_key=<redacted>&page=2');
    expect(breadcrumb.data['http.fragment']).toBe('#access_token=<redacted>&view=list');
    expect(breadcrumb.data.url).toBe('https://api.example.com/v1/models');
  });

  it('treats url.fragment / http.fragment on spans the same way', () => {
    const span = redactSentrySpan({
      description: 'GET https://api.example.com/cb',
      data: { 'url.fragment': '#id_token=SECRETTOKEN456', 'http.fragment': '#plain' },
    });
    expect(span.data['url.fragment']).toBe('#id_token=<redacted>');
    expect(span.data['http.fragment']).toBe('#plain');
  });
});

describe('the registry is bounded and does not evict an origin still in use', () => {
  it('registering again moves the origin to the back of the queue; when full, the least recently registered one is evicted', () => {
    const kept = 'https://kept-mcp.example.com';
    const dropped = 'https://dropped-mcp.example.com';
    registerMcpDirectRequestURL(`${dropped}/mcp`);
    registerMcpDirectRequestURL(`${kept}/mcp`);
    for (let index = 0; index < 127; index += 1) {
      registerMcpDirectRequestURL(`https://filler-${index}.example.com/mcp`);
      // A long-lived connection registers again on every hop
      registerMcpDirectRequestURL(`${kept}/mcp`);
    }
    expect(redactSentryBreadcrumb({ data: { url: `${kept}/hooks/secret` } }).data.url).toBe('https://<mcp-direct>');
    expect(redactSentryBreadcrumb({ data: { url: `${dropped}/hooks/secret` } }).data.url).toBe(`${dropped}/hooks/secret`);
  });
});

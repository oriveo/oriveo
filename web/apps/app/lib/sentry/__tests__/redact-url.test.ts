import { describe, expect, it } from 'vitest';
import {
  redactRegisteredRelayOrigins,
  redactSensitiveQuery,
  redactSentryBreadcrumb,
  redactSentryEvent,
  redactSentrySpan,
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

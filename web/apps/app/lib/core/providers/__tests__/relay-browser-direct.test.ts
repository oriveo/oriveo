import { describe, expect, it } from 'vitest';
import { buildBrowserRelayFetchArgs } from '../relay-browser-direct';

const UPSTREAM = 'https://relay.example.com/v1/responses';

function proxyConfig(authMode: 'none' | 'bearer') {
  const args = buildBrowserRelayFetchArgs(UPSTREAM, { 'Content-Type': 'application/json' }, {
    transport: 'openai_responses',
    authMode,
    apiKey: 'sk-stored-0000',
    customUserAgent: 'Custom UA',
    headers: [{ key: 'X-Internal-Token', value: 'second-secret' }],
    queryParams: [{ key: 'key', value: 'query-secret' }],
  } as Parameters<typeof buildBrowserRelayFetchArgs>[2]);
  expect(args.url).toBe('/api/relay/forward');
  return { raw: args.headers['X-Relay-Proxy-Config'], parsed: JSON.parse(args.headers['X-Relay-Proxy-Config']) };
}

describe('browser -> own reverse proxy proxy config', () => {
  it('with no auth required, the key, custom UA, custom headers and query never leave the browser', () => {
    const { raw, parsed } = proxyConfig('none');
    expect(parsed.authMode).toBe('none');
    expect(parsed.apiKey).toBeUndefined();
    expect(parsed.customUserAgent).toBeUndefined();
    expect(parsed.headers).toBeUndefined();
    expect(parsed.queryParams).toBeUndefined();
    for (const secret of ['sk-stored-0000', 'second-secret', 'query-secret', 'Custom UA']) {
      expect(raw).not.toContain(secret);
    }
  });

  it('when auth is required, they are carried as usual', () => {
    const { parsed } = proxyConfig('bearer');
    expect(parsed.apiKey).toBe('sk-stored-0000');
    expect(parsed.customUserAgent).toBe('Custom UA');
    expect(parsed.headers).toEqual([{ key: 'X-Internal-Token', value: 'second-secret' }]);
    expect(parsed.queryParams).toEqual([{ key: 'key', value: 'query-secret' }]);
  });
});

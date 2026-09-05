import { describe, expect, it } from 'vitest';
import {
  appendRelayEndpointPath,
  buildRelayEndpointCandidates,
  describeRelayEndpoint,
} from './endpoint-normalizer';

describe('Relay endpoint resolver', () => {
  it('splits origin, reverse-proxy prefix, version, and terminal transport', () => {
    expect(describeRelayEndpoint('https://relay.example.com/proxy/v1/chat/completions')).toEqual({
      normalizedInput: 'https://relay.example.com/proxy/v1/chat/completions',
      origin: 'https://relay.example.com',
      pathPrefix: '/proxy',
      explicitVersion: 'v1',
      explicitTransport: 'openai_chat_completions',
      containsEmbeddedQuery: false,
      containsFragment: false,
    });
  });

  it('strips a Gemini terminal route without treating the model name as a prefix', () => {
    const descriptor = describeRelayEndpoint(
      'https://relay.example.com/gateway/v1beta/models/gemini-2.5:generateContent',
    );
    expect(descriptor).toMatchObject({
      pathPrefix: '/gateway',
      explicitVersion: 'v1beta',
      explicitTransport: 'gemini_generate_content',
    });
  });

  it('treats /models as a catalog path, not transport evidence', () => {
    const descriptor = describeRelayEndpoint('relay.example.com/custom/v1/models');
    expect(descriptor).toMatchObject({
      origin: 'https://relay.example.com',
      pathPrefix: '/custom',
      explicitVersion: 'v1',
      explicitTransport: undefined,
    });
  });

  it('builds explicit, default, alternate, then versionless candidates in contract order', () => {
    const descriptor = describeRelayEndpoint('https://relay.example.com/proxy');
    expect(buildRelayEndpointCandidates(descriptor, 'gemini_generate_content')).toEqual([
      { apiBaseURL: 'https://relay.example.com/proxy/v1beta', transport: 'gemini_generate_content', evidence: 'default_version' },
      { apiBaseURL: 'https://relay.example.com/proxy/v1', transport: 'gemini_generate_content', evidence: 'alternate_version' },
      { apiBaseURL: 'https://relay.example.com/proxy', transport: 'gemini_generate_content', evidence: 'versionless_fallback' },
    ]);
  });

  it('keeps a versionless explicit terminal route as the first exact API root', () => {
    const descriptor = describeRelayEndpoint('https://relay.example.com/codex/responses');
    expect(buildRelayEndpointCandidates(descriptor, 'openai_responses')[0]).toEqual({
      apiBaseURL: 'https://relay.example.com/codex',
      transport: 'openai_responses',
      evidence: 'explicit_route',
    });
  });

  it('records embedded query and fragment so discovery can reject before fetch', () => {
    expect(describeRelayEndpoint('https://relay.example.com/v1?key=secret#x')).toMatchObject({
      containsEmbeddedQuery: true,
      containsFragment: true,
    });
  });

  it('rejects userInfo and non-HTTPS URLs', () => {
    expect(() => describeRelayEndpoint('https://user:pass@relay.example.com/v1')).toThrow();
    expect(() => describeRelayEndpoint('http://relay.example.com/v1')).toThrow();
  });

  it('appends terminal paths without carrying query or fragment', () => {
    expect(appendRelayEndpointPath('https://relay.example.com/proxy/v1?x=1#y', '/responses')).toBe(
      'https://relay.example.com/proxy/v1/responses',
    );
  });
});

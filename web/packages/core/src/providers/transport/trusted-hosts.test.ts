// E2-TRUST-01: the official metadata base URL passes only via the delivered trustedHosts.
// The allow / reject / missing-field fallback cases all go through the production sanitizeMetadataBaseURL and resolveEndpoint.
import { describe, expect, it, vi } from 'vitest';
import {
  resolveEndpoint,
  resolveTrustedHosts,
  sanitizeMetadataBaseURL,
  sanitizeTrustedHosts,
  trustedHostMatch,
} from './endpoint-resolver';

describe('E2-TRUST-01 trustedHosts allow / reject / missing-field fallback', () => {
  it('allow: a suffix in the delivered table (including subdomains)', () => {
    expect(sanitizeMetadataBaseURL('miniMax', 'https://api.minimaxi.com/v1', undefined, ['minimax.io', 'minimaxi.com']))
      .toBe('https://api.minimaxi.com/v1');
    expect(sanitizeMetadataBaseURL('moonshot', 'https://api.moonshot.cn/v1', undefined, ['moonshot.ai', 'moonshot.cn']))
      .toBe('https://api.moonshot.cn/v1');
  });

  it('reject: when the delivered list is non-empty only it is trusted, not merged with the built-in fallback; non-https is rejected; all are reported', () => {
    const reporter = vi.fn();
    expect(sanitizeMetadataBaseURL('openAI', 'https://api.openai.com/v1', reporter, ['openai.azure.com'])).toBeUndefined();
    expect(sanitizeMetadataBaseURL('openAI', 'https://evil.example/v1', reporter, ['openai.com'])).toBeUndefined();
    expect(sanitizeMetadataBaseURL('openAI', 'http://api.openai.com/v1', reporter, ['openai.com'])).toBeUndefined();
    expect(reporter.mock.calls.map(([event]) => event.reason)).toEqual(['host_not_allowed', 'host_not_allowed', 'non_https']);
  });

  it('missing field / empty table are equivalent: only the last two labels of the built-in fallback host are trusted (a second domain is not trusted)', () => {
    for (const missing of [undefined, null, []]) {
      expect(sanitizeMetadataBaseURL('miniMax', 'https://api.minimax.io/v1', undefined, missing)).toBe('https://api.minimax.io/v1');
      expect(sanitizeMetadataBaseURL('miniMax', 'https://api.minimaxi.com/v1', undefined, missing)).toBeUndefined();
      expect(sanitizeMetadataBaseURL('moonshot', 'https://api.moonshot.cn/v1', undefined, missing)).toBeUndefined();
    }
    expect(resolveTrustedHosts('siliconFlow', undefined)).toEqual(['siliconflow.cn']);
    expect(resolveTrustedHosts('gemini', undefined)).toEqual(['googleapis.com']);
    // Not an official provider: no trusted-table constraint (same as a missing entry in the old allowlist).
    expect(resolveTrustedHosts('relay', ['relay.example'])).toBeUndefined();
  });

  it('shape validation: uppercase / wildcard / port / IP / single label are dropped one by one; if all are dropped it is treated as a missing field', () => {
    expect(sanitizeTrustedHosts(['minimax.io', 'MiniMax.io', '*.minimax.io', 'minimax.io:443', '1.2.3.4', 'io', 7, 'minimax.io']))
      .toEqual(['minimax.io']);
    expect(resolveTrustedHosts('miniMax', ['*.evil.com', 'EVIL.COM'])).toEqual(['minimax.io']);
    expect(trustedHostMatch('https://notminimax.io/v1', ['minimax.io'])).toBe(false);
    expect(trustedHostMatch('https://api.minimax.io/v1', ['minimax.io'])).toBe(true);
  });

  it('resolveEndpoint consumes the delivered value via transport.trustedHosts; a rejected value falls back to the built-in default', () => {
    expect(resolveEndpoint(null, 'miniMax', 'chat', {
      metadataOverride: { baseUrl: 'https://api.minimaxi.com', endpoints: {}, trustedHosts: ['minimaxi.com'] },
    })).toBe('https://api.minimaxi.com/v1/chat/completions');
    expect(resolveEndpoint(null, 'miniMax', 'chat', {
      metadataOverride: { baseUrl: 'https://api.minimaxi.com', endpoints: {} },
    })).toBe('https://api.minimax.io/v1/chat/completions');
  });
});

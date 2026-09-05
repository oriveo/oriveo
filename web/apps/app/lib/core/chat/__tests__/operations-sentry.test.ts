import { describe, expect, it } from 'vitest';
import {
  createProviderSentryError,
  shouldReportProviderError,
} from '../error-reporting';
import type { ProviderError } from '../../providers/errors';

function providerError(kind: ProviderError['kind'], overrides: Partial<ProviderError> = {}): ProviderError {
  return {
    kind,
    title: 'Provider Error',
    message: 'Provider returned an error',
    ...overrides,
  };
}

describe('chat operations Sentry provider error handling', () => {
  it('does not report user-actionable or transport-layer provider errors', () => {
    expect(shouldReportProviderError(providerError('invalidKey'))).toBe(false);
    expect(shouldReportProviderError(providerError('unauthorized'))).toBe(false);
    expect(shouldReportProviderError(providerError('quotaExceeded'))).toBe(false);
    expect(shouldReportProviderError(providerError('badRequest'))).toBe(false);
    // Transport failures (cannot reach or lost the relay) leave the client nothing to act on, so they are suppressed by kind, even when the title is non-empty
    expect(shouldReportProviderError(providerError('network'))).toBe(false);
  });

  it('never reports failures already returned by an upstream provider or relay', () => {
    expect(shouldReportProviderError(providerError('upstream', { source: 'provider' }))).toBe(false);
    expect(shouldReportProviderError(providerError('emptyResponse', { source: 'provider' }))).toBe(false);
    expect(shouldReportProviderError(providerError('rateLimited', { source: 'provider' }))).toBe(false);
  });

  it('still reports Oriveo-owned unexpected failures', () => {
    expect(shouldReportProviderError(providerError('upstream', { source: 'oriveo' }))).toBe(true);
    expect(shouldReportProviderError(providerError('unavailable', { source: 'oriveo' }))).toBe(true);
    expect(shouldReportProviderError(providerError('emptyResponse', { source: 'oriveo' }))).toBe(true);
  });

  it('does not report a user-owned provider rate limiting, which reaches us with source=oriveo', () => {
    // Payload from a real production event: the free tier passes an OpenRouter shared-pool 429 straight through.
    expect(shouldReportProviderError(providerError('rateLimited', {
      source: 'oriveo',
      status: 429,
      detail: '429 | Provider returned error',
    }))).toBe(false);
  });

  it('does not report a bare network transport failure thrown by fetch', () => {
    // A real production event: the managed route lost connectivity and threw a bare TypeError with no kind.
    expect(shouldReportProviderError(new TypeError('Failed to fetch (api.localhost)'))).toBe(false);
  });

  it('wraps plain provider errors as Error instances with stable messages', () => {
    const error = createProviderSentryError(providerError('upstream', {
      title: 'Provider Error',
      message: 'The AI provider is experiencing issues. Please try again later.',
      detail: 'upstream raw detail',
    }));

    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe('ProviderError');
    expect(error.message).toBe('Provider upstream: Provider Error');
    expect(error.message).not.toContain('upstream raw detail');
  });
});

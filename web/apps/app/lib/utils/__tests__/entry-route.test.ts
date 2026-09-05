import { describe, expect, it } from 'vitest';
import { resolveEntryRoute, sanitizeReturnTo } from '../entry-route';

describe('sanitizeReturnTo', () => {
  it('allows a same-origin relative path', () => {
    expect(sanitizeReturnTo('/chat/abc123')).toBe('/chat/abc123');
    expect(sanitizeReturnTo('/account')).toBe('/account');
  });

  it('rejects protocol-relative URLs', () => {
    expect(sanitizeReturnTo('//evil.com')).toBe('/chat');
    expect(sanitizeReturnTo('//evil.com/phish')).toBe('/chat');
  });

  it('rejects absolute URLs', () => {
    expect(sanitizeReturnTo('https://evil.com')).toBe('/chat');
    expect(sanitizeReturnTo('http://evil.com/phish')).toBe('/chat');
  });

  it('rejects backslash-prefixed redirect tricks', () => {
    expect(sanitizeReturnTo('/\\evil.com')).toBe('/chat');
  });

  it('rejects non-slash and empty inputs', () => {
    expect(sanitizeReturnTo('evil.com')).toBe('/chat');
    expect(sanitizeReturnTo('')).toBe('/chat');
    expect(sanitizeReturnTo('   ')).toBe('/chat');
    expect(sanitizeReturnTo(null)).toBe('/chat');
    expect(sanitizeReturnTo(undefined)).toBe('/chat');
  });
});

describe('resolveEntryRoute', () => {
  it('returns returnTo when explicitly provided', () => {
    expect(resolveEntryRoute({
      hasCompletedOnboarding: true,
      providerCount: 2,
      returnTo: '/account',
    })).toBe('/account');
  });

  it('sanitizes malicious returnTo to /chat', () => {
    expect(resolveEntryRoute({
      hasCompletedOnboarding: true,
      providerCount: 2,
      returnTo: 'https://evil.com/phish',
    })).toBe('/chat');
    expect(resolveEntryRoute({
      hasCompletedOnboarding: true,
      providerCount: 2,
      returnTo: '//evil.com',
    })).toBe('/chat');
  });

  it('sends users with completed setup to chat', () => {
    expect(resolveEntryRoute({
      hasCompletedOnboarding: true,
      providerCount: 1,
    })).toBe('/chat');
  });

  it('sends returning users with providers to chat even if onboarding flag is missing', () => {
    expect(resolveEntryRoute({
      hasCompletedOnboarding: false,
      providerCount: 2,
    })).toBe('/chat');
  });

  it('sends users who completed onboarding without a provider to chat', () => {
    expect(resolveEntryRoute({
      hasCompletedOnboarding: true,
      providerCount: 0,
    })).toBe('/chat');
  });

  it('sends first-run guests to welcome when setup is incomplete', () => {
    expect(resolveEntryRoute({
      hasCompletedOnboarding: false,
      providerCount: 0,
    })).toBe('/welcome');
  });
});

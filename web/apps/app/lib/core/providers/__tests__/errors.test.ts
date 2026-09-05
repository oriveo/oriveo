import { describe, it, expect } from 'vitest';
import {
  ProviderErrorObject,
  asProviderErrorObject,
  networkError,
  toProviderError,
} from '../errors';

describe('ProviderErrorObject', () => {
  it('is a real Error subclass, instanceof Error', () => {
    const err = new ProviderErrorObject({
      kind: 'network',
      title: 'Network Error',
      message: 'msg',
    });
    expect(err).toBeInstanceOf(Error);
    expect(err).toBeInstanceOf(ProviderErrorObject);
    expect(err.name).toBe('ProviderError');
    expect(err.message).toBe('msg');
  });

  it('carries a stack when thrown (key for Sentry stack capture)', () => {
    try {
      throw new ProviderErrorObject({
        kind: 'network',
        title: 't',
        message: 'm',
      });
    } catch (err) {
      expect(err).toBeInstanceOf(Error);
      expect((err as Error).stack).toBeTruthy();
      expect((err as Error).stack).toContain('errors.test.ts');
    }
  });

  it('implements the ProviderError interface with readable fields', () => {
    const err = new ProviderErrorObject({
      kind: 'upstream',
      title: 'Upstream',
      message: 'm',
      detail: 'd',
      i18nKey: 'moderation',
    });
    expect(err.kind).toBe('upstream');
    expect(err.title).toBe('Upstream');
    expect(err.detail).toBe('d');
    expect(err.i18nKey).toBe('moderation');
  });
});

describe('networkError', () => {
  it('returns a ProviderErrorObject instance (with a stack)', () => {
    const err = networkError(new Error('navigator.onLine === false'));
    expect(err).toBeInstanceOf(ProviderErrorObject);
    expect(err).toBeInstanceOf(Error);
    expect(err.kind).toBe('network');
    expect(err.detail).toBe('navigator.onLine === false');
  });

  it('accepts a non-Error value, detail falls back to String()', () => {
    const err = networkError('plain string error');
    expect(err.detail).toBe('plain string error');
  });
});

describe('asProviderErrorObject', () => {
  it('returns an existing ProviderErrorObject as is (no re-wrapping)', () => {
    const original = networkError('x');
    expect(asProviderErrorObject(original)).toBe(original);
  });

  it('wraps a plain ProviderError object into a ProviderErrorObject', () => {
    const plain = { kind: 'upstream' as const, title: 't', message: 'm' };
    const wrapped = asProviderErrorObject(plain);
    expect(wrapped).toBeInstanceOf(ProviderErrorObject);
    expect(wrapped.kind).toBe('upstream');
  });
});

describe('toProviderError', () => {
  it('400 returns badRequest', () => {
    const err = toProviderError(400, '');
    expect(err.kind).toBe('badRequest');
  });

  it('401 returns invalidKey by default', () => {
    const err = toProviderError(401, 'invalid api key');
    expect(err.kind).toBe('invalidKey');
  });

  it('401 + quota keyword returns quotaExceeded', () => {
    const err = toProviderError(401, 'insufficient quota');
    expect(err.kind).toBe('quotaExceeded');
  });

  it('5xx returns upstream by default', () => {
    const err = toProviderError(503, 'server error');
    expect(err.kind).toBe('upstream');
  });

  it('relay upstream 5xx keeps the redacted upstream text as the user-facing body', () => {
    const err = toProviderError(
      500,
      '{"error":"Server error: insufficient balance"}',
      'https://relay.example.com/v1/chat/completions',
    );

    expect(err.kind).toBe('upstream');
    expect(err.message).toBe('Server error: insufficient balance');
    expect(err.detail).toBe('Server error: insufficient balance');
    expect(err.source).toBe('provider');
    expect(err.status).toBe(500);
  });
});

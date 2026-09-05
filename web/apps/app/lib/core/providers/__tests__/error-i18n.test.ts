import { describe, it, expect } from 'vitest';
import { localizeProviderError } from '../error-i18n';

describe('localizeProviderError', () => {
  const mockT = (key: string) => `[translated:${key}]`;

  it('maps invalidKey message to i18n key', () => {
    const raw = 'The API key you entered is invalid or has been revoked. Please check your key and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:invalidKey.message]');
  });

  it('maps rateLimited message to i18n key', () => {
    const raw = 'You have exceeded the rate limit. Please wait a moment and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:rateLimited.message]');
  });

  it('maps network message to i18n key', () => {
    const raw = 'Unable to connect. Please check your internet connection and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:network.message]');
  });

  it('maps upstream message to i18n key', () => {
    const raw = 'The AI provider is experiencing issues. Please try again later.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:upstream.message]');
  });

  it('maps emptyResponse message to i18n key', () => {
    const raw = 'The model catalog response was invalid. Please try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:emptyResponse.message]');
  });

  it('maps emptyModelCatalog message to i18n key', () => {
    const raw = 'The model catalog is empty. Please try again later or enter a model ID manually.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:emptyModelCatalog.message]');
  });

  it('maps badRequest message to i18n key', () => {
    const raw = 'The request was malformed. Please check your input and try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:requestFailed.message]');
  });

  it('maps dynamic "Request failed with status" to requestFailed key', () => {
    const raw = 'Request failed with status 502. Please try again.';
    expect(localizeProviderError(raw, mockT)).toBe('[translated:requestFailed.message]');
  });

  it('maps Relay-specific action messages to i18n keys', () => {
    expect(localizeProviderError(
      'This relay requires Codex client identity. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.',
      mockT,
    )).toBe('[translated:relay.codexIdentityRequiredSwitch]');
    expect(localizeProviderError(
      'The relay upstream does not offer this model. Open Settings → Providers → this relay → Edit → Model and change it to a model ID your relay supports.',
      mockT,
    )).toBe('[translated:relay.modelUnavailable]');
    expect(localizeProviderError(
      'This relay hit a rate limit. Wait a moment, lower request volume, or switch to another key / relay.',
      mockT,
    )).toBe('[translated:relay.rateLimited]');
  });

  it('returns raw message for unknown error strings', () => {
    const raw = 'Some unknown error occurred.';
    expect(localizeProviderError(raw, mockT)).toBe(raw);
  });

  it('falls back to raw message when translation throws', () => {
    const throwingT = () => { throw new Error('missing key'); };
    const raw = 'The API key you entered is invalid or has been revoked. Please check your key and try again.';
    expect(localizeProviderError(raw, throwingT)).toBe(raw);
  });
});

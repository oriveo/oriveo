import { PROVIDER_VALIDATION_MESSAGES } from '../../../lib/core/providers/validation-messages';

/** The lastError recorded on a connection (English original sentence) → localized errors.*; unrecognized ones are returned as is. Shared by the official detail and the relay recovery card. */
export function localizeProviderLastError(
  lastError: string | undefined,
  t: (key: string) => string,
): string | undefined {
  if (!lastError) {
    return undefined;
  }

  if (lastError === 'The API key you entered is invalid or has been revoked. Please check your key and try again.') {
    return t('invalidKey.message');
  }

  if (lastError === 'You have exceeded the rate limit. Please wait a moment and try again.') {
    return t('rateLimited.message');
  }

  if (lastError === 'Unable to connect. Please check your internet connection and try again.') {
    return t('network.message');
  }

  if (lastError === 'The AI provider is experiencing issues. Please try again later.') {
    return t('upstream.message');
  }

  if (lastError === 'The model catalog response was invalid. Please try again.') {
    return t('emptyResponse.message');
  }

  if (lastError === 'The model catalog is empty. Please try again later or enter a model ID manually.') {
    return t('emptyModelCatalog.message');
  }

  // BYOK key validation (2026-06-02): invalid = red banner / unverified = grey soft hint, matching the lastError write-back on iOS.
  if (lastError === PROVIDER_VALIDATION_MESSAGES.invalidKey) {
    return t('validation.invalidKey');
  }

  if (lastError === PROVIDER_VALIDATION_MESSAGES.unverified) {
    return t('validation.unverified');
  }

  if (
    lastError === 'The request was malformed. Please check your input and try again.'
    || /^Request failed with status \d+\. Please try again\.$/.test(lastError)
  ) {
    return t('requestFailed.message');
  }

  return lastError;
}

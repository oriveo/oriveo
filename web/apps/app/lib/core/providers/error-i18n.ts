import { RELAY_GUIDANCE } from '@oriveo/core/providers/relay-error-classifier';
import { RELAY_HTML_PAGE_ERROR } from '@oriveo/core/providers/relay-stream';
import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';
import { RELAY_IMAGE_CHAT_MODEL_REQUIRED_MESSAGE, RELAY_IMAGE_ROUTE_UNSUPPORTED_MESSAGE } from './relay-image-route-error';

// Maps the hardcoded English error messages from errors.ts to i18n keys.
// The message produced by errors.ts is stored as a string in provider.status.message, so this
// module looks the corresponding errors namespace key back up and returns the localized text.

// Relay guidance sentences -> errors.relay.*. A chat failure card stores the English source sentence in its body
// and localizes it at render time (aligned with iOS).
const RELAY_GUIDANCE_TO_KEY: Record<string, string> = {
  // Relay error guidance: English source sentences identical to iOS, produced by RELAY_GUIDANCE in the classifier.
  [RELAY_GUIDANCE.codexIdentityRequiredSwitch]: 'relay.codexIdentityRequiredSwitch',
  [RELAY_GUIDANCE.codexIdentityRejected]: 'relay.codexIdentityRejected',
  [RELAY_GUIDANCE.imageGenerationEndpointUnavailable]: 'relay.imageGenerationEndpointUnavailable',
  [RELAY_GUIDANCE.chatCompletionsRejectedByCodexHost]: 'relay.chatCompletionsRejectedByCodexHost',
  [RELAY_GUIDANCE.imageResponseFormatRejected]: 'relay.imageResponseFormatRejected',
  [RELAY_GUIDANCE.upstreamUnavailable]: 'relay.upstreamUnavailable',
  [RELAY_GUIDANCE.modelUnavailable]: 'relay.modelUnavailable',
  [RELAY_GUIDANCE.responsesProtocolRequired]: 'relay.responsesProtocolRequired',
  [RELAY_GUIDANCE.storeRejected]: 'relay.storeRejected',
  [RELAY_GUIDANCE.serviceTierRejected]: 'relay.serviceTierRejected',
  [RELAY_GUIDANCE.maxTokensRequired]: 'relay.maxTokensRequired',
  [RELAY_GUIDANCE.anthropicAuthRequired]: 'relay.anthropicAuthRequired',
  [RELAY_GUIDANCE.imageSchemaMismatch]: 'relay.imageSchemaMismatch',
  [RELAY_GUIDANCE.clientGated]: 'relay.clientGated',
  [RELAY_HTML_PAGE_ERROR]: 'relay.webPageReturned',
  // Image routing.
  [RELAY_IMAGE_ROUTE_UNSUPPORTED_MESSAGE]: 'relay.imageRouteUnsupported',
  [RELAY_IMAGE_CHAT_MODEL_REQUIRED_MESSAGE]: 'relay.missingChatDriverModel',
};

/** Generic reason line for a local exception (e.g. a manual-setup write failing): the English source matches Android `error_generic_message` and is localized at render time. */
export const UNEXPECTED_ERROR_MESSAGE = 'An unexpected error occurred.';

const ERROR_MESSAGE_TO_KEY: Record<string, string> = {
  [UNEXPECTED_ERROR_MESSAGE]: 'unexpected.message',
  'The request was malformed. Please check your input and try again.': 'requestFailed.message',
  'The API key you entered is invalid or has been revoked. Please check your key and try again.': 'invalidKey.message',
  'You have exceeded the rate limit. Please wait a moment and try again.': 'rateLimited.message',
  'Unable to connect. Please check your internet connection and try again.': 'network.message',
  'The AI provider is experiencing issues. Please try again later.': 'upstream.message',
  'The model catalog response was invalid. Please try again.': 'emptyResponse.message',
  'The model catalog is empty. Please try again later or enter a model ID manually.': 'emptyModelCatalog.message',
  // BYOK key validation: the English keys written back to provider.status.message and lastError.
  [PROVIDER_VALIDATION_MESSAGES.invalidKey]: 'validation.invalidKey',
  [PROVIDER_VALIDATION_MESSAGES.unverified]: 'validation.unverified',
  [PROVIDER_VALIDATION_MESSAGES.catalogUnavailable]: 'validation.catalogUnavailable',
  [PROVIDER_VALIDATION_MESSAGES.grokSubscriptionCatalogUnavailable]: 'validation.grokSubscriptionCatalogUnavailable',
  [PROVIDER_VALIDATION_MESSAGES.grokSubscriptionReauthorize]: 'validation.grokSubscriptionReauthorize',
  [PROVIDER_VALIDATION_MESSAGES.openAISubscriptionCatalogUnavailable]: 'validation.openAISubscriptionCatalogUnavailable',
  [PROVIDER_VALIDATION_MESSAGES.openAISubscriptionReauthorize]: 'validation.openAISubscriptionReauthorize',
  // The four hard subscription failures: the authorization path already has copy in 16 languages,
  // and this wires the resync and chat paths up to it as well.
  [PROVIDER_VALIDATION_MESSAGES.grokSubscriptionNotEligible]: 'validation.grokSubscriptionNotEligible',
  [PROVIDER_VALIDATION_MESSAGES.grokSubscriptionQuotaExhausted]: 'validation.grokSubscriptionQuotaExhausted',
  [PROVIDER_VALIDATION_MESSAGES.grokSubscriptionUnavailable]: 'validation.grokSubscriptionUnavailable',
  [PROVIDER_VALIDATION_MESSAGES.grokSubscriptionCatalogEmpty]: 'validation.grokSubscriptionCatalogEmpty',
  [PROVIDER_VALIDATION_MESSAGES.openAISubscriptionNotEligible]: 'validation.openAISubscriptionNotEligible',
  [PROVIDER_VALIDATION_MESSAGES.openAISubscriptionQuotaExhausted]: 'validation.openAISubscriptionQuotaExhausted',
  [PROVIDER_VALIDATION_MESSAGES.openAISubscriptionUnavailable]: 'validation.openAISubscriptionUnavailable',
  [PROVIDER_VALIDATION_MESSAGES.openAISubscriptionCatalogEmpty]: 'validation.openAISubscriptionCatalogEmpty',
  ...RELAY_GUIDANCE_TO_KEY,
};

type TranslationFn = (key: string) => string;

export function localizeProviderError(rawMessage: string, t: TranslationFn): string {
  const key = ERROR_MESSAGE_TO_KEY[rawMessage];
  if (key) {
    try {
      return t(key);
    } catch {
      return rawMessage;
    }
  }
  // Dynamic format: Request failed with status XXX
  if (rawMessage.startsWith('Request failed with status')) {
    try {
      return t('requestFailed.message');
    } catch {
      return rawMessage;
    }
  }
  return rawMessage;
}

/** English source string persisted as the title of a provider-sourced failure card (aligned with iOS); localizeFailureTitle translates it at render time. */
export const PROVIDER_REQUEST_FAILED_TITLE = 'Provider Request Failed';

/** Failure-card title for display: the English source string is translated to the current language; anything else (including already-localized legacy strings) is returned as is. */
export function localizeFailureTitle(title: string | undefined, t: TranslationFn): string | undefined {
  return title === PROVIDER_REQUEST_FAILED_TITLE ? t('providerRequestFailed.title') : title;
}

/** Failure-card body for display: only text matching the relay guidance source table is localized; anything outside it (upstream raw text, already-localized legacy strings) is returned as is. */
export function localizeRelayGuidance(detail: string | undefined, t: TranslationFn): string | undefined {
  const key = detail ? RELAY_GUIDANCE_TO_KEY[detail] : undefined;
  return key ? t(key) : detail;
}

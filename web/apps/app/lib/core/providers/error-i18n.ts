import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';

// Maps the hardcoded English error messages from errors.ts to i18n keys.
// The message produced by errors.ts is stored as a string in provider.status.message, so this
// module looks the corresponding errors namespace key back up and returns the localized text.

const ERROR_MESSAGE_TO_KEY: Record<string, string> = {
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
  'This relay requires Codex client identity. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.': 'relay.codexIdentityRequiredSwitch',
  'This relay requires Codex client identity. Open Settings → Providers → this relay → Edit → Compatibility and turn on “Codex compatible identity”, then retry.': 'relay.codexIdentityEnable',
  'This relay still rejects Oriveo\'s Codex client identity. Open Settings → Providers → this relay → Edit → Advanced HTTP and set a custom User-Agent or custom Header, or switch to another relay / contact its administrator.': 'relay.codexIdentityRejected',
  'This relay only exposes /v1/responses and rejects /chat/completions. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.': 'relay.chatCompletionsRejectedByCodexHost',
  'The relay could not reach its upstream provider. This is not your configuration — the relay administrator\'s upstream account may be invalid, out of credits, or rate-limited. Switch to another relay or contact its administrator.': 'relay.upstreamUnavailable',
  'The relay upstream does not offer this model. Open Settings → Providers → this relay → Edit → Model and change it to a model ID your relay supports.': 'relay.modelUnavailable',
  'This relay requires the OpenAI Responses protocol. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.': 'relay.responsesProtocolRequired',
  'This relay rejects the store/disable_response_storage field. Open Settings → Providers → this relay → Edit → Compatibility and turn off “Don\'t keep responses in the cloud”, then retry.': 'relay.storeRejected',
  'This relay does not accept the current OpenAI service tier value. Open Settings → Providers → this relay → Edit → Compatibility and clear “OpenAI service tier”, then retry.': 'relay.serviceTierRejected',
  'This relay requires the max_tokens parameter. Open the model settings for this relay and set a max_tokens value, then retry.': 'relay.maxTokensRequired',
  'This relay expects an Anthropic-style x-api-key header. Open Settings → Providers → this relay → Edit → Auth and switch to “x-api-key”, then retry.': 'relay.anthropicAuthRequired',
  'Image attachments use the wrong schema for this relay protocol. The model and protocol may not match — open Settings → Providers → this relay → Edit → Relay type and switch to a type that fits your model, then retry.': 'relay.imageSchemaMismatch',
  'This relay hit a rate limit. Wait a moment, lower request volume, or switch to another key / relay.': 'relay.rateLimited',
  // Image routing.
  'Image generation is not available on this transport. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses or Chat Completions.': 'relay.imageRouteUnsupported',
  'Please add a chat model to this relay before using image generation.': 'relay.missingChatDriverModel',
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

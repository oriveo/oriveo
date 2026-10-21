/**
 * Dedicated error for a Relay image route that is unsupported (the current wire protocol cannot generate images).
 *
 * Thrown before sending from resolveRelayImageRouting in stream-options: no request went out, it is a problem in the
 * user's connection configuration, and the way out is to change the protocol. The kind is in
 * NON_REPORTABLE_PROVIDER_ERROR_KINDS so it is not reported to Sentry (same policy as Android
 * shouldCaptureToSentry for InvalidConfiguration).
 *
 * message is the English source sentence that gets persisted and is not shown directly: the failure card body
 * maps it through error-i18n to errors.relay.imageRouteUnsupported at render time (16 languages, word for word
 * the same as Android relay_image_route_unsupported).
 * The source sentence must not change: already-persisted failure cards use it to look up the localized text.
 *
 * It lives in a leaf module because error-i18n / error-reporting / chat-stream-utils / chat-failure telemetry /
 * stream-options all reference it.
 */
export const RELAY_IMAGE_TRANSPORT_UNSUPPORTED_KIND = 'relayImageTransportUnsupported';

export const RELAY_IMAGE_ROUTE_UNSUPPORTED_MESSAGE =
  'Image generation is not available on this transport. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses or Chat Completions.';

export interface RelayImageTransportUnsupportedError extends Error {
  readonly kind: typeof RELAY_IMAGE_TRANSPORT_UNSUPPORTED_KIND;
  /** The body is message (the guidance source sentence), localized at render time; see errorDetail of the operations-send failure card. */
  readonly relayGuidance: true;
}

export function relayImageTransportUnsupportedError(): RelayImageTransportUnsupportedError {
  const error = new Error(RELAY_IMAGE_ROUTE_UNSUPPORTED_MESSAGE) as Error & {
    kind: string;
    relayGuidance: true;
  };
  error.name = 'ProviderError';
  error.kind = RELAY_IMAGE_TRANSPORT_UNSUPPORTED_KIND;
  error.relayGuidance = true;
  return error as RelayImageTransportUnsupportedError;
}

/**
 * Relay image generation without a chat driver model (image generation over the Responses wire needs a chat model
 * to drive the image_generation tool). Also a local pre-send configuration problem, so the same policy applies:
 * not reported; the body source sentence maps to errors.relay.missingChatDriverModel at render time and must not change.
 */
export const RELAY_IMAGE_CHAT_MODEL_REQUIRED_KIND = 'relayImageChatModelRequired';

export const RELAY_IMAGE_CHAT_MODEL_REQUIRED_MESSAGE =
  'Please add a chat model to this relay before using image generation.';

export interface RelayImageChatModelRequiredError extends Error {
  readonly kind: typeof RELAY_IMAGE_CHAT_MODEL_REQUIRED_KIND;
  readonly relayGuidance: true;
}

export function relayImageChatModelRequiredError(): RelayImageChatModelRequiredError {
  const error = new Error(RELAY_IMAGE_CHAT_MODEL_REQUIRED_MESSAGE) as Error & { kind: string; relayGuidance: true };
  error.name = 'ProviderError';
  error.kind = RELAY_IMAGE_CHAT_MODEL_REQUIRED_KIND;
  error.relayGuidance = true;
  return error as RelayImageChatModelRequiredError;
}

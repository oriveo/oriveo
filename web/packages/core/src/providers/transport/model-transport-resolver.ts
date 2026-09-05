/**
 * modelID to transport kind resolution.
 *
 * Order:
 *   1. `model.transport` from metadata, read through getModelTransport.
 *   2. No metadata: Relay and manually added models fall back to openai_chat.
 *
 * An official provider's endpoint and transport are decided by metadata alone; the client never
 * infers them from model ID substrings.
 *
 * The metadata lookup is injected as getModelTransport (the renderer passes the metadata-client
 * implementation, main passes a snapshot one), so this module is not coupled to a cache layer.
 */

import type { ProviderKind } from '@oriveo/shared/pure-types';

/** Look up the transport that metadata publishes for a modelID plus providerKind. Undefined when absent. */
export type GetModelTransportFn = (
  modelID: string,
  providerKind: ProviderKind | string,
) => string | undefined;

/**
 * Resolve a model's transport kind: metadata first, with a fallback only for Relay and manual models.
 *
 * Returns a string rather than TransportKind because metadata may publish a future kind
 * (forward compatibility); callers should hand it to `resolveStrategyByKindOrFallback` to handle
 * unknown kinds.
 */
export function resolveModelTransport(
  providerKind: ProviderKind | string,
  modelID: string,
  getModelTransport?: GetModelTransportFn,
): string {
  const metadataValue = getModelTransport?.(modelID, providerKind);
  if (metadataValue) return metadataValue;
  // Relay-only heuristic fallback: a user-defined endpoint has no official metadata to follow, so the
  // conservative choice is the OpenAI Chat compatible shape. A rejection must propagate unchanged and
  // must not be silently retried with different parameters.
  return 'openai_chat';
}

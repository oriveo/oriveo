import type { Provider } from '@oriveo/shared';
import { getRelayRuntimeConfig } from '../metadata/metadata-client';
import { getProviderInstanceDisplayName } from '../providers/provider-display';
import { enrichRelayModelsByTransport } from '../providers/provider-selection-snapshot';
import { resolveRelayStoredModel } from '../providers/relay-model-identity';

/** The model stored in a relay conversation is no longer among that connection's enabled models. */
export interface ConversationModelRemoval {
  /** The model id stored in the conversation, kept as is and never rewritten. */
  modelID: string;
  /** Display name of the connection named in the notice bar. */
  connectionName: string;
}

/**
 * Whether the conversation model has been removed: only relay (including local engine) is checked; an empty conversation model does not count as removed (the fallback applies).
 * On removal nothing is silently substituted; the caller uses this to show the notice bar and block send / retry / continue / regenerate.
 */
export function resolveConversationModelRemoval(
  provider: Provider | undefined,
  conversationModelID: string | null | undefined,
): ConversationModelRemoval | null {
  if (!provider || provider.kind !== 'relay') return null;
  const modelID = conversationModelID?.trim();
  if (!modelID) return null;
  // Resolve with the same rule as the selection snapshot: a literal key hit, otherwise accept it when exactly one enabled model has a canonical equal to the stored value
  // (a canonical value stored before literal matching existed); several with the same canonical, or a dated stored value with only the base left, all count as removed.
  const enabledModels = enrichRelayModelsByTransport(provider, provider.models, getRelayRuntimeConfig());
  if (resolveRelayStoredModel(enabledModels, modelID)) return null;
  return { modelID, connectionName: getProviderInstanceDisplayName(provider) };
}

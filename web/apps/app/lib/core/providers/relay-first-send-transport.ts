import type { AIModel, Provider, RelayModelTransport } from '@oriveo/shared';
import { decidedTransport, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { providerFormOf } from '../capability/truth/provider-form';
import { dispatchesImageGeneration } from '../chat/image-generation-dispatch';
import { cachedRelayProbeCandidates, relayCatalogEndpointTypes } from './relay-probe-candidates';

/**
 * First-send transport of an unverified model (RL2-FIRSTSEND-05): chat first send, negative-cache read/write key and the advanced page's "Auto =" all read this one.
 *
 * A relay (non-local) whose model has no transport of its own (missing / legacy auto), whose connection transport is not user-selected, which is not an image-generation model,
 * and whose first candidate is Messages → Messages; everything else = effectiveTransport.
 * Candidates use the same mapping as per-model probing, but read only the catalog endpoint types already in this session and the cached family table, and never send a request for the first send.
 */
export function relayFirstSendTransport(
  provider: Provider,
  model: AIModel,
  options: {
    /** Defaults to the by-model family table cached by metadata-client. */
    cachedFamily?: (modelID: string) => string | undefined;
    /**
     * The first-send attachments contain files, none has extracted text, and Messages cannot send files natively: first send is unchanged and still uses the original transport
     * (same criterion as iOS `ChatManager.relayFirstSendTransport`, computed by the sender and passed in).
     */
    messagesBlockedByFiles?: boolean;
  } = {},
): RelayModelTransport {
  const fallback = effectiveTransport(provider, model);
  if (providerFormOf(provider) !== 'relay') return fallback;
  if (provider.relayRequested?.engineProfile) return fallback;
  const own = model.relayTransport as string | undefined;
  if (own && own !== 'auto') return fallback;
  if (decidedTransport(provider, null) !== undefined) return fallback;
  if (dispatchesImageGeneration(model)) return fallback;
  const first = cachedRelayProbeCandidates({
    modelID: model.id,
    supportedEndpointTypes: relayCatalogEndpointTypes(provider.id, model.id),
    cachedFamily: options.cachedFamily,
  })[0];
  if (first !== 'anthropic_messages') return fallback;
  return options.messagesBlockedByFiles ? fallback : 'anthropic_messages';
}

/**
 * Returns the first-send protocol when the model protocol is undecided but the first send switches to another protocol (Messages), otherwise undefined.
 * The chat preference identity (`capabilityPreferenceIdentity`) uses it so the switch has somewhere to be stored before sending.
 */
export function relayUndecidedFirstSendTransport(
  provider: Pick<Provider, 'id' | 'kind' | 'relayRequested'>,
  model: Pick<AIModel, 'id' | 'relayTransport'>,
): RelayModelTransport | undefined {
  const first = relayFirstSendTransport(provider as Provider, model as AIModel);
  return first !== effectiveTransport(provider as Provider, model as AIModel) ? first : undefined;
}

import type { StoreApi } from 'zustand';
import type { AIModel, Provider, RelayModelTransport } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import type { AppStore } from '../store/app-store';
import { sameNormalizedID } from '../../utils/id-utils';
import { providerFormOf } from '../capability/truth/provider-form';
import { enrichRelayProviderModels } from '../provider-model-ops';

/**
 * A real send reaching delivered upgrades reachable to observed: only when the current model source is still reachable and the current model transport
 * equals the transport at send start; follow-connection (nil) / user / failure / partial output never write, and an unchanged value is not written either.
 * `startProvider` / `startModel` must be snapshots taken at send start. Returns whether it wrote back.
 */
export function promoteRelayTransportOnDelivered(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
): boolean {
  if (providerFormOf(startProvider) !== 'relay' || !startProvider.relayRequested) return false;
  const startTransport = effectiveTransport(startProvider, startModel);
  const latest = store.getState().providers.find((item) => sameNormalizedID(item.id, startProvider.id));
  if (!latest) return false;
  const current = latest.models.find((model) => model.id === startModel.id);
  if (!current || current.relayTransportSource !== 'reachable' || current.relayTransport !== startTransport) {
    return false;
  }
  const models = latest.models.map((model) => (
    model.id === current.id ? { ...model, relayTransportSource: 'observed' as const } : model
  ));
  // The source goes from reachable to observed; the native file allowlist must be inherited again from S0.
  store.getState().updateProvider(latest.id, { models: enrichRelayProviderModels(latest, models) });
  return true;
}

/**
 * After a transport-level fallback switches to `transport` and the upstream starts outputting: write that transport onto the model as observed, on the same write-back path as the delivered upgrade.
 * Nothing is written if the model was deleted, its transport changed or the user picked a transport manually during the send. `startProvider` / `startModel` are snapshots at send start.
 */
export function recordRelayTransportObservedAfterFallback(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
  transport: RelayModelTransport,
): boolean {
  if (providerFormOf(startProvider) !== 'relay' || !startProvider.relayRequested) return false;
  const startTransport = effectiveTransport(startProvider, startModel);
  const latest = store.getState().providers.find((item) => sameNormalizedID(item.id, startProvider.id));
  if (!latest) return false;
  const current = latest.models.find((model) => model.id === startModel.id);
  if (!current || current.relayTransportSource === 'user' || effectiveTransport(latest, current) !== startTransport) {
    return false;
  }
  const models = latest.models.map((model) => (
    model.id === current.id
      ? { ...model, relayTransport: transport, relayTransportSource: 'observed' as const }
      : model
  ));
  store.getState().updateProvider(latest.id, { models: enrichRelayProviderModels(latest, models) });
  return true;
}

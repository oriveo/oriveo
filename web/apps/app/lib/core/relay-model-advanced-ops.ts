import type { StoreApi } from 'zustand';
import type {
  AIModel,
  Provider,
  ReasoningMode,
  RelayCapabilityOverrides,
  RelayModelTransport,
} from '@oriveo/shared';
import { relayFirstSendTransport } from './providers/relay-first-send-transport';
import type { AppStore } from './store/app-store';
import { recordRelayGenerationKeyStatus } from './providers/relay-key-access-writeback';
import { relayPingKeyStatus } from './providers/ping-relay';
import { sameNormalizedID } from '../utils/id-utils';
import { enrichRelayProviderModels } from './provider-model-ops';
import { canProbeRelayModels } from './relay-model-probe-ops';
import { probeRelayModelTransport, type RelayModelProbePing } from './providers/relay-model-probe';
import { clearRelayNegativeCache, type RelayNegativeCacheKind } from './chat/relay-negative-cache';
import { relayAutomaticReasoningLevels } from './chat/capability-control-presentation';
import { clearRelayReasoningTierRejections } from './chat/relay-reasoning-tiers';

/**
 * Writes for "Model > Advanced": per-model protocol, capability overrides, reasoning level set, and restore-all-to-auto.
 * `models` and `catalogModels` are written together by id; persistence goes through `updateProvider`, the same path as per-model probing / capability testing.
 */

/** web = web search: the user source of the web override; Auto clears it (both user and tested). */
export type RelayAdvancedCapabilityKey = 'image' | 'file' | 'imageGeneration' | 'toolCall' | 'web';

/** Negative-cache tier to clear when an override is written as user; image generation has no tier. */
const NEGATIVE_CACHE_KIND: Record<RelayAdvancedCapabilityKey, RelayNegativeCacheKind | null> = {
  image: 'image',
  file: 'file',
  imageGeneration: null,
  toolCall: 'toolCall',
  web: null,
};

function findProvider(store: StoreApi<AppStore>, providerID: string): Provider | undefined {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, providerID));
}

function findModel(provider: Provider | undefined, modelID: string): AIModel | undefined {
  return provider?.models.find((item) => item.id === modelID);
}

/** Rewrites both tables for the same id; when the protocol changes, enrichment must be re-run (envelope and native-file inheritance follow the protocol). */
function writeModel(
  store: StoreApi<AppStore>,
  provider: Provider,
  modelID: string,
  update: (model: AIModel) => AIModel,
  options: { reenrich?: boolean } = {},
): void {
  const apply = (model: AIModel): AIModel => (model.id === modelID ? update(model) : model);
  let models = provider.models.map(apply);
  let catalogModels = provider.catalogModels.map(apply);
  if (options.reenrich) {
    const next = { ...provider, models, catalogModels };
    models = enrichRelayProviderModels(next, models);
    catalogModels = enrichRelayProviderModels(next, catalogModels);
  }
  const updatedAt = new Date().toISOString();
  store.getState().updateProvider(provider.id, { models, catalogModels, updatedAt });
}

function withOverrides(model: AIModel, overrides: RelayCapabilityOverrides | undefined): AIModel {
  const next = { ...model };
  if (overrides && Object.keys(overrides).length > 0) next.relayCapabilityOverrides = overrides;
  else delete next.relayCapabilityOverrides;
  return next;
}

function withoutTransport(model: AIModel): AIModel {
  const next = { ...model };
  delete next.relayTransport;
  delete next.relayTransportSource;
  return next;
}

/** Choosing a protocol writes `{protocol, user}`; `null` (Auto) clears the model-level protocol and its source. Nothing is written if the model is not in the enabled list. */
export function setRelayModelTransport(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  transport: RelayModelTransport | null,
): boolean {
  const provider = findProvider(store, providerID);
  if (!provider || !findModel(provider, modelID)) return false;
  writeModel(store, provider, modelID, (model) => (transport
    ? { ...model, relayTransport: transport, relayTransportSource: 'user' }
    : withoutTransport(model)), { reenrich: true });
  return true;
}

/** On / Off writes `{value, user}` and clears the negative cache of the same tier for the currently effective protocol; `null` (Auto) deletes the key (both user and tested). */
export function setRelayCapabilityOverride(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  key: RelayAdvancedCapabilityKey,
  value: boolean | null,
): boolean {
  const provider = findProvider(store, providerID);
  const target = findModel(provider, modelID);
  if (!provider || !target) return false;
  writeModel(store, provider, modelID, (model) => {
    const overrides: RelayCapabilityOverrides = { ...model.relayCapabilityOverrides };
    if (value === null) delete overrides[key];
    else overrides[key] = { value, source: 'user' };
    return withOverrides(model, overrides);
  });
  const kind = NEGATIVE_CACHE_KIND[key];
  if (value !== null && kind) {
    clearRelayNegativeCache(
      { connectionId: provider.id, modelId: modelID, transport: relayFirstSendTransport(provider, target) },
      [kind],
    );
  }
  return true;
}

/**
 * The reasoning level set can only narrow the automatic set: intersect with the automatic set first, write nothing if empty; delete the override if it equals the automatic set or is `null`.
 * Stores the raw contract values (ReasoningMode), in the order of the five slots.
 */
export function setRelayReasoningLevels(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  levels: readonly ReasoningMode[] | null,
): boolean {
  const provider = findProvider(store, providerID);
  const target = findModel(provider, modelID);
  if (!provider || !target) return false;
  const automatic = relayAutomaticReasoningLevels(provider, target);
  const kept = levels ? automatic.filter((level) => levels.includes(level)) : [];
  if (levels && kept.length === 0) return false;
  const clear = !levels || kept.length === automatic.length;
  writeModel(store, provider, modelID, (model) => {
    const overrides: RelayCapabilityOverrides = { ...model.relayCapabilityOverrides };
    if (clear) delete overrides.reasoningLevels;
    else overrides.reasoningLevels = { value: kept, source: 'user' };
    return withOverrides(model, overrides);
  });
  // Changing the level override is a fresh statement by the user: clear the level-rejection record of this model's current protocol.
  clearRelayReasoningTierRejections({ connectionId: provider.id, modelId: modelID, transport: relayFirstSendTransport(provider, target) });
  return true;
}

/** Whether any override or a user-sourced model-level protocol exists. */
export function canRestoreAllRelayAutomatic(model: Pick<AIModel, 'relayCapabilityOverrides' | 'relayTransportSource'>): boolean {
  return Object.keys(model.relayCapabilityOverrides ?? {}).length > 0 || model.relayTransportSource === 'user';
}

/** Restore all to auto: clears all overrides (user + tested) and user-sourced model-level protocols, but not the negative cache. Writes nothing if there is nothing to clear. */
export function restoreAllRelayAutomatic(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
): boolean {
  const provider = findProvider(store, providerID);
  const target = findModel(provider, modelID);
  if (!provider || !target || !canRestoreAllRelayAutomatic(target)) return false;
  const userTransport = target.relayTransportSource === 'user';
  writeModel(store, provider, modelID, (model) => {
    const cleared = withOverrides(model, undefined);
    return model.relayTransportSource === 'user' ? withoutTransport(cleared) : cleared;
  }, { reenrich: userTransport });
  return true;
}

/**
 * After manually choosing a protocol, run one existing per-model 1-token probe for that protocol: only returns the result and does not write model fields;
 * when a store is given, writes this request's verdict onto the effective key.
 * `null` = undecidable (connection not in probe scope / no root to hit / cancelled); the caller shows no result.
 */
export async function probeRelayModelTransportOnce(
  provider: Provider,
  modelID: string,
  transport: RelayModelTransport,
  deps: { ping?: RelayModelProbePing; signal?: AbortSignal; store?: StoreApi<AppStore> } = {},
): Promise<'reachable' | 'notReachable' | null> {
  if (!canProbeRelayModels(provider)) return null;
  let failure: { error: unknown; status?: number } | undefined;
  // This 1-token probe also writes the effective key's status; if the identity changed, the write-back is discarded. Written only when a store is given.
  const writeKeyStatus = (status: ReturnType<typeof relayPingKeyStatus>, httpStatus?: number) => {
    if (deps.store) recordRelayGenerationKeyStatus(deps.store, provider, { id: modelID }, status, httpStatus);
  };
  try {
    const pass = await probeRelayModelTransport({
      provider,
      modelID,
      candidates: [transport],
      ping: deps.ping,
      signal: deps.signal,
      onCandidateFailure: (_transport, error) => {
        const status = (error as { status?: unknown } | null)?.status;
        failure = { error, ...(typeof status === 'number' ? { status } : {}) };
      },
    });
    if (pass) {
      writeKeyStatus('ok');
      return 'reachable';
    }
  } catch {
    // Cancelled.
    return null;
  }
  if (!failure) return null;
  writeKeyStatus(relayPingKeyStatus({ ok: false, error: failure.error }), failure.status);
  return 'notReachable';
}

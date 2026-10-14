import { create, type StoreApi } from 'zustand';
import { useMemo } from 'react';
import type { AIModel, Provider } from '@oriveo/shared';
import { decidedTransport, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { withErrorReporting } from '../sentry/report-silent';
import { runRelayWebAutoProbeAfterEnable, type RelayWebAutoProbeDeps } from './relay-web-probe-auto';
import { getActiveUIDSync } from '../infra/storage/partition';
import { providerFormOf } from './capability/truth/provider-form';
import { enableProviderModel, enrichRelayProviderModels } from './provider-model-ops';
import { refreshRelayCatalogInStore, type RelayCatalogRefreshResult } from './providers/provider-sync';
import { findRelayModel } from './providers/relay-model-identity';
import { clearRelayNegativeCacheConnection } from './chat/relay-negative-cache';
import {
  probeRelayModelTransport,
  withRelayModelProbePass,
  type RelayModelProbePing,
} from './providers/relay-model-probe';
import { relayCatalogEndpointTypes, resolveRelayProbeCandidates } from './providers/relay-probe-candidates';
import { inspectLocalEngineDeclarationsInBrowser } from './providers/local-browser-probe';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { applyRelayKeyOp, relayEffectiveKeyID, relayKeySecret, type RelayKeyOp } from '@oriveo/shared/relay/relay-keys';
import { subscribeRelayKeyConfirmation, type RelayKeyConfirmationSignal } from './providers/relay-key-confirmation';
import { recordRelayGenerationKeyStatus } from './providers/relay-key-access-writeback';
import { relayPingKeyStatus } from './providers/ping-relay';
import {
  clearCapabilityRejectionsForConnection,
  clearToolCallMemoryForConnection,
} from './chat/capability-recovery-runtime';

/**
 * Lifecycle of Relay per-model probing: lazy verification on enable and re-detection.
 * The probe itself reuses `probeRelayModelTransport`; write-back reuses `withRelayModelProbePass`.
 */

export interface RelayModelProbeDeps {
  /** Defaults to the production `pingRelay`. */
  ping?: RelayModelProbePing;
  /** Defaults to the by-model view of metadata-client. */
  lookupFamily?: (modelID: string) => Promise<string | undefined>;
  /** Defaults to the production read-only declaration reader (re-reads engine declarations on re-detection without sending generation requests). */
  inspectLocalEngine?: typeof inspectLocalEngineDeclarationsInBrowser;
  /** Cancelled when leaving the detail page: after cancellation nothing is written back and no lazy-verification state is kept. */
  signal?: AbortSignal;
}

/* ── Lazy-verification state: in-memory for this session only, not persisted, not synced ─────────────── */
/* Cleared on: lazy verification success, rebind, re-detection; an effective-key value change (T1) / a successful send (T2) clears only "unreachable", not "verifying".
   Neither a successful catalog fetch nor a key status turning healthy clears it: a relay may gate only one protocol, so a healthy key != a usable model. */

export type RelayLazyProbeState =
  | { phase: 'inFlight' }
  /** No candidate passed: error = failure of the last candidate sent (existing error message), statusCode = upstream status code. */
  | { phase: 'failed'; error?: unknown; statusCode?: number };

type LazyProbeStates = Readonly<Record<string, Readonly<Record<string, RelayLazyProbeState>>>>;

const useLazyProbeStore = create<{ states: LazyProbeStates }>(() => ({ states: {} }));

function setLazyProbeState(providerID: string, modelID: string, state: RelayLazyProbeState | null): void {
  useLazyProbeStore.setState(({ states }) => {
    const current = { ...(states[providerID] ?? {}) };
    if (state) current[modelID] = state;
    else delete current[modelID];
    return { states: { ...states, [providerID]: current } };
  });
}

export function relayLazyProbeState(providerID: string, modelID: string): RelayLazyProbeState | undefined {
  return useLazyProbeStore.getState().states[providerID]?.[modelID];
}

/** Omitting modelID = clear everything for this connection (re-detection). */
export function clearRelayLazyProbeStates(providerID: string, modelID?: string): void {
  if (modelID !== undefined) {
    setLazyProbeState(providerID, modelID, null);
    return;
  }
  useLazyProbeStore.setState(({ states }) => {
    const next = { ...states };
    delete next[providerID];
    return { states: next };
  });
}

const EMPTY_LAZY_PROBE_STATES: Readonly<Record<string, RelayLazyProbeState>> = {};

/** For model library page subscriptions: get this connection's lazy-verification state by model id. */
export function useRelayLazyProbeStates(providerID: string): ReadonlyMap<string, RelayLazyProbeState> {
  const states = useLazyProbeStore((store) => store.states[providerID] ?? EMPTY_LAZY_PROBE_STATES);
  return useMemo(() => new Map(Object.entries(states)), [states]);
}

export function __setRelayLazyProbeStateForTest(providerID: string, modelID: string, state: RelayLazyProbeState | null): void {
  setLazyProbeState(providerID, modelID, state);
}

function findProvider(store: StoreApi<AppStore>, providerID: string): Provider | undefined {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, providerID));
}

/* ── Effective-key value change / successful send invalidates "unreachable" ─────────────── */

/** In-flight T1 re-probe sequences: one per trigger, not queued behind each other (a stuck one does not block other connections / other triggers). */
const lazyReprobes = new Set<Promise<void>>();

/** Clears only failed; lazy verifications in progress finish on their own. Returns the cleared model ids (in enable order). */
function clearFailedLazyProbeStates(providerID: string, modelIDs: readonly string[]): string[] {
  const states = useLazyProbeStore.getState().states[providerID] ?? {};
  const cleared = modelIDs.filter((modelID) => states[modelID]?.phase === 'failed');
  for (const modelID of cleared) setLazyProbeState(providerID, modelID, null);
  return cleared;
}

/** T1: the effective key is computed on the latest connection object; cleared models that still have no protocol are verified again through the same lazy-verification entry as enable, following the rebind precedent (in the background, one by one). */
function invalidateLazyProbesForReplacedKeys(store: StoreApi<AppStore>, providerID: string, keyIDs: readonly string[]): void {
  const latest = findProvider(store, providerID);
  if (!latest) return;
  const keys = new Set(keyIDs);
  const bound = latest.models.filter((model) => keys.has(relayEffectiveKeyID(latest, model.id))).map((model) => model.id);
  const cleared = clearFailedLazyProbeStates(latest.id, bound);
  if (cleared.length === 0) return;
  const run = (async () => {
    // Still probed one by one within the same trigger.
    for (const modelID of cleared) {
      await probeAndRecordRelayModel(store, latest.id, modelID, {}).catch((error: unknown) => {
        withErrorReporting('relay.key_replaced_model_probe')(error);
        return false;
      });
    }
  })();
  lazyReprobes.add(run);
  void run.finally(() => lazyReprobes.delete(run));
}

function onRelayKeyConfirmation(signal: RelayKeyConfirmationSignal): void {
  if (signal.type === 'modelDelivered') {
    // T2: clear only that model; do not launch lazy verification.
    clearFailedLazyProbeStates(signal.providerID, [signal.modelID]);
    return;
  }
  invalidateLazyProbesForReplacedKeys(signal.store, signal.providerID, signal.keyIDs);
}

subscribeRelayKeyConfirmation(onRelayKeyConfirmation);

/** For tests: wait for all background re-probes started by T1 to finish. */
export async function __relayLazyReprobesSettledForTest(): Promise<void> {
  while (lazyReprobes.size > 0) await Promise.all([...lazyReprobes]);
}

/** Per-model probing runs only for the user's own relay (Relay form) that is not a local engine. */
export function canProbeRelayModels(provider: Provider): boolean {
  return providerFormOf(provider) === 'relay'
    && Boolean(provider.relayRequested)
    && !provider.relayRequested?.engineProfile;
}

/**
 * If the connection is changed during probing (address / key / default protocol / auth / safe mode), this result is void and not written.
 * key is the effective key of the probed model; it excludes the names and statuses of the key list. Connection-level probes pass null (primary key).
 */
export function relayProbeConnectionIdentity(provider: Provider, modelID: string | null): string {
  return JSON.stringify({
    endpoint: provider.baseURLText,
    apiKey: resolveProviderAPIKey(provider, modelID),
    transport: effectiveTransport(provider, null),
    authMode: provider.relayRequested?.authMode,
    securityMode: provider.relayRequested?.securityMode,
  });
}

/**
 * Probes an enabled model that has no model-level protocol yet (from any source); writes back only on pass (reachable + that protocol root).
 * Writes no field when it does not pass. Returns whether anything was written back.
 * Not probed when the connection protocol was chosen by the user (not auto): such models always follow the connection, with no request, no field written and no lazy-verification state kept.
 */
async function probeAndRecordRelayModel(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  deps: RelayModelProbeDeps,
): Promise<boolean> {
  const provider = findProvider(store, providerID);
  if (!provider || !canProbeRelayModels(provider)) return false;
  const model = provider.models.find((item) => item.id === modelID);
  if (!model || model.relayTransport) return false;
  if (decidedTransport(provider, null)) return false;
  if (deps.signal?.aborted) return false;

  const inFlight: RelayLazyProbeState = { phase: 'inFlight' };
  setLazyProbeState(provider.id, modelID, inFlight);
  let lastFailure: { error: unknown; statusCode?: number } | undefined;
  let pass: Awaited<ReturnType<typeof probeRelayModelTransport>>;
  try {
    const candidates = await resolveRelayProbeCandidates({
      modelID,
      supportedEndpointTypes: relayCatalogEndpointTypes(provider.id, modelID),
      lookupFamily: deps.lookupFamily,
    });
    pass = await probeRelayModelTransport({
      provider,
      modelID,
      candidates,
      ping: deps.ping,
      signal: deps.signal,
      onCandidateFailure: (_transport, error) => {
        const status = (error as { status?: unknown } | null)?.status;
        lastFailure = { error, ...(typeof status === 'number' ? { statusCode: status } : {}) };
      },
    });
  } catch (error) {
    // Cancellation (leaving the detail page) does not count as unreachable; other exceptions are rethrown to the caller's error reporting as before.
    setLazyProbeState(provider.id, modelID, null);
    if (deps.signal?.aborted) return false;
    throw error;
  }
  // Verify the connection identity first: if the address / effective key value etc. changed during probing, this result (success or failure) is void and not recorded as unreachable.
  const latest = findProvider(store, providerID);
  if (!latest || relayProbeConnectionIdentity(latest, modelID) !== relayProbeConnectionIdentity(provider, modelID)) {
    // Only clear our own "verifying", without wiping a lazy verification started later.
    if (relayLazyProbeState(provider.id, modelID) === inFlight) setLazyProbeState(provider.id, modelID, null);
    return false;
  }
  // Nothing was actually sent (no usable candidate): does not count as unreachable.
  setLazyProbeState(provider.id, modelID, !pass && lastFailure ? { phase: 'failed', ...lastFailure } : null);
  // Key status: pass = healthy; on failure look at the last candidate sent (an invalid key / quota exhaustion stops the probe on it); otherwise leave it unchanged.
  if (pass || lastFailure) {
    recordRelayGenerationKeyStatus(
      store,
      provider,
      { id: modelID },
      relayPingKeyStatus(pass ? { ok: true } : { ok: false, error: lastFailure!.error }),
      lastFailure?.statusCode,
    );
  }
  if (!pass) return false;

  const latestModel = latest.models.find((item) => item.id === modelID);
  // The model was removed during probing or its protocol was already set by the user / another path: do not overwrite.
  if (!latestModel || latestModel.relayTransport) return false;

  const next = withRelayModelProbePass(latest, modelID, pass);
  // When the source changes, enrichment must be re-run (reachable does not inherit the native-file allowlist).
  const models = enrichRelayProviderModels(next, next.models);
  const updatedAt = new Date().toISOString();
  store.getState().updateProvider(latest.id, { models, relayRequested: next.relayRequested, updatedAt });
  return true;
}

/**
 * Enables a single model from the model library: enable first, probe afterwards; a probe failure neither reverts the enable nor blocks, and is not thrown to the caller.
 * Only the single-model enable action goes through here; enable-all / batch / undo-remove still use `enableProviderModel` etc. directly, without probing.
 * `onProbeSettled` is only for tests to observe the result.
 */
export function enableProviderModelWithProbe(
  store: StoreApi<AppStore>,
  provider: Provider,
  model: AIModel,
  deps: RelayModelProbeDeps & {
    onProbeSettled?: (recorded: boolean) => void;
    /** Dependencies for the automatic online probe after lazy verification passes. */
    webProbe?: RelayWebAutoProbeDeps;
  } = {},
): AIModel {
  const before = findProvider(store, provider.id) ?? provider;
  const wasEnabled = findRelayModel(before.models, model.id) !== undefined;
  const enabled = enableProviderModel(store, provider, model);
  if (wasEnabled || !canProbeRelayModels(before)) return enabled;
  void probeAndRecordRelayModel(store, before.id, enabled.id, deps)
    .catch((error: unknown) => {
      withErrorReporting('relay.enable_model_probe')(error);
      return false;
    })
    .then((recorded) => {
      // Only a lazy verification that actually ran and passed counts as one automatic online probe event; if it did not run / failed, no probe.
      if (recorded) runRelayWebAutoProbeAfterEnable(store, before.id, enabled.id, deps.webProbe);
      deps.onProbeSettled?.(recorded);
    });
  return enabled;
}

/**
 * Data-layer entry for relay key operations (called by the key management UI): the result of the pure operation,
 * after add all keys re-fetch the catalog, after replaceSecret only that one key is re-fetched (the other keys are skipped); after rebind, models without a protocol send a 1-token request through the same lazy verification as enable.
 * rename / move / delete only write the result. A rejection (deleting the last key, id not found, etc.) returns false and writes nothing.
 */
export async function applyRelayKeyOperation(
  store: StoreApi<AppStore>,
  provider: Provider,
  op: RelayKeyOp,
  deps: RelayModelProbeDeps = {},
): Promise<boolean> {
  const current = findProvider(store, provider.id);
  if (!current || providerFormOf(current) !== 'relay') return false;
  const next = applyRelayKeyOp(current, op);
  if (next === 'refused') return false;
  const updatedAt = new Date().toISOString();
  const patch = {
    apiKey: next.apiKey, // key-choke: stored-field
    apiKeyPreview: next.apiKeyPreview,
    ...(next.relayKeys ? { relayKeys: next.relayKeys } : {}),
    models: next.models,
    catalogModels: next.catalogModels,
    updatedAt,
  };
  store.getState().updateProvider(current.id, patch);

  if (op.type === 'add' || op.type === 'replaceSecret') {
    const saved = findProvider(store, current.id);
    // Value change: models whose effective key is this one have "unreachable" invalidated; only a non-empty new value that differs from the old counts, adding a key itself does not trigger.
    // Clear before refreshing the catalog: the value change takes effect at once and is not lost even if the refresh throws.
    const replacedSecret = op.type === 'replaceSecret' ? relayKeySecret(next, op.id) : undefined;
    if (replacedSecret?.trim() && replacedSecret !== relayKeySecret(current, op.id)) {
      invalidateLazyProbesForReplacedKeys(store, current.id, [op.id]);
    }
    // Adding a key -> re-fetch all keys (the primary key also gets status and listed entries); a value change re-fetches only that one key.
    if (saved) await refreshRelayCatalogInStore(store, saved, op.type === 'add' ? {} : { onlyKeyIDs: [op.id] });
  } else if (op.type === 'rebind') {
    // After a rebind the old "unreachable" no longer holds.
    clearRelayLazyProbeStates(current.id, op.modelID);
    await probeAndRecordRelayModel(store, current.id, op.modelID, deps).catch((error: unknown) => {
      withErrorReporting('relay.rebind_model_probe')(error);
      return false;
    });
  }
  return true;
}

function withoutReachableTransport(model: AIModel): AIModel {
  if (model.relayTransportSource !== 'reachable') return model;
  const next = { ...model };
  delete next.relayTransport;
  delete next.relayTransportSource;
  return next;
}

/**
 * Re-detection (called by the "Re-detect" button on the detail page): clears each model's reachable (protocol and source together), clears this connection's
 * capability-rejection cache and tool-call memory, refreshes the catalog; then in enable order re-probes all enabled models that have no model-level protocol after clearing
 * (a relay has no default model).
 * Does not touch user / observed / tested, does not delete enabled models, does not change the connection protocol. A catalog refresh failure does not block re-probing,
 * but the last-detection time is not written (the header records only measured facts). Returns the catalog refresh result, null = connection no longer exists.
 */
export async function redetectRelayModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  deps: RelayModelProbeDeps = {},
): Promise<RelayCatalogRefreshResult['state'] | null> {
  const current = findProvider(store, provider.id);
  if (!current || providerFormOf(current) !== 'relay') return null;

  clearCapabilityRejectionsForConnection(current.id);
  clearToolCallMemoryForConnection(getActiveUIDSync(), current.id);
  clearRelayNegativeCacheConnection(current.id);
  clearRelayLazyProbeStates(current.id);

  const cleared = current.models.map(withoutReachableTransport);
  if (cleared.some((model, index) => model !== current.models[index])) {
    store.getState().updateProvider(current.id, {
      models: enrichRelayProviderModels(current, cleared),
      updatedAt: new Date().toISOString(),
    });
  }

  const afterClear = findProvider(store, current.id);
  if (!afterClear) return null;
  const catalog = await refreshRelayCatalogInStore(store, afterClear);
  // Only a successful catalog refresh counts as detected (same as iOS / Android); skipped / failed writes no time.
  if (catalog.state === 'loaded') markRelayChecked(store, current.id);
  await refreshLocalEngineDeclarations(store, current.id, deps);

  const refreshed = findProvider(store, current.id);
  if (!refreshed) return catalog.state;
  // Protocols from user / observed / tested sources survive the clear, so probeAndRecordRelayModel skips them; when the user chose the connection protocol, all are skipped.
  const probeIDs = refreshed.models.filter((model) => !model.relayTransport).map((model) => model.id);
  for (const modelID of probeIDs) {
    if (deps.signal?.aborted) break;
    await probeAndRecordRelayModel(store, refreshed.id, modelID, deps);
  }
  return catalog.state;
}

function markRelayChecked(store: StoreApi<AppStore>, providerID: string): void {
  const latest = findProvider(store, providerID);
  if (!latest) return;
  const lastCheckedAt = new Date().toISOString();
  store.getState().updateProvider(latest.id, { lastCheckedAt });
}

/**
 * Local-connection re-detection: sends only read-only requests to re-read per-model declarations (no generation requests), replacing declarations in enabled models and the catalog by model id
 * (a declaration is replaced only if a new one was given this time; otherwise the old one is kept). Does not touch relayCapabilityOverrides and does not probe protocols.
 * The browser has no TOFU certificate channel, so tofu_https connections cannot read declarations and keep the old ones.
 */
async function refreshLocalEngineDeclarations(
  store: StoreApi<AppStore>,
  providerID: string,
  deps: RelayModelProbeDeps,
): Promise<void> {
  const provider = findProvider(store, providerID);
  const requested = provider?.relayRequested;
  const engine = requested?.engineProfile;
  if (!provider || !requested || !engine) return;
  const securityMode = requested.securityMode ?? 'remote_https';
  if (securityMode === 'tofu_https') return;
  const inspect = deps.inspectLocalEngine ?? inspectLocalEngineDeclarationsInBrowser;
  const inspected = await inspect({
    engine,
    endpoint: provider.baseURLText ?? '',
    securityMode,
    apiKey: resolveProviderAPIKey(provider),
  });
  const declared = new Map<string, NonNullable<AIModel['engineDeclaration']>>();
  for (const model of inspected) {
    if (model.engineDeclaration) declared.set(model.id, model.engineDeclaration);
  }
  if (declared.size === 0) return;

  const latest = findProvider(store, providerID);
  if (!latest || relayProbeConnectionIdentity(latest, null) !== relayProbeConnectionIdentity(provider, null)) return;
  const withDeclaration = (model: AIModel): AIModel => {
    const declaration = declared.get(model.id);
    return declaration ? { ...model, engineDeclaration: declaration } : model;
  };
  // Declarations stay on this device only (the sync mapping excludes them), so no sync push and no updatedAt change.
  store.getState().updateProvider(latest.id, {
    models: latest.models.map(withDeclaration),
    catalogModels: latest.catalogModels.map(withDeclaration),
  });
}

import { relayKeyIDs } from '@oriveo/shared/relay/relay-keys';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { useState, useCallback, useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import type { AIModel, Provider } from '@oriveo/shared';
import type { RelayVerificationKeyStatus } from '../core/providers/provider-sync';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as providerOps from '../core/provider-ops';
import {
  canRefreshRelayCatalog,
  planRelaySettingsSave,
  refreshRelayCatalogInStore,
  relayEndpointComparisonKey,
  relayKeysAfterVerification,
  resyncProviderInStore,
  verifyRelayProviderCandidate,
  verifyRelayProviderInStore,
} from '../core/providers/provider-sync';
import { selectResolvedCatalog } from '../core/store/selectors';
import {
  addManualProviderModels,
  disableProviderModel,
  replaceProviderModels,
} from '../core/provider-model-ops';
import { enableProviderModelWithProbe } from '../core/relay-model-probe-ops';
import { removeGenerationParameterScopes } from '../core/chat/generation-parameter-settings';
import { removeAdditionalBodyScopes } from '../core/chat/additional-body-settings';
import { deleteCapabilityPreferencesForModels } from '../core/chat/capability-preference-settings';
import type { RelayConnectionSecurityMode } from '@oriveo/shared';
import {
  hasRelayConnectedEvidence,
  probeRelayEndpoint,
  type RelayDiscoveryResult,
  type RelayProbeTransportKind,
} from '../core/providers/probe/probe-runner';
import { resolveRelayRuntimeFields } from '../core/providers/relay-resolution';
import type { RelayPingResult } from '../core/providers/ping-relay';
import { resolveRelayVerificationSampleModelID } from '../core/providers/provider-selection-snapshot';
import { PROVIDER_VALIDATION_MESSAGES } from '../core/providers/validation-messages';
import { findRelayModel, relayParameterKeysToRemoveOnDisable } from '../core/providers/relay-model-identity';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { relayShotSeed } from '../dev/relay-shots-mode';

export type RelayCatalogLoadState = 'idle' | 'loading' | 'loaded' | 'failed';

export interface RelaySettingsSaveFailure {
  error: unknown;
  phase: 'generation' | 'catalog';
  canSaveUnverified: boolean;
}

interface PendingRelaySettingsSave {
  patch: providerOps.RelaySettingsPatchSource;
  /** This failed verification: "save anyway" writes its key outcome to the key that was actually sent. */
  verified?: { candidate: Provider; keyStatus: RelayVerificationKeyStatus | undefined };
}

/**
 * Key status written together with the patch when an edit is committed: computed by merging the
 * patch into the live record at commit time; nothing is written when there is no verification
 * outcome. Clearing the status when the primary key's value changed is done by
 * updateProviderRelaySettings before the patch.
 */
function relayKeysForCommit(
  live: Provider,
  patch: providerOps.RelaySettingsPatch,
  verified: PendingRelaySettingsSave['verified'],
): Pick<Provider, 'relayKeys'> {
  if (!verified) return {};
  const relayKeys = relayKeysAfterVerification(
    providerOps.buildRelaySettingsCandidate(live, patch),
    verified.candidate,
    verified.keyStatus,
  );
  return relayKeys ? { relayKeys } : {};
}

/**
 * The connection inputs a verification used: normalized address, transport, auth mode, connection
 * security, key, headers, query params and User-Agent. If the candidate merged with the live record
 * at commit time differs in any of these from the one verified, that verification result does not count.
 */
function relayVerificationInputKey(candidate: Provider): string {
  const requested = candidate.relayRequested;
  return JSON.stringify({
    endpoint: relayEndpointComparisonKey(candidate.baseURLText, requested?.securityMode),
    transport: requested?.transport ?? null,
    authMode: requested?.authMode ?? null,
    securityMode: requested?.securityMode ?? null,
    apiKey: resolveProviderAPIKey(candidate),
    headers: requested?.headers ?? [],
    queryParams: requested?.queryParams ?? [],
    customUserAgent: requested?.customUserAgent ?? null,
  });
}

/**
 * Hook holding the action logic of the provider detail page.
 * save and delete are delegated to core/provider-ops; resync and model management stay in the
 * hook because they own useState.
 */
/**
 * Clears a model's parameter scopes after it is disabled. For relays, the literal key is deleted;
 * the canonical read-back key of generation parameters is deleted only when the connection has no
 * other enabled model that uses it as its canonical key. Capability preferences share one key set
 * with generation parameters (same as iOS `AppState.disableModel`). The additional request body
 * has always been stored under the literal key, so only the literal key is deleted.
 */
function removeDisabledModelParameterScopes(provider: Provider, providerId: string, model: AIModel): void {
  const remaining = provider.models.filter((item) => item !== model);
  const keys = provider.kind === 'relay' ? relayParameterKeysToRemoveOnDisable(remaining, model) : [model.id];
  removeModelScopes(providerId, keys, model.id);
}

function removeModelScopes(providerId: string, keys: readonly string[], literalModelId: string): void {
  for (const modelId of keys) removeGenerationParameterScopes({ providerId, modelId });
  deleteCapabilityPreferencesForModels(providerId, keys);
  removeAdditionalBodyScopes({ providerId, modelId: literalModelId });
}

export function useProviderActions(provider: Provider) {
  const router = useRouter();
  const providerId = provider.id;

  const [isSyncing, setIsSyncing] = useState(false);
  const [catalogLoadState, setCatalogLoadState] = useState<RelayCatalogLoadState>(
    provider.lastError === PROVIDER_VALIDATION_MESSAGES.catalogUnavailable
      ? 'failed'
      : provider.catalogModels.length > 0 ? 'loaded' : 'idle',
  );
  const [relaySettingsSaveFailure, setRelaySettingsSaveFailure] = useState<RelaySettingsSaveFailure | null>(null);
  const [pendingRelaySettingsSave, setPendingRelaySettingsSave] = useState<PendingRelaySettingsSave | null>(null);
  const reconnectGeneration = useRef(0);
  const reconnectController = useRef<AbortController | null>(null);
  const catalogRefreshGeneration = useRef(0);

  useEffect(() => () => {
    reconnectGeneration.current += 1;
    reconnectController.current?.abort();
    reconnectController.current = null;
  }, []);

  // Sample preset (dev builds only; always null in production): feed one save failure after a delay on entry.
  useEffect(() => {
    const seeded = relayShotSeed()?.detail?.settingsFailure;
    if (!seeded) return;
    const timer = setTimeout(() => setRelaySettingsSaveFailure(seeded.failure), seeded.delayMs);
    return () => clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (provider.lastError === PROVIDER_VALIDATION_MESSAGES.catalogUnavailable) {
      setCatalogLoadState('failed');
    } else if (provider.catalogModels.length > 0) {
      setCatalogLoadState('loaded');
    }
  }, [provider.catalogModels, provider.lastError]);

  const clearRelaySettingsSaveFailure = useCallback(() => {
    setRelaySettingsSaveFailure(null);
    setPendingRelaySettingsSave(null);
  }, []);

  const startRelayCatalogRefresh = useCallback((
    store: ReturnType<typeof getVanillaStore>,
    savedProvider: Provider,
    options?: { onlyKeyIDs?: readonly string[] },
  ) => {
    const generation = catalogRefreshGeneration.current + 1;
    catalogRefreshGeneration.current = generation;
    setCatalogLoadState('loading');
    void refreshRelayCatalogInStore(store, savedProvider, options).then((result) => {
      if (catalogRefreshGeneration.current !== generation) return;
      if (result.state === 'loaded' || result.state === 'skipped') setCatalogLoadState('loaded');
      if (result.state === 'failed') setCatalogLoadState('failed');
    });
  }, []);

  const saveKey = useCallback(async (newKey: string, normalizedBaseURL?: string) => {
    const store = getVanillaStore();
    const requestProvider = normalizedBaseURL && normalizedBaseURL !== (provider.baseURLText ?? '').trim()
      ? { ...provider, baseURLText: normalizedBaseURL }
      : provider;
    if (requestProvider !== provider) providerOps.updateProviderBaseURL(store, provider, normalizedBaseURL!);
    const keySaved = await providerOps.updateProviderKey(store, requestProvider, newKey);
    if (!keySaved) return;
    // After a key is written, the canonical provider has to be re-read from the store before
    // verifying: on web that yields the new key, on desktop a provider-id ref. The plaintext just
    // entered must never be spliced back into the verifier, or the verifier would hand plaintext
    // to the SyncAdapter when writing status and bypass the KeyVault boundary between the
    // renderer and the sync backend.
    const persistedProvider = store.getState().providers.find((item) => item.id === provider.id);
    if (!persistedProvider) return;
    // Official providers have no relayRequested, so relay verification throws
    // "Relay configuration is missing" before sending anything and it surfaces as an offline error.
    // They use their own three-state validation, which writes the outcome to status and never throws.
    if (persistedProvider.kind !== 'relay') {
      await resyncProviderInStore(store, persistedProvider);
      return;
    }
    const refreshCatalog = canRefreshRelayCatalog(persistedProvider.relayRequested);
    try {
      const result = await verifyRelayProviderInStore(store, persistedProvider);
      if (!result) return;
      clearRelaySettingsSaveFailure();
      if (refreshCatalog) {
        const verifiedProvider = store.getState().providers.find((item) => item.id === provider.id);
        if (verifiedProvider) {
          // A multi-key connection swapped the primary key's value: re-fetch only the primary key's catalog and mark the rest skipped. A single key takes the original path.
          const keyIDs = relayKeyIDs(verifiedProvider);
          startRelayCatalogRefresh(store, verifiedProvider, keyIDs.length > 1 ? { onlyKeyIDs: [keyIDs[0]!] } : undefined);
        }
      } else {
        setCatalogLoadState('idle');
      }
    } catch (error) {
      setCatalogLoadState('idle');
      setRelaySettingsSaveFailure({ error, phase: 'generation', canSaveUnverified: false });
      throw error;
    }
  }, [clearRelaySettingsSaveFailure, provider, startRelayCatalogRefresh]);

  const verifyRelayConnection = useCallback(async (
    candidate: Provider = provider,
  ) => {
    if (isSyncing) return null;
    setIsSyncing(true);
    try {
      return await verifyRelayProviderInStore(getVanillaStore(), candidate);
    } finally {
      setIsSyncing(false);
    }
  }, [isSyncing, provider]);

  /**
   * "Test connection" in the edit-connection page tests the draft: when the draft equals the saved
   * connection (persist), it verifies the saved connection and writes the result back to the
   * connection status; otherwise it only probes the candidate and the result never enters the
   * store. It does not take the write lock: the main button stays clickable while a test is in flight.
   */
  const testRelayDraft = useCallback(async (
    candidate: Provider,
    persist: boolean,
  ): Promise<RelayPingResult | null> => {
    const store = getVanillaStore();
    if (persist) return verifyRelayProviderInStore(store, candidate);
    const verification = await verifyRelayProviderCandidate(candidate, {
      lastUsedModelRef: store.getState().lastUsedModelRef,
    });
    if (!verification.ok) throw verification.error;
    return verification.result;
  }, []);

  /**
   * Removing the key only moves the credential state from S2 back to S1 and never implicitly
   * changes authMode - clearing a key is not the same as switching to "no authentication".
   * No resync follows: fetching the catalog right after deleting the key would always fail and
   * would only show the user a misleading error.
   */
  const removeKey = useCallback(async () => {
    await providerOps.updateProviderKey(getVanillaStore(), provider, '');
  }, [provider]);

  /** Way out of S3: keep the cleartext connection but clear authMode, the key and any sensitive header or query in one action. */
  const clearRelayCredentials = useCallback(async () => {
    await providerOps.clearRelayCredentials(getVanillaStore(), provider);
  }, [provider]);

  /** Only writes the normalized address back before sending; no resync is triggered, so this does not duplicate the caller's own probe. */
  const writeBackBaseURL = useCallback(async (newURL: string) => {
    providerOps.updateProviderBaseURL(getVanillaStore(), provider, newURL);
  }, [provider]);

  const saveName = useCallback((newName: string) => {
    providerOps.updateProviderName(getVanillaStore(), provider, newName);
  }, [provider]);

  const saveRelaySettings = useCallback(async (
    patch: providerOps.RelaySettingsPatchSource,
    options?: {
      /** The caller's draft changed while verification was in flight: this result is discarded as a whole, with no write-back and no failure card. */
      isStale?: () => boolean;
    },
  ): Promise<boolean> => {
    if (isSyncing) return false;
    const store = getVanillaStore();
    const liveProvider = () => store.getState().providers.find((item) => item.id === providerId);
    const canonical = liveProvider();
    if (!canonical) return false;
    const candidate = providerOps.buildRelaySettingsCandidate(canonical, providerOps.resolveRelaySettingsPatch(patch, canonical));
    const plan = planRelaySettingsSave(canonical, candidate);
    if (!plan.needsVerification) {
      const committed = await providerOps.updateProviderRelaySettings(store, canonical, patch);
      if (!committed) return false;
      clearRelaySettingsSaveFailure();
      return true;
    }

    setIsSyncing(true);
    try {
      // The connection was changed elsewhere during verification: if a verification-relevant field
      // the user did not edit changed, verify once more against the merged record; if the second
      // attempt collides again, commit the merge without writing verification status. If only
      // non-verification fields collided, commit the merge and write this result.
      let verifiedCandidate = candidate;
      let verification: Awaited<ReturnType<typeof verifyRelayProviderCandidate>> | null = null;
      for (let attempt = 0; attempt < 2; attempt += 1) {
        verification = await verifyRelayProviderCandidate(verifiedCandidate, {
          lastUsedModelRef: store.getState().lastUsedModelRef,
        });
        const live = liveProvider();
        if (!live) return false;
        if (options?.isStale?.()) return false;
        const merged = providerOps.buildRelaySettingsCandidate(live, providerOps.resolveRelaySettingsPatch(patch, live));
        if (relayVerificationInputKey(merged) === relayVerificationInputKey(verifiedCandidate)) break;
        verifiedCandidate = merged;
        verification = null;
      }

      const commitLive = liveProvider();
      if (!commitLive) return false;
      const commitPlan = planRelaySettingsSave(
        commitLive,
        providerOps.buildRelaySettingsCandidate(commitLive, providerOps.resolveRelaySettingsPatch(patch, commitLive)),
      );
      const shouldRefreshCatalog = commitPlan.needsCatalogRefresh
        && canRefreshRelayCatalog(verifiedCandidate.relayRequested);
      if (verification && !verification.ok) {
        setPendingRelaySettingsSave({
          patch,
          verified: { candidate: verifiedCandidate, keyStatus: verification.keyStatus },
        });
        setRelaySettingsSaveFailure({
          error: verification.error,
          phase: verification.phase,
          canSaveUnverified: true,
        });
        return false;
      }

      const now = new Date().toISOString();
      const committed = await providerOps.updateProviderRelaySettings(store, commitLive, (live) => {
        const resolved = providerOps.resolveRelaySettingsPatch(patch, live);
        return {
          ...resolved,
          ...(shouldRefreshCatalog ? { catalogModels: [] } : {}),
          ...(verification
            ? { status: { kind: 'connected' as const }, lastCheckedAt: now, lastError: undefined }
            : {}),
          // When the second attempt collides again (verification = null), neither the verification status nor the key status is written.
          ...relayKeysForCommit(live, resolved, verification
            ? { candidate: verifiedCandidate, keyStatus: verification.keyStatus }
            : undefined),
        };
      });
      if (!committed) return false;
      clearRelaySettingsSaveFailure();
      if (shouldRefreshCatalog) {
        const savedProvider = liveProvider();
        if (savedProvider) startRelayCatalogRefresh(store, savedProvider);
      }
      return true;
    } finally {
      setIsSyncing(false);
    }
  }, [clearRelaySettingsSaveFailure, isSyncing, providerId, startRelayCatalogRefresh]);

  const relaySettingsSavePlan = useCallback((patch: providerOps.RelaySettingsPatch) => (
    planRelaySettingsSave(provider, providerOps.buildRelaySettingsCandidate(provider, patch))
  ), [provider]);

  const saveBaseURL = useCallback(async (newURL: string): Promise<boolean> => {
    const requested = provider.relayRequested;
    // Official providers have no relay request to re-plan: switching between a vendor's published
    // endpoints is just a write. Going through saveRelaySettings would find nothing to verify and
    // the chosen endpoint would be dropped without a word.
    if (!requested) {
      providerOps.updateProviderBaseURL(getVanillaStore(), provider, newURL);
      return true;
    }
    const relayRequested = { ...requested, resolvedAPIBaseURL: undefined };
    const runtime = resolveRelayRuntimeFields({ baseURLText: newURL, relayRequested });
    return saveRelaySettings({
      baseURLText: newURL.trim() || undefined,
      relayKind: provider.relayKind,
      relayRequested,
      ...runtime,
    });
  }, [provider, saveRelaySettings]);

  const saveRelaySettingsUnverified = useCallback(async (): Promise<boolean> => {
    if (!pendingRelaySettingsSave || isSyncing) return false;
    const store = getVanillaStore();
    const canonical = store.getState().providers.find((item) => item.id === providerId);
    if (!canonical) {
      clearRelaySettingsSaveFailure();
      return false;
    }
    // "Save anyway (unverified)" is likewise merged field by field into the live record and is not invalidated because something else changed it.
    const { patch, verified } = pendingRelaySettingsSave;
    const candidate = providerOps.buildRelaySettingsCandidate(canonical, providerOps.resolveRelaySettingsPatch(patch, canonical));
    const shouldRefreshCatalog = planRelaySettingsSave(canonical, candidate).needsCatalogRefresh
      && canRefreshRelayCatalog(candidate.relayRequested);
    setIsSyncing(true);
    try {
      const committed = await providerOps.updateProviderRelaySettings(store, canonical, (live) => {
        const resolved = providerOps.resolveRelaySettingsPatch(patch, live);
        return {
          ...resolved,
          ...(shouldRefreshCatalog ? { catalogModels: [] } : {}),
          status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
          lastCheckedAt: undefined,
          lastError: PROVIDER_VALIDATION_MESSAGES.unverified,
          ...relayKeysForCommit(live, resolved, verified),
        };
      });
      if (!committed) return false;
      clearRelaySettingsSaveFailure();
      if (shouldRefreshCatalog) {
        const savedProvider = store.getState().providers.find((item) => item.id === providerId);
        if (savedProvider) startRelayCatalogRefresh(store, savedProvider);
      }
      return true;
    } catch {
      return false;
    } finally {
      setIsSyncing(false);
    }
  }, [clearRelaySettingsSaveFailure, isSyncing, pendingRelaySettingsSave, providerId, startRelayCatalogRefresh]);

  const retryRelaySettingsSave = useCallback(async (): Promise<boolean> => {
    const store = getVanillaStore();
    const canonical = store.getState().providers.find((item) => item.id === providerId);
    if (pendingRelaySettingsSave) {
      if (!canonical) {
        clearRelaySettingsSaveFailure();
        return false;
      }
      const pending = pendingRelaySettingsSave;
      setPendingRelaySettingsSave(null);
      return saveRelaySettings(pending.patch);
    }
    if (!canonical || relaySettingsSaveFailure?.phase !== 'generation') return false;
    setIsSyncing(true);
    try {
      const result = await verifyRelayProviderInStore(store, canonical);
      if (!result) return false;
      clearRelaySettingsSaveFailure();
      if (canRefreshRelayCatalog(canonical.relayRequested)) {
        const verifiedProvider = store.getState().providers.find((item) => item.id === providerId);
        if (verifiedProvider) startRelayCatalogRefresh(store, verifiedProvider);
      } else {
        setCatalogLoadState('idle');
      }
      return true;
    } catch (error) {
      setRelaySettingsSaveFailure({ error, phase: 'generation', canSaveUnverified: false });
      return false;
    } finally {
      setIsSyncing(false);
    }
  }, [
    clearRelaySettingsSaveFailure,
    pendingRelaySettingsSave,
    providerId,
    relaySettingsSaveFailure?.phase,
    saveRelaySettings,
    startRelayCatalogRefresh,
  ]);

  const refreshRelayCatalog = useCallback(async (): Promise<boolean> => {
    if (isSyncing || !canRefreshRelayCatalog(provider.relayRequested)) return false;
    setIsSyncing(true);
    setCatalogLoadState('loading');
    try {
      const result = await refreshRelayCatalogInStore(getVanillaStore(), provider);
      if (result.state === 'loaded' || result.state === 'skipped') {
        setCatalogLoadState('loaded');
        return true;
      }
      if (result.state === 'failed') setCatalogLoadState('failed');
      return false;
    } finally {
      setIsSyncing(false);
    }
  }, [isSyncing, provider]);

  const reconnectRelaySecurityMode = useCallback(async (input: {
    securityMode: Exclude<RelayConnectionSecurityMode, 'tofu_https'>;
    normalizedEndpoint: string;
    unverifiedMessage: string;
    modelID: string;
    requested?: Provider['relayRequested'];
  }): Promise<RelayDiscoveryResult | null> => {
    const generation = reconnectGeneration.current + 1;
    reconnectGeneration.current = generation;
    reconnectController.current?.abort();
    const controller = new AbortController();
    reconnectController.current = controller;
    setIsSyncing(true);
    const store = getVanillaStore();
    let unsubscribe: (() => void) | undefined;
    let catalogStateSettled = false;
    try {
      const isCurrent = () => reconnectGeneration.current === generation && !controller.signal.aborted;
      const pending = await providerOps.beginRelaySecurityModeReconnect(store, provider, {
        ...input,
        shouldCommit: isCurrent,
      });
      if (!pending || !isCurrent()) return null;
      setCatalogLoadState('loading');
      // After begin, any write to the same provider replaces the object reference. Cancel the old
      // probe immediately so the user's key is not spent needlessly; finish also runs an identity
      // commit guard that closes the race window between subscribing and committing.
      unsubscribe = store.subscribe((state) => {
        if (state.providers.find((item) => item.id === pending.id) !== pending) controller.abort();
      });
      const requested = pending.relayRequested!;
      // The reconnect probe only looks at the connection-default transport; `auto` is not forced and is left to the probe to choose.
      const connectionTransport = decidedTransport(pending, null);
      const forcedTransport: RelayProbeTransportKind | undefined =
        connectionTransport === 'llamacpp_native' ? 'openai_chat_completions' : connectionTransport;
      // Verification sample = fallback model, then the first catalog entry; relayRequested.modelID is no longer read.
      const modelHint = input.modelID
        || resolveRelayVerificationSampleModelID(pending, store.getState().lastUsedModelRef)
        || undefined;
      const result = await probeRelayEndpoint({
        endpoint: input.normalizedEndpoint,
        apiKey: resolveProviderAPIKey(pending, modelHint || null),
        modelHint,
        forcedTransport,
        securityMode: input.securityMode,
        authMode: requested.authMode === 'auto' ? undefined : requested.authMode,
        headers: requested.headers,
        queryParams: requested.queryParams,
        signal: controller.signal,
      });
      if (!isCurrent()) return null;
      if (result.state === 'verified' && hasRelayConnectedEvidence(result.detection)) {
        unsubscribe();
        unsubscribe = undefined;
        if (!providerOps.finishRelaySecurityModeReconnect(store, pending, result.detection)) return null;
        setCatalogLoadState('loaded');
        catalogStateSettled = true;
        clearRelaySettingsSaveFailure();
      } else {
        setCatalogLoadState('failed');
        catalogStateSettled = true;
      }
      return result;
    } catch (error) {
      if (controller.signal.aborted || (error instanceof Error && error.name === 'AbortError')) return null;
      throw error;
    } finally {
      unsubscribe?.();
      if (reconnectGeneration.current === generation) {
        if (!catalogStateSettled) {
          const current = store.getState().providers.find((item) => item.id === providerId);
          setCatalogLoadState(current?.catalogModels.length ? 'loaded' : 'idle');
        }
        reconnectController.current = null;
        setIsSyncing(false);
      }
    }
  }, [clearRelaySettingsSaveFailure, provider, providerId]);

  const resync = useCallback(async () => {
    if (isSyncing) return;
    setIsSyncing(true);

    try {
      await resyncProviderInStore(getVanillaStore(), provider);
    } catch {
      // resync has already written the resulting state back to provider.status (Issue or
      // Connected) and the UI follows that naturally; this catch only keeps an unhandled
      // rejection from reaching the React error boundary
    } finally {
      setIsSyncing(false);
    }
  }, [provider, isSyncing]);

  const toggleModel = useCallback((model: AIModel) => {
    const enabledModel = provider.kind === 'relay'
      ? findRelayModel(provider.models, model.id)
      : provider.models.find((m) => m.id === model.id);
    if (enabledModel) {
      if (!disableProviderModel(getVanillaStore(), provider, enabledModel.id)) return;
      removeDisabledModelParameterScopes(provider, providerId, enabledModel);
      return;
    }

    // Enabling a single model from the model library: relay connections also lazily verify its protocol; bulk enabling does not come through here.
    enableProviderModelWithProbe(getVanillaStore(), provider, model);
  }, [provider, providerId]);

  const enableAllModels = useCallback(() => {
    // Use the resolved catalog to get every available model
    const resolved = selectResolvedCatalog(provider);
    replaceProviderModels(getVanillaStore(), provider, resolved.catalog);
  }, [provider]);

  const disableAllModels = useCallback(() => {
    provider.models.forEach((model) => {
      const keys = provider.kind === 'relay' ? relayParameterKeysToRemoveOnDisable([], model) : [model.id];
      removeModelScopes(providerId, keys, model.id);
    });
    replaceProviderModels(getVanillaStore(), provider, []);
  }, [provider, providerId]);

  const addModels = useCallback((newModelIds: string[]) => {
    addManualProviderModels(getVanillaStore(), provider, newModelIds);
  }, [provider]);

  /** Rejected (returns false) when a relay has only one model left; parameter scopes are left untouched. */
  const removeModel = useCallback((modelId: string): boolean => {
    const enabledModel = provider.kind === 'relay' ? findRelayModel(provider.models, modelId) : undefined;
    if (!disableProviderModel(getVanillaStore(), provider, modelId)) return false;
    if (enabledModel) {
      removeDisabledModelParameterScopes(provider, providerId, enabledModel);
    } else {
      removeModelScopes(providerId, [modelId], modelId);
    }
    return true;
  }, [provider, providerId]);

  const deleteProvider = useCallback(async () => {
    const didDelete = await providerOps.deleteProvider(getVanillaStore(), providerId);
    if (didDelete) router.push('/providers');
  }, [providerId, router]);

  return {
    isSyncing,
    catalogLoadState,
    relaySettingsSaveFailure,
    saveKey,
    removeKey,
    clearRelayCredentials,
    saveBaseURL,
    writeBackBaseURL,
    saveName,
    saveRelaySettings,
    relaySettingsSavePlan,
    saveRelaySettingsUnverified,
    retryRelaySettingsSave,
    clearRelaySettingsSaveFailure,
    refreshRelayCatalog,
    reconnectRelaySecurityMode,
    verifyRelayConnection,
    testRelayDraft,
    resync,
    toggleModel,
    enableAllModels,
    disableAllModels,
    addModels,
    removeModel,
    deleteProvider,
  };
}

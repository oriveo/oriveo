import { useState, useCallback, useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import type { AIModel, Provider } from '@oriveo/shared';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as providerOps from '../core/provider-ops';
import {
  canRefreshRelayCatalog,
  planRelaySettingsSave,
  refreshRelayCatalogInStore,
  resyncProviderInStore,
  verifyRelayProviderCandidate,
  verifyRelayProviderInStore,
} from '../core/providers/provider-sync';
import { selectResolvedCatalog } from '../core/store/selectors';
import {
  addManualProviderModels,
  disableProviderModel,
  enableProviderModel,
  replaceProviderModels,
} from '../core/provider-model-ops';
import { removeGenerationParameterScopes } from '../core/chat/generation-parameter-settings';
import type { RelayConnectionSecurityMode } from '@oriveo/shared';
import {
  hasRelayConnectedEvidence,
  probeRelayEndpoint,
  type RelayDiscoveryResult,
  type RelayProbeTransportKind,
} from '../core/providers/probe/probe-runner';
import { resolveRelayRuntimeFields } from '../core/providers/relay-resolution';
import { PROVIDER_VALIDATION_MESSAGES } from '../core/providers/validation-messages';

export type RelayCatalogLoadState = 'idle' | 'loading' | 'loaded' | 'failed';

export interface RelaySettingsSaveFailure {
  error: unknown;
  phase: 'generation' | 'catalog';
  canSaveUnverified: boolean;
}

interface PendingRelaySettingsSave {
  patch: providerOps.RelaySettingsPatch;
  shouldRefreshCatalog: boolean;
  providerSnapshot: Provider;
}

/**
 * Hook holding the action logic of the provider detail page.
 * save and delete are delegated to core/provider-ops; resync and model management stay in the
 * hook because they own useState.
 */
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
  ) => {
    const generation = catalogRefreshGeneration.current + 1;
    catalogRefreshGeneration.current = generation;
    setCatalogLoadState('loading');
    void refreshRelayCatalogInStore(store, savedProvider).then((result) => {
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
    const refreshCatalog = canRefreshRelayCatalog(persistedProvider.relayRequested);
    try {
      const result = await verifyRelayProviderInStore(store, persistedProvider);
      if (!result) return;
      clearRelaySettingsSaveFailure();
      if (refreshCatalog) {
        const verifiedProvider = store.getState().providers.find((item) => item.id === provider.id);
        if (verifiedProvider) startRelayCatalogRefresh(store, verifiedProvider);
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
    patch: providerOps.RelaySettingsPatch,
  ): Promise<boolean> => {
    if (isSyncing) return false;
    const store = getVanillaStore();
    const canonical = store.getState().providers.find((item) => item.id === providerId);
    if (!canonical) return false;
    const candidate = providerOps.buildRelaySettingsCandidate(canonical, patch);
    const plan = planRelaySettingsSave(canonical, candidate);
    if (!plan.needsVerification) {
      const committed = await providerOps.updateProviderRelaySettings(store, canonical, patch);
      if (!committed) return false;
      clearRelaySettingsSaveFailure();
      return true;
    }

    const shouldRefreshCatalog = plan.needsCatalogRefresh
      && canRefreshRelayCatalog(candidate.relayRequested);
    setIsSyncing(true);
    try {
      const verification = await verifyRelayProviderCandidate(candidate);
      if (store.getState().providers.find((item) => item.id === providerId) !== canonical) return false;
      if (!verification.ok) {
        setPendingRelaySettingsSave({ patch, shouldRefreshCatalog, providerSnapshot: canonical });
        setRelaySettingsSaveFailure({
          error: verification.error,
          phase: verification.phase,
          canSaveUnverified: true,
        });
        return false;
      }

      const now = new Date().toISOString();
      const committed = await providerOps.updateProviderRelaySettings(store, canonical, {
        ...patch,
        ...(shouldRefreshCatalog ? { catalogModels: [] } : {}),
        status: { kind: 'connected' },
        lastCheckedAt: now,
        lastError: undefined,
      });
      if (!committed) return false;
      clearRelaySettingsSaveFailure();
      if (shouldRefreshCatalog) {
        const savedProvider = store.getState().providers.find((item) => item.id === providerId);
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
    if (!canonical || canonical !== pendingRelaySettingsSave.providerSnapshot) {
      clearRelaySettingsSaveFailure();
      return false;
    }
    setIsSyncing(true);
    try {
      const committed = await providerOps.updateProviderRelaySettings(store, canonical, {
        ...pendingRelaySettingsSave.patch,
        ...(pendingRelaySettingsSave.shouldRefreshCatalog ? { catalogModels: [] } : {}),
        status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
        lastCheckedAt: undefined,
        lastError: PROVIDER_VALIDATION_MESSAGES.unverified,
      });
      if (!committed) return false;
      clearRelaySettingsSaveFailure();
      if (pendingRelaySettingsSave.shouldRefreshCatalog) {
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
      if (!canonical || canonical !== pendingRelaySettingsSave.providerSnapshot) {
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
      const forcedTransport: RelayProbeTransportKind | undefined =
        requested.transport === 'auto' ? undefined
        : requested.transport === 'llamacpp_native' ? 'openai_chat_completions'
        : requested.transport;
      const result = await probeRelayEndpoint({
        endpoint: input.normalizedEndpoint,
        apiKey: pending.apiKey,
        modelHint: input.modelID || requested.modelID,
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
    const isEnabled = provider.models.some((m) => m.id === model.id);
    if (isEnabled) {
      disableProviderModel(getVanillaStore(), provider, model.id);
      removeGenerationParameterScopes({ providerId, modelId: model.id });
      return;
    }

    enableProviderModel(getVanillaStore(), provider, model);
  }, [provider, providerId]);

  const enableAllModels = useCallback(() => {
    // Use the resolved catalog to get every available model
    const resolved = selectResolvedCatalog(provider);
    replaceProviderModels(getVanillaStore(), provider, resolved.catalog);
  }, [provider]);

  const disableAllModels = useCallback(() => {
    provider.models.forEach((model) => removeGenerationParameterScopes({ providerId, modelId: model.id }));
    replaceProviderModels(getVanillaStore(), provider, []);
  }, [provider, providerId]);

  const addModels = useCallback((newModelIds: string[]) => {
    addManualProviderModels(getVanillaStore(), provider, newModelIds);
  }, [provider]);

  const removeModel = useCallback((modelId: string) => {
    disableProviderModel(getVanillaStore(), provider, modelId);
    removeGenerationParameterScopes({ providerId, modelId });
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
    resync,
    toggleModel,
    enableAllModels,
    disableAllModels,
    addModels,
    removeModel,
    deleteProvider,
  };
}

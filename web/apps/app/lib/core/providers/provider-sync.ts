import type { StoreApi } from 'zustand';
import type { LastUsedModelRef, Provider, RelayRequestedConfig } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { getMetadataSnapshot, getRelayRuntimeConfig, refreshMetadata } from '../metadata/metadata-client';
import { getSyncAdapter } from '../sync-port';
import { networkError, toProviderError as httpToProviderError, type ProviderError } from './errors';
import { validateOfficialProviderKey, type KeyValidationResult } from './service';
import type { CatalogMetadataInput } from './catalog-resolver';
import { buildOfficialEnabledModels } from './official-model-sync';
import { buildRelayEndpointURL } from './relay-endpoints';
import { catalogAPIRoot } from './probe/endpoint-normalizer';
import { buildRecommendedModels } from './catalog-model';
import { buildModelsFromCatalog, compareCatalogModels, type RemoteModel } from './adapters/openai-compatible';
import { enrichRelayModelsByTransport, resolveRelayVerificationSampleModelID } from './provider-selection-snapshot';
import { buildDirectAuthHeaders } from '@oriveo/core/providers/relay-adapter';
import { buildBrowserRelayFetchArgs, fetchBrowserRelayDirect } from './relay-browser-direct';
import { pingRelay, relayPingKeyStatus, type RelayPingResult } from './ping-relay';
import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';
import { relaySensitiveCredentialValues } from '@oriveo/core/providers/relay-runtime-support';
import {
  relayEffectiveKeyID,
  relayKeyIDs,
  relayKeyList,
  relayKeySecret,
  relayKeySecrets,
} from '@oriveo/shared/relay/relay-keys';
import type { RelayGenerationKeyStatus } from '@oriveo/core/providers/relay-key-access';
import { relayKeyGoesOut, relayKeysWithStatus } from './relay-key-access-writeback';
import {
  mergeRelayKeyCatalogs,
  relayKeyCatalogFailureStatus,
  type RelayKeyCatalogResult,
  type RelayKeyCatalogStatus,
} from '@oriveo/core/providers/relay-key-catalog';
import {
  fetchGrokSubscriptionModels,
  prepareGrokSubscriptionRequest,
  refreshMetadataOnClientVersionRejected,
} from './grok-subscription';
import { buildGrokSubscriptionModels } from './grok-subscription-catalog';
import { grokSubscriptionErrorToValidationMessage } from './grok-subscription';
import { persistGrokSubscriptionCredential, persistOpenAISubscriptionCredential } from '../provider-ops';
import {
  fetchOpenAISubscriptionModels,
  prepareOpenAISubscriptionRequest,
  refreshMetadataOnCodexClientVersionRejected,
} from './openai-subscription';
import { buildOpenAISubscriptionModels } from './openai-subscription-catalog';
import { openAISubscriptionErrorToValidationMessage } from './openai-subscription';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { clearToolCallMemoryForConnection } from '../chat/capability-recovery-runtime';
import { catalogEntryEndpointTypes, rememberRelayCatalogEndpointTypes } from './relay-probe-candidates';
import { withPreviousEngineDeclarations, withRelayModelLocalFields } from './relay-model-probe';
import { requestBaseURLText } from './endpoint-source';
import { findRelayModel } from './relay-model-identity';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';


const EXCLUDED_RELAY_MODEL_PREFIXES = [
  'whisper', 'tts', 'text-embedding', 'text-search',
  'text-similarity', 'code-search', 'babbage', 'davinci',
  'curie', 'ada', 'text-davinci', 'text-curie', 'text-babbage',
  'text-ada', 'moderation', 'canary',
];

export interface RelaySettingsSavePlan {
  needsVerification: boolean;
  needsCatalogRefresh: boolean;
}

/**
 * Key verdict when the 1-token generation request actually went out: sample model + verdict
 * (null = leave the status alone) + HTTP status. Candidate verification itself never writes;
 * only the verification of an already-persisted connection is written by the caller onto the
 * sample model's effective key, and a draft connection test writes nothing.
 */
export interface RelayVerificationKeyStatus {
  modelID: string;
  status: RelayGenerationKeyStatus | null;
  httpStatus?: number;
}

export type RelayCandidateVerification =
  | {
      ok: true;
      result: RelayPingResult;
      models: Provider['models'];
      catalogModels: Provider['catalogModels'];
      catalogRefreshed: boolean;
      /** Per-key statuses after fetching the catalog key by key (two or more keys); absent for one key. The caller persists them along with the catalog. */
      relayKeys?: Provider['relayKeys'];
      keyStatus: RelayVerificationKeyStatus;
    }
  | {
      ok: false;
      phase: 'generation' | 'catalog';
      error: unknown;
      /** Per-key statuses when every per-key catalog fetch failed: the caller persists them first, then handles it like a single-key failure. */
      relayKeys?: Provider['relayKeys'];
      keyStatus?: RelayVerificationKeyStatus;
    };

export type RelayCatalogRefreshResult =
  | { state: 'loaded'; catalogModels: Provider['catalogModels'] }
  | { state: 'failed'; error: unknown }
  | { state: 'skipped'; catalogModels: Provider['catalogModels'] }
  | { state: 'stale' };

/**
 * Comparison key for "did the address change": trim whitespace and trailing slashes, and when the
 * scheme is missing add one according to the connection's security mode (http for cleartext modes,
 * https otherwise); an explicit scheme is kept, so swapping http and https counts as a change.
 */
export function relayEndpointComparisonKey(
  endpoint: string | null | undefined,
  securityMode?: RelayRequestedConfig['securityMode'],
): string {
  const trimmed = (endpoint ?? '').trim().replace(/\/+$/, '');
  if (!trimmed) return '';
  const scheme = /^([a-z][a-z0-9+.-]*):\/\//i.exec(trimmed);
  if (scheme) return `${scheme[1]!.toLowerCase()}${trimmed.slice(scheme[1]!.length)}`;
  const cleartext = securityMode === 'local_http' || securityMode === 'private_vpn';
  return `${cleartext ? 'http' : 'https'}://${trimmed}`;
}

/**
 * Explicit allowlist: only a change to connection identity fields triggers re-verification.
 * Adding UA/header/query/reasoning fields to the request builder later must not widen that set
 * automatically. Name, default model and display-only fields cause no network traffic.
 * relayKind is not part of the identity: it is a display value derived from the default protocol
 * at save time and is never read on the outbound path.
 */
export function planRelaySettingsSave(
  current: Provider,
  candidate: Provider,
): RelaySettingsSavePlan {
  const currentProjection = relayConnectionIdentityProjection(current);
  const candidateProjection = relayConnectionIdentityProjection(candidate);
  const needsVerification = currentProjection !== candidateProjection;

  const currentRequested = current.relayRequested;
  const candidateRequested = candidate.relayRequested;
  const needsCatalogRefresh = JSON.stringify({
    endpoint: relayEndpointComparisonKey(current.baseURLText, currentRequested?.securityMode),
    apiKey: resolveProviderAPIKey(current),
    transport: currentRequested?.transport,
    authMode: currentRequested?.authMode,
  }) !== JSON.stringify({
    endpoint: relayEndpointComparisonKey(candidate.baseURLText, candidateRequested?.securityMode),
    apiKey: resolveProviderAPIKey(candidate),
    transport: candidateRequested?.transport,
    authMode: candidateRequested?.authMode,
  });

  return { needsVerification, needsCatalogRefresh };
}

function relayConnectionIdentityProjection(provider: Provider): string {
  return JSON.stringify({
    endpoint: relayEndpointComparisonKey(provider.baseURLText, provider.relayRequested?.securityMode),
    transport: provider.relayRequested?.transport,
    authMode: provider.relayRequested?.authMode,
    securityMode: provider.relayRequested?.securityMode,
    apiKey: resolveProviderAPIKey(provider),
  });
}

/**
 * Single verification entry for a candidate: testing a saved connection and "verify and save" in the editor both go through it.
 * Verification sample = fallback model, then the first catalog model; with neither, no request is sent and it returns as a verification failure.
 */
export async function verifyRelayProviderCandidate(
  provider: Provider,
  options: { refreshCatalog?: boolean; lastUsedModelRef?: LastUsedModelRef | null } = {},
): Promise<RelayCandidateVerification> {
  assertRelayProvider(provider, 'verifyRelayProviderCandidate');
  let result: RelayPingResult;
  let validationModelID: string | null | undefined;
  try {
    const requested = provider.relayRequested;
    if (!requested) throw networkError('Relay configuration is missing.');
    validationModelID = resolveRelayVerificationSampleModelID(provider, options.lastUsedModelRef);
    if (!validationModelID) throw networkError('No model to verify this relay with.');
    result = await pingRelay({
      baseURL: provider.baseURLText ?? '',
      apiKey: resolveProviderAPIKey(provider, validationModelID),
      modelID: validationModelID,
      relayRequested: requested,
      relayKind: provider.relayKind,
      model: provider.models.find((model) => model.id === validationModelID),
      connectionKeySecrets: relayKeySecrets(provider),
    });
  } catch (error) {
    const httpStatus = (error as { status?: unknown } | null)?.status;
    return {
      ok: false,
      phase: 'generation',
      error,
      ...(validationModelID
        ? { keyStatus: {
            modelID: validationModelID,
            status: relayPingKeyStatus({ ok: false, error }),
            ...(typeof httpStatus === 'number' ? { httpStatus } : {}),
          } }
        : {}),
    };
  }
  // The ping succeeded, so the sample model is necessarily settled.
  const keyStatus: RelayVerificationKeyStatus = { modelID: validationModelID as string, status: relayPingKeyStatus({ ok: true }) };

  let models = provider.models;
  let catalogModels = provider.catalogModels;
  let catalogRefreshed = false;
  let relayKeys: Provider['relayKeys'];
  if (options.refreshCatalog && canRefreshRelayCatalog(provider.relayRequested)) {
    try {
      if (relayKeyIDs(provider).length > 1) {
        // Two or more keys fetch key by key; if none succeeds it is a catalog failure, with each key's status carried back.
        const catalog = await syncRelayModelsPerKey(provider);
        if (catalog.error !== undefined) {
          return { ok: false, phase: 'catalog', error: catalog.error, relayKeys: catalog.relayKeys, keyStatus };
        }
        models = mergeRelayEnabledModels(provider.models, catalog.catalogModels);
        catalogModels = catalog.catalogModels;
        relayKeys = catalog.relayKeys;
      } else {
        const catalog = await syncRelayModelsDirect(provider);
        models = mergeRelayEnabledModels(provider.models, catalog.models);
        catalogModels = catalog.models;
      }
      catalogRefreshed = true;
    } catch (error) {
      return { ok: false, phase: 'catalog', error, keyStatus };
    }
  }

  return { ok: true, result, models, catalogModels, catalogRefreshed, ...(relayKeys ? { relayKeys } : {}), keyStatus };
}

/**
 * Write the verification verdict of an already-persisted connection onto the sample model's effective key:
 * the whole relayKeys is computed from `current` (the latest record); returns undefined (no write) when
 * that key's value changed during verification, the verdict is null, or the status did not change.
 */
export function relayKeysAfterVerification(
  current: Provider,
  verified: Provider,
  keyStatus: RelayVerificationKeyStatus | undefined,
): NonNullable<Provider['relayKeys']> | undefined {
  if (!keyStatus?.status) return undefined;
  // Write to the key that was actually sent: the request goes out with the sample model's effective key; if that key did not go out, or its value changed, do not write.
  const keyID = relayEffectiveKeyID(verified, keyStatus.modelID);
  if (!relayKeyGoesOut(verified, keyID)) return undefined;
  if (relayKeySecret(current, keyID) !== relayKeySecret(verified, keyID)) return undefined;
  const httpStatus = keyStatus.status === 'ok' ? undefined : keyStatus.httpStatus;
  return relayKeysWithStatus(current, keyID, keyStatus.status, httpStatus) ?? undefined;
}

/** Refetch the catalog only; a successful catalog HTTP call is not connection verification. */
export async function refreshRelayCatalogInStore(
  store: StoreApi<AppStore>,
  provider: Provider,
  options: { onlyKeyIDs?: readonly string[] } = {},
): Promise<RelayCatalogRefreshResult> {
  const canonical = store.getState().providers.find((item) => item.id === provider.id);
  if (!canonical) return { state: 'stale' };
  if (!canRefreshRelayCatalog(canonical.relayRequested)) {
    return { state: 'skipped', catalogModels: canonical.catalogModels };
  }
  if (relayKeyIDs(canonical).length > 1) return refreshRelayMultiKeyCatalogInStore(store, canonical, options.onlyKeyIDs);
  let fetched: Awaited<ReturnType<typeof fetchRelayModelsDirect>>;
  try {
    fetched = await fetchRelayModelsDirect(canonical);
  } catch (error) {
    // The response body is not JSON: record it as a failure (same rule as the per-key path).
    fetched = { ok: false, status: null, body: '', error };
  }
  if (store.getState().providers.find((item) => item.id === provider.id) !== canonical) {
    return { state: 'stale' };
  }
  // A single key also gets its status written, with the same status words / status codes as the per-key path; an implicit single key is materialized into one entry on first write.
  const relayKeys = singleRelayKeyCatalogStatus(canonical, fetched);
  if (fetched.ok) {
    const models = mergeRelayEnabledModels(canonical.models, fetched.models);
    const lastError = canonical.lastError === PROVIDER_VALIDATION_MESSAGES.catalogUnavailable
      ? undefined
      : canonical.lastError;
    const patch = { models, catalogModels: fetched.models, lastError, ...(relayKeys ? { relayKeys } : {}) };
    store.getState().updateProvider(provider.id, patch);
    getSyncAdapter()?.didUpdateProvider({ ...canonical, ...patch });
    return { state: 'loaded', catalogModels: fetched.models };
  }
  // The catalog tri-state has to survive a remount: connection-level unverified stays in
  // status.message, and on catalog failure this slot must hold the exact catalog key rather
  // than relying on the current React local state.
  const lastError = PROVIDER_VALIDATION_MESSAGES.catalogUnavailable;
  const patch = { lastError, ...(relayKeys ? { relayKeys } : {}) };
  store.getState().updateProvider(provider.id, patch);
  getSyncAdapter()?.didUpdateProvider({ ...canonical, ...patch });
  return { state: 'failed', error: fetched.error };
}

/**
 * Catalog refresh for two or more keys: fetch key by key, merge, write each key's status, then keep the enabled models.
 * If the connection identity changed in flight the whole batch is discarded; if only one key's value changed, that key counts as skipped (merged against the latest connection).
 */
async function refreshRelayMultiKeyCatalogInStore(
  store: StoreApi<AppStore>,
  canonical: Provider,
  onlyKeyIDs: readonly string[] | undefined,
): Promise<RelayCatalogRefreshResult> {
  const perKey = await fetchRelayCatalogPerKey(canonical, onlyKeyIDs);
  const latest = store.getState().providers.find((item) => item.id === canonical.id);
  if (!latest || relayMultiKeyConnectionIdentity(latest) !== relayMultiKeyConnectionIdentity(canonical)) {
    return { state: 'stale' };
  }
  const catalog = assembleRelayMultiKeyCatalog(latest, perKey);
  if (catalog.error !== undefined) {
    // No key fetched successfully: leave the catalog alone and only write each key's status plus catalog-unavailable (same lastError as a single-key failure).
    const lastError = PROVIDER_VALIDATION_MESSAGES.catalogUnavailable;
    store.getState().updateProvider(latest.id, { relayKeys: catalog.relayKeys, lastError });
    getSyncAdapter()?.didUpdateProvider({ ...latest, relayKeys: catalog.relayKeys, lastError });
    return { state: 'failed', error: catalog.error };
  }
  const models = mergeRelayEnabledModels(latest.models, catalog.catalogModels);
  const lastError = latest.lastError === PROVIDER_VALIDATION_MESSAGES.catalogUnavailable
    ? undefined
    : latest.lastError;
  const patch = { models, catalogModels: catalog.catalogModels, relayKeys: catalog.relayKeys, lastError };
  store.getState().updateProvider(latest.id, patch);
  getSyncAdapter()?.didUpdateProvider({ ...latest, ...patch });
  return { state: 'loaded', catalogModels: catalog.catalogModels };
}

export function mergeRelayEnabledModels(
  enabledModels: Provider['models'],
  catalogModels: Provider['catalogModels'],
): Provider['models'] {
  if (enabledModels.length > 0) {
    return enabledModels.map((model) => {
      const match = findRelayModel(catalogModels, model.id);
      // A relay has no default model: a catalog refresh does not keep the old isDefault.
      return match ? withRelayModelLocalFields({ ...match, isDefault: false }, model) : model;
    });
  }
  // With nothing enabled, enable the first catalog entry but do not mark it default.
  const fallback = catalogModels[0];
  return fallback ? [{ ...fallback, isDefault: false }] : [];
}

/**
 * Type guard for relay-only entry points. Official providers have no relayRequested, so letting one
 * in fails before any request and gets classified as an offline error. A misrouted call must fail
 * as a misrouted call and leave connection status untouched.
 */
function assertRelayProvider(provider: Provider, entry: string): void {
  if (provider.kind !== 'relay') {
    throw new Error(`${entry} only accepts relay connections, got ${provider.kind}`);
  }
}

/**
 * User-initiated relay verification: a 1-token generation over the same transport as chat.
 * Only that evidence moves a connection to connected; a catalog refresh is separate soft state
 * afterwards and must never rewrite the verification verdict.
 */
export async function verifyRelayProviderInStore(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<RelayPingResult | null> {
  assertRelayProvider(provider, 'verifyRelayProviderInStore');
  // The provider entity itself must already exist. A stale detail page must not spend a
  // user key on a request that has no valid persistence target.
  const persistedProvider = store.getState().providers.find((item) => item.id === provider.id);
  if (!persistedProvider) return null;
  // Persist/sync always start from this canonical Store object: on Desktop it carries
  // the KeyVault ref, never a renderer plaintext key.
  const connectionFingerprint = relayConnectionFingerprint(persistedProvider);
  store.getState().updateProvider(provider.id, {
    status: { kind: 'syncing' },
    lastError: undefined,
  });

  let failedKeyStatus: RelayVerificationKeyStatus | undefined;

  try {
    const verification = await verifyRelayProviderCandidate(provider, {
      lastUsedModelRef: store.getState().lastUsedModelRef,
    });
    if (!verification.ok) {
      // Every per-key fetch failed: persist each key's status first (before the single-key failure path).
      if (verification.relayKeys && currentRelayVerificationProvider(store, provider.id, connectionFingerprint)) {
        store.getState().updateProvider(provider.id, { relayKeys: verification.relayKeys });
      }
      failedKeyStatus = verification.keyStatus;
      throw verification.error;
    }

    // A request may finish after delete/key rotation/connection-settings save. Never
    // let that stale snapshot resurrect or overwrite the canonical Store provider.
    const currentProvider = currentRelayVerificationProvider(store, provider.id, connectionFingerprint);
    if (!currentProvider) return null;
    const relayKeys = relayKeysAfterVerification(
      verification.relayKeys ? { ...currentProvider, relayKeys: verification.relayKeys } : currentProvider,
      provider,
      verification.keyStatus,
    ) ?? verification.relayKeys;
    const nextProvider: Provider = {
      ...currentProvider,
      models: verification.models,
      catalogModels: verification.catalogModels,
      ...(relayKeys ? { relayKeys } : {}),
      lastCheckedAt: new Date().toISOString(),
      lastError: undefined,
      status: { kind: 'connected' },
    };
    store.getState().updateProvider(provider.id, {
      models: nextProvider.models,
      catalogModels: nextProvider.catalogModels,
      ...(relayKeys ? { relayKeys } : {}),
      lastCheckedAt: nextProvider.lastCheckedAt,
      lastError: undefined,
      status: nextProvider.status,
    });
    getSyncAdapter()?.didUpdateProvider(nextProvider);
    return verification.result;
  } catch (error) {
    const providerError = coerceProviderError(error);
    const message = providerError.kind === 'invalidKey' || providerError.kind === 'unauthorized'
      ? PROVIDER_VALIDATION_MESSAGES.invalidKey
      : PROVIDER_VALIDATION_MESSAGES.unverified;
    const currentProvider = currentRelayVerificationProvider(store, provider.id, connectionFingerprint);
    if (!currentProvider) return null;
    const relayKeys = relayKeysAfterVerification(currentProvider, provider, failedKeyStatus);
    // Persisted state holds stable i18n keys only; upstream detail that could echo a credential never reaches the store or sync.
    const nextProvider: Provider = {
      ...currentProvider,
      ...(relayKeys ? { relayKeys } : {}),
      lastCheckedAt: undefined,
      lastError: message,
      status: { kind: 'issue', message },
    };
    store.getState().updateProvider(provider.id, {
      ...(relayKeys ? { relayKeys } : {}),
      lastCheckedAt: undefined,
      lastError: message,
      status: nextProvider.status,
    });
    getSyncAdapter()?.didUpdateProvider(nextProvider);
    throw error;
  }
}

/** Fields whose change invalidates an in-flight Relay validation result. */
function relayConnectionFingerprint(provider: Provider): string {
  return JSON.stringify({
    baseURLText: provider.baseURLText,
    apiKey: resolveProviderAPIKey(provider),
    apiKeyPreview: provider.apiKeyPreview,
    relayKind: provider.relayKind,
    relayRequested: provider.relayRequested,
    relayResolvedAuthMode: provider.relayResolvedAuthMode,
    models: provider.models.map((model) => model.id),
  });
}

function currentRelayVerificationProvider(
  store: StoreApi<AppStore>,
  providerID: string,
  expectedFingerprint: string,
): Provider | undefined {
  const current = store.getState().providers.find((item) => item.id === providerID);
  return current && relayConnectionFingerprint(current) === expectedFingerprint ? current : undefined;
}

/**
 * "Refresh connection" for an official provider:
 * 1. refresh the metadata cache
 * 2. rebuild enabled models from the authoritative metadata catalog (buildOfficialEnabledModels)
 * 3. update status / lastCheckedAt / lastError
 *
 * Relay keeps its existing syncModels behavior.
 */
export async function resyncProviderInStore(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<void> {
  clearToolCallMemoryForConnection(getActiveUIDSync(), provider.id);
  store.getState().updateProvider(provider.id, {
    status: { kind: 'syncing' },
    lastError: undefined,
  });

  // Refresh metadata so pricing and capability data are current (a conditional index request plus
  // this provider's catalog).
  await refreshMetadata({ providerKinds: [provider.kind] }).catch(() => {});

  if (provider.kind === 'relay') {
    await resyncRelayProvider(store, provider);
    return;
  }

  if (provider.authMode === 'subscription') {
    // Dispatch by kind: `authMode` only says "this connection uses a subscription", not which
    // route it takes. Going by authMode alone, a Codex instance would be sent to
    // `prepareGrokSubscriptionRequest`, read an empty `grokSubscription` and report "please
    // reauthorize" - a phantom failure the user can never fix.
    if (provider.kind === 'openAI') {
      await resyncOpenAISubscriptionProvider(store, provider);
      return;
    }
    await resyncGrokSubscriptionProvider(store, provider);
    return;
  }

  await verifyOfficialProvider(store, provider);
}

/**
 * "Refresh connection" for a subscription instance.
 *
 * The official branch would overwrite the catalog with `api.x.ai` entries, so a single resync
 * would replace the model list with ids that do not exist on this route. This pulls from the
 * subscription catalog instead and renews along the way (the access token lasts 6 hours, and a
 * resync usually happens right after it expired).
 */
async function resyncGrokSubscriptionProvider(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<void> {
  const prepared = await prepareGrokSubscriptionRequest(provider);
  if (!prepared.ok) {
    refreshMetadataOnClientVersionRejected(prepared.error);
    const message = grokSubscriptionErrorToValidationMessage(prepared.error);
    store.getState().updateProvider(provider.id, {
      status: { kind: 'issue', message },
      lastError: message,
      lastCheckedAt: new Date().toISOString(),
    });
    return;
  }
  if (prepared.value.refreshed) {
    await persistGrokSubscriptionCredential(store, provider.id, prepared.value.refreshed);
  }

  const catalog = await fetchGrokSubscriptionModels(prepared.value.accessToken);
  if (!catalog.ok) {
    refreshMetadataOnClientVersionRejected(catalog.error);
    // Clear the catalog on failure instead of keeping the previous one: keeping it hands the
    // user a list that may already be void, where every choice fails with a confusing error.
    // Report the reason by class - tier not supported, quota exhausted, session expired,
    // catalog fully filtered - since the fix differs for each.
    const message = grokSubscriptionErrorToValidationMessage(catalog.error);
    store.getState().updateProvider(provider.id, {
      models: [],
      catalogModels: [],
      status: { kind: 'issue', message },
      lastError: message,
      lastCheckedAt: new Date().toISOString(),
    });
    return;
  }

  // Keep the user's chosen default model as long as it is still in the new catalog, and rebuild the rest from what was just fetched.
  const previousDefault = provider.models.find((model) => model.isDefault)?.id;
  const catalogIds = catalog.value.map((descriptor) => descriptor.id);
  const models = buildGrokSubscriptionModels(catalog.value).map((model) => ({
    ...model,
    isDefault: previousDefault && catalogIds.includes(previousDefault)
      ? model.id === previousDefault
      : model.isDefault,
  }));
  store.getState().updateProvider(provider.id, {
    models,
    catalogModels: [],
    status: { kind: 'connected' },
    lastError: undefined,
    lastCheckedAt: new Date().toISOString(),
  });
}

/**
 * "Refresh connection" for a Codex subscription instance.
 *
 * Structurally identical to the Grok one; the only difference is that the catalog fetch also
 * needs an `accountID`, taken from what `prepare` returns (the already parsed value held in the
 * credential) and never re-derived from the access token here.
 */
async function resyncOpenAISubscriptionProvider(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<void> {
  const prepared = await prepareOpenAISubscriptionRequest(provider);
  if (!prepared.ok) {
    refreshMetadataOnCodexClientVersionRejected(prepared.error);
    const message = openAISubscriptionErrorToValidationMessage(prepared.error);
    store.getState().updateProvider(provider.id, {
      status: { kind: 'issue', message },
      lastError: message,
      lastCheckedAt: new Date().toISOString(),
    });
    return;
  }
  if (prepared.value.refreshed) {
    await persistOpenAISubscriptionCredential(store, provider.id, prepared.value.refreshed);
  }

  const catalog = await fetchOpenAISubscriptionModels(
    prepared.value.accessToken,
    prepared.value.accountID,
  );
  if (!catalog.ok) {
    refreshMetadataOnCodexClientVersionRejected(catalog.error);
    // Clear the catalog on failure instead of keeping the official one: the official catalog
    // lists models from the api.openai.com route, none of which exist on the Codex backend.
    // Report the reason by class - tier not supported, quota exhausted, session expired,
    // catalog fully filtered - since the fix differs for each.
    const message = openAISubscriptionErrorToValidationMessage(catalog.error);
    store.getState().updateProvider(provider.id, {
      models: [],
      catalogModels: [],
      status: { kind: 'issue', message },
      lastError: message,
      lastCheckedAt: new Date().toISOString(),
    });
    return;
  }

  // Keep the user's chosen default model as long as it is still in the new catalog, and rebuild the rest from what was just fetched.
  const previousDefault = provider.models.find((model) => model.isDefault)?.id;
  const catalogIds = catalog.value.map((descriptor) => descriptor.slug);
  const models = buildOpenAISubscriptionModels(catalog.value).map((model) => ({
    ...model,
    isDefault: previousDefault && catalogIds.includes(previousDefault)
      ? model.id === previousDefault
      : model.isDefault,
  }));
  store.getState().updateProvider(provider.id, {
    models,
    catalogModels: [],
    status: { kind: 'connected' },
    lastError: undefined,
    lastCheckedAt: new Date().toISOString(),
  });
}

/* --- Official provider: verify connection -------------------------------- */

async function verifyOfficialProvider(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<void> {
  try {
    const metadata = getMetadataSnapshot() as CatalogMetadataInput | null;

    // BYOK key validation: probe through the Next runtime proxy, with a tri-state result
    // (valid/invalid/unverified). Never throws, since invalid is a normal return value; network
    // errors map to unverified, giving the key the benefit of the doubt.
    const validation = await validateOfficialProviderKey(
      provider.kind,
      resolveProviderAPIKey(provider),
      requestBaseURLText(provider),
    );

    if (!metadata) {
      if (provider.models.length > 0 || provider.catalogModels.length > 0) {
        const next = applyValidationOutcome(provider, validation, provider.models, provider.catalogModels);
        store.getState().updateProvider(provider.id, {
          lastCheckedAt: next.lastCheckedAt,
          lastError: next.lastError,
          status: next.status,
        });
        getSyncAdapter()?.didUpdateProvider(next);
        return;
      }

      throw networkError('Official provider metadata unavailable.');
    }

    const build = buildOfficialEnabledModels(provider.kind, metadata, {
      prevEnabledIds: provider.models.map((m) => m.id),
      prevEnabledModels: provider.models,
      prevCatalogModels: provider.catalogModels,
      prevDefaultModelId: provider.models.find((m) => m.isDefault)?.id,
      updatedAt: provider.updatedAt,
      firestoreUpdatedAt: provider.firestoreUpdatedAt,
    }, {
      repairLegacyAutoEnabledAll: true,
    });

    const nextProvider = applyValidationOutcome(
      provider,
      validation,
      build.models,
      build.catalogModels,
    );

    store.getState().updateProvider(provider.id, {
      models: nextProvider.models,
      catalogModels: nextProvider.catalogModels,
      lastCheckedAt: nextProvider.lastCheckedAt,
      lastError: nextProvider.lastError,
      status: nextProvider.status,
    });
    getSyncAdapter()?.didUpdateProvider(nextProvider);
  } catch (err) {
    const providerError = coerceProviderError(err);
    applyProviderError(store, provider, providerError);
  }
}

/**
 * Write the tri-state validation result back to the provider's status / lastCheckedAt / lastError:
 * - valid -> connected, lastError cleared
 * - invalid -> issue(invalid_key copy) with the same copy in lastError
 * - unverified -> connected (benefit of the doubt, still usable) with the soft notice as lastError
 *
 * Never blocking: it only annotates status. models/catalogModels come from the caller, already
 * built from the latest catalog.
 */
function applyValidationOutcome(
  provider: Provider,
  result: KeyValidationResult,
  models: Provider['models'],
  catalogModels: Provider['catalogModels'],
): Provider {
  const base: Provider = {
    ...provider,
    models,
    catalogModels,
    lastCheckedAt: new Date().toISOString(),
  };

  switch (result) {
    case 'valid':
      return { ...base, status: { kind: 'connected' }, lastError: undefined };
    case 'invalid':
      return {
        ...base,
        status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.invalidKey },
        lastError: PROVIDER_VALIDATION_MESSAGES.invalidKey,
      };
    case 'unverified':
      return { ...base, status: { kind: 'connected' }, lastError: PROVIDER_VALIDATION_MESSAGES.unverified };
  }
}

/* --- Relay: keep the existing syncModels behavior ------------------------- */

async function resyncRelayProvider(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<void> {
  try {
    if (!canRefreshRelayCatalog(provider.relayRequested)) {
      const nextProvider: Provider = {
        ...provider,
        lastCheckedAt: new Date().toISOString(),
        lastError: undefined,
        status: { kind: 'connected' },
      };

      store.getState().updateProvider(provider.id, {
        models: nextProvider.models,
        catalogModels: nextProvider.catalogModels,
        lastCheckedAt: nextProvider.lastCheckedAt,
        lastError: undefined,
        status: nextProvider.status,
      });
      getSyncAdapter()?.didUpdateProvider(nextProvider);
      return;
    }

    let models: Provider['models'];
    let relayKeys: Provider['relayKeys'];
    if (relayKeyIDs(provider).length > 1) {
      // Two or more keys fetch key by key; if none succeeds, treat it like a single-key failure (catalog untouched).
      const catalog = await syncRelayModelsPerKey(provider);
      if (catalog.error !== undefined) {
        // Persist each key's status first, then fall through to the catch below as a single-key failure.
        store.getState().updateProvider(provider.id, { relayKeys: catalog.relayKeys });
        throw catalog.error;
      }
      models = catalog.catalogModels;
      relayKeys = catalog.relayKeys;
    } else {
      // A single key also writes its status: materialize / update that one entry against the latest record; skip the write if the connection identity or primary key value changed in flight.
      const fetched = await fetchRelayModelsDirect(provider).catch((error: unknown) => (
        { ok: false as const, status: null, body: '', error }
      ));
      const latest = store.getState().providers?.find((item) => item.id === provider.id) ?? provider;
      const sameConnection = relayMultiKeyConnectionIdentity(latest) === relayMultiKeyConnectionIdentity(provider)
        && resolveProviderAPIKey(latest) === resolveProviderAPIKey(provider)
        && relayKeyIDs(latest).length === 1;
      relayKeys = sameConnection ? singleRelayKeyCatalogStatus(latest, fetched) : undefined;
      if (!fetched.ok) {
        if (relayKeys) store.getState().updateProvider(provider.id, { relayKeys });
        throw fetched.error;
      }
      models = fetched.models;
    }

    const enabledModels = mergeRelayEnabledModels(provider.models, models);

    const nextProvider: Provider = {
      ...provider,
      catalogModels: models,
      models: enabledModels,
      ...(relayKeys ? { relayKeys } : {}),
      lastCheckedAt: new Date().toISOString(),
      lastError: undefined,
      status: { kind: 'connected' },
    };

    store.getState().updateProvider(provider.id, {
      catalogModels: nextProvider.catalogModels,
      models: nextProvider.models,
      ...(relayKeys ? { relayKeys } : {}),
      lastCheckedAt: nextProvider.lastCheckedAt,
      lastError: undefined,
      status: nextProvider.status,
    });
    getSyncAdapter()?.didUpdateProvider(nextProvider);
  } catch (err) {
    const providerError = coerceProviderError(err);
    if (provider.models.length > 0 || provider.catalogModels.length > 0 || provider.lastCheckedAt) {
      const nextProvider: Provider = {
        ...provider,
        lastError: undefined,
        status: { kind: 'connected' },
      };

      store.getState().updateProvider(provider.id, {
        lastError: undefined,
        status: nextProvider.status,
      });
      getSyncAdapter()?.didUpdateProvider(nextProvider);
      return;
    }

    applyProviderError(store, provider, providerError);
  }
}

export function canRefreshRelayCatalog(
  relayRequested: RelayRequestedConfig | null | undefined,
): boolean {
  const transport = relayRequested?.transport;
  // All four cloud protocols refresh via catalogAPIRoot + /models; only llamacpp_native does not.
  return transport !== 'llamacpp_native';
}

async function syncRelayModelsDirect(provider: Provider): Promise<{
  models: Provider['models'];
  recommended: Provider['models'];
}> {
  const fetched = await fetchRelayModelsDirect(provider);
  if (!fetched.ok) throw fetched.error;
  return { models: fetched.models, recommended: buildRecommendedModels(fetched.models) };
}

/** Single-key catalog fetch; failure is returned as a result (with status code and response body) so an explicit single-key list records key status by the same rules as the per-key path. */
async function fetchRelayModelsDirect(
  provider: Provider,
): Promise<{ ok: true; models: Provider['models'] } | Extract<RelayCatalogFetch, { ok: false }>> {
  const fetched = await fetchRelayCatalogWithKey(provider, resolveProviderAPIKey(provider));
  if (!fetched.ok) return fetched;
  rememberRelayCatalogEndpointTypes(provider.id, fetched.endpointTypes);
  return { ok: true, models: relayCatalogModelsFromEntries(provider, fetched.entries) };
}

/**
 * Write the outcome of a single-key catalog fetch as the whole relayKeys (one entry): an explicit single entry is written as is,
 * an implicit single key is materialized as [{id: initial, apiKey: "", status}].
 * Returns undefined (no write) when the status did not change.
 */
function singleRelayKeyCatalogStatus(
  provider: Provider,
  fetched: { ok: true } | { ok: false; status: number | null; body: string },
): Provider['relayKeys'] {
  const [key] = relayKeyList(provider);
  // No key goes out: do not write, do not materialize.
  if (!relayKeyGoesOut(provider, key!.id)) return undefined;
  const next = withRelayKeyCatalogStatus(
    key!,
    fetched.ok ? 'ok' : relayKeyCatalogFailureStatus(fetched.status, fetched.body),
    fetched.ok || fetched.status === null ? undefined : fetched.status,
    new Date().toISOString(),
  );
  return next === key && provider.relayKeys?.length ? undefined : [next];
}

/** Write one key's catalog-fetch outcome back to its entry; if the status did not change the entry is left alone. Shared by the single-key and per-key paths. */
function withRelayKeyCatalogStatus(
  key: NonNullable<Provider['relayKeys']>[number],
  state: RelayKeyCatalogStatus,
  httpStatus: number | undefined,
  checkedAt: string,
): NonNullable<Provider['relayKeys']>[number] {
  if (key.status?.state === state && key.status.httpStatus === httpStatus) return key;
  return { ...key, status: { state, ...(httpStatus !== undefined ? { httpStatus } : {}), checkedAt } };
}

type RelayCatalogFetch =
  | { ok: true; entries: RemoteModel[]; endpointTypes: Record<string, string[]> }
  | { ok: false; status: number | null; body: string; error: unknown };

/**
 * One catalog request with the given key (single-key and per-key use the same request: address, headers and auth mode all follow the connection config, only the key value changes).
 * Network failures and non-2xx responses are returned as results; a response body that fails to parse still throws.
 */
async function fetchRelayCatalogWithKey(provider: Provider, apiKey: string): Promise<RelayCatalogFetch> {
  const requested = resolveRelayRequested(provider.relayRequested);
  // A local engine (engineProfile present) must sync its catalog over the same measured API root
  // as chat (including /v1) and allow plaintext LAN traffic according to securityMode: the
  // default remote_https accepts only public HTTPS and rejects http://192.168.x.x:1234 outright.
  const localEngine = provider.relayRequested?.engineProfile
    ? {
        baseURL: provider.relayRequested.resolvedAPIBaseURL ?? provider.baseURLText,
        securityMode: provider.relayRequested.securityMode,
      }
    : undefined;
  // A cloud relay always uses catalogAPIRoot + /models: the verified root address first, otherwise the address candidate for the connection protocol.
  const upstreamURL = buildRelayEndpointURL({
    baseURL: localEngine?.baseURL ?? catalogAPIRoot(provider) ?? provider.baseURLText,
    transport: requested.transport,
    endpoint: 'models',
    exactBaseURL: true,
    securityMode: localEngine?.securityMode,
  });

  let response: Response;
  try {
    const fetchArgs = buildBrowserRelayFetchArgs(
      upstreamURL,
      buildDirectAuthHeaders(apiKey, requested.authMode),
      {
        transport: requested.transport,
        authMode: requested.authMode,
        apiKey,
        method: 'GET',
        codexCompatIdentity: provider.relayRequested?.codexCompatIdentity,
        customUserAgent: provider.relayRequested?.customUserAgent,
        headers: provider.relayRequested?.headers,
        queryParams: provider.relayRequested?.queryParams,
        // Without securityMode the endpoint is judged as remote_https, so a local engine's
        // plaintext catalog sync is routed as if it were a public endpoint. Same marker as
        // the chat path, where buildRelayProxyConfig passes relaySecurityMode through.
        securityMode: localEngine?.securityMode,
      },
    );
    response = await fetchBrowserRelayDirect(fetchArgs.url, {
      method: 'GET',
      headers: {
        'Content-Type': 'application/json',
        ...fetchArgs.headers,
      },
    });
  } catch (err) {
    return { ok: false, status: null, body: '', error: networkError(err) };
  }

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    const error = httpToProviderError(response.status, body, upstreamURL, {
      // Relay catalog request: the guidance branch only recognizes isRelay (official providers never show relay guidance).
      // No protocol is passed: /models belongs to no chat protocol, and the connection-level protocol is only the default used to assemble headers.
      isRelay: true,
      relayKind: provider.relayKind,
      authMode: requested.authMode,
    }, [
      ...relaySensitiveCredentialValues({
        apiKey,
        headers: provider.relayRequested?.headers,
        queryParams: provider.relayRequested?.queryParams,
      }),
      // The redaction list assembled from the connection includes every key.
      ...relayKeySecrets(provider).filter((value) => value.trim().length > 0),
    ]);
    return { ok: false, status: response.status, body, error };
  }

  const data = decodeRelayCatalogEntries(await response.json());
  // Per-model probe candidates need new-api's supported_endpoint_types: keep only the latest one per connection, in memory.
  const endpointTypes: Record<string, string[]> = {};
  for (const entry of data) {
    const types = catalogEntryEndpointTypes(entry);
    if (types && typeof entry?.id === 'string') endpointTypes[entry.id] = types;
  }
  const entries = data.filter((model) => {
    const id = model.id.toLowerCase();
    return !EXCLUDED_RELAY_MODEL_PREFIXES.some((prefix) => id.startsWith(prefix));
  });
  return { ok: true, entries, endpointTypes };
}

/**
 * Catalog response decoding: take only the `data` array, in upstream order. The OpenAI list, new-api `{success,data}`
 * and Anthropic paginated shells are all accepted by it (fixture shellCases); display sorting happens later in buildModelsFromCatalog.
 */
export function decodeRelayCatalogEntries(json: unknown): RemoteModel[] {
  return (json as { data?: RemoteModel[] }).data ?? [];
}

function relayCatalogModelsFromEntries(provider: Provider, remoteModels: RemoteModel[]): Provider['models'] {
  // Intersect the envelope by each model's effective protocol (effectiveTransport), same rule as bootstrap / provider-model-ops.
  return withPreviousEngineDeclarations(enrichRelayModelsByTransport(
    provider,
    buildModelsFromCatalog(remoteModels, {}, 'openAI'),
    getRelayRuntimeConfig(),
  ), provider);
}

/* --- Per-key catalog fetch for multiple keys ----------------------------- */

interface RelayKeyCatalogFetch {
  keyID: string;
  /** The value used for the request; compared with the latest connection before persisting, and if it changed this key counts as skipped. */
  secret: string;
  fetched: RelayCatalogFetch;
}

/** Sequentially issue a catalog request per key; when `onlyKeyIDs` is given, fetch only those keys (replacing one key's value refetches just that key). */
async function fetchRelayCatalogPerKey(
  provider: Provider,
  onlyKeyIDs?: readonly string[],
): Promise<RelayKeyCatalogFetch[]> {
  const out: RelayKeyCatalogFetch[] = [];
  for (const keyID of relayKeyIDs(provider)) {
    if (onlyKeyIDs && !onlyKeyIDs.includes(keyID)) continue;
    const secret = relayKeySecret(provider, keyID) ?? '';
    let fetched: RelayCatalogFetch;
    try {
      fetched = await fetchRelayCatalogWithKey(provider, secret);
    } catch (error) {
      // The response body is not JSON: this key is recorded as a failure and does not drag down the others.
      fetched = { ok: false, status: null, body: '', error };
    }
    out.push({ keyID, secret, fetched });
  }
  return out;
}

/** Connection identity without the keys: if it changes while per-key fetches are in flight, the whole batch is discarded. */
function relayMultiKeyConnectionIdentity(provider: Provider): string {
  return JSON.stringify({
    baseURLText: provider.baseURLText,
    relayKind: provider.relayKind,
    relayRequested: provider.relayRequested,
    relayResolvedAuthMode: provider.relayResolvedAuthMode,
  });
}

interface RelayMultiKeyCatalog {
  catalogModels: Provider['models'];
  relayKeys: NonNullable<Provider['relayKeys']>;
  /** The first error when no key fetched successfully; the catalog is kept as is. */
  error?: unknown;
}

/** Merge the per-key results into a catalog and key statuses against the latest connection; a key whose value changed or that is no longer in the list counts as skipped. */
function assembleRelayMultiKeyCatalog(
  provider: Provider,
  perKey: readonly RelayKeyCatalogFetch[],
  now = new Date(),
): RelayMultiKeyCatalog {
  const keys = relayKeyIDs(provider);
  const results: Record<string, RelayKeyCatalogResult> = {};
  const fetchedEntries: RemoteModel[] = [];
  const seen = new Set<string>();
  const endpointTypes: Record<string, string[]> = {};
  let firstError: unknown;
  let anyOk = false;
  for (const keyID of keys) {
    const item = perKey.find((candidate) => candidate.keyID === keyID);
    if (!item || relayKeySecret(provider, keyID) !== item.secret) {
      results[keyID] = 'skipped';
      continue;
    }
    if (item.fetched.ok) {
      anyOk = true;
      results[keyID] = { ok: item.fetched.entries.map((entry) => entry.id) };
      for (const entry of item.fetched.entries) {
        if (seen.has(entry.id)) continue;
        seen.add(entry.id);
        fetchedEntries.push(entry);
      }
      for (const [id, types] of Object.entries(item.fetched.endpointTypes)) endpointTypes[id] ??= types;
    } else {
      results[keyID] = { status: item.fetched.status, body: item.fetched.body };
      firstError ??= item.fetched.error;
    }
  }
  const merged = mergeRelayKeyCatalogs(keys, provider.catalogModels, results);
  const fetchedModels = new Map(relayCatalogModelsFromEntries(provider, fetchedEntries).map((model) => [model.id, model]));
  const previousModels = new Map(provider.catalogModels.map((model) => [model.id, model]));
  // The merge function yields entries in fixture order; apply the same display sort as the single-key path before persisting, so both paths produce one ordering.
  const catalogModels = merged.catalog.flatMap((entry) => {
    const base = fetchedModels.get(entry.id) ?? previousModels.get(entry.id);
    return base ? [{ ...base, relayListedByKeyIDs: entry.relayListedByKeyIDs }] : [];
  }).sort(compareCatalogModels);
  const checkedAt = now.toISOString();
  const relayKeys = relayKeyList(provider).map((key) => {
    const state = merged.statuses[key.id];
    if (!state || !relayKeyGoesOut(provider, key.id)) return key;
    const result = results[key.id];
    const httpStatus = state !== 'ok' && result && result !== 'skipped' && 'status' in result && typeof result.status === 'number'
      ? result.status
      : undefined;
    return withRelayKeyCatalogStatus(key, state, httpStatus, checkedAt);
  });
  if (anyOk) rememberRelayCatalogEndpointTypes(provider.id, endpointTypes);
  return { catalogModels, relayKeys, ...(anyOk ? {} : { error: firstError }) };
}

/**
 * Step 1 of adding a relay: the primary key's catalog was already obtained by discovery; every other key is fetched one by one via
 * catalogAPIRoot + /models, then assembled with the primary key's catalog by the same merge function the refresh uses (listing keys,
 * per-key statuses, display sort). No generation request is made.
 * `provider` is the connection about to be saved (with the add already applied); `primary` is the primary key's catalog from discovery.
 */
export async function fetchRelayAddKeyCatalogs(
  provider: Provider,
  primary:
    | { ok: true; modelIDs: readonly string[]; endpointTypes?: Record<string, string[]> }
    | { ok: false; status: number | null },
): Promise<RelayAddKeyCatalogs> {
  const keys = relayKeyIDs(provider);
  const primaryID = keys[0]!;
  const others = await fetchRelayCatalogPerKey(provider, keys.slice(1));
  const perKey: RelayKeyCatalogFetch[] = [
    {
      keyID: primaryID,
      secret: relayKeySecret(provider, primaryID) ?? '',
      fetched: primary.ok
        ? {
            ok: true,
            entries: primary.modelIDs.map((id) => ({ id }) as RemoteModel),
            endpointTypes: primary.endpointTypes ?? {},
          }
        : { ok: false, status: primary.status, body: '', error: undefined },
    },
    ...others,
  ];
  const assembled = assembleRelayMultiKeyCatalog(provider, perKey);
  const endpointTypes: Record<string, string[]> = { ...(primary.ok ? primary.endpointTypes ?? {} : {}) };
  for (const item of others) {
    if (!item.fetched.ok) continue;
    for (const [id, types] of Object.entries(item.fetched.endpointTypes)) endpointTypes[id] ??= types;
  }
  return {
    catalogModels: assembled.catalogModels,
    relayKeys: assembled.relayKeys,
    endpointTypes,
    perKey: perKey.map((item) => (item.fetched.ok
      ? { keyID: item.keyID, ok: true as const, modelIDs: item.fetched.entries.map((entry) => entry.id) }
      : { keyID: item.keyID, ok: false as const, status: item.fetched.status })),
  };
}

export interface RelayAddKeyCatalogs {
  catalogModels: Provider['models'];
  relayKeys: NonNullable<Provider['relayKeys']>;
  endpointTypes: Record<string, string[]>;
  perKey: Array<
    | { keyID: string; ok: true; modelIDs: string[] }
    | { keyID: string; ok: false; status: number | null }
  >;
}

async function syncRelayModelsPerKey(provider: Provider): Promise<RelayMultiKeyCatalog> {
  return assembleRelayMultiKeyCatalog(provider, await fetchRelayCatalogPerKey(provider));
}

function resolveRelayRequested(
  relayRequested: RelayRequestedConfig | null | undefined,
): {
  transport: Exclude<RelayRequestedConfig['transport'], 'auto'>;
  authMode: Exclude<RelayRequestedConfig['authMode'], 'auto'>;
} {
  const transport = relayRequested?.transport === 'auto' || !relayRequested?.transport
    ? 'openai_chat_completions'
    : relayRequested.transport;
  const authMode = relayRequested?.authMode === 'auto' || !relayRequested?.authMode
    ? defaultRelayAuthMode(transport)
    : relayRequested.authMode;
  return { transport, authMode };
}

function defaultRelayAuthMode(
  transport: Exclude<RelayRequestedConfig['transport'], 'auto'>,
): Exclude<RelayRequestedConfig['authMode'], 'auto'> {
  switch (transport) {
    case 'anthropic_messages':
      return 'x_api_key';
    case 'gemini_generate_content':
      return 'x_goog_api_key';
    case 'llamacpp_native':
      return 'none';
    case 'openai_chat_completions':
    case 'openai_responses':
      return 'bearer';
  }
}

/* --- Shared helpers ------------------------------------------------------- */

function applyProviderError(
  store: StoreApi<AppStore>,
  provider: Provider,
  providerError: ProviderError,
): void {
  const preserveAvailability = shouldKeepProviderAvailableAfterError(providerError, provider);
  const nextProvider: Provider = {
    ...provider,
    lastError: providerError.message,
    status: preserveAvailability
      ? { kind: 'connected' }
      : { kind: 'issue', message: providerError.message },
  };

  store.getState().updateProvider(provider.id, {
    lastError: nextProvider.lastError,
    status: nextProvider.status,
  });
  getSyncAdapter()?.didUpdateProvider(nextProvider);
}

function coerceProviderError(error: unknown): ProviderError {
  if (typeof error === 'object' && error !== null && 'kind' in error && 'message' in error) {
    return error as ProviderError;
  }
  return networkError(error);
}

function shouldKeepProviderAvailableAfterError(
  error: ProviderError,
  provider: Provider,
): boolean {
  const hasState = provider.models.length > 0 || !!provider.lastCheckedAt;
  if (!hasState) return false;

  switch (error.kind) {
    case 'invalidKey':
    case 'badRequest':
      return false;
    case 'unauthorized':
    case 'quotaExceeded':
    case 'rateLimited':
    case 'unavailable':
    case 'network':
    case 'upstream':
    case 'emptyModelCatalog':
    case 'emptyResponse':
      return true;
    // On the subscription route, 426 (something to adapt to), 401 (reauthorize) and 429 (next
    // cycle) do not mean this connection is broken. The existing catalog stays usable, and only
    // a 403, meaning the tier is not supported, should mark the connection unusable.
    case 'grokSubscriptionUnavailable':
    case 'grokSubscriptionExpired':
    case 'grokSubscriptionQuotaExhausted':
      return true;
    case 'grokSubscriptionIneligible':
      return false;
    // Same for Codex: 426 / 401 / 429 are all transient and the existing catalog stays usable.
    case 'openAISubscriptionUnavailable':
    case 'openAISubscriptionExpired':
    case 'openAISubscriptionQuotaExhausted':
      return true;
    case 'openAISubscriptionIneligible':
      return false;
  }
}

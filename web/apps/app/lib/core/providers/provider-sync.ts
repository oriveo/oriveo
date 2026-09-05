import type { StoreApi } from 'zustand';
import type { Provider, RelayRequestedConfig } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { getMetadataSnapshot, getRelayRuntimeConfig, refreshMetadata } from '../metadata/metadata-client';
import { getSyncAdapter } from '../sync-port';
import { networkError, toProviderError as httpToProviderError, type ProviderError } from './errors';
import { validateOfficialProviderKey, type KeyValidationResult } from './service';
import type { CatalogMetadataInput } from './catalog-resolver';
import { buildOfficialEnabledModels } from './official-model-sync';
import { buildRelayEndpointURL } from './relay-endpoints';
import { buildRecommendedModels } from './catalog-model';
import { buildModelsFromCatalog, type RemoteModel } from './adapters/openai-compatible';
import { enrichRelayCatalog } from './relay-official-catalog-match';
import { IS_DESKTOP } from './desktop-stream';
import { buildDirectAuthHeaders } from '@oriveo/core/providers/relay-adapter';
import { buildBrowserRelayFetchArgs, fetchBrowserRelayDirect } from './relay-browser-direct';
import { pingRelay, type RelayPingResult } from './ping-relay';
import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';
import { relaySensitiveCredentialValues } from '@oriveo/core/providers/relay-runtime-support';
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

export type RelayCandidateVerification =
  | {
      ok: true;
      result: RelayPingResult;
      models: Provider['models'];
      catalogModels: Provider['catalogModels'];
      catalogRefreshed: boolean;
    }
  | {
      ok: false;
      phase: 'generation' | 'catalog';
      error: unknown;
    };

export type RelayCatalogRefreshResult =
  | { state: 'loaded'; catalogModels: Provider['catalogModels'] }
  | { state: 'failed'; error: unknown }
  | { state: 'skipped'; catalogModels: Provider['catalogModels'] }
  | { state: 'stale' };

/**
 * Explicit allowlist: only a change to connection identity fields triggers re-verification.
 * Adding UA/header/query/reasoning fields to the request builder later must not widen that set
 * automatically. Name, default model and display-only fields cause no network traffic.
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
    baseURLText: current.baseURLText,
    relayKind: current.relayKind,
    apiKey: current.apiKey,
    transport: currentRequested?.transport,
    authMode: currentRequested?.authMode,
  }) !== JSON.stringify({
    baseURLText: candidate.baseURLText,
    relayKind: candidate.relayKind,
    apiKey: candidate.apiKey,
    transport: candidateRequested?.transport,
    authMode: candidateRequested?.authMode,
  });

  return { needsVerification, needsCatalogRefresh };
}

function relayConnectionIdentityProjection(provider: Provider): string {
  return JSON.stringify({
    endpoint: provider.baseURLText,
    transport: provider.relayRequested?.transport,
    relayKind: provider.relayKind,
    authMode: provider.relayRequested?.authMode,
    securityMode: provider.relayRequested?.securityMode,
    apiKey: provider.apiKey,
  });
}

function relayValidationModelID(provider: Provider): string {
  return provider.models.find((model) => model.isDefault)?.id
    ?? provider.relayRequested?.modelID
    ?? '';
}

/** Single verification entry for a candidate: testing a saved connection and "verify and save" in the editor both go through it. */
export async function verifyRelayProviderCandidate(
  provider: Provider,
  options: { refreshCatalog?: boolean } = {},
): Promise<RelayCandidateVerification> {
  let result: RelayPingResult;
  try {
    const requested = provider.relayRequested;
    if (!requested) throw networkError('Relay configuration is missing.');
    result = await pingRelay({
      baseURL: provider.baseURLText ?? '',
      apiKey: provider.apiKey,
      modelID: relayValidationModelID(provider) || 'gpt-4o',
      relayRequested: requested,
      relayKind: provider.relayKind,
    });
  } catch (error) {
    return { ok: false, phase: 'generation', error };
  }

  let models = provider.models;
  let catalogModels = provider.catalogModels;
  let catalogRefreshed = false;
  if (options.refreshCatalog && canRefreshRelayCatalog(provider.relayRequested)) {
    try {
      const catalog = await syncRelayModelsDirect(provider);
      models = mergeRelayEnabledModels(provider.models, catalog.models);
      catalogModels = catalog.models;
      catalogRefreshed = true;
    } catch (error) {
      return { ok: false, phase: 'catalog', error };
    }
  }

  return { ok: true, result, models, catalogModels, catalogRefreshed };
}

/** Refetch the catalog only; a successful catalog HTTP call is not connection verification. */
export async function refreshRelayCatalogInStore(
  store: StoreApi<AppStore>,
  provider: Provider,
): Promise<RelayCatalogRefreshResult> {
  const canonical = store.getState().providers.find((item) => item.id === provider.id);
  if (!canonical) return { state: 'stale' };
  if (!canRefreshRelayCatalog(canonical.relayRequested)) {
    return { state: 'skipped', catalogModels: canonical.catalogModels };
  }
  try {
    const catalog = await syncRelayModelsDirect(canonical);
    if (store.getState().providers.find((item) => item.id === provider.id) !== canonical) {
      return { state: 'stale' };
    }
    const models = mergeRelayEnabledModels(canonical.models, catalog.models);
    const lastError = canonical.lastError === PROVIDER_VALIDATION_MESSAGES.catalogUnavailable
      ? undefined
      : canonical.lastError;
    const nextProvider = { ...canonical, models, catalogModels: catalog.models, lastError };
    store.getState().updateProvider(provider.id, {
      models,
      catalogModels: catalog.models,
      lastError,
    });
    getSyncAdapter()?.didUpdateProvider(nextProvider);
    return { state: 'loaded', catalogModels: catalog.models };
  } catch (error) {
    if (store.getState().providers.find((item) => item.id === provider.id) !== canonical) {
      return { state: 'stale' };
    }
    // The catalog tri-state has to survive a remount: connection-level unverified stays in
    // status.message, and on catalog failure this slot must hold the exact catalog key rather
    // than relying on the current React local state.
    const lastError = PROVIDER_VALIDATION_MESSAGES.catalogUnavailable;
    const nextProvider = {
      ...canonical,
      lastError,
    };
    store.getState().updateProvider(provider.id, {
      lastError,
    });
    getSyncAdapter()?.didUpdateProvider(nextProvider);
    return { state: 'failed', error };
  }
}

export function mergeRelayEnabledModels(
  enabledModels: Provider['models'],
  catalogModels: Provider['catalogModels'],
): Provider['models'] {
  if (enabledModels.length > 0) {
    return enabledModels.map((model) => {
      const match = catalogModels.find((candidate) => candidate.id === model.id);
      return match ? { ...match, isDefault: model.isDefault } : model;
    });
  }
  const fallback = catalogModels.find((model) => model.isDefault) ?? catalogModels[0];
  return fallback ? [{ ...fallback, isDefault: true }] : [];
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

  try {
    const verification = await verifyRelayProviderCandidate(provider);
    if (!verification.ok) throw verification.error;

    // A request may finish after delete/key rotation/connection-settings save. Never
    // let that stale snapshot resurrect or overwrite the canonical Store provider.
    const currentProvider = currentRelayVerificationProvider(store, provider.id, connectionFingerprint);
    if (!currentProvider) return null;
    const nextProvider: Provider = {
      ...currentProvider,
      models: verification.models,
      catalogModels: verification.catalogModels,
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
    return verification.result;
  } catch (error) {
    const providerError = coerceProviderError(error);
    const message = providerError.kind === 'invalidKey' || providerError.kind === 'unauthorized'
      ? PROVIDER_VALIDATION_MESSAGES.invalidKey
      : PROVIDER_VALIDATION_MESSAGES.unverified;
    const currentProvider = currentRelayVerificationProvider(store, provider.id, connectionFingerprint);
    if (!currentProvider) return null;
    // Persisted state holds stable i18n keys only; upstream detail that could echo a credential never reaches the store or sync.
    const nextProvider: Provider = {
      ...currentProvider,
      lastCheckedAt: undefined,
      lastError: message,
      status: { kind: 'issue', message },
    };
    store.getState().updateProvider(provider.id, {
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
    apiKey: provider.apiKey,
    apiKeyPreview: provider.apiKeyPreview,
    relayKind: provider.relayKind,
    relayRequested: provider.relayRequested,
    relayResolvedAuthMode: provider.relayResolvedAuthMode,
    models: provider.models.map((model) => ({ id: model.id, isDefault: model.isDefault })),
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

  // Refresh metadata so pricing and capability data are current.
  await refreshMetadata().catch(() => {});

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
      provider.apiKey,
      provider.baseURLText,
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

    const { models } = await syncRelayModelsDirect(provider);

    const enabledModels = mergeRelayEnabledModels(provider.models, models);

    const nextProvider: Provider = {
      ...provider,
      catalogModels: models,
      models: enabledModels,
      lastCheckedAt: new Date().toISOString(),
      lastError: undefined,
      status: { kind: 'connected' },
    };

    store.getState().updateProvider(provider.id, {
      catalogModels: nextProvider.catalogModels,
      models: nextProvider.models,
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
  return !transport
    || transport === 'auto'
    || transport === 'openai_chat_completions'
    || transport === 'openai_responses';
}

async function syncRelayModelsDirect(provider: Provider): Promise<{
  models: Provider['models'];
  recommended: Provider['models'];
}> {
  const requested = resolveRelayRequested(provider.relayRequested);
  // A local engine (engineProfile present) must sync its catalog over the same measured API root
  // as chat (including /v1) and allow plaintext LAN traffic according to securityMode: the
  // default remote_https accepts only public HTTPS and rejects http://192.168.x.x:1234 outright.
  // The cloud relay branch is unaffected.
  const localEngine = provider.relayRequested?.engineProfile
    ? {
        baseURL: provider.relayRequested.resolvedAPIBaseURL ?? provider.baseURLText,
        securityMode: provider.relayRequested.securityMode,
      }
    : undefined;
  const upstreamURL = buildRelayEndpointURL({
    baseURL: localEngine?.baseURL ?? provider.baseURLText,
    transport: requested.transport,
    endpoint: 'models',
    exactBaseURL: Boolean(localEngine?.baseURL),
    securityMode: localEngine?.securityMode,
  });

  let json: { data?: RemoteModel[] };
  if (IS_DESKTOP) {
    // On desktop the relay /models probe goes through main IPC (apiKey passed as apiKeyRef, ref-or-plaintext).
    try {
      json = (await window.oriveo!.provider.models({
        providerKind: 'relay',
        apiKeyRef: provider.apiKey,
        relay: { baseURL: provider.baseURLText ?? '', transport: requested.transport, authMode: requested.authMode },
      })) as { data?: RemoteModel[] };
    } catch (err) {
      throw networkError(err);
    }
  } else {
    let response: Response;
    try {
      const fetchArgs = buildBrowserRelayFetchArgs(
        upstreamURL,
        buildDirectAuthHeaders(provider.apiKey, requested.authMode),
        {
          transport: requested.transport,
          authMode: requested.authMode,
          apiKey: provider.apiKey,
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
      throw networkError(err);
    }

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      throw httpToProviderError(response.status, body, upstreamURL, {
        relayKind: provider.relayKind,
        transport: requested.transport,
        authMode: requested.authMode,
        modelID: provider.relayRequested?.modelID,
        codexCompatIdentity: provider.relayRequested?.codexCompatIdentity,
      }, relaySensitiveCredentialValues({
        apiKey: provider.apiKey,
        headers: provider.relayRequested?.headers,
        queryParams: provider.relayRequested?.queryParams,
      }));
    }

    json = await response.json() as { data?: RemoteModel[] };
  }

  const remoteModels = (json.data ?? []).filter((model) => {
    const id = model.id.toLowerCase();
    return !EXCLUDED_RELAY_MODEL_PREFIXES.some((prefix) => id.startsWith(prefix));
  });
  const models = enrichRelayCatalog(
    buildModelsFromCatalog(remoteModels, {}, 'openAI'),
    requested.transport === 'llamacpp_native' ? undefined : requested.transport,
    getRelayRuntimeConfig(),
  );
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
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

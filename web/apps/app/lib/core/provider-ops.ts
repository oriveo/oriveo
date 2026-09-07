/**
 * Provider operations - combined store and sync transaction
 */

import type { StoreApi } from 'zustand';
import * as Sentry from '@sentry/nextjs';
import {
  makeRelayRequested,
  type Provider,
  type ProviderSubscriptionCredential,
  type RelayConnectionSecurityMode,
} from '@oriveo/shared';
import { formatApiKeyPreview } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { getSyncAdapter } from './sync-port';
import { makeUniqueProviderInstanceName } from './providers/provider-display';
import {
  buildRelayCapabilityBitmap,
  resolveRelayRuntimeFields,
} from './providers/relay-resolution';
import { enrichRelayProvider } from './provider-model-ops';
import { revokeGrokSubscriptionCredential } from './providers/grok-subscription';
import { trackEvent, telemetryEndpointHost, telemetryProviderKind } from './telemetry';
import { PROVIDER_VALIDATION_MESSAGES } from './providers/validation-messages';
import { allowsCredentialEditing } from './providers/provider-status';
import {
  deleteProvider as deleteStoredProvider,
  deleteProviderFromPartition,
  deleteProviderAndEnqueuePendingDeletion,
  putProvider,
  putProviderIfCurrent,
  putProviderAndCancelPendingDeletion,
  putProviderAndCancelPendingDeletionIfCurrent,
} from '../infra/storage/idb';
import { getActiveUIDSync } from '../infra/storage/partition';
import {
  flushPendingProviderDeletions,
  registerPendingProviderDeletion,
  unregisterPendingProviderDeletion,
} from './sync-port';
import { serializeProviderSyncMutation } from './providers/provider-sync-serial';
import { removeGenerationParameterScopes } from './chat/generation-parameter-settings';
import { deleteAllCapabilityPreferencesForConnection } from './chat/capability-preference-settings';
import {
  clearCapabilityRejectionsForConnection,
  clearToolCallMemoryForConnection,
} from './chat/capability-recovery-runtime';
import {
  hasRelayConnectedEvidence,
  type RelayDetectedConfiguration,
} from './providers/probe/probe-runner';
import {
  relayHasCredentialMaterialAcross,
  relayRequiresCredential,
} from '@oriveo/core/providers/relay-runtime-support';
import {
  advanceCapabilityEvidenceIdentity,
  beginCapabilityEvidenceIdentityIfAbsent,
  tombstoneCapabilityEvidenceIdentity,
} from './providers/capability-evidence-identity';

function relayConnectionSemantics(provider: Provider): string {
  return JSON.stringify({
    baseURLText: provider.baseURLText ?? null,
    relayKind: provider.relayKind ?? null,
    requested: provider.relayRequested ? {
      transport: provider.relayRequested.transport ?? null,
      authMode: provider.relayRequested.authMode ?? null,
      securityMode: provider.relayRequested.securityMode ?? null,
      resolvedAPIBaseURL: provider.relayRequested.resolvedAPIBaseURL ?? null,
    } : null,
    resolved: {
      baseURLText: provider.relayResolvedBaseURLText ?? null,
      transport: provider.relayResolvedTransport ?? null,
      authMode: provider.relayResolvedAuthMode ?? null,
      headerProfile: provider.relayResolvedHeaderProfile ?? null,
      familyHint: provider.relayResolvedFamilyHint ?? null,
    },
  });
}

function relayCredentialListEqual(
  before: NonNullable<Provider['relayRequested']>['headers'],
  after: NonNullable<Provider['relayRequested']>['headers'],
): boolean {
  const left = before ?? [];
  const right = after ?? [];
  return left.length === right.length && left.every((item, index) => (
    item.key === right[index]?.key && item.value === right[index]?.value
  ));
}

/**
 * Header and query material already lives in the renderer's relay config, so this only does an
 * exact in-memory comparison: no KeyVault read, no hashing, and nothing written to identity
 * storage. undefined and [] both mean "no credential material", so a change in the form's
 * serialized shape does not falsely advance the epoch.
 */
function relayKVcredentialMaterialChanged(before: Provider, after: Provider): boolean {
  return !relayCredentialListEqual(before.relayRequested?.headers, after.relayRequested?.headers)
    || !relayCredentialListEqual(before.relayRequested?.queryParams, after.relayRequested?.queryParams);
}

function relayConnectionSemanticsChanged(before: Provider, after: Provider): boolean {
  return relayConnectionSemantics(before) !== relayConnectionSemantics(after);
}

// The object returned by begin doubles as the generation guard for finish; a WeakMap also binds
// the local partition it started on, so a probe returning after activeUID switched but before
// the store rehydrated cannot write one account's result into another's.
const relayReconnectPartition = new WeakMap<Provider, string>();

export interface AddProviderOptions {
  /**
   * Only for the cancellable creation flow of a new id. Re-read just before the persistence
   * transaction commits; false means this generation of the creation must be abandoned without
   * leaving KeyVault, IDB, store or sync side effects.
   */
  shouldCommit?: () => boolean;
}

export async function addProvider(
  store: StoreApi<AppStore>,
  provider: Provider,
  options: AddProviderOptions = {},
): Promise<boolean> {
  const callerShouldCommit = options.shouldCommit;
  const creationUID = getActiveUIDSync();
  const shouldCommit = callerShouldCommit
    ? () => callerShouldCommit() && getActiveUIDSync() === creationUID
    : undefined;
  if (shouldCommit && !shouldCommit()) return false;
  // Shared enrichment fallback on the creation path: a relay provider's model fields (priceTier,
  // promptPrice, capabilities, canonicalModelId and so on) are merged with the catalog match
  // before being written to the store. This keeps every entry point consistent: creating from
  // RelaySetup with a default model, creating at relay/new and filling in models later, and
  // official providers all write enriched data into the store.
  const stored = enrichRelayProvider(provider);
  if (getActiveUIDSync() !== creationUID) return false;
  if (shouldCommit && !shouldCommit()) return false;
  const uid = creationUID;
  const shouldSyncProvider = uid !== 'guest' && allowsCredentialEditing(stored.kind);
  let persisted = false;
  if (shouldSyncProvider) {
    await serializeProviderSyncMutation(uid, async () => {
      persisted = shouldCommit
        ? await putProviderAndCancelPendingDeletionIfCurrent(stored, uid, shouldCommit)
        : await putProviderAndCancelPendingDeletion(stored, uid).then(() => true);
      if (!persisted) return;
      if (shouldCommit && !shouldCommit()) {
        await deleteProviderFromPartition(stored.id, uid);
        persisted = false;
        return;
      }
      if (getActiveUIDSync() !== uid) return;
      unregisterPendingProviderDeletion(uid, stored.id);
      beginCapabilityEvidenceIdentityIfAbsent(uid, stored.id);
      store.getState().addProvider(stored);
      const adapter = getSyncAdapter();
      if (adapter?.boundUID === uid) adapter.didUpdateProvider(stored);
    });
  } else {
    persisted = shouldCommit
      ? await putProviderIfCurrent(stored, uid, shouldCommit)
      : await putProvider(stored, uid).then(() => true);
    if (!persisted) return false;
    if (shouldCommit && !shouldCommit()) {
      await deleteProviderFromPartition(stored.id, uid);
      return false;
    }
    if (getActiveUIDSync() !== uid) return true;
    beginCapabilityEvidenceIdentityIfAbsent(uid, stored.id);
    store.getState().addProvider(stored);
  }
  if (!persisted) return false;
  trackEvent('provider_added', {
    provider_kind: telemetryProviderKind(stored.kind),
    has_custom_endpoint: Boolean(stored.baseURLText),
    // "This model was typed by the user rather than taken from the catalog". isManual is the
    // persisted truth: catalog matches have the field stripped by official-model-sync's
    // stripResolverExtras.
    is_manual_model: stored.models.some((model) => model.isManual === true),
    relay_kind: stored.kind === 'relay' ? stored.relayKind ?? null : null,
    model_count: stored.models.length,
    // Which address actually connected, redacted the same way as the failure side so both
    // dashboards compare on one dimension. For relay this is the address the probe resolved
    // (the same one the send side reports as relay_url), so a shorthand the user typed and its
    // resolved form do not show up as different hosts in the two dashboards.
    endpoint_host: telemetryEndpointHost(
      stored.kind === 'relay'
        ? stored.relayResolvedBaseURLText ?? stored.baseURLText
        : stored.baseURLText,
    ),
  });
  return true;
}

/**
 * Persist Grok subscription credentials, for both first authorization and every renewal.
 *
 * Local only: `didUpdateProvider` is not called and the credential never enters the sync path,
 * the same policy as apiKey. There is therefore no path by which the cloud overwrites a local
 * credential - `mergeProviderFields` is an allow-list merge and the remote document has no such
 * field.
 */
export async function persistGrokSubscriptionCredential(
  store: StoreApi<AppStore>,
  providerId: string,
  credential: ProviderSubscriptionCredential,
): Promise<boolean> {
  const uid = getActiveUIDSync();
  const canonical = store.getState().providers.find((item) => item.id === providerId);
  if (!canonical) return false;
  const next: Provider = { ...canonical, grokSubscription: credential, authMode: 'subscription' };
  await putProvider(next, uid);
  if (getActiveUIDSync() !== uid) return false;
  store.getState().updateProvider(providerId, {
    grokSubscription: credential,
    authMode: 'subscription',
  });
  clearToolCallMemoryForConnection(uid, providerId);
  return true;
}

/**
 * Persist Codex (ChatGPT subscription sign-in) credentials, for first authorization and every
 * renewal.
 *
 * Kept separate from the Grok variant rather than branching on kind: they write different
 * fields, a merged function would need an extra kind argument at every call site, and a missed
 * one would silently write the wrong field - the two credentials look identical, so the type
 * system cannot catch it.
 */
export async function persistOpenAISubscriptionCredential(
  store: StoreApi<AppStore>,
  providerId: string,
  credential: ProviderSubscriptionCredential,
): Promise<boolean> {
  const uid = getActiveUIDSync();
  const canonical = store.getState().providers.find((item) => item.id === providerId);
  if (!canonical) return false;
  const next: Provider = { ...canonical, openAISubscription: credential, authMode: 'subscription' };
  await putProvider(next, uid);
  if (getActiveUIDSync() !== uid) return false;
  store.getState().updateProvider(providerId, {
    openAISubscription: credential,
    authMode: 'subscription',
  });
  clearToolCallMemoryForConnection(uid, providerId);
  return true;
}

/**
 * Switch a subscription instance back to API key mode.
 *
 * The only way out once the kill switch is off: the connection is kept, so the custom name and
 * model selections built up on this instance survive, while the subscription credential is
 * detached and the catalog is emptied. `grok-4.6` from the subscription catalog does not exist
 * on the API key path, and keeping it would hand the user a list that is guaranteed to fail. A
 * normal resync follows once a key is entered.
 */
export async function switchProviderToApiKeyMode(
  store: StoreApi<AppStore>,
  providerId: string,
): Promise<boolean> {
  const uid = getActiveUIDSync();
  const canonical = store.getState().providers.find((item) => item.id === providerId);
  if (!canonical) return false;
  // Try to notify the upstream of the revocation first, then drop the local credential. Failure
  // does not block: leaving a working token behind is worse than one missed upstream
  // notification. Codex has no revoke endpoint, so local deletion is the whole action there.
  await revokeGrokSubscriptionCredential(canonical.grokSubscription);
  const next: Provider = {
    ...canonical,
    authMode: 'apiKey',
    grokSubscription: undefined,
    openAISubscription: undefined,
    models: [],
    catalogModels: [],
    status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
    lastError: undefined,
    updatedAt: new Date().toISOString(),
  };
  await putProvider(next, uid);
  if (getActiveUIDSync() !== uid) return false;
  store.getState().updateProvider(providerId, {
    authMode: 'apiKey',
    grokSubscription: undefined,
    openAISubscription: undefined,
    models: [],
    catalogModels: [],
    status: next.status,
    lastError: undefined,
    updatedAt: next.updatedAt,
  });
  advanceCapabilityEvidenceIdentity(uid, providerId, { credentialEpoch: true });
  clearToolCallMemoryForConnection(uid, providerId);
  return true;
}

export async function updateProviderKey(store: StoreApi<AppStore>, provider: Provider, newKey: string): Promise<boolean> {
  const mutationUID = getActiveUIDSync();
  const preview = formatApiKeyPreview(newKey);
  const canonical = store.getState().providers.find((item) => item.id === provider.id);
  if (!canonical) return false;
  const verificationReset = canonical.kind === 'relay' && newKey.trim()
    ? {
        status: { kind: 'issue' as const, message: PROVIDER_VALIDATION_MESSAGES.unverified },
        lastCheckedAt: undefined,
        lastError: PROVIDER_VALIDATION_MESSAGES.unverified,
        // A new key can belong to a completely different account or model set, so the catalog is invalidated immediately; already-enabled models remain the user's own data.
        catalogModels: [],
      }
    : {};
  const patch = {
    apiKey: newKey,
    apiKeyPreview: preview,
    updatedAt: new Date().toISOString(),
    ...verificationReset,
  };
  const nextProvider = { ...canonical, ...patch };
  store.getState().updateProvider(provider.id, patch);
  advanceCapabilityEvidenceIdentity(mutationUID, provider.id, { credentialEpoch: true });
  clearToolCallMemoryForConnection(mutationUID, provider.id);
  getSyncAdapter()?.didUpdateProvider(nextProvider);
  return true;
}

/** Clearing patch for all three kinds of credential material (key, custom headers, custom query), shared by both clear paths. */
function credentialsClearedPatch(relayRequested: Provider['relayRequested']): Partial<Provider> {
  return {
    apiKey: '',
    apiKeyPreview: '',
    ...(relayRequested
      ? {
          relayRequested: {
            ...relayRequested,
            authMode: 'none' as const,
            headers: undefined,
            queryParams: undefined,
          },
        }
      : {}),
    relayResolvedAuthMode: 'none' as const,
  };
}

/**
 * Way out of the credential interlock on a plaintext connection: one action drops all three
 * kinds of credential material - authMode goes to none, and the key, custom headers and custom
 * query parameters are removed.
 *
 * This has to be a single patch. Split into updateProviderKey plus updateProviderRelaySettings,
 * the second write's `didUpdateProvider` would take the stale provider from its closure and sync
 * the just-deleted key back to the cloud.
 */
export async function clearRelayCredentials(store: StoreApi<AppStore>, provider: Provider): Promise<void> {
  const mutationUID = getActiveUIDSync();
  const patch = {
    ...credentialsClearedPatch(provider.relayRequested),
    updatedAt: new Date().toISOString(),
  };
  const nextProvider = { ...provider, ...patch };
  store.getState().updateProvider(provider.id, patch);
  const connectionChanged = relayConnectionSemanticsChanged(provider, nextProvider);
  const credentialChanged = provider.apiKey.trim().length > 0
    || relayKVcredentialMaterialChanged(provider, nextProvider);
  if (connectionChanged || credentialChanged) {
    advanceCapabilityEvidenceIdentity(mutationUID, provider.id, {
      connectionGeneration: connectionChanged,
      credentialEpoch: credentialChanged,
    });
    clearToolCallMemoryForConnection(mutationUID, provider.id);
  }
  getSyncAdapter()?.didUpdateProvider(nextProvider);
}

/**
 * First stage of a connection-mode switch: invalidate the old connection immediately, then write
 * the security boundary the user explicitly chose. Plaintext mode applies the credential clear
 * atomically in the same patch (auth=none plus removing key, header and query). The old resolved
 * API root must be cleared so nothing keeps sending to the previous security mode's path while
 * the reconnect is in flight.
 */
export async function beginRelaySecurityModeReconnect(
  store: StoreApi<AppStore>,
  provider: Provider,
  input: {
    securityMode: Exclude<RelayConnectionSecurityMode, 'tofu_https'>;
    normalizedEndpoint: string;
    unverifiedMessage: string;
    requested?: Provider['relayRequested'];
    shouldCommit?: () => boolean;
  },
): Promise<Provider | null> {
  const mutationUID = getActiveUIDSync();
  const cleartext = input.securityMode === 'local_http' || input.securityMode === 'private_vpn';
  const currentRequested = provider.relayRequested
    ?? makeRelayRequested(provider.relayKind ?? 'openai_compatible');
  const draftRequested = input.requested ?? currentRequested;
  const hasCredentialMaterial = cleartext && relayHasCredentialMaterialAcross([
    {
      authMode: currentRequested.authMode,
      hasStoredKey: provider.apiKey.trim().length > 0,
      headers: currentRequested.headers,
      queryParams: currentRequested.queryParams,
    },
    {
      authMode: draftRequested.authMode,
      hasStoredKey: false,
      headers: draftRequested.headers,
      queryParams: draftRequested.queryParams,
    },
  ]);
  const relayRequested = {
    ...draftRequested,
    securityMode: input.securityMode,
    resolvedAPIBaseURL: undefined,
    ...(cleartext
      ? {
          authMode: 'none' as const,
          ...(hasCredentialMaterial ? { headers: undefined, queryParams: undefined } : {}),
        }
      : {}),
  };
  if (input.shouldCommit && !input.shouldCommit()) return null;

  const patch: Partial<Provider> = {
    baseURLText: input.normalizedEndpoint,
    relayRequested,
    relayResolvedBaseURLText: undefined,
    relayResolvedTransport: undefined,
    relayResolvedAuthMode: undefined,
    relayResolvedHeaderProfile: undefined,
    relayResolvedFamilyHint: undefined,
    relayProbeVersion: undefined,
    relayCapabilityBitmap: undefined,
    relayLastProbeAt: undefined,
    relayLastProbeErrorClass: undefined,
    relayFingerprintKey: undefined,
    lastCheckedAt: undefined,
    catalogModels: [],
    // Enabled models are the user's own data: invalidating the catalog clears only the catalog and does not delete models that can still be used.
    models: provider.models,
    status: { kind: 'issue', message: input.unverifiedMessage },
    lastError: input.unverifiedMessage,
    updatedAt: new Date().toISOString(),
    ...(hasCredentialMaterial ? { apiKey: '', apiKeyPreview: '' } : {}),
  };
  store.getState().updateProvider(provider.id, patch);
  const nextProvider = store.getState().providers.find((item) => item.id === provider.id);
  if (!nextProvider) return null;
  const credentialChanged = (provider.apiKey.trim().length > 0 && nextProvider.apiKey.trim().length === 0)
    || relayKVcredentialMaterialChanged(provider, nextProvider);
  advanceCapabilityEvidenceIdentity(mutationUID, provider.id, {
    connectionGeneration: true,
    credentialEpoch: credentialChanged,
  });
  clearToolCallMemoryForConnection(mutationUID, provider.id);
  relayReconnectPartition.set(nextProvider, mutationUID);
  getSyncAdapter()?.didUpdateProvider(nextProvider);
  return nextProvider;
}

/** Promote a connection from issue to connected only after the production probe has both refreshed the catalog and passed a 1-token verification. */
export function finishRelaySecurityModeReconnect(
  store: StoreApi<AppStore>,
  provider: Provider,
  detection: RelayDetectedConfiguration,
): Provider | null {
  const mutationUID = relayReconnectPartition.get(provider);
  if (!mutationUID || getActiveUIDSync() !== mutationUID) return null;
  // A generation-only fallback proves the user's model can generate, not that the new endpoint's
  // model library is really readable. The mode switch already emptied the old catalog, so
  // without catalog evidence the connection has to stay in issue.
  if (!hasRelayConnectedEvidence(detection)) return null;
  // Commit only while the object generation written by begin is still the store's current value.
  // A user edit, a deletion or the next reconnect replaces the reference and disqualifies an
  // older probe's connected/catalog/root result.
  if (store.getState().providers.find((item) => item.id === provider.id) !== provider) return null;
  const requested = provider.relayRequested
    ?? makeRelayRequested(provider.relayKind ?? 'openai_compatible');
  const relayRequested = { ...requested, resolvedAPIBaseURL: detection.apiBaseURL };
  const refreshedCatalog = detection.catalogModels;
  const models = provider.models.map((model) => ({
    ...(refreshedCatalog.find((candidate) => candidate.id === model.id) ?? model),
    isDefault: model.isDefault,
  }));
  const enabledModels = models.length > 0
    ? models
    : refreshedCatalog[0] ? [{ ...refreshedCatalog[0], isDefault: true }] : provider.models;
  const now = new Date().toISOString();
  const runtime = resolveRelayRuntimeFields({
    baseURLText: provider.baseURLText,
    relayRequested: {
      ...relayRequested,
      transport: detection.transport,
      authMode: detection.authMode,
    },
  });
  const patch: Partial<Provider> = {
    relayRequested,
    ...runtime,
    relayResolvedTransport: detection.transport,
    relayResolvedAuthMode: detection.authMode,
    relayResolvedBaseURLText: detection.apiBaseURL,
    relayCapabilityBitmap: buildRelayCapabilityBitmap(detection.transport, {
      catalogEvidenceSucceeded: detection.catalogEvidenceSucceeded,
    }),
    catalogModels: refreshedCatalog,
    models: enabledModels,
    status: { kind: 'connected' },
    lastError: undefined,
    lastCheckedAt: now,
    relayLastProbeAt: now,
    updatedAt: now,
  };
  store.getState().updateProvider(provider.id, patch);
  const nextProvider = store.getState().providers.find((item) => item.id === provider.id);
  if (!nextProvider) return null;
  if (relayConnectionSemanticsChanged(provider, nextProvider)) {
    advanceCapabilityEvidenceIdentity(mutationUID, provider.id, { connectionGeneration: true });
    clearToolCallMemoryForConnection(mutationUID, provider.id);
  }
  getSyncAdapter()?.didUpdateProvider(nextProvider);
  return nextProvider;
}

export function updateProviderBaseURL(store: StoreApi<AppStore>, provider: Provider, url: string) {
  const val = url.trim() || undefined;
  const relayPatch = provider.kind === 'relay'
    ? (() => {
        const relayRequested = provider.relayRequested
          ? { ...provider.relayRequested, resolvedAPIBaseURL: undefined }
          : undefined;
        return {
          relayRequested,
          relayResolvedBaseURLText: resolveRelayRuntimeFields({
            baseURLText: val,
            relayRequested,
          }).relayResolvedBaseURLText,
        };
      })()
    : {};
  const patch = {
    baseURLText: val,
    updatedAt: new Date().toISOString(),
    ...relayPatch,
  };
  store.getState().updateProvider(provider.id, patch);
  if (provider.baseURLText !== val) {
    advanceCapabilityEvidenceIdentity(getActiveUIDSync(), provider.id, { connectionGeneration: true });
    clearToolCallMemoryForConnection(getActiveUIDSync(), provider.id);
  }
  getSyncAdapter()?.didUpdateProvider({ ...provider, ...patch });
}

export function updateProviderName(store: StoreApi<AppStore>, provider: Provider, name: string) {
  const trimmed = makeUniqueProviderInstanceName(
    name,
    provider.kind,
    store.getState().providers,
    provider.id,
  );
  store.getState().updateProvider(provider.id, {
    customName: trimmed,
    updatedAt: new Date().toISOString(),
  });
  getSyncAdapter()?.didUpdateProvider({ ...provider, customName: trimmed });
}

export type RelaySettingsPatch = Partial<Pick<Provider,
  | 'baseURLText'
  | 'relayKind'
  | 'relayRequested'
  | 'relayResolvedBaseURLText'
  | 'relayResolvedTransport'
  | 'relayResolvedAuthMode'
  | 'relayResolvedHeaderProfile'
  | 'relayResolvedFamilyHint'
  | 'relayCapabilityBitmap'
  | 'models'
  | 'catalogModels'
  | 'status'
  | 'lastCheckedAt'
  | 'lastError'
>> & Pick<Provider, 'relayKind' | 'relayRequested'>;

/**
 * Build the relay edit candidate with exactly the rules used for the final persistence.
 * Validation must go through here, especially for `authMode=none`: the candidate request must
 * not keep carrying an old key, header or query, and saving must not use a second set of rules.
 */
export function buildRelaySettingsCandidate(
  provider: Provider,
  patch: RelaySettingsPatch,
): Provider {
  return { ...provider, ...relaySettingsEffectivePatch(provider, patch) };
}

function relaySettingsEffectivePatch(
  provider: Provider,
  patch: RelaySettingsPatch,
): RelaySettingsPatch {
  const dropsCredentials = patch.relayRequested?.authMode === 'none'
    && (provider.apiKey.trim().length > 0
      || (patch.relayRequested.headers?.length ?? 0) > 0
      || (patch.relayRequested.queryParams?.length ?? 0) > 0);
  return dropsCredentials
    ? { ...patch, ...credentialsClearedPatch(patch.relayRequested) }
    : patch;
}

export async function updateProviderRelaySettings(
  store: StoreApi<AppStore>,
  provider: Provider,
  patch: RelaySettingsPatch,
): Promise<boolean> {
  const mutationUID = getActiveUIDSync();
  const canonicalProvider = store.getState().providers.find((item) => item.id === provider.id);
  if (!canonicalProvider) return false;
  // When the auth mode falls back to "no authentication", the same write also deletes the stored
  // key and any sensitive transport credential. Keeping a key that is stored but never sent turns
  // into a zombie config on the next switch to a cleartext connection or a move to another
  // device: it saves fine but cannot be sent.
  const dropsCredentials = patch.relayRequested?.authMode === 'none'
    && (canonicalProvider.apiKey.trim().length > 0
      || (patch.relayRequested.headers?.length ?? 0) > 0
      || (patch.relayRequested.queryParams?.length ?? 0) > 0);
  const effectivePatch = relaySettingsEffectivePatch(canonicalProvider, patch);
  const updatedAt = new Date().toISOString();
  const nextProvider = {
    ...canonicalProvider,
    ...effectivePatch,
    updatedAt,
  };
  store.getState().updateProvider(provider.id, {
    ...effectivePatch,
    updatedAt,
  });
  const connectionChanged = relayConnectionSemanticsChanged(canonicalProvider, nextProvider);
  const credentialChanged = (dropsCredentials && canonicalProvider.apiKey.trim().length > 0)
    || relayKVcredentialMaterialChanged(canonicalProvider, nextProvider);
  if (connectionChanged || credentialChanged) {
    advanceCapabilityEvidenceIdentity(mutationUID, provider.id, {
      connectionGeneration: connectionChanged,
      credentialEpoch: credentialChanged,
    });
    clearToolCallMemoryForConnection(mutationUID, provider.id);
  }
  getSyncAdapter()?.didUpdateProvider(nextProvider);
  return true;
}

export async function deleteProvider(store: StoreApi<AppStore>, providerId: string): Promise<boolean> {
  const removed = store.getState().providers.find((p) => p.id === providerId);
  if (!removed) return false;

  const uid = getActiveUIDSync();
  // Deleting a connection also tries to revoke the upstream token first; deletion continues even
  // if revocation fails, so no usable credential is left locally. This runs after the uid read: a
  // revocation is a network round trip, and if the account switches meanwhile, the deletion that
  // follows must still act on this partition.
  await revokeGrokSubscriptionCredential(removed.grokSubscription);
  const shouldSyncDeletion = uid !== 'guest' && allowsCredentialEditing(removed.kind);
  let committed = false;
  try {
    if (shouldSyncDeletion) {
      await serializeProviderSyncMutation(uid, async () => {
        await deleteProviderAndEnqueuePendingDeletion(providerId, uid);
        if (getActiveUIDSync() !== uid) return;
        registerPendingProviderDeletion(uid, providerId);
        store.getState().removeProvider(providerId);
        committed = true;
      });
    } else {
      await deleteStoredProvider(providerId, uid);
      if (getActiveUIDSync() !== uid) return false;
      store.getState().removeProvider(providerId);
      committed = true;
    }
  } catch (error) {
    console.error('[ProviderOps] Failed to persist provider deletion:', error);
    Sentry.captureException(error, {
      tags: { module: 'provider.ops', phase: 'delete-persist' },
    });
    return false;
  }

  // If the partition switched during the IDB transaction the current store belongs to another account, so the remaining side effects must not run.
  if (!committed || getActiveUIDSync() !== uid) return false;
  tombstoneCapabilityEvidenceIdentity(uid, providerId);
  removeGenerationParameterScopes({ providerId });
  deleteAllCapabilityPreferencesForConnection(providerId);
  clearCapabilityRejectionsForConnection(providerId);
  clearToolCallMemoryForConnection(uid, providerId);
  if (shouldSyncDeletion) void flushPendingProviderDeletions(uid);
  trackEvent('provider_removed', {
    provider_kind: telemetryProviderKind(removed?.kind),
  });
  return true;
}

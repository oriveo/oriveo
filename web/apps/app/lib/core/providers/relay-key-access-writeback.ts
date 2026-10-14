import type { StoreApi } from 'zustand';
import type { AIModel, Provider, RelayKeyStatusState } from '@oriveo/shared';
import {
  RELAY_IMPLICIT_KEY_ID,
  relayEffectiveKeyID,
  relayKeyList,
  relayKeySecret,
} from '@oriveo/shared/relay/relay-keys';
import type { RelayGenerationKeyStatus, RelayKeyAccessOutcome } from '@oriveo/core/providers/relay-key-access';
import type { AppStore } from '../store/app-store';
import type { StreamEvent } from './types';
import { sameNormalizedID } from '../../utils/id-utils';
import { providerFormOf } from '../capability/truth/provider-form';
import { emitRelayKeyConfirmation } from './relay-key-confirmation';
import { relayProviderRequiresCredential } from './relay-runtime-support';

/**
 * Write-back of the key classification on the relay send side (RK-2; contract C3 section 8, first item, fixture key-access.v1.json sendCases).
 * Write-back identity = the effective key of the model at send start (same rule as picking the key); only changes the connection in the latest store, no write if the status is unchanged.
 */

type ErrorEvent = Extract<StreamEvent, { type: 'error' }>;

/**
 * Key classification for pre-output error events: only accept the conclusion the production chain computed where the raw text was available and carried with the event; never parse redacted fragments afterwards.
 * Local / network sources and in-stream error frames are always none.
 */
export function relayKeyAccessOfEvent(event: ErrorEvent): RelayKeyAccessOutcome {
  if (typeof event.status !== 'number' || event.streamErrorFrame) return 'none';
  if (event.source === 'oriveo' || event.source === 'network') return 'none';
  return event.relayKeyAccess ?? 'none';
}

/** Classification carried in the first-leg rejection context of the tool loop (MCP / library) (computed by proxy-client where the raw text is). */
export function relayKeyAccessOfToolRejection(context: unknown): RelayKeyAccessOutcome {
  if (typeof context !== 'object' || context === null) return 'none';
  const value = (context as { relayKeyAccess?: unknown }).relayKeyAccess;
  return value === 'model_access_denied' || value === 'key_invalid' || value === 'key_limited' ? value : 'none';
}

function latestRelay(store: StoreApi<AppStore>, startProvider: Provider): Provider | null {
  if (providerFormOf(startProvider) !== 'relay') return null;
  return store.getState().providers.find((item) => sameNormalizedID(item.id, startProvider.id)) ?? null;
}

/** `model_access_denied`: record relayDeniedKeyID = effective key on that model (written for a single key too, with id initial). */
export function recordRelayModelAccessDenied(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
): boolean {
  const latest = latestRelay(store, startProvider);
  if (!latest) return false;
  const keyID = relayEffectiveKeyID(startProvider, startModel.id);
  const current = latest.models.find((model) => model.id === startModel.id);
  if (!current || current.relayDeniedKeyID === keyID) return false;
  const models = latest.models.map((model) => (model.id === current.id ? { ...model, relayDeniedKeyID: keyID } : model));
  store.getState().updateProvider(latest.id, { models });
  return true;
}

/**
 * Whether this key will go out with the request: auth method none / no credential needed, or an empty value → no key goes out, so status is moot.
 */
export function relayKeyGoesOut(provider: Provider, keyID: string): boolean {
  return relayProviderRequiresCredential(provider) && (relayKeySecret(provider, keyID) ?? '').trim().length > 0;
}

/**
 * The whole relayKeys after writing a status onto a key; returns null when nothing needs writing (the key is absent, no key goes out, state and httpStatus both unchanged).
 * The first status write on a single-key connection (no list) materializes [{id: initial, apiKey: "", status}].
 */
export function relayKeysWithStatus(
  provider: Provider,
  keyID: string,
  state: RelayKeyStatusState,
  httpStatus: number | undefined,
  now = new Date(),
): NonNullable<Provider['relayKeys']> | null {
  const implicit = !provider.relayKeys || provider.relayKeys.length === 0;
  if (implicit && keyID !== RELAY_IMPLICIT_KEY_ID) return null;
  if (!relayKeyGoesOut(provider, keyID)) return null;
  const keys = relayKeyList(provider);
  const entry = keys.find((key) => key.id === keyID);
  if (!entry) return null;
  if (entry.status?.state === state && entry.status.httpStatus === httpStatus) return null;
  const status = {
    state,
    ...(typeof httpStatus === 'number' ? { httpStatus } : {}),
    checkedAt: now.toISOString(),
  };
  return keys.map((key) => (key.id === keyID ? { ...key, status } : key));
}

/** Connection identity bound to the write-back: address, default transport / auth / security mode, that key's value; excludes name and status. */
function relayKeyWriteIdentity(provider: Provider, keyID: string): string {
  return JSON.stringify({
    endpoint: provider.baseURLText,
    transport: provider.relayRequested?.transport,
    authMode: provider.relayRequested?.authMode,
    securityMode: provider.relayRequested?.securityMode,
    secret: relayKeySecret(provider, keyID) ?? null,
  });
}

/**
 * Write the status of that key (the effective key at startModel when the send started); no write if state and httpStatus are both unchanged.
 * If the connection identity changed during the request (address / transport / auth / that key's value), discard without writing.
 */
export function recordRelayKeyStatus(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: Pick<AIModel, 'id'>,
  state: RelayKeyStatusState,
  httpStatus: number | undefined,
  now = new Date(),
): boolean {
  const latest = latestRelay(store, startProvider);
  if (!latest) return false;
  const keyID = relayEffectiveKeyID(startProvider, startModel.id);
  if (relayKeyWriteIdentity(latest, keyID) !== relayKeyWriteIdentity(startProvider, keyID)) return false;
  const relayKeys = relayKeysWithStatus(latest, keyID, state, httpStatus, now);
  if (!relayKeys) return false;
  store.getState().updateProvider(latest.id, { relayKeys });
  return true;
}

/** Write-back of generation requests (re-verification / lazy verification / capability test): a null conclusion leaves the status alone. A 2xx normal carries no status code. */
export function recordRelayGenerationKeyStatus(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: Pick<AIModel, 'id'>,
  status: RelayGenerationKeyStatus | null,
  httpStatus: number | undefined,
): boolean {
  if (!status) return false;
  return recordRelayKeyStatus(store, startProvider, startModel, status, status === 'ok' ? undefined : httpStatus);
}

/** Write-back of the classification result: no-access is recorded on the model, key invalid / quota writes that key's status; none writes nothing. */
export function applyRelayKeyAccessOutcome(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
  outcome: RelayKeyAccessOutcome,
  httpStatus: number | undefined,
): RelayKeyAccessOutcome {
  if (outcome === 'model_access_denied') {
    recordRelayModelAccessDenied(store, startProvider, startModel);
  } else if (outcome === 'key_invalid' || outcome === 'key_limited') {
    recordRelayKeyStatus(store, startProvider, startModel, outcome === 'key_invalid' ? 'invalid' : 'limited', httpStatus);
  }
  return outcome;
}

/** Write-back dispatch for non-2xx before output; returns the classification result, which the caller uses to decide whether to skip the capability rejection loop. */
export function applyRelayKeyAccessRejection(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
  event: ErrorEvent,
): RelayKeyAccessOutcome {
  return applyRelayKeyAccessOutcome(store, startProvider, startModel, relayKeyAccessOfEvent(event), event.status);
}

/**
 * Write-back of tool-loop (MCP / library) rejection before output, using the same write-back function as normal sends.
 * Returns the classification result; for model_access_denied the caller does not perform "drop tools and resend". Always none for non-Relay shapes.
 */
export function applyRelayToolRejection(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
  context: unknown,
): RelayKeyAccessOutcome {
  if (providerFormOf(startProvider) !== 'relay') return 'none';
  const status = typeof context === 'object' && context !== null ? (context as { status?: unknown }).status : undefined;
  return applyRelayKeyAccessOutcome(
    store, startProvider, startModel, relayKeyAccessOfToolRejection(context), typeof status === 'number' ? status : undefined,
  );
}

/**
 * Send success: clear relayDeniedKeyID if it equals the effective key; write ok if that key's status is not ok (a single key materializes one entry).
 * Also emits the delivered signal: the model's "not connected" is cleared whether or not the key status changed; writing the key ok does not clear other models (key normal ≠ model usable).
 */
export function recordRelayKeyAccessOnDelivered(
  store: StoreApi<AppStore>,
  startProvider: Provider,
  startModel: AIModel,
  now = new Date(),
): void {
  const latest = latestRelay(store, startProvider);
  if (!latest) return;
  emitRelayKeyConfirmation({ type: 'modelDelivered', providerID: latest.id, modelID: startModel.id });
  const keyID = relayEffectiveKeyID(startProvider, startModel.id);
  const current = latest.models.find((model) => model.id === startModel.id);
  if (current && current.relayDeniedKeyID === keyID) {
    const models = latest.models.map((model) => {
      if (model.id !== current.id) return model;
      const { relayDeniedKeyID: _cleared, ...rest } = model;
      return rest;
    });
    store.getState().updateProvider(latest.id, { models });
  }
  const entry = relayKeyList(latest).find((key) => key.id === keyID);
  if (entry && entry.status?.state !== 'ok') {
    recordRelayKeyStatus(store, startProvider, startModel, 'ok', undefined, now);
  }
}

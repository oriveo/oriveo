/**
 * Browser-side runtime for Grok subscription sign-in: device code authorization, credential renewal and subscription catalog fetching.
 *
 * All three outbound calls go through the app's own Next routes (`/api/providers/grok-subscription/*`):
 * a direct browser call to `auth.x.ai` is blocked by CORS, and the upstream endpoints have to be
 * resolved on the server from the delivered configuration, which the browser cannot supply.
 *
 * The pure rules (configuration normalization, error code translation, renewal timing) live in
 * `@oriveo/core/providers/grok-subscription` and are shared with the Next routes; this file only
 * does IO and local credential handling.
 */

import type { Provider, ProviderSubscriptionCredential } from '@oriveo/shared';
import {
  countGrokSubscriptionModelsInPayload,
  decodeGrokDeviceAuthorization,
  decodeGrokSubscriptionModelDescriptors,
  type GrokModelDescriptor,
  decodeGrokSubscriptionTokens,
  grokSubscriptionTokensNeedRefresh,
  mapGrokSubscriptionFailure,
  type GrokDeviceAuthorization,
  type GrokSubscriptionAuthConfig,
  type GrokSubscriptionErrorKind,
} from '@oriveo/core/providers/grok-subscription';
import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';
import { getGrokSubscriptionAuthConfig, refreshMetadata } from '../metadata/metadata-client';

const DEVICE_CODE_ENDPOINT = '/api/providers/grok-subscription/device-code';
const TOKEN_ENDPOINT = '/api/providers/grok-subscription/token';
const MODELS_ENDPOINT = '/api/providers/grok-subscription/models';
const REVOKE_ENDPOINT = '/api/providers/grok-subscription/revoke';

export type GrokSubscriptionResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: GrokSubscriptionErrorKind };

async function postJSON(
  url: string,
  body: unknown,
): Promise<GrokSubscriptionResult<unknown>> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body ?? {}),
    });
  } catch {
    return { ok: false, error: 'transport' };
  }
  const text = await response.text().catch(() => '');
  if (!response.ok) {
    // A 503 comes from our own route saying the configuration was not delivered or the kill switch is on; it is not upstream semantics.
    if (response.status === 503) return { ok: false, error: 'configurationUnavailable' };
    if (response.status === 502) return { ok: false, error: 'transport' };
    return { ok: false, error: mapGrokSubscriptionFailure(response.status, text) };
  }
  try {
    return { ok: true, value: text ? JSON.parse(text) : null };
  } catch {
    return { ok: false, error: 'upstream' };
  }
}

/** Step one: request a device code and the authorization page URL to show the user. */
export async function requestGrokDeviceAuthorization(
  config: GrokSubscriptionAuthConfig,
): Promise<GrokSubscriptionResult<GrokDeviceAuthorization>> {
  const result = await postJSON(DEVICE_CODE_ENDPOINT, {});
  if (!result.ok) return result;
  const authorization = decodeGrokDeviceAuthorization(result.value, config);
  // An authorization URL outside the trusted hosts means the configuration is unusable: better to do nothing than send the user to an unknown domain.
  if (!authorization) return { ok: false, error: 'configurationUnavailable' };
  return { ok: true, value: authorization };
}

/**
 * Step two: poll the token endpoint once.
 *
 * Sends a single request and translates the result once; `authorizationPending` / `slowDown` come
 * back as errors so the caller decides whether to keep waiting or slow down. Pacing stays in the
 * state machine, keeping this function stateless.
 */
export async function pollGrokDeviceToken(
  deviceCode: string,
  nowMs: number = Date.now(),
): Promise<GrokSubscriptionResult<ProviderSubscriptionCredential>> {
  const result = await postJSON(TOKEN_ENDPOINT, { deviceCode });
  if (!result.ok) return result;
  const tokens = decodeGrokSubscriptionTokens(result.value, nowMs);
  if (!tokens) return { ok: false, error: 'upstream' };
  return { ok: true, value: tokens };
}

/** Exchange a refresh token for a new access token. **The refresh_token rotates**, so the new value must be written back. */
export async function refreshGrokSubscriptionTokens(
  refreshToken: string,
  nowMs: number = Date.now(),
): Promise<GrokSubscriptionResult<ProviderSubscriptionCredential>> {
  const result = await postJSON(TOKEN_ENDPOINT, { refreshToken });
  if (!result.ok) return result;
  const tokens = decodeGrokSubscriptionTokens(result.value, nowMs);
  if (!tokens) return { ok: false, error: 'upstream' };
  return {
    ok: true,
    // Some implementations do not return a refresh_token on refresh; keep the old one, otherwise renewal ability is lost.
    value: tokens.refreshToken ? tokens : { ...tokens, refreshToken },
  };
}

/**
 * Fetch the model catalog for the subscription path (`grok-4.6` / `grok-4.5`, no overlap with the official catalog).
 *
 * Returns descriptors rather than bare ids: capabilities must follow the upstream declaration, otherwise every new model needs a code change.
 */
export async function fetchGrokSubscriptionModels(
  accessToken: string,
): Promise<GrokSubscriptionResult<GrokModelDescriptor[]>> {
  const result = await postJSON(MODELS_ENDPOINT, { accessToken });
  if (!result.ok) return result;
  const descriptors = decodeGrokSubscriptionModelDescriptors(result.value);
  if (descriptors.length === 0) {
    const declared = countGrokSubscriptionModelsInPayload(result.value);
    return { ok: false, error: declared > 0 ? 'catalogEmpty' : 'catalogUnavailable' };
  }
  return { ok: true, value: descriptors };
}

/** Stable English string written to `provider.lastError` when a subscription call fails. */
export function grokSubscriptionErrorToValidationMessage(
  kind: GrokSubscriptionErrorKind,
): string {
  switch (kind) {
    case 'unauthorized':
      return PROVIDER_VALIDATION_MESSAGES.grokSubscriptionReauthorize;
    case 'subscriptionNotEligible':
      return PROVIDER_VALIDATION_MESSAGES.grokSubscriptionNotEligible;
    case 'quotaExhausted':
      return PROVIDER_VALIDATION_MESSAGES.grokSubscriptionQuotaExhausted;
    case 'clientVersionRejected':
    case 'configurationUnavailable':
      return PROVIDER_VALIDATION_MESSAGES.grokSubscriptionUnavailable;
    case 'catalogEmpty':
      return PROVIDER_VALIDATION_MESSAGES.grokSubscriptionCatalogEmpty;
    default:
      return PROVIDER_VALIDATION_MESSAGES.grokSubscriptionCatalogUnavailable;
  }
}

/**
 * Best-effort upstream token revocation on disconnect.
 *
 * **Never blocks local cleanup**: once the user chooses disconnect or switching back to an API key,
 * no usable token should remain on the machine. An upstream outage, a timeout, or a missing
 * revocation endpoint only means the upstream was not notified; the local credential is deleted
 * either way. That is why this function neither returns a failure nor throws.
 */
export async function revokeGrokSubscriptionCredential(
  credential: Pick<ProviderSubscriptionCredential, 'accessToken' | 'refreshToken'> | undefined,
): Promise<void> {
  const accessToken = credential?.accessToken?.trim();
  const refreshToken = credential?.refreshToken?.trim();
  if (!accessToken && !refreshToken) return;
  await postJSON(REVOKE_ENDPOINT, {
    ...(accessToken ? { accessToken } : {}),
    ...(refreshToken ? { refreshToken } : {}),
  }).catch(() => undefined);
}

export interface PreparedGrokSubscriptionRequest {
  accessToken: string;
  config: GrokSubscriptionAuthConfig;
  /** Whether a renewal happened. If it did, the new credential must be written back, or the next send refreshes again with the stale value. */
  refreshed?: ProviderSubscriptionCredential;
}

/**
 * Gather what a subscription request needs: the current access token, renewed if necessary.
 *
 * Failures always return a specific reason rather than a generic error, because the caller decides
 * which message to show: "please authorize again" and "your subscription tier does not support
 * this" call for completely different next steps.
 */
export async function prepareGrokSubscriptionRequest(
  provider: Pick<Provider, 'grokSubscription'>,
  nowMs: number = Date.now(),
): Promise<GrokSubscriptionResult<PreparedGrokSubscriptionRequest>> {
  const config = getGrokSubscriptionAuthConfig();
  // Turned off by the kill switch, or never delivered by the backend: do not send anything. The
  // degraded notice for already connected instances is the UI's job; this only guarantees that a
  // possibly invalid configuration is not used to keep calling upstream.
  if (!config) return { ok: false, error: 'configurationUnavailable' };

  const stored = provider.grokSubscription;
  if (!stored?.accessToken) return { ok: false, error: 'unauthorized' };

  if (!grokSubscriptionTokensNeedRefresh(stored, nowMs)) {
    return { ok: true, value: { accessToken: stored.accessToken, config } };
  }
  // Expired with no refresh token available, so authorization has to be redone.
  if (!stored.refreshToken) return { ok: false, error: 'unauthorized' };

  const refreshed = await refreshGrokSubscriptionTokens(stored.refreshToken, nowMs);
  if (refreshed.ok) {
    return {
      ok: true,
      value: { accessToken: refreshed.value.accessToken, config, refreshed: refreshed.value },
    };
  }
  // Renewal failed but the old token has not actually expired yet: `needsRefresh` fires 5 minutes
  // early, and within that window the old token is still valid. Forcing a re-login over one network
  // hiccup is too blunt.
  if (stored.expiresAt !== undefined && nowMs < stored.expiresAt) {
    return { ok: true, value: { accessToken: stored.accessToken, config } };
  }
  return { ok: false, error: 'unauthorized' };
}

/**
 * A 426 is the earliest signal that xAI moved: it means the delivered client version is now below
 * the upstream minimum. The client snapshot has a 24h TTL and only refreshes in the background on a
 * cache hit, so without an explicit refresh a user could wait a full day after the configuration is
 * fixed.
 */
export function refreshMetadataOnClientVersionRejected(kind: GrokSubscriptionErrorKind): void {
  if (kind !== 'clientVersionRejected') return;
  void refreshMetadata().catch(() => {});
}

/** Map a subscription failure to the `errors.*` kind that is localized at render time. The four messages must stay distinct. */
export function grokSubscriptionErrorKindToProviderErrorKind(
  kind: GrokSubscriptionErrorKind,
): string {
  switch (kind) {
    case 'clientVersionRejected':
    case 'configurationUnavailable':
      return 'grokSubscriptionUnavailable';
    case 'subscriptionNotEligible':
      return 'grokSubscriptionIneligible';
    case 'unauthorized':
      return 'grokSubscriptionExpired';
    case 'quotaExhausted':
      return 'grokSubscriptionQuotaExhausted';
    case 'transport':
      return 'network';
    default:
      return 'upstream';
  }
}

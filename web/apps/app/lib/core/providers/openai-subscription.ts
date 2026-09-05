/**
 * Browser-side runtime for Codex (ChatGPT subscription sign-in): two-stage device code
 * authorization, credential renewal and catalog fetching.
 *
 * All three outbound calls go through our own Next routes
 * (`/api/providers/openai-subscription/*`). A browser cannot reach `auth.openai.com`
 * directly because of CORS, and the upstream endpoints have to be resolved on the server
 * from delivered configuration rather than passed in from the browser.
 *
 * Pure logic (configuration normalization, error code translation, capability parsing,
 * renewal timing) lives in `@oriveo/core/providers/openai-subscription` and is shared with
 * those routes; this file only does IO and local credential handling.
 *
 * Codex has no revocation endpoint, unlike Grok, so there is no `revoke` counterpart:
 * disconnecting only deletes locally.
 */

import type { Provider, ProviderSubscriptionCredential } from '@oriveo/shared';
import {
  countCodexModelsInPayload,
  decodeCodexModelDescriptors,
  decodeOpenAIDeviceAuthorization,
  decodeOpenAISubscriptionTokens,
  mapCodexDevicePollFailure,
  mapOpenAISubscriptionFailure,
  openAISubscriptionTokensNeedRefresh,
  type CodexModelDescriptor,
  type OpenAIDeviceAuthorization,
  type OpenAISubscriptionAuthConfig,
  type OpenAISubscriptionErrorKind,
} from '@oriveo/core/providers/openai-subscription';
import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';
import { getOpenAISubscriptionAuthConfig, refreshMetadata } from '../metadata/metadata-client';

const DEVICE_CODE_ENDPOINT = '/api/providers/openai-subscription/device-code';
const TOKEN_ENDPOINT = '/api/providers/openai-subscription/token';
const MODELS_ENDPOINT = '/api/providers/openai-subscription/models';

/** The route uses this to mark which of the two stages an upstream response came from: the same status code means opposite things in each stage. */
const CODEX_STAGE_HEADER = 'X-Oriveo-Codex-Stage';

export type OpenAISubscriptionResult<T> =
  | { ok: true; value: T }
  /**
   * `upstreamStatus` is set only when the upstream returned something unexpected, so that
   * class of failure can explain itself.
   *
   * Without it, `upstream` and a plain network failure share one message, "cannot connect
   * to Codex", and user reports become useless for diagnosis: the only information that
   * separates "could not connect" from "connected but got a 500" is lost at the point
   * where the failure is turned into copy.
   */
  | { ok: false; error: OpenAISubscriptionErrorKind; upstreamStatus?: number };

async function postJSON(url: string, body: unknown): Promise<OpenAISubscriptionResult<unknown>> {
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
    // A 503 comes from our own route (configuration not delivered, or turned off by the kill switch), not from the upstream.
    if (response.status === 503) return { ok: false, error: 'configurationUnavailable' };
    if (response.status === 502) return { ok: false, error: 'transport' };
    // A 403/404 while polling means the user has not approved yet; a 403 in another stage
    // means the plan does not support this. The route marks the stage, and without that
    // header half the guesses would be wrong.
    const stage = response.headers.get(CODEX_STAGE_HEADER);
    const map = stage === 'poll' ? mapCodexDevicePollFailure : mapOpenAISubscriptionFailure;
    const error = map(response.status, text);
    // Only `upstream` - a response no rule claimed - needs the status code attached: for
    // every other kind the message already describes the situation, and one more HTTP
    // number would only confuse the user.
    return error === 'upstream'
      ? { ok: false, error, upstreamStatus: response.status }
      : { ok: false, error };
  }
  try {
    return { ok: true, value: text ? JSON.parse(text) : null };
  } catch {
    return { ok: false, error: 'upstream' };
  }
}

/** Step one: request a device code and get the short code to show the user. */
export async function requestOpenAIDeviceAuthorization(
  config: OpenAISubscriptionAuthConfig,
): Promise<OpenAISubscriptionResult<OpenAIDeviceAuthorization>> {
  const result = await postJSON(DEVICE_CODE_ENDPOINT, {});
  if (!result.ok) return result;
  const authorization = decodeOpenAIDeviceAuthorization(result.value, config);
  // If the authorization page is not on a trusted host, treat the configuration as unavailable rather than sending the user to an unknown domain.
  if (!authorization) return { ok: false, error: 'configurationUnavailable' };
  return { ok: true, value: authorization };
}

/**
 * Step two: poll the authorization state once.
 *
 * The PKCE exchange is folded into the server side: once the route has
 * `authorization_code + code_verifier` it swaps for tokens immediately, so a single call
 * here either yields usable credentials or a definite intermediate state or failure. The
 * state machine mirrors the Grok one.
 */
export async function pollOpenAIDeviceToken(
  deviceAuthID: string,
  userCode: string,
  nowMs: number = Date.now(),
): Promise<OpenAISubscriptionResult<ProviderSubscriptionCredential>> {
  const result = await postJSON(TOKEN_ENDPOINT, { deviceAuthID, userCode });
  if (!result.ok) return result;
  const tokens = decodeOpenAISubscriptionTokens(result.value, nowMs);
  // A credential whose accountID cannot be parsed will always be missing the
  // `chatgpt-account-id` header on the way out; failing here is more honest than letting
  // the user hit "could not load the model list" one step later.
  if (!tokens) return { ok: false, error: 'upstream' };
  return { ok: true, value: tokens };
}

/**
 * Exchange a refresh token for a new access token.
 *
 * OpenAI's refresh response usually returns neither refresh_token nor id_token, so both
 * have to be carried over from the old values; otherwise renewal and account identity are
 * discarded together.
 */
export async function refreshOpenAISubscriptionTokens(
  credential: ProviderSubscriptionCredential,
  nowMs: number = Date.now(),
): Promise<OpenAISubscriptionResult<ProviderSubscriptionCredential>> {
  if (!credential.refreshToken) return { ok: false, error: 'unauthorized' };
  const result = await postJSON(TOKEN_ENDPOINT, { refreshToken: credential.refreshToken });
  if (!result.ok) return result;
  const tokens = decodeOpenAISubscriptionTokens(result.value, nowMs, {
    refreshToken: credential.refreshToken,
    accountID: credential.accountID,
    planType: credential.planType,
  });
  if (!tokens) return { ok: false, error: 'upstream' };
  return { ok: true, value: tokens };
}

/**
 * Fetch the model catalog for the Codex subscription path (the gpt-5.x family, with no
 * overlap with the official catalog).
 *
 * Returns descriptors rather than plain slugs so capabilities follow the upstream
 * declaration and every new model does not need a code change.
 * `accountID` is passed in by the caller and deliberately not parsed from the access token
 * here.
 */
export async function fetchOpenAISubscriptionModels(
  accessToken: string,
  accountID: string,
): Promise<OpenAISubscriptionResult<CodexModelDescriptor[]>> {
  if (!accountID.trim()) return { ok: false, error: 'unauthorized' };
  const result = await postJSON(MODELS_ENDPOINT, { accessToken, accountID });
  if (!result.ok) return result;
  const descriptors = decodeCodexModelDescriptors(result.value);
  if (descriptors.length === 0) {
    // Getting models back but filtering all of them out is not the same as never receiving a catalog; retrying only helps in the second case.
    const declared = countCodexModelsInPayload(result.value);
    return { ok: false, error: declared > 0 ? 'catalogEmpty' : 'catalogUnavailable' };
  }
  return { ok: true, value: descriptors };
}

/**
 * Map a subscription failure to the stable English string written into `provider.lastError`.
 *
 * Writing the same "catalog could not be loaded" line for every failure turned three very
 * different situations - unsupported account plan, quota exhausted, expired login - into
 * one instruction ("refresh the connection") that would not help in any of them. The four
 * messages already exist in 16 languages on the authorization path; this connects them to
 * the chat and resync path as well.
 */
export function openAISubscriptionErrorToValidationMessage(
  kind: OpenAISubscriptionErrorKind,
): string {
  switch (kind) {
    case 'unauthorized':
      return PROVIDER_VALIDATION_MESSAGES.openAISubscriptionReauthorize;
    case 'subscriptionNotEligible':
      return PROVIDER_VALIDATION_MESSAGES.openAISubscriptionNotEligible;
    case 'quotaExhausted':
      return PROVIDER_VALIDATION_MESSAGES.openAISubscriptionQuotaExhausted;
    case 'clientVersionRejected':
    case 'configurationUnavailable':
      return PROVIDER_VALIDATION_MESSAGES.openAISubscriptionUnavailable;
    case 'catalogEmpty':
      return PROVIDER_VALIDATION_MESSAGES.openAISubscriptionCatalogEmpty;
    default:
      // transport / upstream / catalogUnavailable  
      // The action that gets the user out of any of them really is to retry.
      return PROVIDER_VALIDATION_MESSAGES.openAISubscriptionCatalogUnavailable;
  }
}

export interface PreparedOpenAISubscriptionRequest {
  accessToken: string;
  accountID: string;
  config: OpenAISubscriptionAuthConfig;
  /** Whether a renewal happened this time. If it did, the new credential has to be written back, or the next send would still hold the old value and refresh again. */
  refreshed?: ProviderSubscriptionCredential;
}

/**
 * Gather what an outbound subscription request needs: the current access token and account
 * id, renewing if necessary.
 *
 * Failures return a specific meaning rather than a generic error, because "authorize again"
 * and "this subscription plan is not supported" call for completely different next steps
 * from the user.
 */
export async function prepareOpenAISubscriptionRequest(
  provider: Pick<Provider, 'openAISubscription'>,
  nowMs: number = Date.now(),
): Promise<OpenAISubscriptionResult<PreparedOpenAISubscriptionRequest>> {
  const config = getOpenAISubscriptionAuthConfig();
  // Turned off by the kill switch, or never delivered by the backend: do not go outbound.
  // Degraded messaging for already-connected instances is the UI's job; this only makes
  // sure a possibly stale configuration is not used to keep hitting the upstream.
  if (!config) return { ok: false, error: 'configurationUnavailable' };

  const stored = provider.openAISubscription;
  if (!stored?.accessToken) return { ok: false, error: 'unauthorized' };
  // A credential without an account id will always be missing the `chatgpt-account-id` header, so ask for re-authorization instead of sending it anyway.
  const accountID = stored.accountID?.trim();
  if (!accountID) return { ok: false, error: 'unauthorized' };

  if (!openAISubscriptionTokensNeedRefresh(stored, nowMs)) {
    return { ok: true, value: { accessToken: stored.accessToken, accountID, config } };
  }
  // No refresh token and the old one has expired, so authorization has to be run again.
  if (!stored.refreshToken) return { ok: false, error: 'unauthorized' };

  const refreshed = await refreshOpenAISubscriptionTokens(stored, nowMs);
  if (refreshed.ok) {
    return {
      ok: true,
      value: {
        accessToken: refreshed.value.accessToken,
        // When refresh returns no id_token, decode has already carried over the old accountID, so this is never empty.
        accountID: refreshed.value.accountID ?? accountID,
        config,
        refreshed: refreshed.value,
      },
    };
  }
  // Renewal failed but the old token has not actually expired: `needsRefresh` fires five
  // minutes early, the old token still works inside that window, and kicking the user back
  // to sign-in over one network blip would be too harsh.
  if (stored.expiresAt !== undefined && nowMs < stored.expiresAt) {
    return { ok: true, value: { accessToken: stored.accessToken, accountID, config } };
  }
  return { ok: false, error: 'unauthorized' };
}

/**
 * A 426 is the only early signal that OpenAI changed something: it means the delivered
 * `version` is now below the upstream minimum. The client snapshot has a 24h TTL and only
 * refreshes in the background on a cache hit, so without fetching immediately a user could
 * wait a full day after the configuration is corrected.
 */
export function refreshMetadataOnCodexClientVersionRejected(
  kind: OpenAISubscriptionErrorKind,
): void {
  if (kind !== 'clientVersionRejected') return;
  void refreshMetadata().catch(() => {});
}

/** Map a subscription failure to the `errors.*` kind that is localized at render time. The four messages must stay distinct. */
export function openAISubscriptionErrorKindToProviderErrorKind(
  kind: OpenAISubscriptionErrorKind,
): string {
  switch (kind) {
    case 'clientVersionRejected':
    case 'configurationUnavailable':
      return 'openAISubscriptionUnavailable';
    case 'subscriptionNotEligible':
      return 'openAISubscriptionIneligible';
    case 'unauthorized':
      return 'openAISubscriptionExpired';
    case 'quotaExhausted':
      return 'openAISubscriptionQuotaExhausted';
    case 'transport':
      return 'network';
    default:
      return 'upstream';
  }
}

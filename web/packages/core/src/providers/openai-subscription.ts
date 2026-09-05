/**
 * Pure logic for the OpenAI Codex subscription sign-in: parsing the served config and running
 * the two-stage device code flow.
 *
 * **The client runs the flow, it does not hold the knowledge.** Endpoints, client id, required
 * headers, model catalog source and the kill switch all come from
 * `providerConfigs[openAI].protocolFeatures.subscriptionAuth` in the served metadata. The one
 * exception is `chatgpt-account-id`, which is a per-user identity derived from the sign-in
 * token JWT rather than knowledge.
 *
 * Six protocol differences from the Grok subscription flow (each covered again on the relevant
 * function):
 * 1. **Two stages**: polling returns `authorization_code + code_verifier`, and a further PKCE
 *    exchange is needed to obtain a token.
 * 2. No revocation endpoint: disconnecting is a local delete only.
 * 3. `GET /models` must carry `?client_version=<served version header>`, otherwise upstream 400s.
 * 4. `/models` responds with `{"models":[{slug,visibility,supported_in_api}]}`, not the official
 *    `{"data":[{id}]}`.
 * 5. Outbound traffic goes to `/responses` with hard body constraints: `store:false` /
 *    `stream:true` / `instructions` / `include`.
 * 6. A 403/404 while polling the device endpoint means the user has not approved yet, not a
 *    permanent failure. That is the opposite of what a 403 means outside polling.
 *
 * Everything here is a pure function (no fetch, no storage, no DOM) so the browser and the Next
 * route share one set of rules.
 */

// Version comparison is plain numeric semantics and provider independent, so reuse the Grok
// implementation rather than growing a second one that will eventually diverge on some edge case.
import { compareGrokVersions } from './grok-subscription';

/** Everything one Codex subscription request needs. URLs are assembled here so callers cannot get them wrong. */
export interface OpenAISubscriptionAuthConfig {
  clientId: string;
  /** Stage one: request a device code (`.../deviceauth/usercode`). */
  deviceAuthorizationEndpoint: string;
  /** Stage one polling: returns `authorization_code + code_verifier`, **not** a token. */
  deviceTokenEndpoint: string;
  /** Stage two: the OAuth token endpoint, shared by the PKCE exchange and by refresh. */
  tokenEndpoint: string;
  /**
   * Authorization page URL.
   *
   * Unlike Grok, the Codex usercode response does **not** carry `verification_uri_complete`, so
   * the page URL comes from the served config, is checked against the host allowlist here, and
   * the short code is typed in by the user.
   */
  verificationURL: string;
  /** `redirect_uri`, required by the PKCE exchange and same-origin with the authorization endpoint. */
  redirectURI: string;
  trustedVerificationHosts: string[];
  resourceBaseURL: string;
  /** Headers that must be forwarded verbatim (`originator` / `version` / `OpenAI-Beta`). Both names and values are server-decided. */
  requiredHeaders: Record<string, string>;
  modelsPath: string;
  chatPath: string;
  /**
   * Full subscription catalog URL, without the `client_version` query parameter which is added
   * at request time.
   *
   * **The official catalog cannot stand in for it**: that one describes the metered
   * `api.openai.com` path, while the Codex backend exposes a separate gpt-5.x family
   * (sol / terra / luna and so on).
   */
  modelsURL: string;
  /** Full subscription chat endpoint. `resourceBaseURL` already carries `/backend-api/codex`, so only `/responses` is appended. */
  responsesURL: string;
  pollIntervalSeconds: number;
  pollTimeoutSeconds: number;
}

/**
 * Whether subscription sign-in is usable on this client.
 *
 * Three states rather than a boolean, because "the backend served nothing" and "an operator
 * turned it off" are different things to the user: the former should show nothing at all (older
 * server, missing snapshot), the latter must state the reason to users who are already
 * connected instead of failing silently.
 */
export type OpenAISubscriptionAvailability =
  | { state: 'available'; config: OpenAISubscriptionAuthConfig }
  | { state: 'disabled'; notice?: string }
  | { state: 'unavailable' };

export interface ResolveOpenAISubscriptionOptions {
  /** Current client version; defaults to '0.0.0'. */
  appVersion?: string;
  /** Which platform key to look up in `minAppVersion`. A missing key means no gate. */
  platform?: string;
}

const DEFAULT_MODELS_PATH = '/models';
const DEFAULT_CHAT_PATH = '/responses';
const DEFAULT_POLL_INTERVAL_SECONDS = 5;
const DEFAULT_POLL_TIMEOUT_SECONDS = 900;

/**
 * The only legitimate host for the Codex backend.
 *
 * The allowlist holds a single entry and requires an **exact match**: `resourceBaseURL` decides
 * where the access token is sent, so one tampered served value is a credential leak. Allowing
 * subdomains has no legitimate use here.
 */
const CODEX_RESOURCE_HOST = 'chatgpt.com';

/** ChatGPT account information lives under this namespaced claim in the id_token. */
const OPENAI_AUTH_CLAIM_NAMESPACE = 'https://api.openai.com/auth';

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function readString(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => readString(item)?.toLowerCase())
    .filter((item): item is string => Boolean(item));
}

function readStringMap(value: unknown): Record<string, string> {
  if (!isRecord(value)) return {};
  const out: Record<string, string> = {};
  for (const [key, raw] of Object.entries(value)) {
    const name = readString(key);
    const item = typeof raw === 'string' ? raw : undefined;
    if (name && item !== undefined) out[name] = item;
  }
  return out;
}

function readPositiveInt(value: unknown, fallback: number, minimum: number): number {
  const parsed = typeof value === 'number' && Number.isFinite(value) ? Math.trunc(value) : undefined;
  if (parsed === undefined) return fallback;
  return Math.max(minimum, parsed);
}

/** https, no port, no user/pass, non-empty host. Credentials or a custom port smuggled into the URL are rejected. */
function normalizedHTTPSURL(raw: unknown): URL | null {
  const text = readString(raw);
  if (!text) return null;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:') return null;
  if (url.username || url.password || url.port) return null;
  if (!url.hostname) return null;
  return url;
}

/** The host must match the served allowlist exactly. This is the gate against a tampered config redirecting to a phishing page. */
function trustedHTTPSURL(raw: unknown, hosts: readonly string[]): URL | null {
  const url = normalizedHTTPSURL(raw);
  if (!url) return null;
  return hosts.includes(url.hostname.toLowerCase()) ? url : null;
}

function normalizedPath(raw: unknown, fallback: string): string {
  const text = readString(raw);
  if (!text) return fallback;
  return text.startsWith('/') ? text : `/${text}`;
}

/**
 * Join base + path.
 *
 * `resourceBaseURL` already carries `/backend-api/codex`, so path only adds `/responses` or
 * `/models`. Keeping the join in one place means the rest of the code only ever consumes the
 * finished `responsesURL` / `modelsURL`; the Grok flow once shipped a `/v1/v1` 404 by doing
 * this in several places.
 */
export function joinOpenAISubscriptionURL(base: string, path: string): string {
  const trimmedBase = base.replace(/\/+$/, '');
  const trimmedPath = path.startsWith('/') ? path : `/${path}`;
  return `${trimmedBase}${trimmedPath}`;
}

/**
 * Parse the raw served JSON slice into a usable config.
 *
 * **Decode leniently, never throw**: any missing or invalid required field degrades to
 * `unavailable` rather than producing a half-built config. A missing endpoint is a flow that
 * cannot complete, and bailing out early is more honest than letting the user get stuck midway.
 */
export function resolveOpenAISubscriptionAuth(
  raw: unknown,
  options: ResolveOpenAISubscriptionOptions = {},
): OpenAISubscriptionAvailability {
  if (!isRecord(raw)) return { state: 'unavailable' };

  // flow is the contract version marker: if OpenAI changes the authorization scheme, an older
  // client that does not recognize the new flow should bow out instead of forcing the two-stage
  // device code logic onto it.
  if (readString(raw.flow) !== 'codex_device_code') return { state: 'unavailable' };

  const disabledNotice = readString(raw.disabledNotice);
  if (raw.enabled !== true) return { state: 'disabled', notice: disabledNotice };

  const platform = options.platform ?? 'web';
  const minAppVersion = isRecord(raw.minAppVersion) ? raw.minAppVersion : undefined;
  const minimum = readString(minAppVersion?.[platform]);
  if (minimum) {
    // The version gate exists to shut out old clients with known-bad logic, which would otherwise
    // keep hitting upstream. A missing platform key means no gate.
    const appVersion = readString(options.appVersion) ?? '0.0.0';
    if (compareGrokVersions(appVersion, minimum) < 0) {
      return { state: 'disabled', notice: disabledNotice };
    }
  }

  const clientId = readString(raw.clientId);
  const resourceBaseURL = normalizedHTTPSURL(raw.resourceBaseURL);
  // The host of resourceBaseURL must be **exactly** chatgpt.com: this is where the access token
  // goes, and allowing subdomains opens the door to a tampered served value.
  if (!clientId || !resourceBaseURL) return { state: 'unavailable' };
  if (resourceBaseURL.hostname.toLowerCase() !== CODEX_RESOURCE_HOST) {
    return { state: 'unavailable' };
  }

  const trustedAuthHosts = readStringArray(raw.trustedAuthHosts);
  if (trustedAuthHosts.length === 0) return { state: 'unavailable' };

  const deviceAuthorizationEndpoint = trustedHTTPSURL(raw.deviceAuthorizationEndpoint, trustedAuthHosts);
  const deviceTokenEndpoint = trustedHTTPSURL(raw.deviceTokenEndpoint, trustedAuthHosts);
  const tokenEndpoint = trustedHTTPSURL(raw.tokenEndpoint, trustedAuthHosts);
  // redirect_uri is required by the PKCE exchange and must be same-origin with the authorization endpoint, otherwise upstream rejects it.
  const redirectURI = trustedHTTPSURL(raw.redirectURI, trustedAuthHosts);
  if (!deviceAuthorizationEndpoint || !deviceTokenEndpoint || !tokenEndpoint || !redirectURI) {
    return { state: 'unavailable' };
  }

  const trustedVerificationHosts = readStringArray(raw.trustedVerificationHosts);
  if (trustedVerificationHosts.length === 0) return { state: 'unavailable' };
  const verificationURL = trustedHTTPSURL(raw.verificationURL, trustedVerificationHosts);
  if (!verificationURL) return { state: 'unavailable' };

  const modelsPath = normalizedPath(raw.modelsPath, DEFAULT_MODELS_PATH);
  const chatPath = normalizedPath(raw.chatPath, DEFAULT_CHAT_PATH);
  const base = resourceBaseURL.toString();

  return {
    state: 'available',
    config: {
      clientId,
      deviceAuthorizationEndpoint: deviceAuthorizationEndpoint.toString(),
      deviceTokenEndpoint: deviceTokenEndpoint.toString(),
      tokenEndpoint: tokenEndpoint.toString(),
      verificationURL: verificationURL.toString(),
      redirectURI: redirectURI.toString(),
      trustedVerificationHosts,
      resourceBaseURL: base,
      requiredHeaders: readStringMap(raw.requiredHeaders),
      modelsPath,
      chatPath,
      modelsURL: joinOpenAISubscriptionURL(base, modelsPath),
      responsesURL: joinOpenAISubscriptionURL(base, chatPath),
      // The polling interval fallback is only used when the server does not supply one; an interval returned by upstream wins (see the slow_down handling).
      pollIntervalSeconds: readPositiveInt(raw.pollIntervalSeconds, DEFAULT_POLL_INTERVAL_SECONDS, 1),
      pollTimeoutSeconds: readPositiveInt(raw.pollTimeoutSeconds, DEFAULT_POLL_TIMEOUT_SECONDS, 60),
    },
  };
}

/**
 * Whether an authorization page link falls within the trusted hosts.
 *
 * The Codex authorization page URL comes from the served config rather than an upstream
 * response, and `resolveOpenAISubscriptionAuth` already validates it. This entry point stays
 * separate so callers whose config has a different origin can still pass the same gate.
 */
export function allowsOpenAIVerificationURL(
  config: Pick<OpenAISubscriptionAuthConfig, 'trustedVerificationHosts'>,
  candidate: string,
): boolean {
  const url = normalizedHTTPSURL(candidate);
  if (!url) return false;
  const host = url.hostname.toLowerCase();
  return config.trustedVerificationHosts.some((trusted) => {
    const normalized = trusted.toLowerCase();
    return host === normalized || host.endsWith(`.${normalized}`);
  });
}

/**
 * Build the catalog URL with `client_version` attached.
 *
 * Without that query parameter upstream always answers 400 `missing field client_version`. The
 * value comes from the served `version` header rather than being hardcoded, so raising the
 * minimum is a config change instead of a release.
 */
export function buildCodexModelsURL(config: OpenAISubscriptionAuthConfig): string {
  const clientVersion = config.requiredHeaders.version?.trim();
  if (!clientVersion) return config.modelsURL;
  const url = new URL(config.modelsURL);
  url.searchParams.set('client_version', clientVersion);
  return url.toString();
}

/**
 * Failure semantics for the subscription path.
 *
 * The four hard failures call for completely different user actions, and collapsing them into
 * "network error" reports "your subscription tier does not support this" as an outage on our
 * side. A generic message once hid an unreachable chatgpt.com behind three rounds of changes to
 * code that was already correct.
 */
export type OpenAISubscriptionErrorKind =
  /** Upstream is still waiting for the user to approve in the browser. Normal intermediate state, keep polling. */
  | 'authorizationPending'
  /** Upstream considers the polling too frequent and requires a longer interval (RFC 8628). */
  | 'slowDown'
  /** The device code was not approved within `expires_in`. */
  | 'codeExpired'
  /** The user declined on the authorization page. */
  | 'accessDenied'
  /** HTTP 426: the served `version` is below the Codex backend minimum. **The only early signal that OpenAI changed something.** */
  | 'clientVersionRejected'
  /** HTTP 403 / `usage_not_included`: the account tier cannot use Codex from a third-party app. Not an outage on our side. */
  | 'subscriptionNotEligible'
  /** HTTP 401: the token is invalid. Refresh once automatically, and only ask for a new sign-in if that fails. */
  | 'unauthorized'
  /** HTTP 429 / `usage_limit_reached`: the Codex quota for this period is spent. Do not retry. */
  | 'quotaExhausted'
  /** The served config is missing or invalid, including a failed host allowlist check. */
  | 'configurationUnavailable'
  /** The catalog could not be fetched. Clear it and say so rather than leaving a dead official catalog behind. */
  | 'catalogUnavailable'
  /**
   * Upstream did return a catalog, but nothing survived filtering.
   *
   * This must stay separate from `catalogUnavailable`: that one means the catalog never arrived
   * (network, credentials, protocol), this one means it arrived and this account sees no usable
   * model on this path. The remedies are opposite: retrying helps in the first case and will
   * never help in the second. Merging them makes users hit "refresh connection" over and over
   * against a state that cannot improve.
   */
  | 'catalogEmpty'
  | 'transport'
  | 'upstream';

/** An upstream error can be either a string or a `{code|type}` object; accept both. */
function readUpstreamErrorCode(body: string): string | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return undefined;
  }
  if (!isRecord(parsed)) return undefined;
  const direct = readString(parsed.error);
  if (direct) return direct.toLowerCase();
  if (isRecord(parsed.error)) {
    const detail = readString(parsed.error.code) ?? readString(parsed.error.type);
    if (detail) return detail.toLowerCase();
  }
  // For some errors the usercode / token endpoints put the code at the top level rather than inside the error object.
  const topLevel = readString(parsed.error_code) ?? readString(parsed.code);
  return topLevel?.toLowerCase();
}

/**
 * Translate an HTTP status plus OAuth error code into explicit semantics.
 *
 * **For the non device-poll paths** (PKCE exchange, refresh, models), where a 403 means "tier
 * not supported". During device polling a 403/404 means the opposite (the user has not approved
 * yet) and is handled by `mapCodexDevicePollFailure`.
 */
export function mapOpenAISubscriptionFailure(
  status: number,
  body: string,
): OpenAISubscriptionErrorKind {
  switch (readUpstreamErrorCode(body)) {
    case 'authorization_pending':
    case 'deviceauth_authorization_pending':
      return 'authorizationPending';
    case 'slow_down':
      return 'slowDown';
    case 'expired_token':
    case 'device_code_expired':
      return 'codeExpired';
    case 'access_denied':
      return 'accessDenied';
    case 'usage_limit_reached':
    case 'rate_limit_exceeded':
      return 'quotaExhausted';
    case 'usage_not_included':
      return 'subscriptionNotEligible';
    case 'refresh_token_invalidated':
    case 'invalid_grant':
      return 'unauthorized';
    default:
      break;
  }
  switch (status) {
    case 401:
      return 'unauthorized';
    case 403:
      return 'subscriptionNotEligible';
    case 426:
      return 'clientVersionRejected';
    case 429:
      return 'quotaExhausted';
    default:
      return 'upstream';
  }
}

/**
 * Translation specific to the device polling stage.
 *
 * **Here a 403/404 means the user has not approved in the browser yet**, the exact opposite of
 * every other path: the Codex device endpoint uses those statuses for an intermediate state.
 * Applying the generic rules and mapping them to `subscriptionNotEligible` kills the flow on the
 * spot, which shows up as "your account is not supported" right after scanning the code.
 */
export function mapCodexDevicePollFailure(
  status: number,
  body: string,
): OpenAISubscriptionErrorKind {
  const mapped = mapOpenAISubscriptionFailure(status, body);
  // An explicit error code always wins: if upstream says access_denied, the request really was denied.
  if (readUpstreamErrorCode(body)) return mapped;
  if (status === 403 || status === 404) return 'authorizationPending';
  return mapped;
}

/**
 *  
 *
 *  
 *  
 */
export function openAISubscriptionErrorAllowsRetry(kind: OpenAISubscriptionErrorKind): boolean {
  switch (kind) {
    case 'codeExpired':
    case 'accessDenied':
    case 'transport':
    case 'upstream':
    case 'authorizationPending':
    case 'slowDown':
    case 'catalogUnavailable':
      return true;
    default:
      return false;
  }
}

/**
 * Whether this failure signals that OpenAI changed something.
 *
 * A 426 is the only early signal: receiving it means the served `version` has fallen below the
 * upstream minimum. Besides the message, it must force a metadata refresh straight away, since
 * the client snapshot has a 24h TTL and only refreshes in the background on a cache hit. Waiting
 * for natural expiry would leave users broken for up to a day after the config is fixed.
 */
export function openAISubscriptionErrorRequiresConfigRefresh(
  kind: OpenAISubscriptionErrorKind,
): boolean {
  return kind === 'clientVersionRejected';
}

/** Upstream response to the stage-one device code authorization request. */
export interface OpenAIDeviceAuthorization {
  deviceAuthID: string;
  userCode: string;
  /** Authorization page URL, taken from the **served config** (Codex does not return verification_uri_complete) and already allowlisted. */
  verificationURL: string;
  expiresIn: number;
  /** Polling interval requested by upstream; falls back to the value in the served config when absent. */
  interval?: number;
}

/**
 * Parse a usercode response.
 *
 * Key difference from Grok: **the authorization page URL is not taken from the upstream
 * response**. The Codex usercode response only carries `device_auth_id + user_code`, and the
 * user confirms the short code on the served authorization page.
 */
export function decodeOpenAIDeviceAuthorization(
  payload: unknown,
  config: OpenAISubscriptionAuthConfig,
): OpenAIDeviceAuthorization | null {
  if (!isRecord(payload)) return null;
  const deviceAuthID = readString(payload.device_auth_id);
  const userCode = readString(payload.user_code);
  if (!deviceAuthID || !userCode) return null;
  // The served authorization page URL was already allowlisted during resolve; check it again so a caller cannot bypass the gate with a hand-built config.
  if (!allowsOpenAIVerificationURL(config, config.verificationURL)) return null;

  const expiresIn =
    typeof payload.expires_in === 'number' && Number.isFinite(payload.expires_in)
      ? Math.trunc(payload.expires_in)
      : config.pollTimeoutSeconds;
  // interval may arrive as a number or as a numeric string; accept both.
  const rawInterval = payload.interval;
  const interval =
    typeof rawInterval === 'number' && Number.isFinite(rawInterval)
      ? Math.max(1, Math.trunc(rawInterval))
      : typeof rawInterval === 'string' && /^\d+$/.test(rawInterval.trim())
        ? Math.max(1, Number(rawInterval.trim()))
        : undefined;

  return {
    deviceAuthID,
    userCode,
    verificationURL: config.verificationURL,
    expiresIn,
    ...(interval !== undefined ? { interval } : {}),
  };
}

/** Successful stage-one polling result: **not a token**, but the pair of values used for the PKCE exchange. */
export interface CodexAuthorizationGrant {
  authorizationCode: string;
  codeVerifier: string;
}

/**
 * Parse a device polling response.
 *
 * Upstream expresses "not approved yet" as HTTP 200 with an empty code, so a missing pair is not
 * a failure and the caller keeps polling. Treating it as a parse error would kill the flow before
 * the user has had a chance to approve.
 */
export function decodeCodexAuthorizationGrant(payload: unknown): CodexAuthorizationGrant | null {
  if (!isRecord(payload)) return null;
  const authorizationCode = readString(payload.authorization_code);
  const codeVerifier = readString(payload.code_verifier);
  if (!authorizationCode || !codeVerifier) return null;
  return { authorizationCode, codeVerifier };
}

/**
 * Codex subscription credentials held on this device. **Stored locally only, never uploaded**,
 * matching how apiKey is handled (BYOK).
 *
 * `accountID` is the `chatgpt-account-id` header every request must carry. It is decoded from
 * the JWT and checked for emptiness **at token exchange time**; every later use reads that
 * resolved value and **must not look it up again** (see `decodeOpenAISubscriptionTokens`).
 */
export interface OpenAISubscriptionTokens {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  /** Absolute expiry (epoch milliseconds). Absent means upstream did not say, which is treated as "do not refresh proactively". */
  expiresAt?: number;
  accountID: string;
  planType?: string;
  obtainedAt: number;
}

/** base64url to UTF-8 text. Browsers and Node both have `atob` (Node 16+); fall back to Buffer when they do not. */
function decodeBase64URL(segment: string): string | null {
  const normalized = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  try {
    const globalAtob = (globalThis as { atob?: (data: string) => string }).atob;
    if (typeof globalAtob === 'function') {
      const binary = globalAtob(padded);
      const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
      return new TextDecoder().decode(bytes);
    }
    const nodeBuffer = (globalThis as { Buffer?: { from(input: string, encoding: string): { toString(encoding: string): string } } }).Buffer;
    if (nodeBuffer) return nodeBuffer.from(padded, 'base64').toString('utf8');
    return null;
  } catch {
    return null;
  }
}

/** Decode a JWT payload; anything undecodable yields null and never throws, since one bad token should only make the credential unusable, not break the flow. */
function decodeJWTPayload(token: string): Record<string, unknown> | null {
  const parts = token.split('.');
  if (parts.length < 2) return null;
  const text = decodeBase64URL(parts[1]);
  if (!text) return null;
  try {
    const parsed = JSON.parse(text) as unknown;
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * Read a string claim from a token, checking both the top level and the
 * `https://api.openai.com/auth` namespace.
 *
 * `chatgpt_account_id` actually lives under the namespace, and **only the id_token is guaranteed
 * to carry it**; the access token is not. Decoding it from the access token on demand once
 * failed with "cannot list models" immediately after a successful authorization.
 */
export function readOpenAIJWTClaim(token: string, claim: string): string | undefined {
  const payload = decodeJWTPayload(token);
  if (!payload) return undefined;
  const direct = readString(payload[claim]);
  if (direct) return direct;
  const namespaced = payload[OPENAI_AUTH_CLAIM_NAMESPACE];
  if (isRecord(namespaced)) return readString(namespaced[claim]);
  return undefined;
}

/** The `exp` carried by the access token (epoch milliseconds); it is more authoritative than `expires_in`. */
export function readOpenAIJWTExpiration(token: string): number | undefined {
  const payload = decodeJWTPayload(token);
  const exp = payload?.exp;
  if (typeof exp !== 'number' || !Number.isFinite(exp)) return undefined;
  return Math.trunc(exp) * 1000;
}

/**
 * Parse a token response together with the account information in the JWT.
 *
 * **Returns null when `chatgpt_account_id` cannot be read**: such a credential would always send
 * requests without the `chatgpt-account-id` header, and keeping it only pushes the user into an
 * error they cannot act on.
 *
 * `previousRefreshToken` / `previousAccountID` let the refresh path carry the old values
 * forward. OpenAI's refresh response usually returns neither a refresh_token nor an id_token, so
 * not carrying them forward throws away both renewal and the account identity.
 */
export function decodeOpenAISubscriptionTokens(
  payload: unknown,
  nowMs: number,
  previous?: { refreshToken?: string; accountID?: string; planType?: string },
): OpenAISubscriptionTokens | null {
  if (!isRecord(payload)) return null;
  const accessToken = readString(payload.access_token);
  if (!accessToken) return null;

  const idToken = readString(payload.id_token);
  // The id_token is the one carrying chatgpt_account_id; the access_token is only a fallback when it is missing.
  const claimSource = idToken ?? accessToken;
  const accountID =
    readOpenAIJWTClaim(claimSource, 'chatgpt_account_id') ??
    readString(previous?.accountID);
  if (!accountID) return null;

  const planType =
    readOpenAIJWTClaim(claimSource, 'chatgpt_plan_type') ?? readString(previous?.planType);
  const refreshToken = readString(payload.refresh_token) ?? readString(previous?.refreshToken);
  const expiresIn =
    typeof payload.expires_in === 'number' && Number.isFinite(payload.expires_in)
      ? Math.trunc(payload.expires_in)
      : undefined;
  const expiresAt =
    readOpenAIJWTExpiration(accessToken) ??
    (expiresIn !== undefined ? nowMs + expiresIn * 1000 : undefined);

  return {
    accessToken,
    ...(refreshToken ? { refreshToken } : {}),
    ...(idToken ? { idToken } : {}),
    ...(expiresAt !== undefined ? { expiresAt } : {}),
    accountID,
    ...(planType ? { planType } : {}),
    obtainedAt: nowMs,
  };
}

/**
 * Whether it is time to refresh proactively.
 *
 * Refreshing 5 minutes early avoids the window where a token is still valid at check time but
 * has expired by the time the request reaches upstream, which shows up as random 401s instead of
 * one predictable refresh.
 */
export function openAISubscriptionTokensNeedRefresh(
  tokens: Pick<OpenAISubscriptionTokens, 'expiresAt'>,
  nowMs: number,
  leewayMs = 5 * 60 * 1000,
): boolean {
  if (tokens.expiresAt === undefined) return false;
  return nowMs + leewayMs >= tokens.expiresAt;
}

/** One Codex subscription model together with the capabilities upstream declares for it. */
export interface CodexModelDescriptor {
  slug: string;
  displayName?: string;
  supportsWebSearch: boolean;
  supportedReasoningLevels: string[];
  defaultReasoningLevel?: string;
  supportsImageInput: boolean;
  contextWindow?: number;
}

export function codexDescriptorSupportsReasoning(
  descriptor: Pick<CodexModelDescriptor, 'supportedReasoningLevels'>,
): boolean {
  return descriptor.supportedReasoningLevels.length > 0;
}

/**
 * Parse a Codex `/models` response together with the per-model capabilities upstream declares.
 *
 * Two Codex-specific conventions:
 * (1) the response shape is `{"models":[{slug,visibility,supported_in_api,...}]}`, **not** the
 *     official `{"data":[{id}]}`; (2) only slugs with `visibility=="list"` and
 *     `supported_in_api==true` are accepted, so hidden entries (codex-auto-review) and entries
 *     without API support (gpt-5.3-codex-spark) stay out of the user's catalog.
 *
 * Unlike the lenient Grok filtering, the test here is **strict equality**: both fields are known
 * to exist, and accepting a slug with `visibility != list` hands the user something upstream
 * deliberately hid.
 *
 * Capabilities are **copied from the declaration and degrade when absent**: a non-empty
 * `web_search_tool_type` means web search is supported, an empty string or a missing field means
 * it is not, and the slug is never used to guess.
 */
/**
 * How many models this response **declares**, before filtering.
 *
 * Only used to tell "no catalog" apart from "a catalog that filtered down to nothing". It does
 * not build the catalog, so it deliberately validates no fields and just counts the `models`
 * array.
 */
export function countCodexModelsInPayload(payload: unknown): number {
  if (!isRecord(payload) || !Array.isArray(payload.models)) return 0;
  return payload.models.length;
}

export function decodeCodexModelDescriptors(payload: unknown): CodexModelDescriptor[] {
  if (!isRecord(payload) || !Array.isArray(payload.models)) return [];
  const descriptors: CodexModelDescriptor[] = [];
  for (const raw of payload.models) {
    if (!isRecord(raw)) continue;
    const slug = readString(raw.slug);
    if (!slug) continue;
    if (readString(raw.visibility) !== 'list') continue;
    if (raw.supported_in_api !== true) continue;

    // Upstream sends an **array of objects**, `[{effort, description}, ...]`, not an array of
    // strings. Parsing it as strings yields undefined for every entry and an always-empty level
    // table, which surfaces as "this model does not support thinking" on every subscription model
    // even though upstream declares 4 to 6 levels per model. The flat string form is accepted too,
    // so a change back to it does not empty the table again.
    const levels = Array.isArray(raw.supported_reasoning_levels)
      ? raw.supported_reasoning_levels
          .map((item) => readString(item) ?? (isRecord(item) ? readString(item.effort) : undefined))
          .filter((item): item is string => Boolean(item))
      : [];
    const modalities = Array.isArray(raw.input_modalities)
      ? raw.input_modalities.map((item) => readString(item)?.toLowerCase())
      : [];

    descriptors.push({
      slug,
      displayName: readString(raw.display_name),
      // A tool type from upstream means it is supported; an empty string or a missing field means it is not. Nothing is inferred.
      supportsWebSearch: Boolean(readString(raw.web_search_tool_type)),
      supportedReasoningLevels: levels,
      defaultReasoningLevel: readString(raw.default_reasoning_level),
      supportsImageInput: modalities.includes('image'),
      contextWindow:
        typeof raw.context_window === 'number' && Number.isFinite(raw.context_window)
          ? Math.trunc(raw.context_window)
          : undefined,
    });
  }
  return descriptors;
}

/**
 * Product level to the `reasoning.effort` value upstream accepts. **Only returns values that
 * actually appear in the upstream `declaredLevels`.**
 *
 * The rule being enforced is "never send a level upstream does not recognize". Subscription
 * models are not in the metadata catalog and have no official recipe, but the Codex `/models`
 * response declares `supported_reasoning_levels` per model, so that list is used for admission:
 * only recognized values are sent, and a rename upstream fails to match rather than keeping the
 * old value in flight.
 *
 * - Empty `declaredLevels` (upstream declared nothing) means undefined, nothing is injected.
 * - `automatic` means undefined, deferring to the upstream `default_reasoning_level`, which is a
 *   better choice than picking one for the user.
 * - Other levels walk the candidate order and take the first one upstream recognizes, so a
 *   model offering fewer levels than the product still lands on a valid one instead of silently
 *   sending nothing.
 */
export function codexReasoningEffort(
  mode: string | undefined,
  declaredLevels: readonly string[],
): string | undefined {
  if (declaredLevels.length === 0) return undefined;
  const declared = new Set(declaredLevels.map((level) => level.toLowerCase()));
  let candidates: string[];
  switch (mode) {
    case 'fast':
      candidates = ['low', 'minimal', 'medium'];
      break;
    case 'balanced':
      candidates = ['medium', 'low', 'high'];
      break;
    case 'deep':
      candidates = ['high', 'medium'];
      break;
    case 'max':
      candidates = ['xhigh', 'high', 'medium'];
      break;
    default:
      // 'automatic' and any unknown level defer to the upstream default rather than guessing for the user.
      return undefined;
  }
  return candidates.find((candidate) => declared.has(candidate));
}

/**
 * Build the outbound Codex `/responses` body.
 *
 * Six hard constraints; missing any one of them can get the request rejected:
 * 1. `store` must be false, Codex explicitly rejects `store:true`
 * 2. `stream:true`
 * 3. the system prompt goes into `instructions` only, never as an input message
 * 4. `include: ["reasoning.encrypted_content"]`, the prerequisite for resuming reasoning across turns
 * 5. web search = **user intent and upstream declaration**; if either is missing, no `tools`
 * 6. the thinking level is only taken from the set upstream declares (see `codexReasoningEffort`)
 *
 * This is **self-contained and separate** from the API-key Responses builder: that one is keyed
 * on models in the metadata catalog (capability recipes, previous_response_id, 400 self-healing,
 * chat-completions fallback), and subscription models are not in it.
 */
export interface BuildCodexResponsesBodyInput {
  modelID: string;
  /** Input array already arranged per the Responses schema (reusing the existing openai-responses builder). */
  input: unknown[];
  systemPrompt?: string;
  /** The user turned the web search switch on for this turn. */
  webSearchRequested?: boolean;
  /** Upstream declares web search for this model. Both this and the user intent must hold before tools are added. */
  webSearchDeclared?: boolean;
  reasoningMode?: string;
  /** Levels upstream declares for this model; empty means no effort is injected. */
  declaredReasoningLevels?: readonly string[];
}

export function buildCodexResponsesBody(
  input: BuildCodexResponsesBodyInput,
): Record<string, unknown> {
  const body: Record<string, unknown> = {
    model: input.modelID,
    input: input.input,
    stream: true,
    // Codex rejects store:true; this is a hard constraint, not a tunable.
    store: false,
    // Encrypted reasoning has to be included explicitly or the next turn cannot resume it.
    include: ['reasoning.encrypted_content'],
  };

  const systemPrompt = input.systemPrompt?.trim();
  if (systemPrompt) body.instructions = systemPrompt;

  // Web search: user intent and upstream declaration. If either is missing, do not add the tool, since sending tools upstream never declared gets the whole request rejected.
  if (input.webSearchRequested === true && input.webSearchDeclared === true) {
    body.tools = [{ type: 'web_search' }];
  }

  const effort = codexReasoningEffort(input.reasoningMode, input.declaredReasoningLevels ?? []);
  if (effort) {
    // summary:'auto' is what the Codex backend accepts, and it emits reasoning summary deltas accordingly.
    body.reasoning = { effort, summary: 'auto' };
  }

  return body;
}

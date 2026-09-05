/**
 * Grok subscription sign-in: config resolution plus the pure device-code flow logic.
 *
 * **The client runs the flow, it does not hold the knowledge.** Endpoints, client id, scopes,
 * required headers and the on/off switch all come from the bundled provider config at
 * `providerConfigs[grok].protocolFeatures.subscriptionAuth`.
 *
 * That is not fastidiousness: the xAI CLI proxy chain shipped several breaking changes during
 * 2026-05 and the `x-grok-client-version` floor was raised more than once - a missing or too-low
 * value is an immediate HTTP 426. Hard-coding these values into the client buys a time bomb that
 * can only be defused by shipping a new release.
 *
 * Everything here is a pure function (no fetch, no storage, no DOM), so the browser, the Next
 * route handler and the Electron main process share one set of rules.
 */

/** Every parameter one subscription request needs. URLs are already joined here, so the outbound side cannot get them wrong. */
export interface GrokSubscriptionAuthConfig {
  clientId: string;
  scopes: string;
  deviceAuthorizationEndpoint: string;
  tokenEndpoint: string;
  /** Optional: without it, credentials are just dropped locally. One missing optional endpoint must not disable the whole flow. */
  revocationEndpoint?: string;
  trustedVerificationHosts: string[];
  resourceBaseURL: string;
  /** Headers that must be sent verbatim (e.g. `x-grok-client-version`). Both keys and values come from the config. */
  requiredHeaders: Record<string, string>;
  modelsPath: string;
  chatPath: string;
  responsesPath: string;
  apiBackend?: string;
  /**
   * Full URL of the subscription catalog.
   *
   * **The official catalog cannot stand in for it**: as of 2026-08-19 this chain only accepts
   * `grok-4.6` / `grok-4.5`, while the official catalog carries `grok-4.3` / `grok-code-fast-1`.
   */
  modelsURL: string;
  /**
   * Full URL of the subscription chat endpoint.
   *
   * Must be configured together with `resourceBaseURL`, and **must not reuse the values from
   * `providers.grok.transport`**: there `baseUrl` is `https://api.x.ai` with path
   * `/v1/chat/completions`, whereas this base already carries `/v1`. Swapping the base but not
   * the path yields `.../v1/v1/chat/completions` and a 404 from upstream.
   */
  chatURL: string;
  responsesURL: string;
  pollIntervalSeconds: number;
  pollTimeoutSeconds: number;
}

/**
 * Whether subscription sign-in is usable on this client.
 *
 * Three states rather than a boolean: "not configured" and "turned off on purpose" are different
 * things to the user. The first should show nothing at all (old config, missing snapshot); the
 * second must tell already-connected users why, instead of failing silently.
 */
export type GrokSubscriptionAvailability =
  | { state: 'available'; config: GrokSubscriptionAuthConfig }
  | { state: 'disabled'; notice?: string }
  | { state: 'unavailable' };

export interface ResolveGrokSubscriptionOptions {
  /** Current client version; defaults to '0.0.0'. */
  appVersion?: string;
  /** Which platform key to look up in `minAppVersion`. A missing key means no gate. */
  platform?: string;
}

const DEFAULT_MODELS_PATH = '/models';
const DEFAULT_CHAT_PATH = '/chat/completions';
const DEFAULT_RESPONSES_PATH = '/responses';
const DEFAULT_POLL_INTERVAL_SECONDS = 5;
const DEFAULT_POLL_TIMEOUT_SECONDS = 1800;

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

/** https, no port/user/pass, non-empty host - a URL carrying credentials or a custom port is rejected. */
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

/** The host must be on the configured allowlist - this is the gate against a tampered config redirecting users to a phishing page. */
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
 * Joins base + path.
 *
 * The base already carries `/v1` while the path is `/chat/completions`, so **neither side repeats
 * `/v1`**. Joining happens only here; the rest of the code consumes the finished `chatURL` /
 * `modelsURL`.
 */
export function joinGrokSubscriptionURL(base: string, path: string): string {
  const trimmedBase = base.replace(/\/+$/, '');
  const trimmedPath = path.startsWith('/') ? path : `/${path}`;
  return `${trimmedBase}${trimmedPath}`;
}

/**
 * Compares version numbers segment by segment. `1.2.10` > `1.2.9` (string comparison gets this
 * backwards); missing segments count as 0 when the two have different lengths.
 */
export function compareGrokVersions(lhs: string, rhs: string): number {
  const parse = (value: string): number[] =>
    value.split('.').map((segment) => {
      const digits = /^\d+/.exec(segment.trim());
      return digits ? Number(digits[0]) : 0;
    });
  const left = parse(lhs);
  const right = parse(rhs);
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const l = left[index] ?? 0;
    const r = right[index] ?? 0;
    if (l !== r) return l < r ? -1 : 1;
  }
  return 0;
}

/**
 * Parses the raw config slice into a usable configuration.
 *
 * **Lenient decoding, never throws**: any missing or invalid required field degrades to
 * `unavailable` rather than assembling a partial config. One missing endpoint is a dead-end flow,
 * and bailing out early is more honest than letting the user get stuck halfway through.
 */
export function resolveGrokSubscriptionAuth(
  raw: unknown,
  options: ResolveGrokSubscriptionOptions = {},
): GrokSubscriptionAvailability {
  if (!isRecord(raw)) return { state: 'unavailable' };

  // flow is the contract version marker: if xAI later switches authorization style (say to PKCE
  // authorization code), an old client that does not recognise the new flow should bow out
  // rather than force device-code logic onto it.
  if (readString(raw.flow) !== 'oauth_device_code') return { state: 'unavailable' };

  const disabledNotice = readString(raw.disabledNotice);
  if (raw.enabled !== true) return { state: 'disabled', notice: disabledNotice };

  const platform = options.platform ?? 'web';
  const minAppVersion = isRecord(raw.minAppVersion) ? raw.minAppVersion : undefined;
  const minimum = readString(minAppVersion?.[platform]);
  if (minimum) {
    // The version gate exists to shut out old clients with known-broken logic; letting them keep
    // hitting upstream damages the relationship with xAI. A missing platform key means no gate.
    const appVersion = readString(options.appVersion) ?? '0.0.0';
    if (compareGrokVersions(appVersion, minimum) < 0) {
      return { state: 'disabled', notice: disabledNotice };
    }
  }

  const clientId = readString(raw.clientId);
  const scopes = readString(raw.scopes);
  const resourceBaseURL = normalizedHTTPSURL(raw.resourceBaseURL);
  if (!clientId || !scopes || !resourceBaseURL) return { state: 'unavailable' };

  const trustedAuthHosts = readStringArray(raw.trustedAuthHosts);
  if (trustedAuthHosts.length === 0) return { state: 'unavailable' };

  const deviceEndpoint = trustedHTTPSURL(raw.deviceAuthorizationEndpoint, trustedAuthHosts);
  const tokenEndpoint = trustedHTTPSURL(raw.tokenEndpoint, trustedAuthHosts);
  if (!deviceEndpoint || !tokenEndpoint) return { state: 'unavailable' };

  const trustedVerificationHosts = readStringArray(raw.trustedVerificationHosts);
  if (trustedVerificationHosts.length === 0) return { state: 'unavailable' };

  const revocationEndpoint = trustedHTTPSURL(raw.revocationEndpoint, trustedAuthHosts);
  const modelsPath = normalizedPath(raw.modelsPath, DEFAULT_MODELS_PATH);
  const chatPath = normalizedPath(raw.chatPath, DEFAULT_CHAT_PATH);
  const responsesPath = normalizedPath(raw.responsesPath, DEFAULT_RESPONSES_PATH);
  const base = resourceBaseURL.toString();

  return {
    state: 'available',
    config: {
      clientId,
      scopes,
      deviceAuthorizationEndpoint: deviceEndpoint.toString(),
      tokenEndpoint: tokenEndpoint.toString(),
      ...(revocationEndpoint ? { revocationEndpoint: revocationEndpoint.toString() } : {}),
      trustedVerificationHosts,
      resourceBaseURL: base,
      requiredHeaders: readStringMap(raw.requiredHeaders),
      modelsPath,
      chatPath,
      responsesPath,
      ...(readString(raw.apiBackend) ? { apiBackend: readString(raw.apiBackend) } : {}),
      modelsURL: joinGrokSubscriptionURL(base, modelsPath),
      chatURL: joinGrokSubscriptionURL(base, chatPath),
      responsesURL: joinGrokSubscriptionURL(base, responsesPath),
      // Polling fallbacks come from the RFC 8628 recommendation and observed xAI device-code
      // responses, and are only used when the config omits them; an interval returned by upstream
      // wins (see the slow_down handling).
      pollIntervalSeconds: readPositiveInt(raw.pollIntervalSeconds, DEFAULT_POLL_INTERVAL_SECONDS, 1),
      pollTimeoutSeconds: readPositiveInt(raw.pollTimeoutSeconds, DEFAULT_POLL_TIMEOUT_SECONDS, 60),
    },
  };
}

/**
 * Whether the authorization page link falls inside a trusted host.
 *
 * `verification_uri_complete` in the device-code response comes from upstream, not from our own
 * config, so calling `window.open` on it directly lets upstream decide which domain the user lands
 * on. Checking it against the configured allowlist closes the "tampered config -> phishing
 * redirect" path.
 */
export function allowsGrokVerificationURL(
  config: Pick<GrokSubscriptionAuthConfig, 'trustedVerificationHosts'>,
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
 * Failure semantics of the subscription chain.
 *
 * The four classes call for completely different recovery actions. Reporting a blanket "network
 * error" would present "your subscription tier is not supported" as our own fault and point the
 * user in the wrong direction.
 */
export type GrokSubscriptionErrorKind =
  /** Upstream is still waiting for the user to approve in the browser - a normal interim state, keep polling. */
  | 'authorizationPending'
  /** Upstream considers our polling too fast and requires a longer interval (RFC 8628). */
  | 'slowDown'
  /** The device code passed `expires_in` without being authorized. */
  | 'codeExpired'
  /** The user declined on the authorization page. */
  | 'accessDenied'
  /** HTTP 426: client version is below the current xAI floor. **The only early signal that xAI changed something.** */
  | 'clientVersionRejected'
  /** HTTP 403: the account is not on the allowlist, or its subscription tier does not allow third-party apps. Not our fault, do not retry. */
  | 'subscriptionNotEligible'
  /** HTTP 401: token is invalid. Refresh once automatically; only ask for a fresh sign-in if that fails. */
  | 'unauthorized'
  /** HTTP 429: this week's usage pool is exhausted. Do not retry. */
  | 'quotaExhausted'
  /** Config missing or invalid, including a failed host allowlist check. */
  | 'configurationUnavailable'
  /** Catalog fetch failed: clear the list and say so, rather than leaving a dead official catalog behind. */
  | 'catalogUnavailable'
  /** Upstream returned a catalog but filtering left no usable model - the recovery action is the opposite of "catalog fetch failed", so the two must not be merged. */
  | 'catalogEmpty'
  | 'transport'
  | 'upstream';

/**
 * Translates HTTP status code + OAuth error code into an explicit meaning.
 *
 * Upstream expresses the interim device-code states (pending / slow_down) as **400 plus an error
 * code**, so the status code alone is not enough - reading only the 400 would treat "the user has
 * not approved yet" as a permanent failure and the flow could never complete.
 */
export function mapGrokSubscriptionFailure(status: number, body: string): GrokSubscriptionErrorKind {
  let code: string | undefined;
  try {
    const parsed = JSON.parse(body) as unknown;
    if (isRecord(parsed)) code = readString(parsed.error)?.toLowerCase();
  } catch {
    code = undefined;
  }
  switch (code) {
    case 'authorization_pending':
      return 'authorizationPending';
    case 'slow_down':
      return 'slowDown';
    case 'expired_token':
      return 'codeExpired';
    case 'access_denied':
      return 'accessDenied';
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
 * Whether trying again could plausibly succeed.
 *
 * Only failures where a retry can actually work deserve a retry button: an unsupported subscription
 * tier is a dead end, and offering a button there only makes the user click it in vain.
 */
export function grokSubscriptionErrorAllowsRetry(kind: GrokSubscriptionErrorKind): boolean {
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
 * Whether the failure signals that xAI changed something.
 *
 * 426 is the only early signal: receiving it means the configured client version is already below
 * the upstream floor. Besides showing a notice, the config must be force-refreshed immediately -
 * the cached snapshot has a 24h TTL and otherwise only refreshes in the background, so users would
 * wait up to a day after the config is fixed.
 */
export function grokSubscriptionErrorRequiresConfigRefresh(
  kind: GrokSubscriptionErrorKind,
): boolean {
  return kind === 'clientVersionRejected';
}

/** Upstream response to one device-code authorization request. */
export interface GrokDeviceAuthorization {
  deviceCode: string;
  userCode: string;
  /** Authorization page URL with the short code already in the query, so the user does not have to copy the 8 digits by hand. */
  verificationURL: string;
  expiresIn: number;
  /** Polling interval requested by upstream; falls back to the configured value when absent. */
  interval?: number;
}

/**
 * Decodes the device-code response and checks the authorization URL against the allowlist.
 *
 * An authorization URL outside the trusted hosts counts as config unavailable - better to do
 * nothing than to send the user to an unknown domain.
 */
export function decodeGrokDeviceAuthorization(
  payload: unknown,
  config: GrokSubscriptionAuthConfig,
): GrokDeviceAuthorization | null {
  if (!isRecord(payload)) return null;
  const deviceCode = readString(payload.device_code);
  const userCode = readString(payload.user_code);
  const verification =
    readString(payload.verification_uri_complete) ?? readString(payload.verification_uri);
  if (!deviceCode || !userCode || !verification) return null;
  if (!allowsGrokVerificationURL(config, verification)) return null;
  const expiresIn =
    typeof payload.expires_in === 'number' && Number.isFinite(payload.expires_in)
      ? Math.trunc(payload.expires_in)
      : config.pollTimeoutSeconds;
  const interval =
    typeof payload.interval === 'number' && Number.isFinite(payload.interval)
      ? Math.max(1, Math.trunc(payload.interval))
      : undefined;
  return {
    deviceCode,
    userCode,
    verificationURL: verification,
    expiresIn,
    ...(interval !== undefined ? { interval } : {}),
  };
}

/** Subscription credentials held on this device. **Stored locally only, never synced** - same policy as API keys under BYOK. */
export interface GrokSubscriptionTokens {
  accessToken: string;
  refreshToken?: string;
  /** Upstream reports `expires_in` in seconds; it is stored as an absolute millisecond timestamp. Absent means upstream did not say, so do not refresh proactively. */
  expiresAt?: number;
  scopes?: string;
  obtainedAt: number;
}

export function decodeGrokSubscriptionTokens(
  payload: unknown,
  nowMs: number,
): GrokSubscriptionTokens | null {
  if (!isRecord(payload)) return null;
  const accessToken = readString(payload.access_token);
  if (!accessToken) return null;
  const expiresIn =
    typeof payload.expires_in === 'number' && Number.isFinite(payload.expires_in)
      ? Math.trunc(payload.expires_in)
      : undefined;
  const refreshToken = readString(payload.refresh_token);
  const scopes = readString(payload.scope);
  return {
    accessToken,
    ...(refreshToken ? { refreshToken } : {}),
    ...(expiresIn !== undefined ? { expiresAt: nowMs + expiresIn * 1000 } : {}),
    ...(scopes ? { scopes } : {}),
    obtainedAt: nowMs,
  };
}

/**
 * Whether it is time to refresh proactively.
 *
 * Refreshing 5 minutes early avoids the window where the token is still valid at check time but
 * expires just as the request reaches upstream - that shows up as random 401s instead of one
 * predictable refresh.
 */
export function grokSubscriptionTokensNeedRefresh(
  tokens: Pick<GrokSubscriptionTokens, 'expiresAt'>,
  nowMs: number,
  leewayMs = 5 * 60 * 1000,
): boolean {
  if (tokens.expiresAt === undefined) return false;
  return nowMs + leewayMs >= tokens.expiresAt;
}

/** Subscription catalog response -> list of model ids. */
export function decodeGrokSubscriptionModelIds(payload: unknown): string[] {
  if (!isRecord(payload) || !Array.isArray(payload.data)) return [];
  return payload.data
    .map((item) => (isRecord(item) ? readString(item.id) : undefined))
    .filter((id): id is string => Boolean(id));
}

/** One subscription model together with the capabilities upstream declares for it. */
export interface GrokModelDescriptor {
  id: string;
  displayName?: string;
  supportsWebSearch: boolean;
  supportsReasoning: boolean;
  reasoningEfforts: string[];
  defaultReasoningEffort?: string;
  contextWindow?: number;
  apiBackend?: string;
}

/**
 * Parses the subscription catalog together with the per-model capabilities upstream declares.
 *
 * Field names are taken from the catalog cache the grok CLI writes to disk (its origin is exactly
 * cli-chat-proxy.grok.com/v1/models and its grok_version matches the configured client version),
 * i.e. the same endpoint and the same data. The CLI reshapes the response, so which level a field
 * sits at is uncertain - everything is therefore read optionally and anything missing degrades to
 * "not declared". A degraded entry behaves exactly like an id-only entry, so it is never worse,
 * and once upstream starts sending a field it takes effect automatically without a client change.
 *
 * The filter is **deliberately lenient** (hidden !== true && supported_in_api !== false): requiring
 * the fields to be truthy would filter the whole catalog to empty the moment one is absent, which
 * is a far worse regression than missing capabilities.
 */
/** How many models this upstream response declares, before filtering. Used only to tell "catalog fetch failed" apart from "everything was filtered out". */
export function countGrokSubscriptionModelsInPayload(payload: unknown): number {
  return decodeGrokSubscriptionModelIds(payload).length;
}

export function decodeGrokSubscriptionModelDescriptors(payload: unknown): GrokModelDescriptor[] {
  if (!isRecord(payload) || !Array.isArray(payload.data)) return [];
  const descriptors: GrokModelDescriptor[] = [];
  for (const raw of payload.data) {
    if (!isRecord(raw)) continue;
    const id = readString(raw.id);
    if (!id) continue;
    if (raw.hidden === true) continue;
    if (raw.supported_in_api === false) continue;

    const efforts = Array.isArray(raw.reasoning_efforts)
      ? raw.reasoning_efforts
          .map((entry) => (isRecord(entry) ? readString(entry.value) : undefined))
          .filter((value): value is string => Boolean(value))
      : [];
    const defaultEffort = Array.isArray(raw.reasoning_efforts)
      ? raw.reasoning_efforts
          .map((entry) => (isRecord(entry) && entry.default === true ? readString(entry.value) : undefined))
          .find((value): value is string => Boolean(value))
      : undefined;

    descriptors.push({
      id,
      displayName: readString(raw.name),
      supportsWebSearch: raw.supports_backend_search === true,
      // Either source being true means supported: some models only send supports_reasoning_effort, others only the list.
      supportsReasoning: raw.supports_reasoning_effort === true || efforts.length > 0,
      reasoningEfforts: efforts,
      defaultReasoningEffort: defaultEffort,
      contextWindow: typeof raw.context_window === 'number' ? raw.context_window : undefined,
      apiBackend: readString(raw.api_backend),
    });
  }
  return descriptors;
}

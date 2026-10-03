/**
 * Remote MCP authorization.
 *
 * Covers: discovery from a 401 `WWW-Authenticate` (RFC 9728, including the `resource` check), authorization
 * server metadata (RFC 8414, with strict issuer validation), the three client registration tiers (CIMD /
 * DCR / neither supported -> an access token is needed), PKCE (S256), a mandatory `state`, `resource`
 * (RFC 8707) on both requests, the 2x2 `iss` check (RFC 9207), the token exchange, refresh, and
 * serialization of concurrent refreshes for the same server.
 *
 * Network access goes through the injected `McpTransport` (web: discovery and the token exchange are
 * forwarded by this site too, since authorization servers usually do not allow cross-origin requests);
 * the browser authorization page goes through the injected `McpAuthorizationLauncher` (web: a new window
 * plus a BroadcastChannel handoff from the callback page).
 * This file does not depend on any UI.
 */

import { genPkce, genState } from '../auth/oauth-pkce';
import {
  McpCredentialPersistenceError,
  type McpAccessCredentials,
  type McpCredentialStore,
  type McpCredentials,
} from './mcp-credentials';
import { isJsonObject, parseJsonLimited } from './mcp-json';
import { sha256Bytes } from './mcp-pure';
import {
  MCP_MAX_AUTH_RESPONSE_BYTES,
  McpTransportError,
  isHttpsUrl,
  isSameOrigin,
  readBodyText,
  tryParseUrl,
  type McpTransport,
} from './mcp-transport';
import type { JsonValue } from './mcp-types';
import type { McpAuthChallenge } from './mcp-www-authenticate';

// -- Client identity: the client metadata document and the redirect URI ---

export const MCP_CLIENT_NAME = 'Oriveo';
export const MCP_OAUTH_CALLBACK_PATH = '/mcp/oauth/callback';
export const MCP_CLIENT_METADATA_DOCUMENT_PATH = '/oauth/mcp-client.json';

/**
 * How this client identifies itself to an authorization server: the redirect URI, the redirect URIs to
 * register through DCR, and the CIMD document URL.
 *
 * There is no built-in identity. The app is self-hosted, so the identity is always derived from the origin
 * it is served from (`mcpWebClientIdentity`): a redirect URI fixed to some other domain would send the
 * authorization code there, and this page would wait for a callback that never arrives.
 */
export interface McpClientIdentity {
  /** Redirect URI used in the authorization request and the token exchange. */
  redirectUri: string;
  /** Every redirect URI reported to the authorization server during DCR registration. */
  redirectUris: readonly string[];
  /**
   * The CIMD `client_id` (= the document URL). `null` = this client has no document the authorization server
   * can fetch (the current origin is not public https): skip CIMD and use DCR only; when the authorization
   * server does not support DCR the outcome is "an access token is needed".
   */
  clientMetadataDocumentUrl: string | null;
  /** DCR `application_type` (OIDC registration: `web` only accepts https redirects, `native` accepts custom schemes and loopback http). */
  applicationType: 'native' | 'web';
}

/**
 * The web identity: both the redirect URI and the CIMD `client_id` derive from the current origin.
 * `publiclyReachable` is decided by the caller (true only for public https) - the authorization server has
 * to fetch the CIMD document itself and cannot reach localhost or private addresses, so declaring one there
 * would be pointless.
 */
export function mcpWebClientIdentity(origin: string, options: { publiclyReachable: boolean }): McpClientIdentity {
  const base = origin.replace(/\/+$/, '');
  const redirectUri = `${base}${MCP_OAUTH_CALLBACK_PATH}`;
  const https = base.startsWith('https://');
  return {
    redirectUri,
    redirectUris: [redirectUri],
    clientMetadataDocumentUrl: https && options.publiclyReachable ? `${base}${MCP_CLIENT_METADATA_DOCUMENT_PATH}` : null,
    applicationType: https ? 'web' : 'native',
  };
}

/** The CIMD document body: `client_id` is character for character the document URL, and the only redirect listed is this origin's callback page. */
export function mcpClientMetadataDocument(origin: string): Record<string, JsonValue> {
  const base = origin.replace(/\/+$/, '');
  return {
    client_id: `${base}${MCP_CLIENT_METADATA_DOCUMENT_PATH}`,
    client_name: MCP_CLIENT_NAME,
    redirect_uris: [`${base}${MCP_OAUTH_CALLBACK_PATH}`],
    token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
  };
}

/** DCR registration request body (RFC 7591). A client MUST specify `application_type`. */
export function dcrRegistrationBody(scope: string | null, identity: McpClientIdentity): Record<string, JsonValue> {
  const body: Record<string, JsonValue> = {
    client_name: MCP_CLIENT_NAME,
    redirect_uris: [...identity.redirectUris],
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    token_endpoint_auth_method: 'none',
    application_type: identity.applicationType,
  };
  if (scope) body.scope = scope;
  return body;
}

// -- Protected resource metadata discovery (RFC 9728) ---------------------

/** The origin with the path removed (an explicit port is kept). */
function originOf(url: URL): string {
  return `${url.protocol}//${url.host}`;
}

/** The path of a URL; the root path `/` counts as no path (WHATWG URL reports `/` even for a URL without one). */
function pathOf(url: URL): string {
  return url.pathname === '/' ? '' : url.pathname;
}

/**
 * Discovery order: prefer `resource_metadata` from `WWW-Authenticate`; without it, build the well-known
 * URLs in turn - first the one for the MCP endpoint path, then the root one.
 */
export function protectedResourceMetadataCandidates(challenge: McpAuthChallenge | null, endpoint: string): string[] {
  const result: string[] = [];
  if (challenge?.resourceMetadata) result.push(challenge.resourceMetadata);
  const url = tryParseUrl(endpoint);
  if (url) {
    const path = pathOf(url);
    if (path) result.push(`${originOf(url)}/.well-known/oauth-protected-resource${path}`);
    result.push(`${originOf(url)}/.well-known/oauth-protected-resource`);
  }
  return [...new Set(result)];
}

/** Canonical URI (RFC 8707): lowercase scheme and host, no fragment, no trailing slash. */
export function canonicalResourceUri(endpoint: string): string {
  const url = tryParseUrl(endpoint);
  if (!url) return endpoint;
  let path = url.pathname;
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  if (path === '/') path = '';
  return `${url.protocol}//${url.host}${path}${url.search}`;
}

/**
 * Whether the `resource` in protected resource metadata corresponds to the endpoint we requested (RFC 9728
 * section 3.3): same origin, and the path equals the endpoint path or is one of its parent path segments.
 * Missing, non-https, or carrying a query string or fragment without being the endpoint itself: no match.
 */
export function resourceCoversEndpoint(resource: string | null | undefined, endpoint: string): boolean {
  if (!resource) return false;
  const resourceUrl = tryParseUrl(resource);
  const endpointUrl = tryParseUrl(endpoint);
  if (!resourceUrl || !endpointUrl || !isHttpsUrl(resourceUrl)) return false;
  if (canonicalResourceUri(resource) === canonicalResourceUri(endpoint)) return true;
  if (!isSameOrigin(resourceUrl, endpointUrl) || resourceUrl.search || resourceUrl.hash) return false;
  const base = pathOf(resourceUrl).replace(/\/$/, '');
  return base === '' || endpointUrl.pathname === base || endpointUrl.pathname.startsWith(`${base}/`);
}

interface ProtectedResourceMetadata {
  resource: string | null;
  authorizationServers: string[];
  scopesSupported: string[];
}

function parseProtectedResourceMetadata(json: JsonValue | undefined): ProtectedResourceMetadata | null {
  if (!isJsonObject(json)) return null;
  const servers = stringArray(json.authorization_servers);
  if (servers.length === 0) return null;
  return {
    resource: typeof json.resource === 'string' ? json.resource : null,
    authorizationServers: servers,
    scopesSupported: stringArray(json.scopes_supported),
  };
}

// -- Authorization server metadata (RFC 8414) -----------------------------

/** Two or three well-known URLs in an order that depends on whether the issuer has a path. */
export function authorizationServerMetadataCandidates(issuer: string): string[] {
  const url = tryParseUrl(issuer);
  if (!url) return [];
  const origin = originOf(url);
  const path = pathOf(url);
  if (path) {
    return [
      `${origin}/.well-known/oauth-authorization-server${path}`,
      `${origin}/.well-known/openid-configuration${path}`,
      `${origin}${path}/.well-known/openid-configuration`,
    ];
  }
  return [`${origin}/.well-known/oauth-authorization-server`, `${origin}/.well-known/openid-configuration`];
}

export interface McpAuthorizationServerMetadata {
  issuer: string;
  authorizationEndpoint: string | null;
  tokenEndpoint: string | null;
  registrationEndpoint: string | null;
  scopesSupported: string[];
  clientIdMetadataDocumentSupported: boolean;
  authorizationResponseIssParameterSupported: boolean;
  codeChallengeMethodsSupported: string[];
}

export function parseAuthorizationServerMetadata(json: JsonValue | undefined): McpAuthorizationServerMetadata | null {
  if (!isJsonObject(json) || typeof json.issuer !== 'string' || json.issuer.length === 0) return null;
  return {
    issuer: json.issuer,
    // Authorization / token / registration endpoints must be https; anything else is treated as absent, and the flow cannot proceed from there.
    authorizationEndpoint: httpsOrNull(json.authorization_endpoint),
    tokenEndpoint: httpsOrNull(json.token_endpoint),
    registrationEndpoint: httpsOrNull(json.registration_endpoint),
    scopesSupported: stringArray(json.scopes_supported),
    clientIdMetadataDocumentSupported: json.client_id_metadata_document_supported === true,
    authorizationResponseIssParameterSupported: json.authorization_response_iss_parameter_supported === true,
    codeChallengeMethodsSupported: stringArray(json.code_challenge_methods_supported),
  };
}

export type McpClientRegistrationKind = 'cimd' | 'dcr';

/** Priority: pre-registration (no client has one, skipped) -> CIMD -> DCR -> `null` when neither exists (meaning "an access token is needed"; the fourth tier is deliberately skipped). */
export function decideClientRegistration(metadata: McpAuthorizationServerMetadata, cimdAvailable = true): McpClientRegistrationKind | null {
  // Skip this tier when this client has no fetchable CIMD document (the web running on localhost or a private origin).
  if (metadata.clientIdMetadataDocumentSupported && cimdAvailable) return 'cimd';
  if (metadata.registrationEndpoint) return 'dcr';
  return null;
}

/**
 * Scope selection: prefer the `scope` from the 401; otherwise use `scopes_supported` from the protected
 * resource metadata; add `offline_access` when the authorization server's `scopes_supported` lists it.
 */
export function resolveScope(challengeScope: string | null | undefined, resourceScopes: string[], serverScopes: string[]): string | null {
  const parts = challengeScope && challengeScope.trim() ? challengeScope.split(' ').filter(Boolean) : [...resourceScopes];
  if (serverScopes.includes('offline_access') && !parts.includes('offline_access')) parts.push('offline_access');
  return parts.length > 0 ? parts.join(' ') : null;
}

// -- Callback validation --------------------------------------------------

export type McpCallbackRejectionReason =
  | 'state_mismatch'
  | 'iss_missing_while_declared_supported'
  | 'iss_mismatch'
  | 'iss_mismatch_trailing_slash_not_normalized'
  | 'redirect_uri_mismatch'
  | 'authorization_error'
  | 'missing_code';

export type McpCallbackValidation = { accepted: true; code: string } | { accepted: false; reason: McpCallbackRejectionReason };

/** The callback URL must be the one we registered (compares scheme / host / path, ignores the query string). */
export function redirectUriMatches(callbackUrl: string, registered: string): boolean {
  const callback = tryParseUrl(callbackUrl);
  const expected = tryParseUrl(registered);
  if (!callback || !expected) return false;
  return callback.protocol === expected.protocol && callback.host === expected.host && callback.pathname === expected.pathname;
}

/**
 * Validates `iss` against the 2x2 table in RFC 9207 section 2.4, **with no normalization before comparing**.
 * When `iss` does not match, `error` / `error_description` are not trusted, which is why the `error` check
 * comes after the `iss` check.
 */
export function validateAuthorizationCallback(input: {
  params: Record<string, string>;
  expectedState: string;
  expectedIssuer: string;
  issParameterSupported: boolean;
  callbackUrl?: string | null;
  registeredRedirectUri?: string | null;
}): McpCallbackValidation {
  if (input.callbackUrl && input.registeredRedirectUri && !redirectUriMatches(input.callbackUrl, input.registeredRedirectUri)) {
    return { accepted: false, reason: 'redirect_uri_mismatch' };
  }
  if (input.params.state !== input.expectedState) return { accepted: false, reason: 'state_mismatch' };
  const iss = Object.hasOwn(input.params, 'iss') ? input.params.iss : undefined;
  if (input.issParameterSupported && iss === undefined) return { accepted: false, reason: 'iss_missing_while_declared_supported' };
  if (iss !== undefined && iss !== input.expectedIssuer) {
    return {
      accepted: false,
      reason: iss === `${input.expectedIssuer}/` ? 'iss_mismatch_trailing_slash_not_normalized' : 'iss_mismatch',
    };
  }
  if (input.params.error !== undefined) return { accepted: false, reason: 'authorization_error' };
  const code = input.params.code;
  if (!code) return { accepted: false, reason: 'missing_code' };
  return { accepted: true, code };
}

// -- Token response -------------------------------------------------------

/** Lifetime cap: ten years (absurdly large values are clamped so the expiry time stays representable). */
const MAX_EXPIRES_IN_SECONDS = 10 * 365 * 24 * 3600;

export interface McpTokenResponse {
  accessToken: string;
  /** Seconds. Non-positive values are treated as absent (otherwise every call would see "about to expire" and refresh). */
  expiresIn: number | null;
  /** MUST NOT assume a refresh token is always returned. */
  refreshToken: string | null;
}

export function parseTokenResponse(json: JsonValue | undefined): McpTokenResponse | null {
  if (!isJsonObject(json) || typeof json.access_token !== 'string' || json.access_token.length === 0) return null;
  // We only ever send `Authorization: Bearer`; a token the server explicitly labels as another type (DPoP, MAC, ...) cannot be used as a Bearer token.
  if (typeof json.token_type === 'string' && json.token_type.toLowerCase() !== 'bearer') return null;
  const expires = typeof json.expires_in === 'number' && Number.isFinite(json.expires_in) && json.expires_in > 0
    ? Math.min(json.expires_in, MAX_EXPIRES_IN_SECONDS)
    : null;
  return {
    accessToken: json.access_token,
    expiresIn: expires,
    refreshToken: typeof json.refresh_token === 'string' && json.refresh_token.length > 0 ? json.refresh_token : null,
  };
}

// -- Request construction (pure functions, replayed against fixtures) -----

export function buildAuthorizationUrl(input: {
  authorizationEndpoint: string;
  clientId: string;
  redirectUri: string;
  state: string;
  codeChallenge: string;
  resource: string;
  scope: string | null;
}): string {
  const url = new URL(input.authorizationEndpoint);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', input.clientId);
  url.searchParams.set('redirect_uri', input.redirectUri);
  url.searchParams.set('state', input.state);
  url.searchParams.set('code_challenge', input.codeChallenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('resource', input.resource);
  if (input.scope) url.searchParams.set('scope', input.scope);
  return url.toString();
}

/** Token exchange form: `resource` MUST be present, `code_verifier` matches S256. */
export function tokenExchangeForm(input: { code: string; clientId: string; redirectUri: string; codeVerifier: string; resource: string }): Array<[string, string]> {
  return [
    ['grant_type', 'authorization_code'],
    ['code', input.code],
    ['redirect_uri', input.redirectUri],
    ['client_id', input.clientId],
    ['code_verifier', input.codeVerifier],
    ['resource', input.resource],
  ];
}

/** Refresh form: `resource` MUST be present. */
export function refreshTokenForm(input: { refreshToken: string; clientId: string; resource: string }): Array<[string, string]> {
  return [
    ['grant_type', 'refresh_token'],
    ['refresh_token', input.refreshToken],
    ['client_id', input.clientId],
    ['resource', input.resource],
  ];
}

// -- Injection points -----------------------------------------------------

/** Source of randomness (the web injects `crypto.getRandomValues`, tests inject fixed values). core never touches the global crypto. */
export interface McpRandomPort {
  randomBytes(count: number): Uint8Array;
}

/**
 * The browser authorization page. Opens the authorization URL and waits for the callback page to hand back
 * the query parameters (web: a new window plus `listenForMcpOauthCallback`). Throws when the user closes
 * the window or gives up. When known, `callbackUrl` is handed back too, to check that the callback URL is
 * the one we registered.
 */
export interface McpAuthorizationLauncher {
  open(request: { url: string; state: string; redirectUri: string; signal?: AbortSignal }): Promise<{
    params: Record<string, string>;
    callbackUrl?: string | null;
  }>;
}

// -- Errors ---------------------------------------------------------------

export type McpAuthorizerErrorKind =
  /** The client cannot be registered automatically; the flow goes to "an access token is needed". */
  | 'not_auto_registerable'
  | 'registration_failed'
  /** The authorization server rejected the registration (`invalid_client` / `unauthorized_client`); the locally cached DCR registration has been cleared. */
  | 'client_rejected'
  /** Authorization server metadata is **definitely** unavailable (all 404 / not JSON / issuer validation failed). */
  | 'metadata_unavailable'
  /** Could not connect this time (network, timeout, 5xx, 429, 408). **Transient**; must not be used as a reason to demand a new sign-in. */
  | 'temporarily_unavailable'
  /** The callback was rejected. Carries no text from the server. */
  | 'callback_rejected'
  | 'token_request_failed'
  | 'no_refresh_token'
  /** The credentials could not be written to local storage; the caller must not treat this sign-in / refresh as persisted. */
  | 'credential_persistence_failed'
  | 'cancelled';

export class McpAuthorizerError extends Error {
  readonly kind: McpAuthorizerErrorKind;
  readonly rejection: McpCallbackRejectionReason | null;
  constructor(kind: McpAuthorizerErrorKind, rejection: McpCallbackRejectionReason | null = null) {
    super(`MCP authorization failed: ${kind}${rejection ? ` (${rejection})` : ''}`);
    this.name = 'McpAuthorizerError';
    this.kind = kind;
    this.rejection = rejection;
  }

  get isTransient(): boolean {
    return this.kind === 'temporarily_unavailable';
  }
}

// -- Discovery result -----------------------------------------------------

/** The product of discovery: **only metadata has been read; nothing has been registered with the authorization server yet**. */
export interface McpAuthorizationPlan {
  issuer: string;
  authorizationEndpoint: string;
  tokenEndpoint: string;
  registrationKind: McpClientRegistrationKind;
  registrationEndpoint: string | null;
  scope: string | null;
  resource: string;
  issParameterSupported: boolean;
}

export type McpAuthDiscoveryOutcome =
  | { kind: 'ready'; plan: McpAuthorizationPlan }
  | { kind: 'needsToken' }
  | { kind: 'temporarilyUnavailable' };

/** The per-request record of one authorization attempt (verifier, issuer and state live in the same record). */
export interface McpAuthorizationAttempt {
  url: string;
  issuer: string;
  codeVerifier: string;
  state: string;
  redirectUri: string;
  clientId: string;
  registrationKind: McpClientRegistrationKind;
  tokenEndpoint: string;
  resource: string;
  issParameterSupported: boolean;
}

export interface McpClientRegistration {
  kind: McpClientRegistrationKind;
  clientId: string;
  issuer: string;
}

type Fetched<T> = { kind: 'found'; value: T } | { kind: 'absent' } | { kind: 'transient' };

const AUTH_REQUEST_TIMEOUT_MS = 60_000;
/** Refresh first when the access token is this close to expiring. */
const DEFAULT_EXPIRY_SKEW_MS = 60_000;

/** The half read back from storage -> the credential shape exposed to callers (the refresh token is not carried along). */
function withoutRefreshFlag(access: McpAccessCredentials): McpCredentials {
  const { hasRefreshToken: _flag, ...credentials } = access;
  return credentials;
}

function isTransientStatus(status: number): boolean {
  return status >= 500 || status === 429 || status === 408;
}

function isClientRejection(error: unknown): boolean {
  return error === 'invalid_client' || error === 'unauthorized_client';
}

// -- Authorizer -----------------------------------------------------------

/**
 * A mutex across execution contexts (web: `navigator.locks`, shared by every tab of the same origin). Tasks
 * under the same name run strictly one after another. Without it, serialization only holds inside this
 * instance, which is enough for a single process only (see `McpAuthorizer.refresh`).
 */
export type McpExclusiveLock = <T>(name: string, task: () => Promise<T>) => Promise<T>;

export interface McpAuthorizerOptions {
  transport: McpTransport;
  /** The default authorization page; `authorize` can take another one per call (the authorizer is a per-partition singleton, while each click opens its own window). */
  launcher?: McpAuthorizationLauncher;
  credentialStore: McpCredentialStore;
  random: McpRandomPort;
  now?: () => number;
  /** This client's identity towards authorization servers. */
  identity: McpClientIdentity;
  refreshLock?: McpExclusiveLock;
}

/**
 * The add flow uses it in three steps:
 * 1. `discover` - reads metadata only and decides whether automatic registration is possible; **no registration, no storage writes**.
 * 2. The caller shows the pre-sign-in prompt and the user consents.
 * 3. `authorize` - register (reusing the locally cached DCR registration) -> open the authorization page -> validate the callback -> exchange the token -> persist.
 */
export class McpAuthorizer {
  private readonly transport: McpTransport;
  private readonly launcher: McpAuthorizationLauncher | null;
  private readonly credentialStore: McpCredentialStore;
  private readonly random: McpRandomPort;
  private readonly now: () => number;
  private readonly identity: McpClientIdentity;
  private readonly refreshLock: McpExclusiveLock;
  /**
   * Serializes concurrent refreshes for the same server; the key is `uid:serverId`. **This table is an
   * instance field**, so the app layer must make every call site of one partition share a single authorizer;
   * across tabs, `refreshLock` does the job.
   */
  private readonly refreshes = new Map<string, Promise<McpCredentials>>();
  /** Serializes concurrent registrations for the same `uid + issuer`. */
  private readonly registrations = new Map<string, Promise<McpClientRegistration>>();

  constructor(options: McpAuthorizerOptions) {
    this.transport = options.transport;
    this.launcher = options.launcher ?? null;
    this.credentialStore = options.credentialStore;
    this.random = options.random;
    this.now = options.now ?? (() => Date.now());
    this.identity = options.identity;
    this.refreshLock = options.refreshLock ?? ((_name, task) => task());
  }

  // -- Discovery ------------------------------------------------------

  /** Discovers the authorization server and decides whether automatic registration is possible. **Sends GETs only; registers nothing and writes no storage.** */
  async discover(challenge: McpAuthChallenge | null, endpoint: string): Promise<McpAuthDiscoveryOutcome> {
    const resource = await this.fetchProtectedResourceMetadata(protectedResourceMetadataCandidates(challenge, endpoint), endpoint);
    if (resource.kind === 'absent') return { kind: 'needsToken' };
    if (resource.kind === 'transient') return { kind: 'temporarilyUnavailable' };
    // With several authorization servers, take the first https one (RFC 9728 section 7.6 leaves the choice to the client).
    const issuer = resource.value.authorizationServers.find((candidate) => {
      const url = tryParseUrl(candidate);
      return url !== null && isHttpsUrl(url);
    });
    if (!issuer) return { kind: 'needsToken' };
    const server = await this.fetchAuthorizationServerMetadata(issuer);
    if (server.kind === 'absent') return { kind: 'needsToken' };
    if (server.kind === 'transient') return { kind: 'temporarilyUnavailable' };
    const metadata = server.value;
    const registrationKind = decideClientRegistration(metadata, this.identity.clientMetadataDocumentUrl !== null);
    // An authorization server that does not declare S256 may simply ignore code_challenge: no browser sign-in, same outcome as "cannot register automatically".
    if (
      !metadata.codeChallengeMethodsSupported.includes('S256') ||
      !metadata.authorizationEndpoint ||
      !metadata.tokenEndpoint ||
      !registrationKind
    ) {
      return { kind: 'needsToken' };
    }
    return {
      kind: 'ready',
      plan: {
        issuer: metadata.issuer,
        authorizationEndpoint: metadata.authorizationEndpoint,
        tokenEndpoint: metadata.tokenEndpoint,
        registrationKind,
        registrationEndpoint: registrationKind === 'dcr' ? metadata.registrationEndpoint : null,
        scope: resolveScope(challenge?.scope, resource.value.scopesSupported, metadata.scopesSupported),
        resource: canonicalResourceUri(endpoint),
        issParameterSupported: metadata.authorizationResponseIssParameterSupported,
      },
    };
  }

  // -- Registration ---------------------------------------------------

  /**
   * Obtains the client registration on this authorization server. CIMD needs no registration; DCR checks the
   * local cache first (keyed by `uid + issuer`) and registers once, storing the result, only when nothing is
   * cached. **Call it only after the user has agreed to open the browser.**
   */
  async register(plan: McpAuthorizationPlan, uid: string): Promise<McpClientRegistration> {
    if (plan.registrationKind === 'cimd') {
      const documentUrl = this.identity.clientMetadataDocumentUrl;
      if (!documentUrl) throw new McpAuthorizerError('not_auto_registerable');
      return { kind: 'cimd', clientId: documentUrl, issuer: plan.issuer };
    }
    const cached = await this.credentialStore.loadClientRegistration(plan.issuer, uid);
    // An old registration whose redirect URIs changed (changed in a release, or opened from another origin) can no longer be used; register again.
    if (cached && sameList(cached.redirectUris, this.identity.redirectUris)) {
      return { kind: 'dcr', clientId: cached.clientId, issuer: cached.issuer };
    }
    const key = `${uid}:dcr:${plan.issuer}`;
    const existing = this.registrations.get(key);
    if (existing) return existing;
    const task = this.registerDynamically(plan, uid).finally(() => this.registrations.delete(key));
    this.registrations.set(key, task);
    return task;
  }

  private async registerDynamically(plan: McpAuthorizationPlan, uid: string): Promise<McpClientRegistration> {
    if (!plan.registrationEndpoint) throw new McpAuthorizerError('registration_failed');
    const response = await this.post(plan.registrationEndpoint, {
      contentType: 'application/json',
      body: JSON.stringify(dcrRegistrationBody(plan.scope, this.identity)),
    });
    if (isTransientStatus(response.status)) throw new McpAuthorizerError('temporarily_unavailable');
    const clientId = isJsonObject(response.json) ? response.json.client_id : undefined;
    if (response.status < 200 || response.status >= 300 || typeof clientId !== 'string' || clientId.length === 0) {
      throw new McpAuthorizerError('registration_failed');
    }
    // Client credentials are bound to the issuer and never reused across authorization servers; they are stored on this device only.
    try {
      await this.credentialStore.saveClientRegistration({ clientId, issuer: plan.issuer, redirectUris: [...this.identity.redirectUris] }, uid);
    } catch {
      throw new McpAuthorizerError('credential_persistence_failed');
    }
    return { kind: 'dcr', clientId, issuer: plan.issuer };
  }

  private async discardRejectedRegistration(clientId: string, issuer: string, uid: string): Promise<void> {
    const cached = await this.credentialStore.loadClientRegistration(issuer, uid);
    if (cached?.clientId === clientId) await this.credentialStore.deleteClientRegistration(issuer, uid);
  }

  // -- Authorization --------------------------------------------------

  /**
   * The full browser sign-in: register -> open the authorization page -> validate the callback -> exchange
   * the token -> persist. When the authorization server rejects the cached DCR registration, clear it,
   * register again and run the flow once more (only once).
   */
  async authorize(
    plan: McpAuthorizationPlan,
    serverId: string,
    uid: string,
    options: { signal?: AbortSignal; launcher?: McpAuthorizationLauncher } = {},
  ): Promise<McpCredentials> {
    const launcher = options.launcher ?? this.launcher;
    // No authorization page to open = the user has no way to sign in.
    if (!launcher) throw new McpAuthorizerError('cancelled');
    let retriesLeft = plan.registrationKind === 'dcr' ? 1 : 0;
    while (true) {
      const attempt = await this.beginAuthorization(plan, uid);
      let callback: { params: Record<string, string>; callbackUrl?: string | null };
      try {
        callback = await launcher.open({ url: attempt.url, state: attempt.state, redirectUri: attempt.redirectUri, signal: options.signal });
      } catch {
        throw new McpAuthorizerError('cancelled');
      }
      try {
        return await this.completeAuthorization(attempt, callback.params, serverId, uid, callback.callbackUrl ?? null);
      } catch (error) {
        if (error instanceof McpAuthorizerError && error.kind === 'client_rejected' && retriesLeft > 0) {
          retriesLeft -= 1;
          continue;
        }
        throw error;
      }
    }
  }

  /** Registers and builds the authorization request, leaving a per-request record. `overrides` only lets tests inject a fixed state / verifier. */
  async beginAuthorization(
    plan: McpAuthorizationPlan,
    uid: string,
    overrides: { state?: string; codeVerifier?: string } = {},
  ): Promise<McpAuthorizationAttempt> {
    const registration = await this.register(plan, uid);
    const port = { randomBytes: (n: number) => this.random.randomBytes(n), sha256: async (data: Uint8Array) => sha256Bytes(data) };
    let codeVerifier: string;
    let codeChallenge: string;
    if (overrides.codeVerifier) {
      codeVerifier = overrides.codeVerifier;
      codeChallenge = pkceChallenge(codeVerifier);
    } else {
      const pkce = await genPkce(port);
      codeVerifier = pkce.verifier;
      codeChallenge = pkce.challenge;
    }
    const state = overrides.state ?? genState(port);
    return {
      url: buildAuthorizationUrl({
        authorizationEndpoint: plan.authorizationEndpoint,
        clientId: registration.clientId,
        redirectUri: this.identity.redirectUri,
        state,
        codeChallenge,
        resource: plan.resource,
        scope: plan.scope,
      }),
      issuer: plan.issuer,
      codeVerifier,
      state,
      redirectUri: this.identity.redirectUri,
      clientId: registration.clientId,
      registrationKind: registration.kind,
      tokenEndpoint: plan.tokenEndpoint,
      resource: plan.resource,
      issParameterSupported: plan.issParameterSupported,
    };
  }

  /** The token is exchanged and persisted only after callback validation passes. Every rejection returns before the token exchange, **saving no token at all**. */
  async completeAuthorization(
    attempt: McpAuthorizationAttempt,
    params: Record<string, string>,
    serverId: string,
    uid: string,
    callbackUrl: string | null = null,
  ): Promise<McpCredentials> {
    const validation = validateAuthorizationCallback({
      params,
      expectedState: attempt.state,
      expectedIssuer: attempt.issuer,
      issParameterSupported: attempt.issParameterSupported,
      callbackUrl,
      registeredRedirectUri: attempt.redirectUri,
    });
    if (!validation.accepted) {
      // Reaching authorization_error means the callback URL, state and iss have all passed validation, so `error` can be trusted.
      if (validation.reason === 'authorization_error' && attempt.registrationKind === 'dcr' && isClientRejection(params.error)) {
        await this.discardRejectedRegistration(attempt.clientId, attempt.issuer, uid);
        throw new McpAuthorizerError('client_rejected');
      }
      throw new McpAuthorizerError('callback_rejected', validation.reason);
    }
    const response = await this.post(attempt.tokenEndpoint, {
      contentType: 'application/x-www-form-urlencoded',
      body: new URLSearchParams(
        tokenExchangeForm({
          code: validation.code,
          clientId: attempt.clientId,
          redirectUri: attempt.redirectUri,
          codeVerifier: attempt.codeVerifier,
          resource: attempt.resource,
        }),
      ).toString(),
    });
    if (isTransientStatus(response.status)) throw new McpAuthorizerError('temporarily_unavailable');
    const tokens = response.status >= 200 && response.status < 300 ? parseTokenResponse(response.json) : null;
    if (!tokens) {
      if (attempt.registrationKind === 'dcr' && isJsonObject(response.json) && isClientRejection(response.json.error)) {
        await this.discardRejectedRegistration(attempt.clientId, attempt.issuer, uid);
        throw new McpAuthorizerError('client_rejected');
      }
      throw new McpAuthorizerError('token_request_failed');
    }
    // Signing in again replaces only the OAuth fields; a token the user pasted stays untouched.
    const previous = await this.credentialStore.load(serverId, uid);
    const credentials: McpCredentials = {
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: tokens.expiresIn === null ? null : this.now() + tokens.expiresIn * 1000,
      issuer: attempt.issuer,
      clientId: attempt.clientId,
      resource: attempt.resource,
      pastedToken: previous?.pastedToken ?? null,
    };
    await this.persist(credentials, serverId, uid);
    return credentials;
  }

  // -- Refresh --------------------------------------------------------

  /**
   * Refreshes the access token. **Concurrent refreshes for the same server are serialized**: concurrent calls
   * trigger a single refresh. `temporarily_unavailable` means the connection failed this time (credentials
   * are kept as they are); only `no_refresh_token` / `token_request_failed` / `metadata_unavailable` mean the
   * user has to sign in again.
   */
  refresh(serverId: string, uid: string): Promise<McpCredentials> {
    const key = `${uid}:${serverId}`;
    const existing = this.refreshes.get(key);
    if (existing) return existing;
    const task = this.refreshExclusively(serverId, uid).finally(() => this.refreshes.delete(key));
    this.refreshes.set(key, task);
    return task;
  }

  /**
   * Refreshes only after acquiring the cross-tab lock. Another tab may already have refreshed while we waited
   * (after refresh token rotation the old one is void immediately, and exchanging it again only yields
   * `invalid_grant`): once inside the lock, **reread storage bypassing the in-memory cache**; if the access
   * token has already been replaced and is not yet expired, use it without sending a request.
   */
  private async refreshExclusively(serverId: string, uid: string): Promise<McpCredentials> {
    const observed = await this.credentialStore.load(serverId, uid);
    return this.refreshLock(`mcp-refresh:${uid}:${serverId}`, async () => {
      const fresh = await this.credentialStore.reload(serverId, uid);
      if (fresh?.accessToken && fresh.accessToken !== (observed?.accessToken ?? null) && !this.expiresSoon(fresh.expiresAt)) {
        return withoutRefreshFlag(fresh);
      }
      return this.performRefresh(serverId, uid);
    });
  }

  private expiresSoon(expiresAt: number | null | undefined, skewMs = DEFAULT_EXPIRY_SKEW_MS): boolean {
    return expiresAt != null && expiresAt - this.now() < skewMs;
  }

  /**
   * Returns a usable access token before a call: refreshes first when it is about to expire. If the refresh
   * hits a transient error while the token has in fact not expired, the current token is returned as usual;
   * if it has expired, the error is thrown (the caller treats this step as `unreachable`). Without an OAuth
   * token, the pasted token is returned.
   */
  async validAccessToken(serverId: string, uid: string, expirySkewMs = DEFAULT_EXPIRY_SKEW_MS): Promise<string | null> {
    const credentials = await this.credentialStore.load(serverId, uid);
    if (!credentials) return null;
    if (!credentials.accessToken) return credentials.pastedToken ?? null;
    const expiresAt = credentials.expiresAt;
    if (expiresAt == null || expiresAt - this.now() >= expirySkewMs || !credentials.hasRefreshToken) {
      return credentials.accessToken;
    }
    try {
      return (await this.refresh(serverId, uid)).accessToken ?? null;
    } catch (error) {
      if (error instanceof McpAuthorizerError && error.isTransient && expiresAt > this.now()) return credentials.accessToken;
      throw error;
    }
  }

  /**
   * Stores an access token the user pasted and **clears the OAuth fields at the same time** (access token,
   * refresh token, expiry, issuer, client_id, resource). `validAccessToken` prefers an OAuth access token
   * when there is one: keeping those fields would mean the freshly pasted token is never used.
   * Throws `credential_persistence_failed` when storage cannot be written.
   */
  async storePastedToken(token: string, serverId: string, uid: string): Promise<void> {
    await this.persist({ pastedToken: token }, serverId, uid);
  }

  private async performRefresh(serverId: string, uid: string): Promise<McpCredentials> {
    const existing = await this.credentialStore.reload(serverId, uid);
    // The refresh token is read only here and the reference is dropped right after use.
    const refreshToken = existing?.hasRefreshToken ? await this.credentialStore.loadRefreshToken(serverId, uid) : null;
    const issuer = existing?.issuer;
    const clientId = existing?.clientId;
    const resource = existing?.resource;
    if (!existing || !refreshToken || !issuer || !clientId || !resource) throw new McpAuthorizerError('no_refresh_token');

    const server = await this.fetchAuthorizationServerMetadata(issuer);
    if (server.kind === 'transient') throw new McpAuthorizerError('temporarily_unavailable');
    if (server.kind === 'absent' || !server.value.tokenEndpoint) throw new McpAuthorizerError('metadata_unavailable');

    const response = await this.post(server.value.tokenEndpoint, {
      contentType: 'application/x-www-form-urlencoded',
      body: new URLSearchParams(refreshTokenForm({ refreshToken, clientId, resource })).toString(),
    });
    if (isTransientStatus(response.status)) throw new McpAuthorizerError('temporarily_unavailable');
    const tokens = response.status >= 200 && response.status < 300 ? parseTokenResponse(response.json) : null;
    if (!tokens) {
      const oauthError = isJsonObject(response.json) ? response.json.error : undefined;
      if (oauthError === 'invalid_grant') {
        // Reread before writing: the refresh token we sent may have been declared void only because another
        // place (a tab without the lock) just exchanged it for a new one. When the stored refresh token is no
        // longer the one we sent, the new token is good - use it, do not wipe it.
        const stored = await this.credentialStore.loadRefreshToken(serverId, uid);
        if (stored && stored !== refreshToken) {
          const latest = await this.credentialStore.reload(serverId, uid);
          if (latest?.accessToken) return withoutRefreshFlag(latest);
          throw new McpAuthorizerError('token_request_failed');
        }
        // Refresh token void -> drop the tokens, keep the client registration (issuer / clientId / resource), move to needsAuth (fixture token.error.json).
        await this.persist({ issuer, clientId, resource, pastedToken: existing.pastedToken ?? null }, serverId, uid);
      } else if (isClientRejection(oauthError)) {
        await this.discardRejectedRegistration(clientId, issuer, uid);
      }
      throw new McpAuthorizerError('token_request_failed');
    }
    const updated: McpCredentials = {
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken ?? refreshToken,
      expiresAt: tokens.expiresIn === null ? null : this.now() + tokens.expiresIn * 1000,
      issuer,
      clientId,
      resource,
      pastedToken: existing.pastedToken ?? null,
    };
    // Persist right after a successful refresh; if the write fails, raise instead of handing out the in-memory token as if it were saved.
    await this.persist(updated, serverId, uid);
    return updated;
  }

  private async persist(credentials: McpCredentials, serverId: string, uid: string): Promise<void> {
    try {
      await this.credentialStore.save(credentials, serverId, uid);
    } catch (error) {
      if (error instanceof McpCredentialPersistenceError) throw new McpAuthorizerError('credential_persistence_failed');
      throw new McpAuthorizerError('credential_persistence_failed');
    }
  }

  // -- Internal: HTTP -------------------------------------------------

  /**
   * Metadata GET: follows same-origin https redirects only (identical on all clients; discovery requests
   * carry no credentials). A refused redirect (cross-origin, downgrade to http, too many hops) is treated as
   * "this candidate URL has no metadata": move on to the next candidate, it is not a transient error
   * (see `isDefinitiveMiss`).
   */
  private async get(url: string): Promise<{ status: number; json: JsonValue | undefined }> {
    return this.request({ url, method: 'GET', headers: { accept: 'application/json' }, redirect: 'same-origin' });
  }

  /** Token / registration POST: **never follows redirects** (the body carries the authorization code, the verifier, the refresh token). */
  private async post(url: string, input: { contentType: string; body: string }): Promise<{ status: number; json: JsonValue | undefined }> {
    try {
      return await this.request({
        url,
        method: 'POST',
        headers: { accept: 'application/json', 'content-type': input.contentType },
        body: input.body,
        redirect: 'never',
      });
    } catch (error) {
      if (error instanceof McpTransportError && error.kind === 'blocked') throw new McpAuthorizerError('token_request_failed');
      throw new McpAuthorizerError('temporarily_unavailable');
    }
  }

  private async request(input: {
    url: string;
    method: 'GET' | 'POST';
    headers: Record<string, string>;
    body?: string;
    redirect: 'same-origin' | 'never';
  }): Promise<{ status: number; json: JsonValue | undefined }> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort('timeout'), AUTH_REQUEST_TIMEOUT_MS);
    try {
      const response = await this.transport.send({ ...input, signal: controller.signal });
      const text = await readBodyText(response.body, MCP_MAX_AUTH_RESPONSE_BYTES);
      return { status: response.status, json: parseJsonLimited(text) };
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * The three outcomes of fetching metadata. "Definitely absent" and "could not connect this time" must stay
   * distinct: the former is a conclusion, the latter only a transient error. A request refused by this
   * site's policy (`blocked`, e.g. `resource_metadata` pointing outside `.well-known`) counts as "absent" and
   * the next candidate is tried - the forwarding route only lets GETs under `.well-known` through.
   */
  private async fetchProtectedResourceMetadata(candidates: string[], endpoint: string): Promise<Fetched<ProtectedResourceMetadata>> {
    let sawTransient = false;
    for (const candidate of candidates) {
      const url = tryParseUrl(candidate);
      if (!url || !isHttpsUrl(url)) continue;
      let response: { status: number; json: JsonValue | undefined };
      try {
        response = await this.get(candidate);
      } catch (error) {
        if (!isDefinitiveMiss(error)) sawTransient = true;
        continue;
      }
      if (isTransientStatus(response.status)) {
        sawTransient = true;
        continue;
      }
      const metadata = response.status === 200 ? parseProtectedResourceMetadata(response.json) : null;
      // RFC 9728 section 3.3: `resource` must correspond to the endpoint we requested, otherwise it MUST NOT
      // be used - or anyone's metadata could steer us to the authorization server of their choosing.
      if (!metadata || !resourceCoversEndpoint(metadata.resource, endpoint)) continue;
      return { kind: 'found', value: metadata };
    }
    return sawTransient ? { kind: 'transient' } : { kind: 'absent' };
  }

  private async fetchAuthorizationServerMetadata(issuer: string): Promise<Fetched<McpAuthorizationServerMetadata>> {
    const issuerUrl = tryParseUrl(issuer);
    if (!issuerUrl || !isHttpsUrl(issuerUrl)) return { kind: 'absent' };
    let sawTransient = false;
    for (const candidate of authorizationServerMetadataCandidates(issuer)) {
      let response: { status: number; json: JsonValue | undefined };
      try {
        response = await this.get(candidate);
      } catch (error) {
        if (!isDefinitiveMiss(error)) sawTransient = true;
        continue;
      }
      if (isTransientStatus(response.status)) {
        sawTransient = true;
        continue;
      }
      const metadata = response.status === 200 ? parseAuthorizationServerMetadata(response.json) : null;
      // RFC 8414 section 3.3: `issuer` MUST be **identical** to the identifier used to build the URL; reject it otherwise.
      // Raw strings are compared: `new URL(issuer).toString()` appends a trailing slash, exactly the normalization that is not allowed.
      if (!metadata || metadata.issuer !== issuer) continue;
      return { kind: 'found', value: metadata };
    }
    return sawTransient ? { kind: 'transient' } : { kind: 'absent' };
  }
}

/** A definitive miss while fetching metadata: refused by this site's policy, or the other side answered with a redirect we do not follow (cross-origin etc.). A retry gives the same result, so it is not transient. */
function isDefinitiveMiss(error: unknown): boolean {
  return error instanceof McpTransportError && (error.kind === 'blocked' || error.kind === 'redirect_rejected');
}

/** `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))` (OAuth 2.1 section 7.5.2). */
export function pkceChallenge(verifier: string): string {
  const bytes = sha256Bytes(Uint8Array.from(Array.from(verifier, (char) => char.charCodeAt(0) & 0xff)));
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function stringArray(value: JsonValue | undefined): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
}

function httpsOrNull(value: JsonValue | undefined): string | null {
  if (typeof value !== 'string') return null;
  const url = tryParseUrl(value);
  return url && isHttpsUrl(url) ? value : null;
}

function sameList(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((item, index) => item === b[index]);
}

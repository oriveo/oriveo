/**
 * Replace URL query parameters that may carry credentials with a placeholder.
 *
 * Used by:
 * - `beforeSend` / `beforeSendTransaction` / `beforeSendSpan` / `beforeBreadcrumb` in sentry.{server,edge}.config.ts
 * - `beforeSend` / `beforeSendTransaction` / `beforeSendSpan` / `beforeBreadcrumb` in instrumentation-client.ts
 *
 * The file name is historical: besides URLs, this module also removes credential request headers
 * (see isCredentialRequestHeader).
 *
 * What triggered it: the Gemini adapter used to append `?key=AIza...` to the outgoing fetch URL.
 * Sentry's default PII scrubber only filters headers such as `Authorization` and leaves non-standard
 * parameter names in the URL query alone, so a BYOK key ended up in the Sentry trace every time.
 *
 * Gemini now uses the `x-goog-api-key` header (see chat/stream/route.ts and gemini.ts), and this
 * function stays as defense in depth for any future adapter, a Relay query_key mode, or a third-party SDK default.
 */
const SENSITIVE_URL_PARAMS = [
  'key',
  'api_key',
  'apiKey',
  'apikey',
  'access_token',
  'token',
  'auth',
  'authorization',
  'password',
  'secret',
  // OAuth callback URLs (/mcp/oauth/callback?code=…&state=…&iss=…) and token parameters.
  // The callback page clears the address bar once it has read them, but the URL the page loaded
  // with may already be in a transaction or a breadcrumb. `iss` is not a secret, yet it is the
  // address of the authorization server the user connected to, which is usage data that should
  // not leave the device.
  'code',
  'state',
  'iss',
  'refresh_token',
  'id_token',
  'client_secret',
] as const;

const REDACTED = '<redacted>';
const REDACTED_RELAY_ORIGIN = 'https://<relay-direct>';
const registeredRelayOrigins: string[] = [];
const MAX_REGISTERED_RELAY_ORIGINS = 128;

/** Register only origins actually used by the browser Relay direct transport. */
export function registerRelayRequestURL(raw: string): void {
  try {
    const origin = new URL(raw).origin;
    if (registeredRelayOrigins.includes(origin)) return;
    registeredRelayOrigins.push(origin);
    if (registeredRelayOrigins.length > MAX_REGISTERED_RELAY_ORIGINS) {
      registeredRelayOrigins.shift();
    }
  } catch {
    // The endpoint policy rejects invalid URLs before this function is reached.
  }
}

export function redactRegisteredRelayOrigins(input: string): string {
  let redacted = input;
  for (const origin of registeredRelayOrigins) {
    redacted = redacted.split(origin).join(REDACTED_RELAY_ORIGIN);
  }
  return redacted;
}

// ── MCP servers this process has connected to directly ──────────────────────────────────────────
//
// Two places send requests straight to an MCP server: the browser connecting to a private-network
// server, and the server-side forward route `/api/mcp/forward` sending the upstream request to a
// public one. The SDK's fetch / http breadcrumbs and spans carry the full address. Unlike a relay,
// an MCP address is often a credential in itself (a key in a path segment or in a query parameter
// of any name), so replacing the origin is not enough: everything from the origin to the end of
// the address is replaced by a placeholder, leaving no character of the path or query string, and
// the fields on the same breadcrumb or span that hold the host name, path, query string or peer IP
// separately are removed as well.
const REDACTED_MCP_URL = 'https://<mcp-direct>';
const registeredMcpOrigins: string[] = [];
const MAX_REGISTERED_MCP_ORIGINS = 128;

/**
 * Registers the origin of a target address before the request is sent; from then on any address
 * starting with it is redacted in full before reporting. The registry is bounded (the server is a
 * long-lived process) and evicts the least recently used origin when full. Registering an origin
 * again moves it back to the end of the queue, so one that is in use is not pushed out by others.
 */
export function registerMcpDirectRequestURL(raw: string): void {
  try {
    const origin = new URL(raw).origin;
    if (origin === 'null') return;
    const existing = registeredMcpOrigins.indexOf(origin);
    if (existing === registeredMcpOrigins.length - 1 && existing !== -1) return;
    if (existing !== -1) registeredMcpOrigins.splice(existing, 1);
    registeredMcpOrigins.push(origin);
    if (registeredMcpOrigins.length > MAX_REGISTERED_MCP_ORIGINS) registeredMcpOrigins.shift();
  } catch {
    // The transport rejects an invalid address itself, so no request is ever sent for one.
  }
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function redactRegisteredMcpDirectUrls(input: string): string {
  let redacted = input;
  for (const origin of registeredMcpOrigins) {
    // The origin must be followed by the start of a path, query or fragment, or by the end of the
    // address: `https://10.0.0.5` must not swallow `https://10.0.0.50` or `https://10.0.0.5:8443`
    // (a different origin). The address ends at whitespace or a quote.
    redacted = redacted.replace(new RegExp(`${escapeRegExp(origin)}(?=[/?#\\s"'<>]|$)[^\\s"'<>]*`, 'gi'), REDACTED_MCP_URL);
  }
  return redacted;
}

/** Whether this text contains the address of a registered MCP server. */
function mentionsRegisteredMcpUrl(input: unknown): boolean {
  return typeof input === 'string' && redactRegisteredMcpDirectUrls(input) !== input;
}

/** Every redaction applied to text that may contain an address before it is reported: direct MCP addresses are replaced in full first, then the rest is handled by parameter name and relay origin. */
function redactUrlText(input: string): string {
  return redactRegisteredRelayOrigins(redactSensitiveQuery(redactRegisteredMcpDirectUrls(input)));
}

// Sensitive query parameters are replaced by regex rather than parsed with new URL(), because a
// span.description can be `"GET https://..."` or `"http.client GET https://..."` and carries prefix text.
const SENSITIVE_QUERY_PATTERN = new RegExp(
  `([?&](?:${SENSITIVE_URL_PARAMS.join('|')})=)[^&\\s"'<>]+`,
  'gi',
);

export function redactSensitiveQuery(input: string): string {
  if (!input) return input;
  return input.replace(SENSITIVE_QUERY_PATTERN, `$1${REDACTED}`);
}

/**
 * Credential request headers. They are removed from every report unconditionally, whatever the
 * route or the error type.
 *
 * Why this is done here: `onRequestError = Sentry.captureRequestError` in `instrumentation.ts`
 * puts the inbound request headers into `event.request.headers` wholesale, and the SDK only strips
 * cookie and IP headers by default. The forward routes carry credentials in request headers:
 * - `/api/mcp/forward`: `x-mcp-credential` (the user's MCP token), `x-mcp-target-url`, `x-mcp-headers`
 * - `/api/relay/forward`: `x-relay-proxy-config` (JSON containing the apiKey), `x-relay-upstream-url`
 * - the knowledge-base routes: `x-openai-api-key` / `x-openai-base-url`
 *
 * Matching by prefix rather than listing each name keeps new members of those two families safe
 * by default.
 */
const CREDENTIAL_HEADER_PREFIXES = ['x-mcp-', 'x-relay-'] as const;
const CREDENTIAL_HEADER_NAMES = new Set([
  'authorization',
  'proxy-authorization',
  'cookie',
  'x-openai-api-key',
  'x-openai-base-url',
  'x-api-key',
  'api-key',
  'x-goog-api-key',
]);
// The key prefix the SDK uses when it writes request headers into span attributes; `-` in a header name becomes `_`.
const SPAN_REQUEST_HEADER_ATTRIBUTE_PREFIX = 'http.request.header.';

export function isCredentialRequestHeader(name: string): boolean {
  const normalized = name.trim().toLowerCase().replace(/_/g, '-');
  if (CREDENTIAL_HEADER_NAMES.has(normalized)) return true;
  return CREDENTIAL_HEADER_PREFIXES.some((prefix) => normalized.startsWith(prefix));
}

/** Removes credential request headers in place (header names are case-insensitive). */
function stripCredentialRequestHeaders(headers: unknown): void {
  if (!headers || typeof headers !== 'object') return;
  const record = headers as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (isCredentialRequestHeader(key)) delete record[key];
  }
}

/** Removes span attribute keys of the form `http.request.header.<credential header>` in place. */
function stripCredentialHeaderAttributes(data: unknown): void {
  if (!data || typeof data !== 'object') return;
  const record = data as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (!key.startsWith(SPAN_REQUEST_HEADER_ATTRIBUTE_PREFIX)) continue;
    // The SDK expands cookie into `http.request.header.cookie.<name>`, so the first segment decides.
    const headerName = key.slice(SPAN_REQUEST_HEADER_ATTRIBUTE_PREFIX.length).split('.')[0];
    if (isCredentialRequestHeader(headerName)) delete record[key];
  }
}

export type RedactableSentryEvent = {
  request?: { url?: string; headers?: unknown } | undefined;
  contexts?: Record<string, unknown> | undefined;
};

/**
 * Sentry event hook: sanitizes request.url and removes credential request headers.
 *
 * Both error events (`beforeSend`) and transaction events (`beforeSendTransaction`) go through it.
 * A transaction event carries `request.headers` too, and the attributes of its root span live in
 * `contexts.trace.data`: the return value of `beforeSendSpan` for a root span is merged back into
 * the event, so deleting a key there has no effect and it has to be deleted here.
 */
export function redactSentryEvent<T extends RedactableSentryEvent>(event: T): T {
  if (event.request?.url) {
    event.request.url = redactUrlText(event.request.url);
  }
  stripCredentialRequestHeaders(event.request?.headers);
  const trace = event.contexts?.trace;
  if (trace && typeof trace === 'object') {
    stripCredentialHeaderAttributes((trace as { data?: unknown }).data);
  }
  return event;
}

// Breadcrumb fields that hold an address: fetch / xhr / server-side http use `url`, navigation uses `from` / `to`.
const BREADCRUMB_URL_FIELDS = ['url', 'from', 'to'] as const;
// Server-side http breadcrumbs split the query string and fragment out of `url` (the values keep the leading `?` / `#`).
const BREADCRUMB_QUERY_FIELDS = ['http.query', 'http.fragment'] as const;

function redactBareQuery(query: string): string {
  if (!query) return query;
  if (query.startsWith('?')) return redactSensitiveQuery(query);
  // A fragment can carry parameters as well, such as `#access_token=…` (OAuth implicit flow); treat it like a query string.
  if (query.startsWith('#')) return `#${redactSensitiveQuery(`?${query.slice(1)}`).slice(1)}`;
  return redactSensitiveQuery(`?${query}`).slice(1);
}

/**
 * Sentry breadcrumb hook. Usage: sentry.init({ beforeBreadcrumb: redactSentryBreadcrumb })
 *
 * All three runtimes (browser, Node, edge) need it: the server-side http integration records a
 * breadcrumb for every outbound request as well.
 */
export function redactSentryBreadcrumb<
  T extends { data?: Record<string, unknown> | undefined },
>(breadcrumb: T): T {
  if (!breadcrumb.data) return breadcrumb;
  const data = breadcrumb.data;
  // A request to an MCP server: once the address is redacted in full, the split-out query string and fragment must not stay as they are.
  const toMcpServer = BREADCRUMB_URL_FIELDS.some((field) => mentionsRegisteredMcpUrl(data[field]));
  for (const field of BREADCRUMB_URL_FIELDS) {
    const value = data[field];
    if (typeof value === 'string') {
      data[field] = redactUrlText(value);
    }
  }
  for (const field of BREADCRUMB_QUERY_FIELDS) {
    const value = data[field];
    if (typeof value !== 'string') continue;
    if (toMcpServer) delete data[field];
    else data[field] = redactBareQuery(value);
  }
  return breadcrumb;
}

// Span attribute keys that hold a full address (both the old and the new semantic conventions are in use).
const SPAN_URL_ATTRIBUTES = ['http.url', 'url.full', 'url', 'http.target'] as const;
// Keys that hold only a query string or fragment: the value may lack the leading `?`, in which case the `[?&]` prefix in redactSensitiveQuery misses the first parameter.
const SPAN_QUERY_ATTRIBUTES = ['http.query', 'url.query', 'http.fragment', 'url.fragment'] as const;
// On a span for a request to an MCP server, the keys that hold the host name, path, query string or
// peer address separately. With the address redacted in full these have to go, or the host name and
// a path carrying a key would leak out next to it.
const SPAN_MCP_LOCATION_ATTRIBUTES = [
  'http.target',
  'http.host',
  'http.query',
  'http.fragment',
  'net.peer.name',
  'net.peer.ip',
  'net.peer.port',
  'network.peer.address',
  'network.peer.port',
  'server.address',
  'server.port',
  'url.domain',
  'url.path',
  'url.port',
  'url.query',
  'url.fragment',
] as const;

/**
 * Sentry span hook: sanitizes the description and the attributes holding an address or query
 * string, and removes credential request header attributes.
 * Usage: sentry.init({ beforeSendSpan: redactSentrySpan })
 */
export function redactSentrySpan<
  T extends {
    description?: string | undefined;
    data?: Record<string, unknown> | undefined;
  },
>(span: T): T {
  const data = span.data;
  const toMcpServer =
    mentionsRegisteredMcpUrl(span.description) ||
    (data !== undefined && SPAN_URL_ATTRIBUTES.some((key) => mentionsRegisteredMcpUrl(data[key])));
  if (span.description) {
    span.description = redactUrlText(span.description);
  }
  if (data) {
    if (toMcpServer) {
      for (const key of SPAN_MCP_LOCATION_ATTRIBUTES) delete data[key];
    }
    for (const key of SPAN_URL_ATTRIBUTES) {
      const value = data[key];
      if (typeof value === 'string') {
        data[key] = redactUrlText(value);
      }
    }
    for (const key of SPAN_QUERY_ATTRIBUTES) {
      const value = data[key];
      if (typeof value === 'string') data[key] = redactBareQuery(value);
    }
  }
  stripCredentialHeaderAttributes(span.data);
  return span;
}

/**
 * HTTP transport for remote MCP: redirect rules, resource limits and the forwarding wire protocol.
 *
 * The protocol client and the authorizer only know `McpTransport`; they cannot tell whether a request
 * goes out directly or is forwarded through this site:
 *
 * - **Forwarded** (`createForwardMcpTransport`): public servers always go through `/api/mcp/forward`.
 *   Target URL, method, protocol headers and credential travel in `X-Mcp-*` request headers; the route
 *   hands the upstream `MCP-Session-Id` / `WWW-Authenticate` back as `X-Mcp-Session-Id` /
 *   `X-Mcp-WWW-Authenticate`, and this module restores the original names so upper layers see no
 *   difference.
 * - **Direct** (`createDirectMcpTransport`): private-network addresses are reached by the browser itself
 *   (the server cannot reach the user's intranet, and the forwarding route's SSRF guard would refuse
 *   them anyway); Node tests use it as well.
 *
 * Both paths guarantee: https only; the credential goes only into `Authorization` (direct) or
 * `X-Mcp-Credential` (forwarded) and never into the URL; redirects are followed only to the same origin
 * over https, without changing the method, at most 5 hops.
 */

export type McpHttpMethod = 'GET' | 'POST' | 'DELETE';

/** `same-origin`: follow only same-origin https redirects that keep the method (307 / 308), at most 5 hops; `never`: follow none. */
export type McpRedirectPolicy = 'same-origin' | 'never';

export interface McpHttpRequest {
  url: string;
  method: McpHttpMethod;
  /** Protocol headers (`accept` / `content-type` / `mcp-*`). **Must not** contain `authorization`: the credential goes in `credential`. */
  headers: Record<string, string>;
  body?: string;
  /** The server's token; direct sends it as `Authorization: Bearer`, forwarded puts it in `X-Mcp-Credential`. */
  credential?: string | null;
  redirect: McpRedirectPolicy;
  signal?: AbortSignal;
}

export interface McpHttpResponse {
  status: number;
  /** Header names are compared case-insensitively. */
  headers: { get(name: string): string | null };
  body: ReadableStream<Uint8Array> | null;
}

export interface McpTransport {
  send(request: McpHttpRequest): Promise<McpHttpResponse>;
  /**
   * How long (seconds) a single call to `url` over this transport can wait at most; `null` / not
   * implemented = the transport itself has no ceiling. The protocol client's call timeout is
   * `min(callTimeoutSeconds, this value)` - the transport timeout must be strictly greater than the call
   * timeout, so when the transport has a ceiling the call timeout has to give way.
   */
  callTimeoutCeilingSeconds?(url: string): number | null;
}

/**
 * The longest a client waits for one call forwarded through this site.
 *
 * A reverse proxy sits in front of the forwarding route. A typical nginx setup without a dedicated
 * `proxy_read_timeout` uses the default: 504 after 60 seconds without a byte from the upstream (Next),
 * and a CDN in front of that may cut at 100 seconds. The forwarding route has no byte to write until the
 * upstream MCP server has returned its response headers, so a call the server answers after 55 seconds
 * would be cut by the reverse proxy before it reaches us. The three layers are staggered 5 seconds
 * apart: call timeout (≤ 50) < route timeout (55) < reverse proxy (60). When the runtime configuration
 * raises `callTimeoutSeconds` above this, forwarded calls are still capped here; direct browser
 * connections (private-network servers) are not affected.
 */
export const MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS = 50;
/** How long the forwarding route waits for upstream response headers and for the next body chunk: the call-timeout ceiling plus a margin, strictly greater than any forwarded call timeout. */
export const MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS = MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS + 5;

/**
 * Kinds of transport failure:
 * - `network`: cannot connect (DNS / connection / certificate / rate limit), transient;
 * - `timeout`: the upstream did not answer in time (reported by the forwarding route);
 * - `blocked`: refused by this site's policy (private-network address, disallowed request shape),
 *   deterministic, a retry gives the same result;
 * - `redirect_rejected`: the redirect violates the redirect rules;
 * - `insecure`: the URL is not https, **not a single byte was sent**.
 */
export type McpTransportErrorKind = 'network' | 'timeout' | 'blocked' | 'redirect_rejected' | 'insecure';

export class McpTransportError extends Error {
  readonly kind: McpTransportErrorKind;
  constructor(kind: McpTransportErrorKind) {
    super(`MCP transport failure: ${kind}`);
    this.name = 'McpTransportError';
    this.kind = kind;
  }
}

export const MCP_MAX_REDIRECTS = 5;

export function isHttpsUrl(url: URL): boolean {
  return url.protocol === 'https:' && url.hostname.length > 0;
}

export function tryParseUrl(raw: string): URL | null {
  try {
    return new URL(raw);
  } catch {
    return null;
  }
}

function resolveUrl(raw: string, base: URL): URL | null {
  try {
    return new URL(raw, base);
  } catch {
    return null;
  }
}

/** Same origin = same scheme + host + port (`URL.origin` already fills in the scheme's default port). */
export function isSameOrigin(a: URL, b: URL): boolean {
  return a.origin === b.origin;
}

// ── fetch port (core never touches the global fetch) ─────────────────────

export interface McpFetchInit {
  method: string;
  headers: Record<string, string>;
  body?: string;
  signal?: AbortSignal;
  redirect: 'manual';
}

export interface McpFetchResponse {
  status: number;
  /** Browsers give an `opaqueredirect` (status 0, unreadable Location) for a 3xx under `redirect: 'manual'`. */
  type?: string;
  headers: { get(name: string): string | null };
  body: ReadableStream<Uint8Array> | null;
}

export type McpFetch = (url: string, init: McpFetchInit) => Promise<McpFetchResponse>;

function isAbort(signal: AbortSignal | undefined): boolean {
  return signal?.aborted === true;
}

async function discard(response: McpFetchResponse): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // The body of a redirect / error response does not matter.
  }
}

// ── Direct ───────────────────────────────────────────────────────────────

/**
 * Direct transport. Redirects are followed manually here (`redirect: 'manual'`) and every hop is judged
 * again: same origin, https, method preserved (301 / 302 / 303 turn a POST into a GET, and a GET to an
 * MCP endpoint either gets a 405 or leaves an SSE stream hanging). The credential is attached again on
 * every hop - the target has been confirmed same-origin, and otherwise a 401 after a same-origin 307
 * would be misreported as "sign in again".
 */
export function createDirectMcpTransport(fetchPort: McpFetch): McpTransport {
  return {
    async send(request) {
      const initial = tryParseUrl(request.url);
      if (!initial || !isHttpsUrl(initial) || initial.username || initial.password) {
        throw new McpTransportError('insecure');
      }
      const origin = initial;
      let current: URL = initial;
      for (let hop = 0; ; hop++) {
        const headers: Record<string, string> = { ...request.headers };
        if (request.credential) headers.Authorization = `Bearer ${request.credential}`;
        let response: McpFetchResponse;
        try {
          response = await fetchPort(current.toString(), {
            method: request.method,
            headers,
            body: request.method === 'POST' ? request.body : undefined,
            signal: request.signal,
            redirect: 'manual',
          });
        } catch (error) {
          if (isAbort(request.signal)) throw error;
          throw new McpTransportError('network');
        }
        if (response.type === 'opaqueredirect') {
          await discard(response);
          throw new McpTransportError('redirect_rejected');
        }
        if (response.status < 300 || response.status >= 400 || response.status === 304) {
          return { status: response.status, headers: response.headers, body: response.body };
        }
        await discard(response);
        const location = response.headers.get('location');
        const next: URL | null = location ? resolveUrl(location, current) : null;
        const allowed =
          request.redirect === 'same-origin' &&
          hop < MCP_MAX_REDIRECTS &&
          (response.status === 307 || response.status === 308) &&
          next !== null &&
          isHttpsUrl(next) &&
          !next.username &&
          !next.password &&
          isSameOrigin(origin, next);
        if (!allowed || !next) throw new McpTransportError('redirect_rejected');
        current = next;
      }
    },
  };
}

// ── Forwarded ────────────────────────────────────────────────────────────

export const MCP_FORWARD_PATH = '/api/mcp/forward';

const ERROR_SOURCE_HEADER = 'x-oriveo-error-source';

/**
 * Through this site's forwarding route. The request always reaches the route as a `POST`; the real
 * method goes in `X-Mcp-Method`.
 *
 * The route's own refusals (`X-Oriveo-Error-Source: oriveo | network`) become `McpTransportError` here
 * so upper layers do not mistake them for the upstream server's answer - otherwise a 429 from this
 * site's rate limit would read as "the server requires sign-in / is not MCP".
 *
 * `redirect: 'never'` is passed to the route as `X-Mcp-Redirect: never`: the route does not follow a
 * 3xx and answers `upstream_redirect_blocked`, which becomes `redirect_rejected` here - the same outcome
 * as on the direct path. With `same-origin` the route applies the same rules as the direct path: only
 * same-origin https 307 / 308 are followed.
 */
export function createForwardMcpTransport(input: { fetch: McpFetch; forwardPath?: string }): McpTransport {
  const forwardPath = input.forwardPath ?? MCP_FORWARD_PATH;
  return {
    callTimeoutCeilingSeconds: () => MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS,
    async send(request) {
      const target = tryParseUrl(request.url);
      if (!target || !isHttpsUrl(target) || target.username || target.password) {
        throw new McpTransportError('insecure');
      }
      const protocolHeaders: Record<string, string> = {};
      for (const [key, value] of Object.entries(request.headers)) protocolHeaders[key.toLowerCase()] = value;
      const headers: Record<string, string> = {
        'X-Mcp-Target-Url': target.toString(),
        'X-Mcp-Method': request.method,
        'X-Mcp-Headers': JSON.stringify(protocolHeaders),
      };
      if (request.credential) headers['X-Mcp-Credential'] = request.credential;
      if (request.redirect === 'never') headers['X-Mcp-Redirect'] = 'never';

      let response: McpFetchResponse;
      try {
        response = await input.fetch(forwardPath, {
          method: 'POST',
          headers,
          body: request.method === 'POST' ? request.body ?? '' : undefined,
          signal: request.signal,
          redirect: 'manual',
        });
      } catch (error) {
        if (isAbort(request.signal)) throw error;
        throw new McpTransportError('network');
      }

      const source = response.headers.get(ERROR_SOURCE_HEADER);
      if (source === 'oriveo' || source === 'network') {
        const code = await readRouteErrorCode(response);
        throw new McpTransportError(classifyRouteError(source, response.status, code));
      }
      return {
        status: response.status,
        headers: forwardedResponseHeaders(response.headers),
        body: response.body,
      };
    },
  };
}

async function readRouteErrorCode(response: McpFetchResponse): Promise<string | null> {
  try {
    const text = await readBodyText(response.body, 64 * 1024);
    const parsed = JSON.parse(text) as { code?: unknown };
    return typeof parsed.code === 'string' ? parsed.code : null;
  } catch {
    return null;
  }
}

function classifyRouteError(source: string, status: number, code: string | null): McpTransportErrorKind {
  if (source === 'network') return code === 'mcp_upstream_timeout' ? 'timeout' : 'network';
  if (code === 'upstream_redirect_blocked') return 'redirect_rejected';
  // Rate limits and concurrency caps are transient; the rest (private address, request shape, oversized request) fails the same on retry.
  if (status === 429) return 'network';
  return 'blocked';
}

/** Restores the original names of the two upstream headers the route renamed; everything else (`content-type` etc.) is read as is. */
function forwardedResponseHeaders(raw: { get(name: string): string | null }): { get(name: string): string | null } {
  return {
    get(name: string) {
      const lowered = name.toLowerCase();
      if (lowered === 'mcp-session-id') return raw.get('x-mcp-session-id');
      if (lowered === 'www-authenticate') return raw.get('x-mcp-www-authenticate');
      return raw.get(name);
    },
  };
}

// ── Route selection ──────────────────────────────────────────────────────

/**
 * Public addresses are forwarded, private ones go direct. The predicate is injected by the caller (the
 * web app reuses the relay's `shouldProxyRelayViaServer`, the same private-network test as the
 * server-side SSRF guard, which avoids the dead end "judged public → forwarded → refused by SSRF").
 */
export function createRoutingMcpTransport(input: {
  shouldForward: (url: string) => boolean;
  forward: McpTransport;
  direct: McpTransport;
}): McpTransport {
  const pick = (url: string) => (input.shouldForward(url) ? input.forward : input.direct);
  return {
    send(request) {
      return pick(request.url).send(request);
    },
    callTimeoutCeilingSeconds(url) {
      return pick(url).callTimeoutCeilingSeconds?.(url) ?? null;
    },
  };
}

// ── Reading the response body ────────────────────────────────────────────

export const MCP_MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
export const MCP_MAX_AUTH_RESPONSE_BYTES = 1024 * 1024;

export class McpBodyTooLargeError extends Error {
  constructor() {
    super('MCP response body exceeds the limit');
    this.name = 'McpBodyTooLargeError';
  }
}

/** Counts while reading and stops as soon as `limit` bytes are exceeded (no buffer-then-measure). Invalid UTF-8 becomes U+FFFD. */
export async function readBodyText(body: ReadableStream<Uint8Array> | null, limit: number): Promise<string> {
  if (!body) return '';
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let text = '';
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) throw new McpBodyTooLargeError();
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return text;
  } finally {
    reader.cancel().catch(() => {});
  }
}

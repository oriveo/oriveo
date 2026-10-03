import type { LookupAddress } from "node:dns";
import { MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS } from "@oriveo/core/mcp/mcp-transport";
import {
  assertUrlNotSsrf,
  SsrfBlockedError,
} from "../../_shared/ssrf-guard";
import { checkRateLimit, getClientIp, buildRateLimitHeaders } from "../../chat/stream/rate-limit";
import { acquireForwardSlot } from "./concurrency";
import { redactTargetURL } from "./redact-target-url";
import {
  requestUpstreamWithPinnedAddress,
  type UpstreamMethod,
  type UpstreamRequestInput,
} from "./upstream-request";

export const runtime = "nodejs";

/**
 * Server-side forwarding for remote MCP requests made from the browser.
 *
 * Third-party MCP servers rarely open CORS to a specific web origin, so a direct browser request is
 * blocked. The browser puts the target address and that server's credential in dedicated headers,
 * and the Node runtime makes the upstream request and writes the response stream back unchanged.
 *
 * The structure mirrors `api/relay/forward/route.ts`:
 * - reuses `assertUrlNotSsrf` (port allowlist + private/reserved/cloud-metadata blocklist + DNS pin)
 * - reuses the chat/stream rate limiter, counted separately under the `mcp:` namespace
 * - has the same idle and total-duration (10 min) timeouts; see `UPSTREAM_WAIT_TIMEOUT_MS` for the
 *   limit on waiting for response headers and on idleness
 *
 * Differences from the relay route:
 * 1. Only https targets are accepted; http is always rejected.
 * 2. Outbound headers are built from an allowlist: only the few MCP needs are sent, and `host` /
 *    `cookie` and the like are never forwarded.
 * 3. OAuth discovery (GET) and the token exchange (POST + form encoding) also go through here.
 * 4. The request body has a hard cap, each IP has a concurrency limit, and a client disconnect
 *    aborts the upstream request.
 *
 * ## Where credentials and bodies go
 *
 * A credential stays in Node process memory only for the duration of one request: it is never
 * written to disk or logged. Request and response bodies are not recorded either, and error messages
 * returned to the caller carry only the redacted address (`redactTargetURL`).
 *
 * "Never reaches Sentry" is not guaranteed by the absence of reporting calls in this file, because
 * the framework reports on our behalf: when the response stream is cut with `controller.error()`,
 * Next's `onRequestError` hands the whole set of inbound request headers to Sentry. The real
 * guarantee lives in `lib/sentry/`: `redactSentryEvent` unconditionally removes every `x-mcp-*`
 * request header, and `isIgnorableMcpProtectiveAbort` classifies this route's protective cuts as
 * expected noise. Check both before changing the error messages here
 * (`MCP stream …` / `MCP response …` / `MCP upstream request aborted`).
 *
 * ## Accepted residual risk: this forwarding endpoint is open
 *
 * Same stance as the relay route: the app has no accounts, so there is no identity to gate on. The
 * abuse surface (using this host's IP to reach arbitrary public https targets) is narrowed by the
 * following instead:
 * - only allowlisted ports on public https hosts are reachable; private, reserved and cloud-metadata
 *   addresses are stopped by the SSRF guard;
 * - 60 requests per minute and at most 8 concurrent per IP; request body ≤ 256 KB, response ≤ 8 MB
 *   and at most 10 minutes;
 * - only the methods and shapes MCP uses are kept:
 *   · `POST` + JSON: MCP JSON-RPC requests, and OAuth dynamic client registration;
 *   · `POST` + form encoding: only token requests carrying `grant_type`;
 *   · `GET`: only metadata discovery under `/.well-known/`, or SSE with `Accept: text/event-stream`
 *     (for the latter, a 2xx upstream response that is not an event stream is not handed back);
 *   · `DELETE`: only session termination carrying `mcp-session-id`.
 * - redirects are followed only to the same https origin; token requests never follow them, and the
 *   caller can send `X-Mcp-Redirect: never` to stop any request from following.
 * - with the outbound header allowlist and no pass-through of upstream response headers, the caller
 *   can neither smuggle in `cookie` / `host` nor obtain the upstream's `Set-Cookie`.
 * What this cannot stop: someone using it to send a JSON POST to a public MCP-shaped endpoint. That
 * is the same exposure the relay route has.
 */

const TARGET_URL_HEADER = "x-mcp-target-url";
const METHOD_HEADER = "x-mcp-method";
const CREDENTIAL_HEADER = "x-mcp-credential";
const EXTRA_HEADERS_HEADER = "x-mcp-headers";
// Redirect policy. Absent / `same-origin`: follow only same-origin https, at most 5 hops; `never`:
// follow nothing. Token requests (form + grant_type) are treated as `never` whatever the caller says:
// the body holds the authorization code, verifier and refresh token, and a 3xx must not be able to
// carry it to a different path. Registration and discovery requests declare `never` explicitly.
const REDIRECT_HEADER = "x-mcp-redirect";
const ERROR_SOURCE_HEADER = "X-Oriveo-Error-Source";
const ENDPOINT_FORBIDDEN = { error: "Endpoint blocked by server policy", code: "endpoint_forbidden" };
const REQUEST_NOT_ALLOWED = {
  error: "Request shape is not allowed for this endpoint",
  code: "mcp_request_not_allowed",
};
const MCP_UPSTREAM_TIMEOUT_CODE = "mcp_upstream_timeout";
const MCP_UPSTREAM_CONNECTION_FAILED_CODE = "mcp_upstream_connection_failed";
// MCP JSON-RPC responses are usually a few KB, and a single result fed back to the model is capped
// at 24,000 characters. 8MB is far beyond any reasonable tools/list or tools/call response; anything
// larger is treated as a misbehaving upstream. This is plain byte counting: each chunk is counted and
// enqueued immediately without buffering, and a malicious upstream is bounded by the total-duration
// timeout and the per-IP rate limit.
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
// Hard cap on the request body. A single tool's arguments are limited to 16 KB and a token request is
// a few hundred bytes; 256 KB leaves an order of magnitude of headroom while keeping this endpoint
// from being used to push large payloads at third parties.
const MAX_REQUEST_BODY_BYTES = 256 * 1024;
// The limit both for waiting on upstream response headers and for waiting on the next body chunk. It
// must be strictly greater than the client's call timeout: a `tools/call` returns no bytes at all
// until the server has finished, so with a limit shorter than the call timeout every slowish tool
// would be cut off as a "timeout". It must also be below the read timeout of the reverse proxy in
// front, otherwise the browser gets the proxy's 504 instead of our error body carrying
// `mcp_upstream_timeout`. See `MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS` for the value and reasoning.
const UPSTREAM_WAIT_TIMEOUT_MS = MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS * 1000;
const MAX_SAME_ORIGIN_REDIRECTS = 5;
const STREAM_IDLE_TIMEOUT_MS = UPSTREAM_WAIT_TIMEOUT_MS;
const STREAM_TOTAL_TIMEOUT_MS = 600_000;

const ALLOWED_METHODS = new Set(["GET", "POST", "DELETE"]);
/**
 * Allowlist (lowercase) of outbound headers the caller may set. Anything outside it is not
 * forwarded, and that means rejected outright rather than filtered out.
 *
 * `mcp-method` / `mcp-name` are required headers in the 2026-07-28 protocol revision (the former
 * MUST be on every request, the latter on `tools/call`); without them a modern server answers
 * 400 + `-32020`.
 *
 * `authorization` is deliberately absent: a credential may only come in through `x-mcp-credential`,
 * and this route turns it into `Bearer`. Letting the caller send its own `authorization` and then
 * silently dropping it would make "I sent a token and still got 401" impossible to diagnose, so it
 * is an explicit rejection.
 */
const FORWARDABLE_HEADERS = new Set([
  "accept",
  "content-type",
  "mcp-protocol-version",
  "mcp-session-id",
  "mcp-method",
  "mcp-name",
  "last-event-id",
]);
// `Mcp-Param-{Name}`: the header name is dynamic, so it is allowed by prefix. The name after the
// prefix is restricted to RFC 9110 token characters so that a dynamic header name cannot carry
// separators or control characters.
const MCP_PARAM_HEADER_PREFIX = "mcp-param-";
const MCP_PARAM_NAME_PATTERN = /^[a-z0-9!#$%&'*+.^_`|~-]{1,64}$/;
const MAX_MCP_PARAM_HEADERS = 16;
// Outbound header values: the specification requires non-ASCII values to be encoded as
// `=?base64?…?=`, so a legitimate value is only ever visible ASCII plus space / tab. CR / LF and
// other control characters are rejected (request header injection).
const HEADER_VALUE_PATTERN = /^[\t\x20-\x7e]*$/;
const MAX_HEADER_VALUE_LENGTH = 2048;
// An access token may be a JWT, which is much longer than an ordinary header value.
const MAX_CREDENTIAL_LENGTH = 8192;
// The two upstream response headers handed back to the browser (see buildClientResponseHeaders).
const SESSION_ID_RESPONSE_HEADER = "X-Mcp-Session-Id";
const WWW_AUTHENTICATE_RESPONSE_HEADER = "X-Mcp-WWW-Authenticate";
const MAX_SESSION_ID_LENGTH = 1024;
const MAX_WWW_AUTHENTICATE_LENGTH = 4096;
const JSON_CONTENT_TYPE = "application/json";
const FORM_CONTENT_TYPE = "application/x-www-form-urlencoded";
const ALLOWED_CONTENT_TYPES = new Set([JSON_CONTENT_TYPE, FORM_CONTENT_TYPE]);
const EVENT_STREAM_CONTENT_TYPE = "text/event-stream";
const DEFAULT_ACCEPT = "application/json, text/event-stream";

type UpstreamRequester = (input: UpstreamRequestInput) => Promise<Response>;

type McpForwardGlobal = typeof globalThis & {
  __oriveoMcpForwardUpstreamRequester?: UpstreamRequester;
};

export async function POST(request: Request): Promise<Response> {
  return forwardMcpRequest(request, "POST");
}

export async function GET(request: Request): Promise<Response> {
  return forwardMcpRequest(request, "GET");
}

export async function DELETE(request: Request): Promise<Response> {
  return forwardMcpRequest(request, "DELETE");
}

async function forwardMcpRequest(request: Request, fallbackMethod: UpstreamMethod): Promise<Response> {
  // Rate limit: even with the SSRF guard blocking internal targets, this endpoint still needs
  // throttling so it cannot be abused as an open proxy (hammering arbitrary public targets from this
  // host's IP). It uses its own namespace so it does not compete with the relay route for quota.
  const clientIp = getClientIp(request.headers);
  const rateOutcome = checkRateLimit(`mcp:${clientIp}`);
  if (!rateOutcome.allowed) {
    return new Response(JSON.stringify({ error: "Rate limit exceeded" }), {
      status: 429,
      headers: {
        "Content-Type": "application/json",
        [ERROR_SOURCE_HEADER]: "oriveo",
        ...buildRateLimitHeaders(rateOutcome),
        "Retry-After": String(Math.max(1, Math.ceil((rateOutcome.resetAt - Date.now()) / 1000))),
      },
    });
  }

  const releaseSlot = acquireForwardSlot(clientIp);
  if (!releaseSlot) {
    return new Response(
      JSON.stringify({ error: "Too many concurrent MCP requests", code: "mcp_too_many_concurrent_requests" }),
      {
        status: 429,
        headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo", "Retry-After": "1" },
      },
    );
  }

  // Returning the slot: any return or throw before a streaming response is obtained releases it in
  // the finally below; once the upstream stream has been handed over, the stream itself releases it
  // when it settles (fully read / errored / cancelled / timed out).
  let slotOwnedByStream = false;
  try {
    return await forwardWithSlot(request, fallbackMethod, () => {
      slotOwnedByStream = true;
      return releaseSlot;
    });
  } finally {
    if (!slotOwnedByStream) releaseSlot();
  }
}

async function forwardWithSlot(
  request: Request,
  fallbackMethod: UpstreamMethod,
  handOffSlotToStream: () => () => void,
): Promise<Response> {
  const rawTarget = request.headers.get(TARGET_URL_HEADER);
  if (!rawTarget) {
    return json({ error: "Missing X-Mcp-Target-Url header" }, 400);
  }

  let target: URL;
  try {
    target = new URL(rawTarget);
  } catch {
    return json({ error: "Invalid target URL" }, 400);
  }

  // Only https is accepted.
  if (target.protocol !== "https:") {
    return json(ENDPOINT_FORBIDDEN, 403);
  }
  if (target.username || target.password) {
    return json({ error: "Target URL userInfo is not allowed", code: "endpoint_forbidden" }, 400);
  }

  const method = resolveMethod(request.headers.get(METHOD_HEADER), fallbackMethod);
  if (!method) {
    return json({ error: "Unsupported upstream method" }, 400);
  }

  let extraHeaders: Record<string, string>;
  try {
    extraHeaders = parseExtraHeaders(request.headers.get(EXTRA_HEADERS_HEADER));
  } catch (error) {
    return json({ error: (error as Error).message }, 400);
  }

  const credential = request.headers.get(CREDENTIAL_HEADER)?.trim() ?? "";
  if (credential.length > MAX_CREDENTIAL_LENGTH || !HEADER_VALUE_PATTERN.test(credential)) {
    return json({ error: "Invalid X-Mcp-Credential header" }, 400);
  }

  const forwardedHeaders = buildUpstreamHeaders({
    credential,
    extraHeaders,
    hasBody: method === "POST",
  });
  if (!forwardedHeaders) {
    return json({ error: "Unsupported Content-Type" }, 400);
  }

  const shape = classifyRequestShape(method, target, forwardedHeaders);
  if (!shape) {
    return json(REQUEST_NOT_ALLOWED, 400);
  }

  const redirectMode = resolveRedirectMode(request.headers.get(REDIRECT_HEADER));
  if (!redirectMode) {
    return json({ error: "Invalid X-Mcp-Redirect header" }, 400);
  }
  const followRedirects = redirectMode === "same-origin" && shape !== "token";

  let body: string | undefined;
  if (method === "POST") {
    const read = await readRequestBody(request, MAX_REQUEST_BODY_BYTES);
    if (!read.ok) {
      return json({ error: "Request body is too large", code: "mcp_request_too_large" }, 413);
    }
    body = read.text;
    if (shape === "token" && !new URLSearchParams(body).get("grant_type")) {
      return json(REQUEST_NOT_ALLOWED, 400);
    }
  }

  let pinnedAddress: LookupAddress;
  try {
    // Reuse the shared SSRF guard: port allowlist + private/reserved/metadata IP blocklist + DNS pin.
    pinnedAddress = (await assertUrlNotSsrf(target)).address;
  } catch (error) {
    if (error instanceof SsrfBlockedError) return json(ENDPOINT_FORBIDDEN, 403);
    throw error;
  }

  if (request.signal.aborted) return clientClosed();

  let upstream: Response;
  let currentURL = target;
  const allowedOrigin = target.origin;
  const controller = new AbortController();
  // Client disconnect (page closed, stop pressed, fetch aborted) aborts the upstream request.
  // Otherwise the upstream request keeps running until it ends or hits the timeout; for a write tool
  // set to run automatically, that means the user pressed stop and the write happened anyway.
  const onClientAbort = () => controller.abort();
  request.signal.addEventListener("abort", onClientAbort, { once: true });
  const detachClientAbort = () => request.signal.removeEventListener("abort", onClientAbort);

  const timeout = setTimeout(() => controller.abort(), UPSTREAM_WAIT_TIMEOUT_MS);
  // Until an upstream response that can be handed back exists, every exit must detach the listener
  // on request.signal.
  let upstreamHandedOff = false;
  try {
    let redirectCount = 0;
    while (true) {
      upstream = await getUpstreamRequester()({
        url: currentURL,
        method,
        headers: forwardedHeaders,
        body,
        signal: controller.signal,
        address: pinnedAddress,
      });
      if (upstream.status < 300 || upstream.status >= 400) break;

      if (!followRedirects) {
        // No-follow mode: a 3xx is not handed back (Location may point anywhere); report it as a
        // blocked redirect.
        await cancelResponseBody(upstream);
        return json({ error: "Upstream redirects are not followed for this request", code: "upstream_redirect_blocked" }, 502);
      }

      // Follow only redirects that keep the request method (same as the direct implementation). For
      // POST / DELETE that is 307 / 308 only: 301 / 302 / 303 conventionally turn a POST into a GET,
      // and a GET to an MCP endpoint either gets 405 or leaves an SSE stream hanging, with the tool
      // arguments in the body already lost. GET (metadata discovery) is a GET anyway, so 301 / 302 /
      // 303 are followed too; plenty of real servers use them for same-origin redirects of
      // well-known addresses. Any other 3xx is not a followable redirect.
      const preservesMethod = upstream.status === 307 || upstream.status === 308
        || (method === "GET" && (upstream.status === 301 || upstream.status === 302 || upstream.status === 303));
      if (!preservesMethod) {
        await cancelResponseBody(upstream);
        return json({ error: "Upstream redirect would change the request method", code: "upstream_redirect_blocked" }, 502);
      }

      const location = upstream.headers.get("Location");
      if (!location || redirectCount >= MAX_SAME_ORIGIN_REDIRECTS) {
        await cancelResponseBody(upstream);
        return json({ error: "Upstream redirect is invalid or exceeded the limit", code: "upstream_redirect_blocked" }, 502);
      }

      let redirectedURL: URL;
      try {
        redirectedURL = new URL(location, currentURL);
      } catch {
        await cancelResponseBody(upstream);
        return json({ error: "Upstream redirect URL is invalid", code: "upstream_redirect_blocked" }, 502);
      }
      if (
        redirectedURL.origin !== allowedOrigin
        || redirectedURL.protocol !== "https:"
        || redirectedURL.username
        || redirectedURL.password
      ) {
        await cancelResponseBody(upstream);
        return json({ error: "Cross-origin upstream redirects are not allowed", code: "upstream_redirect_blocked" }, 502);
      }

      await cancelResponseBody(upstream);
      try {
        // Resolve and pin again on every hop so a redirect on the same host cannot bypass the DNS
        // rebinding protection.
        pinnedAddress = (await assertUrlNotSsrf(redirectedURL)).address;
      } catch (error) {
        if (error instanceof SsrfBlockedError) {
          return json({ error: "Redirect target blocked by server policy", code: "endpoint_forbidden" }, 403);
        }
        throw error;
      }
      currentURL = redirectedURL;
      redirectCount += 1;
    }

    // A GET that asked for SSE got a 2xx that is not an event stream: that is not an MCP notification
    // stream, so the body is not handed back. This removes "GET any public page" from what this
    // endpoint can do (non-2xx responses are still handed back, because the client relies on the
    // status code to tell 405 from 401).
    if (
      shape === "sse"
      && upstream.status >= 200
      && upstream.status < 300
      && mediaType(upstream.headers.get("Content-Type")) !== EVENT_STREAM_CONTENT_TYPE
    ) {
      await cancelResponseBody(upstream);
      controller.abort();
      return json({ error: "Upstream did not return an event stream", code: "mcp_unexpected_content_type" }, 502);
    }

    upstreamHandedOff = upstream.body !== null;
  } catch (error) {
    if (request.signal.aborted) return clientClosed();
    return json({
      error: describeFetchError(error, redactTargetURL(currentURL.toString())),
      code: controller.signal.aborted
        ? MCP_UPSTREAM_TIMEOUT_CODE
        : MCP_UPSTREAM_CONNECTION_FAILED_CODE,
    }, 502, "network");
  } finally {
    clearTimeout(timeout);
    if (!upstreamHandedOff) detachClientAbort();
  }

  const responseHeaders = buildClientResponseHeaders(upstream, currentURL);
  if (!upstream.body) {
    return new Response(null, { status: upstream.status, headers: responseHeaders });
  }

  const releaseSlot = handOffSlotToStream();
  const guarded = guardResponseBody(upstream.body, {
    abortUpstream: () => controller.abort(),
    onSettled: () => {
      detachClientAbort();
      releaseSlot();
    },
  });
  return new Response(guarded, { status: upstream.status, headers: responseHeaders });
}

/**
 * Response headers returned to the browser. Upstream headers are not passed through wholesale
 * (`Set-Cookie` would plant cookies on our own domain, and CORS headers would rewrite this site's
 * cross-origin policy); only the two the protocol needs are picked and returned under our own names:
 *
 * - `MCP-Session-Id` → `X-Mcp-Session-Id`: the session identifier of the older protocol, which the
 *   client MUST send on every subsequent request. Lose it and the second request to an older server
 *   is a 400.
 * - `WWW-Authenticate` → `X-Mcp-WWW-Authenticate`: the preferred source for authorization discovery
 *   on 401 / 403 (`resource_metadata` and `insufficient_scope`). The original name is avoided because
 *   browsers have built-in handling for it, and our response is not issuing a challenge to the
 *   browser.
 *
 * A value that is too long or contains control characters is not returned at all (a truncated
 * session identifier and a truncated challenge are both worse than none: the former can never match,
 * the latter could cut the `resource_metadata` address into a different address). The request is
 * same-origin with this route, so browser JS can read custom response headers without
 * `Access-Control-Expose-Headers`.
 */
function buildClientResponseHeaders(upstream: Response, finalURL: URL): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": upstream.headers.get("Content-Type") || "application/json",
    "Cache-Control": "no-cache, no-store",
    // The body comes from a third party and so does its `Content-Type`: do not let the browser sniff
    // the type (if someone opens this address directly, HTML declared as JSON is not rendered as a
    // page under our origin).
    "X-Content-Type-Options": "nosniff",
    "X-Mcp-Target-Url": redactTargetURL(finalURL.toString()),
    [ERROR_SOURCE_HEADER]: "provider",
  };
  const sessionId = safeResponseHeaderValue(upstream.headers.get("mcp-session-id"), MAX_SESSION_ID_LENGTH);
  if (sessionId) headers[SESSION_ID_RESPONSE_HEADER] = sessionId;
  const challenge = safeResponseHeaderValue(
    upstream.headers.get("www-authenticate"),
    MAX_WWW_AUTHENTICATE_LENGTH,
  );
  if (challenge) headers[WWW_AUTHENTICATE_RESPONSE_HEADER] = challenge;
  return headers;
}

function safeResponseHeaderValue(raw: string | null, maxLength: number): string | null {
  if (raw === null) return null;
  const value = raw.trim();
  if (!value || value.length > maxLength) return null;
  if (!HEADER_VALUE_PATTERN.test(value)) return null;
  return value;
}

async function cancelResponseBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // The body of a redirect response does not matter; a failed cancel must not bypass the redirect
    // policy.
  }
}

function resolveRedirectMode(raw: string | null): "same-origin" | "never" | null {
  if (raw === null) return "same-origin";
  const normalized = raw.trim().toLowerCase();
  return normalized === "same-origin" || normalized === "never" ? normalized : null;
}

function getUpstreamRequester(): UpstreamRequester {
  return (globalThis as McpForwardGlobal).__oriveoMcpForwardUpstreamRequester
    ?? requestUpstreamWithPinnedAddress;
}

function resolveMethod(raw: string | null, fallback: UpstreamMethod): UpstreamMethod | null {
  if (raw === null) return fallback;
  const normalized = raw.toUpperCase();
  return ALLOWED_METHODS.has(normalized) ? (normalized as UpstreamMethod) : null;
}

function mediaType(contentType: string | null | undefined): string {
  return (contentType ?? "").split(";")[0].trim().toLowerCase();
}

type RequestShape = "jsonrpc" | "token" | "discovery" | "sse" | "session-delete";

/**
 * This endpoint forwards only the few request shapes MCP uses (see "Accepted residual risk" in the
 * file header). Returns null for anything else. `token` is additionally re-checked for `grant_type`
 * once the request body has been read.
 */
function classifyRequestShape(
  method: UpstreamMethod,
  target: URL,
  upstreamHeaders: Record<string, string>,
): RequestShape | null {
  if (method === "POST") {
    return mediaType(upstreamHeaders["Content-Type"]) === FORM_CONTENT_TYPE ? "token" : "jsonrpc";
  }
  if (method === "DELETE") {
    // The only use of DELETE is terminating an older-protocol session, and it must say which one.
    return upstreamHeaders["mcp-session-id"] ? "session-delete" : null;
  }
    // GET (1): OAuth metadata discovery. All three well-known documents (protected resource /
    // authorization server / OIDC) and both path forms (inserted before the path, appended after it)
    // contain a `.well-known` path segment.
  if (target.pathname.split("/").includes(".well-known")) return "discovery";
  // GET (2): the server notification stream of the older protocol, where the client declares that it
  // accepts only an event stream.
  if (upstreamHeaders.Accept.trim().toLowerCase() === EVENT_STREAM_CONTENT_TYPE) return "sse";
  return null;
}

/**
 * Counts while reading and stops as soon as the cap is exceeded (rather than buffering the whole
 * body and measuring it afterwards). `Content-Length` is used only to reject early, never as a
 * trusted length: it may be missing, and it may lie.
 */
async function readRequestBody(
  request: Request,
  maxBytes: number,
): Promise<{ ok: true; text: string } | { ok: false }> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    await request.body?.cancel().catch(() => {});
    return { ok: false };
  }
  if (!request.body) return { ok: true, text: "" };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      return { ok: false };
    }
    chunks.push(value);
  }
  return { ok: true, text: Buffer.concat(chunks).toString("utf8") };
}

/**
 * Parses the extra outbound headers the caller wants to send. A key outside the allowlist or an
 * invalid value throws instead of being dropped silently.
 */
function parseExtraHeaders(raw: string | null): Record<string, string> {
  if (!raw) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    try {
      parsed = JSON.parse(decodeURIComponent(raw));
    } catch {
      throw new Error("Invalid X-Mcp-Headers header");
    }
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("Invalid X-Mcp-Headers header");
  }
  const out: Record<string, string> = {};
  let paramHeaderCount = 0;
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    const normalized = key.trim().toLowerCase();
    if (normalized === "authorization") {
      throw new Error("Header not allowed: authorization (send the credential in X-Mcp-Credential)");
    }
    if (normalized.startsWith(MCP_PARAM_HEADER_PREFIX)) {
      if (!MCP_PARAM_NAME_PATTERN.test(normalized.slice(MCP_PARAM_HEADER_PREFIX.length))) {
        throw new Error("Header not allowed: invalid Mcp-Param name");
      }
      paramHeaderCount += 1;
      if (paramHeaderCount > MAX_MCP_PARAM_HEADERS) {
        throw new Error("Too many Mcp-Param headers");
      }
    } else if (!FORWARDABLE_HEADERS.has(normalized)) {
      // The header name comes from the caller; cap its length before echoing it so arbitrarily long
      // input is not written into the error body as is.
      throw new Error(`Header not allowed: ${normalized.slice(0, 64)}`);
    }
    if (typeof value !== "string") {
      throw new Error(`Header value must be a string: ${normalized}`);
    }
    if (value.length > MAX_HEADER_VALUE_LENGTH || !HEADER_VALUE_PATTERN.test(value)) {
      // Report only the header name and never echo the value (it may be a tool argument).
      throw new Error(`Header value is not allowed: ${normalized}`);
    }
    if (Object.hasOwn(out, normalized)) {
      throw new Error(`Duplicate header: ${normalized}`);
    }
    out[normalized] = value;
  }
  return out;
}

function buildUpstreamHeaders(input: {
  credential: string;
  extraHeaders: Record<string, string>;
  hasBody: boolean;
}): Record<string, string> | null {
  const headers: Record<string, string> = {
    Accept: DEFAULT_ACCEPT,
  };
  // The token endpoint requires form encoding; every other MCP request is JSON.
  const contentType = input.extraHeaders["content-type"] ?? JSON_CONTENT_TYPE;
  if (!ALLOWED_CONTENT_TYPES.has(mediaType(contentType))) return null;
  // Methods without a body do not send Content-Type: sending it claims that a body follows.
  if (input.hasBody) headers["Content-Type"] = contentType;

  if (input.credential) headers.Authorization = `Bearer ${input.credential}`;

  for (const [key, value] of Object.entries(input.extraHeaders)) {
    if (key === "content-type") continue;
    if (key === "accept") {
      // Override the default instead of adding a second, lowercase `accept` next to it.
      headers.Accept = value;
      continue;
    }
    headers[key] = value;
  }
  return headers;
}

function json(
  payload: Record<string, unknown>,
  status: number,
  source: "oriveo" | "network" = "oriveo",
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", "X-Content-Type-Options": "nosniff", [ERROR_SOURCE_HEADER]: source },
  });
}

/**
 * The client is already gone and nobody reads this response; the status follows nginx's 499
 * convention so it can be told apart in access logs.
 */
function clientClosed(): Response {
  return json({ error: "Client closed request", code: "client_closed_request" }, 499);
}

/**
 * Wraps the upstream response stream in three protections (idle timeout / total duration / byte
 * cap) and guarantees that however the stream ends (fully read, upstream error, cancelled
 * downstream, cut by a protection) it settles exactly once: timers cleared, `onSettled` notified.
 *
 * A hand-written ReadableStream is used instead of a TransformStream: the latter never sees the
 * downstream cancel, so after a client disconnect both timers would stay armed until they fire (up
 * to 10 minutes) and the upstream connection would not be aborted.
 *
 * Errors thrown by a protective cut start with `MCP stream ` / `MCP response `. The Sentry filter
 * recognizes them by that prefix (`lib/sentry/ignore-relay-noise.ts`), so a wording change has to be
 * made in both places.
 */
function guardResponseBody(
  body: ReadableStream<Uint8Array>,
  hooks: { abortUpstream: () => void; onSettled: () => void },
): ReadableStream<Uint8Array> {
  const reader = body.getReader();
  let total = 0;
  let settled = false;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let totalTimer: ReturnType<typeof setTimeout> | undefined;
  let streamController: ReadableStreamDefaultController<Uint8Array> | undefined;

  const settle = (): boolean => {
    if (settled) return false;
    settled = true;
    if (idleTimer) clearTimeout(idleTimer);
    if (totalTimer) clearTimeout(totalTimer);
    idleTimer = undefined;
    totalTimer = undefined;
    hooks.onSettled();
    return true;
  };

  const cut = (message: string) => {
    if (!settle()) return;
    hooks.abortUpstream();
    void reader.cancel().catch(() => {});
    streamController?.error(new Error(message));
  };

  const armIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(
      () => cut(`MCP stream idle timeout (no data for ${STREAM_IDLE_TIMEOUT_MS / 1000} seconds)`),
      STREAM_IDLE_TIMEOUT_MS,
    );
  };

  return new ReadableStream<Uint8Array>({
    start(controller) {
      streamController = controller;
      armIdleTimer();
      totalTimer = setTimeout(
        () => cut(`MCP stream exceeded maximum duration of ${STREAM_TOTAL_TIMEOUT_MS / 1000} seconds`),
        STREAM_TOTAL_TIMEOUT_MS,
      );
    },
    async pull(controller) {
      try {
        const { done, value } = await reader.read();
        if (settled) return;
        if (done) {
          settle();
          controller.close();
          return;
        }
        total += value.byteLength;
        if (total > MAX_RESPONSE_BYTES) {
          cut(`MCP response exceeded the ${MAX_RESPONSE_BYTES / 1024 / 1024}MB limit`);
          return;
        }
        armIdleTimer();
        controller.enqueue(value);
      } catch (error) {
        if (!settle()) return;
        controller.error(error);
      }
    },
    cancel(reason) {
      // Downstream stopped reading (client disconnected). The upstream must stop too.
      if (!settle()) return;
      hooks.abortUpstream();
      return reader.cancel(reason).catch(() => {});
    },
  });
}

/** The real cause of a failed node:http request is sometimes hidden in error.cause; surface it too. */
function describeFetchError(error: unknown, upstreamURL: string): string {
  if (!(error instanceof Error)) {
    return `Upstream fetch failed: ${upstreamURL}`;
  }

  const cause = error.cause;
  const causeMessage =
    cause && typeof cause === "object" && "message" in cause && typeof cause.message === "string"
      ? cause.message
      : null;
  const causeCode =
    cause && typeof cause === "object" && "code" in cause && typeof cause.code === "string"
      ? cause.code
      : null;

  const parts = [error.message || "Upstream fetch failed"];
  if (causeMessage && causeMessage !== error.message) parts.push(causeMessage);
  if (causeCode) parts.push(`(${causeCode})`);
  parts.push(`[upstream: ${upstreamURL}]`);
  return parts.join(" — ");
}

import type { LookupAddress } from "node:dns";
import http from "node:http";
import https from "node:https";
import { Readable } from "node:stream";
import {
  assertUrlNotSsrf,
  SsrfBlockedError,
} from "../../_shared/ssrf-guard";
import { checkRateLimit, getClientIp, buildRateLimitHeaders } from "../../chat/stream/rate-limit";

export const runtime = "nodejs";

/**
 * Reverse proxy for browser-side relay requests.
 *
 * Third-party relay endpoints rarely open CORS for a specific site, so a direct browser request is
 * blocked by Access-Control. The client puts the real upstream URL and the structured relay config
 * in dedicated headers, the Next.js Node runtime builds the upstream auth and protocol headers and
 * makes the request (which is not subject to CORS), and the response stream is written straight
 * back to the browser.
 *
 * The key stays in Node process memory for the duration of one request; it is never written to
 * disk or logged.
 */

const UPSTREAM_URL_HEADER = "x-relay-upstream-url";
const PROXY_CONFIG_HEADER = "x-relay-proxy-config";
const UPSTREAM_METHOD_HEADER = "x-relay-upstream-method";
const ERROR_SOURCE_HEADER = "X-Oriveo-Error-Source";
const ENDPOINT_FORBIDDEN = { error: "Endpoint blocked by server policy", code: "endpoint_forbidden" };
const RELAY_UPSTREAM_TIMEOUT_CODE = "relay_upstream_timeout";
const RELAY_UPSTREAM_CONNECTION_FAILED_CODE = "relay_upstream_connection_failed";
// Image responses are base64 payloads: a single gpt-image is roughly 3-4MB, and a streaming
// Responses call first sends partial_image preview frames (up to 3 by protocol). An SSE stream with
// one preview plus one final image was measured at 9.83MB, so a 10MB cap cuts a normal image
// generation off mid-flight and the client only sees a network error. This is a pure byte counter:
// chunks are counted and enqueued immediately with no buffering, so raising it costs no memory. A
// hostile upstream is bounded by STREAM_TOTAL_TIMEOUT_MS and the per-IP rate limit on forward.
const MAX_RESPONSE_BYTES = 64 * 1024 * 1024;
const UPSTREAM_RESPONSE_HEADER_TIMEOUT_MS = 30_000;
const MAX_SAME_ORIGIN_REDIRECTS = 5;
// Two layers of timeout on a streaming response:
// - idle: no chunk for 90 seconds means the upstream or the network is gone, so cut it off.
// - total: a hard 10 minute cap per response, to bound a hostile upstream looping forever.
// Both are deliberate server-side protection and are filtered out by beforeSend in
// sentry.server.config.ts; the messages start with "Relay stream " / "Relay response " so they can
// be recognized.
const STREAM_IDLE_TIMEOUT_MS = 90_000;
const STREAM_TOTAL_TIMEOUT_MS = 600_000;

const FORBIDDEN_CUSTOM_HEADERS = new Set([
  "host",
  "cookie",
  "content-length",
  "connection",
  "transfer-encoding",
  "x-relay-upstream-url",
  "x-relay-proxy-config",
]);

interface RelayProxyConfig {
  transport?: string;
  authMode?: string;
  apiKey?: string;
  codexCompatIdentity?: boolean;
  customUserAgent?: string;
  headers?: Array<{ key?: string; value?: string }>;
  queryParams?: Array<{ key?: string; value?: string }>;
}

interface UpstreamRequestInput {
  url: URL;
  method: "GET" | "POST";
  headers: Record<string, string>;
  body?: string;
  signal: AbortSignal;
  address: LookupAddress;
}

type UpstreamRequester = (input: UpstreamRequestInput) => Promise<Response>;

type RelayForwardGlobal = typeof globalThis & {
  __oriveoRelayForwardUpstreamRequester?: UpstreamRequester;
};

export async function POST(request: Request): Promise<Response> {
  return forwardRelayRequest(request, "POST");
}

export async function GET(request: Request): Promise<Response> {
  return forwardRelayRequest(request, "GET");
}

async function forwardRelayRequest(request: Request, fallbackMethod: "GET" | "POST"): Promise<Response> {
  // Rate limiting: relay forwards to a user-supplied endpoint, so even with the SSRF guard blocking
  // private ranges this endpoint still needs a cap, or it becomes an open proxy that lets anyone hit
  // arbitrary public targets from this server's IP. It reuses the chat/stream rate limiter under a
  // relay: namespace, so the two endpoints do not compete for the same quota.
  const clientIp = getClientIp(request.headers);
  const rateOutcome = checkRateLimit(`relay:${clientIp}`);
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

  const upstreamURL = request.headers.get(UPSTREAM_URL_HEADER);
  if (!upstreamURL) {
    return new Response(
      JSON.stringify({ error: "Missing X-Relay-Upstream-URL header" }),
      { status: 400, headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo" } },
    );
  }

  let parsed: URL;
  try {
    parsed = new URL(upstreamURL);
  } catch {
    return new Response(
      JSON.stringify({ error: `Invalid upstream URL: ${upstreamURL}` }),
      { status: 400, headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo" } },
    );
  }

  if (parsed.protocol === "http:") {
    return json(ENDPOINT_FORBIDDEN, 403);
  }
  if (parsed.protocol !== "https:") {
    return new Response(
      JSON.stringify({ error: `Unsupported upstream scheme: ${parsed.protocol}` }),
      { status: 400, headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo" } },
    );
  }
  if (parsed.username || parsed.password) {
    return json({ error: "Upstream URL userInfo is not allowed", code: "endpoint_forbidden" }, 400);
  }

  const rawProxyConfig = request.headers.get(PROXY_CONFIG_HEADER);
  if (!rawProxyConfig) {
    return new Response(
      JSON.stringify({ error: "Missing X-Relay-Proxy-Config header" }),
      { status: 400, headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo" } },
    );
  }

  const proxyConfig = parseProxyConfig(rawProxyConfig);
  if (!proxyConfig) {
    return new Response(
      JSON.stringify({ error: "Invalid X-Relay-Proxy-Config header" }),
      { status: 400, headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo" } },
    );
  }

  let pinnedAddress: LookupAddress;
  try {
    // The scheme was already validated as http/https above; the shared SSRF guard adds the port allowlist, the private and reserved IP blocklist, and the DNS pin.
    pinnedAddress = (await assertUrlNotSsrf(parsed)).address;
  } catch (error) {
    if (error instanceof SsrfBlockedError) {
      return json(ENDPOINT_FORBIDDEN, 403);
    }
    throw error;
  }

  applyQueryParams(parsed, proxyConfig);
  const method = resolveUpstreamMethod(request.headers.get(UPSTREAM_METHOD_HEADER), fallbackMethod);

  const forwardedHeaders = buildStructuredUpstreamHeaders(proxyConfig);

  const body = method === "GET" ? undefined : await request.text();

  let upstream: Response;
  let currentURL = parsed;
  let currentMethod = method;
  let currentBody = body;
  const allowedOrigin = parsed.origin;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), UPSTREAM_RESPONSE_HEADER_TIMEOUT_MS);
  try {
    let redirectCount = 0;
    while (true) {
      upstream = await getUpstreamRequester()({
        url: currentURL,
        method: currentMethod,
        headers: forwardedHeaders,
        body: currentBody,
        signal: controller.signal,
        address: pinnedAddress,
      });
      if (upstream.status < 300 || upstream.status >= 400) break;

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
        // Re-resolve and pin every hop so a same-host redirect cannot bypass DNS rebinding protection.
        pinnedAddress = (await assertUrlNotSsrf(redirectedURL)).address;
      } catch (error) {
        if (error instanceof SsrfBlockedError) {
          return json({ error: "Redirect target blocked by server policy", code: "endpoint_forbidden" }, 403);
        }
        throw error;
      }
      const redirected = redirectedRequest(upstream.status, currentMethod, currentBody);
      currentURL = redirectedURL;
      currentMethod = redirected.method;
      currentBody = redirected.body;
      redirectCount += 1;
    }
  } catch (error) {
    return json({
      error: describeFetchError(error, redactURL(currentURL.toString())),
      code: controller.signal.aborted
        ? RELAY_UPSTREAM_TIMEOUT_CODE
        : RELAY_UPSTREAM_CONNECTION_FAILED_CODE,
    }, 502, "network");
  } finally {
    clearTimeout(timeout);
  }

  const responseHeaders: Record<string, string> = {
    "Content-Type": upstream.headers.get("Content-Type") || "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Relay-Upstream-URL": redactURL(currentURL.toString()),
    [ERROR_SOURCE_HEADER]: "provider",
  };

  return new Response(limitResponseBody(upstream.body, () => controller.abort()), {
    status: upstream.status,
    headers: responseHeaders,
  });
}

async function cancelResponseBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // Redirect bodies are irrelevant; a cancellation failure must not bypass redirect policy.
  }
}

function redirectedRequest(
  statusCode: number,
  method: "GET" | "POST",
  body: string | undefined,
): { method: "GET" | "POST"; body: string | undefined } {
  if (method === "POST" && (statusCode === 301 || statusCode === 302 || statusCode === 303)) {
    return { method: "GET", body: undefined };
  }
  return { method, body };
}

function getUpstreamRequester(): UpstreamRequester {
  return (globalThis as RelayForwardGlobal).__oriveoRelayForwardUpstreamRequester
    ?? requestUpstreamWithPinnedAddress;
}

function resolveUpstreamMethod(raw: string | null, fallback: "GET" | "POST"): "GET" | "POST" {
  const normalized = raw?.toUpperCase();
  return normalized === "GET" || normalized === "POST" ? normalized : fallback;
}

function json(
  payload: Record<string, unknown>,
  status: number,
  source: "oriveo" | "network" = "oriveo",
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: source },
  });
}

function parseProxyConfig(raw: string | null): RelayProxyConfig | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as RelayProxyConfig;
  } catch {
    try {
      return JSON.parse(decodeURIComponent(raw)) as RelayProxyConfig;
    } catch {
      return null;
    }
  }
}

function buildStructuredUpstreamHeaders(config: RelayProxyConfig): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  const apiKey = config.apiKey?.trim();
  switch (config.authMode) {
    case "x_api_key":
      if (apiKey) headers["x-api-key"] = apiKey;
      headers["anthropic-version"] = "2023-06-01";
      break;
    case "x_goog_api_key":
      if (apiKey) headers["x-goog-api-key"] = apiKey;
      break;
    case "query_key":
      break;
    case "bearer":
    case "auto":
    default:
      if (apiKey) headers.Authorization = `Bearer ${apiKey}`;
      break;
  }

  if (
    (config.transport === "openai_responses" || config.transport === "auto")
    && config.codexCompatIdentity !== false
  ) {
    headers["User-Agent"] = "codex_cli_rs/0.50.0 (Oriveo Web; Node.js)";
    headers.Originator = "codex_cli_rs";
    headers.session_id = crypto.randomUUID();
    headers["OpenAI-Beta"] = "responses=experimental";
  }

  if (config.customUserAgent?.trim()) {
    headers["User-Agent"] = config.customUserAgent.trim();
  }

  for (const pair of config.headers ?? []) {
    const key = pair.key?.trim();
    const value = pair.value ?? "";
    if (!key || FORBIDDEN_CUSTOM_HEADERS.has(key.toLowerCase())) continue;
    headers[key] = value;
  }

  return headers;
}

function applyQueryParams(url: URL, config: RelayProxyConfig | null): void {
  if (!config) return;
  if (config.authMode === "query_key" && config.apiKey && !url.searchParams.has("key")) {
    url.searchParams.set("key", config.apiKey);
  }
  for (const pair of config.queryParams ?? []) {
    const key = pair.key?.trim();
    if (!key) continue;
    url.searchParams.set(key, pair.value ?? "");
  }
}

function limitResponseBody(
  body: ReadableStream<Uint8Array> | null,
  abortUpstream: () => void,
): ReadableStream<Uint8Array> | null {
  if (!body) return body;
  let total = 0;
  let finished = false;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let totalTimer: ReturnType<typeof setTimeout> | undefined;

  const clearTimers = () => {
    if (idleTimer) clearTimeout(idleTimer);
    if (totalTimer) clearTimeout(totalTimer);
    idleTimer = undefined;
    totalTimer = undefined;
  };

  return body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    start(controller) {
      const abort = (message: string) => {
        if (finished) return;
        finished = true;
        clearTimers();
        abortUpstream();
        controller.error(new Error(message));
      };
      idleTimer = setTimeout(
        () => abort(`Relay stream idle timeout (no data for ${STREAM_IDLE_TIMEOUT_MS / 1000} seconds)`),
        STREAM_IDLE_TIMEOUT_MS,
      );
      totalTimer = setTimeout(
        () => abort(`Relay stream exceeded maximum duration of ${STREAM_TOTAL_TIMEOUT_MS / 1000} seconds`),
        STREAM_TOTAL_TIMEOUT_MS,
      );
    },
    transform(chunk, controller) {
      if (finished) return;
      total += chunk.byteLength;
      if (total > MAX_RESPONSE_BYTES) {
        finished = true;
        clearTimers();
        abortUpstream();
        controller.error(
          new Error(`Relay response exceeded the ${MAX_RESPONSE_BYTES / 1024 / 1024}MB limit`),
        );
        return;
      }
      // Any data received resets the idle timer; the total timer keeps running
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        if (finished) return;
        finished = true;
        clearTimers();
        abortUpstream();
        controller.error(
          new Error(`Relay stream idle timeout (no data for ${STREAM_IDLE_TIMEOUT_MS / 1000} seconds)`),
        );
      }, STREAM_IDLE_TIMEOUT_MS);
      controller.enqueue(chunk);
    },
    flush() {
      finished = true;
      clearTimers();
    },
  }));
}

function requestUpstreamWithPinnedAddress(input: UpstreamRequestInput): Promise<Response> {
  const client = input.url.protocol === "https:" ? https : http;
  const requestHeaders: Record<string, string> = {
    ...input.headers,
    Host: input.url.host,
  };

  // Pin the IP only in production, to block DNS rebinding SSRF. In development Node resolves DNS
  // itself, because the fake IP pools used by local proxies (Surge, ClashX, WARP) otherwise make the
  // upstream unreachable. The trade-off: development still has ALLOWED_PORTS, the scheme allowlist
  // and the IP blocklist as a first line, and the second DNS resolution race only exists there.
  const shouldPinIP = process.env.NODE_ENV === "production";

  return new Promise<Response>((resolve, reject) => {
    let responseMessage: http.IncomingMessage | null = null;
    // https.RequestOptions accepts servername and lookup; the http typings reject servername, so the https type is used.
    const baseOptions: https.RequestOptions = {
      protocol: input.url.protocol,
      hostname: input.url.hostname,
      port: input.url.port || undefined,
      path: `${input.url.pathname}${input.url.search}`,
      method: input.method,
      headers: requestHeaders,
      servername: input.url.hostname,
    };
    if (shouldPinIP) {
      baseOptions.lookup = (_hostname, options, callback) => {
        if (typeof options === "object" && options?.all) {
          callback(null, [{ address: input.address.address, family: input.address.family }]);
          return;
        }
        callback(null, input.address.address, input.address.family);
      };
    }
    const request = client.request(
      baseOptions,
      (response) => {
        responseMessage = response;
        const headers = new Headers();
        for (const [key, value] of Object.entries(response.headers)) {
          if (Array.isArray(value)) {
            for (const item of value) headers.append(key, item);
          } else if (value !== undefined) {
            headers.set(key, String(value));
          }
        }
        response.once("close", () => {
          input.signal.removeEventListener("abort", abort);
        });
        resolve(new Response(Readable.toWeb(response) as ReadableStream<Uint8Array>, {
          status: response.statusCode ?? 502,
          headers,
        }));
      },
    );

    const abort = () => {
      const error = new Error("Relay upstream request aborted");
      responseMessage?.destroy(error);
      request.destroy(error);
    };
    input.signal.addEventListener("abort", abort, { once: true });

    request.once("error", (error) => {
      input.signal.removeEventListener("abort", abort);
      reject(error);
    });

    if (input.signal.aborted) {
      abort();
      return;
    }

    if (input.body !== undefined) {
      request.write(input.body);
    }
    request.end();
  });
}

/** The real reason a Node undici fetch failed hides in error.cause, so surface it. */
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

function redactURL(value: string): string {
  try {
    const url = new URL(value);
    for (const key of [...url.searchParams.keys()]) {
      if (/key|token|secret|password/i.test(key)) {
        url.searchParams.set(key, "***");
      }
    }
    return url.toString();
  } catch {
    return value.replace(/([?&][^=]*(?:key|token|secret|password)[^=]*=)[^&]+/gi, "$1***");
  }
}

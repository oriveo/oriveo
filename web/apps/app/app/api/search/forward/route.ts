import type { LookupAddress } from "node:dns";
import {
  buildSearchRequest,
  classifySearchError,
  parseSearchResponse,
  parseServiceAddress,
  validateCustomSearchService,
  validateManualMapping,
  CUSTOM_TIMEOUT_SEC,
  ERROR_CLASSES,
  HARD_LIMITS,
  SEARXNG_SPEC,
  type CustomServiceInput,
  type ErrorRule,
  type ResponseMapping,
  type SearchErrorInput,
  type SearchRequest,
  type TransportField,
  type TransportSpec,
} from "@oriveo/core/search/search-transport";
import { assertUrlNotSsrf, SsrfBlockedError } from "../../_shared/ssrf-guard";
import { buildRateLimitHeaders, checkRateLimit, getClientIp } from "../../chat/stream/rate-limit";
import { requestUpstreamWithPinnedAddress, type UpstreamRequestInput } from "../../mcp/forward/upstream-request";
import { presetHostCheck } from "@oriveo/core/search/search-catalog";
import { getSearchCatalog } from "../../../../lib/search/search-catalog-loader";

export const runtime = "nodejs";

/**
 * Server-side forwarding for external web search (external search service contract, sections 9-11).
 *
 * Browsers calling a search service directly are mostly blocked by CORS, so a single json_http/v1 request is made here on the Node runtime:
 * - Preset services: host, path and mapping come only from the server-loaded, signature-verified catalog; an address / mapping in the request body is rejected with 400.
 * - Custom services: the address passes the SSRF guard (private / unresolved hosts feed form validation via addressClass); the target is recomputed server-side from
 *   origin + requestPath, and only a valid subset of the mapping is accepted.
 * Exactly one upstream request is made; the result is mapped by the core layer to { ok: true, ... } or { ok: false, <error class> ... } and returned to the browser.
 *
 * The key / Authorization / custom auth headers live only in memory for this request: never logged, never in error text, never sent to Sentry
 * (the upstream request uses upstream-request's suppressTracing).
 */

const ERROR_SOURCE_HEADER = "X-Oriveo-Error-Source";
const MAX_SAME_ORIGIN_REDIRECTS = 5;
// These fields in a preset request body mean an attempt to change host / path / mapping: always reject, never silently ignore (boundHost is only compared, so it is allowed)
const PRESET_FORBIDDEN_FIELDS = ["url", "host", "port", "path", "address", "mapping", "transport", "headers"];
// Form validation requires a name; forwarding only cares about address and mapping, so a fixed placeholder is used
const FORWARD_SERVICE_NAME = "search-forward";

type UpstreamRequester = (input: UpstreamRequestInput) => Promise<Response>;

type SearchForwardGlobal = typeof globalThis & {
  __oriveoSearchForwardUpstreamRequester?: UpstreamRequester;
};

interface ForwardPlan {
  spec: TransportSpec;
  request: SearchRequest;
  /** Truncation count when parsing the response (same rule as building the request: non-positive integers use the default) */
  count: number | null;
  timeoutSec: number;
  custom: boolean;
  /** A custom service has already passed the SSRF guard during validation and has a pinned address */
  pinned: LookupAddress | null;
}

type PlanOutcome = { plan: ForwardPlan } | { invalid: string[] } | { failure: SearchErrorInput } | { empty: true };

type JsonObject = Record<string, unknown>;

/**
 * Total timeout for one forward: counted from the first DNS lookup (first-hop SSRF resolution), covering all hops and body reads.
 * Presets start it before sending, custom services when resolving the address during validation; it starts only once.
 */
class ForwardDeadline {
  private readonly controller = new AbortController();
  private timer: ReturnType<typeof setTimeout> | null = null;

  get signal(): AbortSignal {
    return this.controller.signal;
  }

  start(timeoutSec: number): void {
    if (this.timer || this.controller.signal.aborted) return;
    this.timer = setTimeout(() => this.controller.abort(), timeoutSec * 1000);
  }

  abort(): void {
    this.controller.abort();
  }

  clear(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}

/** SSRF guard + DNS pin; DNS itself cannot be cancelled, so it races against the total timeout. On timeout a plain error is thrown and the caller decides by signal.aborted. */
function resolvePinned(url: string | URL, deadline: ForwardDeadline): Promise<LookupAddress> {
  return new Promise<LookupAddress>((resolve, reject) => {
    const onAbort = () => reject(new Error("Search forward deadline exceeded"));
    if (deadline.signal.aborted) {
      onAbort();
      return;
    }
    deadline.signal.addEventListener("abort", onAbort, { once: true });
    assertUrlNotSsrf(url)
      .then((checked) => resolve(checked.address), reject)
      .finally(() => deadline.signal.removeEventListener("abort", onAbort));
  });
}

export async function POST(request: Request): Promise<Response> {
  // Same rate-limit helper as relay/forward, with an independent counter under the search: namespace
  const clientIp = getClientIp(request.headers);
  const rateOutcome = checkRateLimit(`search:${clientIp}`);
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

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return invalid(["body_invalid"]);
  }
  if (!isObject(body)) return invalid(["body_invalid"]);

  const common = readCommonFields(body);
  if ("invalid" in common) return invalid(common.invalid);

  const deadline = new ForwardDeadline();
  try {
    let outcome: PlanOutcome;
    if (body.kind === "preset") outcome = await planPreset(body, common);
    else if (body.kind === "custom") outcome = await planCustom(body, common, deadline);
    else outcome = { invalid: ["kind_invalid"] };

    if ("invalid" in outcome) return invalid(outcome.invalid);
    // Empty query: do not call upstream, reply with "no results"
    if ("empty" in outcome) return result({ ok: true, kind: "empty" });
    if ("failure" in outcome) {
      // Pre-send check failed / refused locally: upstream received no request and nothing was billed (sent:false, so the chat side does not count this request)
      return result({
        ok: false,
        ...classifySearchError({ ...outcome.failure, custom: body.kind === "custom", otherServices: common.otherServices }),
        sent: false,
      });
    }
    return await send(outcome.plan, deadline, common.otherServices);
  } finally {
    deadline.clear();
  }
}

interface CommonFields {
  query: string;
  /** Passed through as-is to buildSearchRequest: it handles non-positive integers with the default of 5 */
  count: number | null;
  key: string | null;
  otherServices: number;
}

function readCommonFields(body: JsonObject): CommonFields | { invalid: string[] } {
  const errors: string[] = [];
  const query = typeof body.query === "string" ? body.query : "";
  const count = typeof body.count === "number" ? body.count : null;
  let key: string | null = null;
  if (body.key !== undefined && body.key !== null) {
    if (typeof body.key === "string") key = body.key.trim() || null;
    else errors.push("key_invalid");
  }
  let otherServices = 0;
  if (body.otherServices !== undefined && body.otherServices !== null) {
    if (typeof body.otherServices === "number" && Number.isSafeInteger(body.otherServices) && body.otherServices >= 0) {
      otherServices = body.otherServices;
    } else {
      errors.push("other_services_invalid");
    }
  }
  return errors.length ? { invalid: errors } : { query, count, key, otherServices };
}

/** Same rule as buildSearchRequest: only positive integers count as a requested value, the rest use the default. */
function effectiveCount(count: number | null): number | null {
  return count !== null && Number.isSafeInteger(count) && count > 0 ? count : null;
}

async function planPreset(body: JsonObject, common: CommonFields): Promise<PlanOutcome> {
  if (PRESET_FORBIDDEN_FIELDS.some((field) => Object.prototype.hasOwnProperty.call(body, field))) {
    return { invalid: ["preset_target_not_allowed"] };
  }
  if (typeof body.serviceId !== "string" || typeof body.regionId !== "string") return { invalid: ["service_invalid"] };
  if (typeof body.boundHost !== "string" || !body.boundHost) return { invalid: ["bound_host_missing"] };
  if (!common.key) return { invalid: ["key_missing"] };
  const catalog = await getSearchCatalog();
  const service = catalog?.active.get(body.serviceId) ?? null;
  // Host check before sending the key: catalog host changed -> host_changed; entry withdrawn, site missing, or catalog wholly unavailable -> service_withdrawn
  const verdict = presetHostCheck({
    boundHost: body.boundHost,
    entry: service?.entry ?? null,
    regionId: body.regionId,
    withdrawn: catalog?.withdrawn.has(body.serviceId) ?? false,
  });
  if (verdict !== "ok" || !service) return { failure: { preflight: verdict === "ok" ? "service_withdrawn" : verdict } };
  const region = service.entry.regions.find((r) => r.id === body.regionId);
  if (!region) return { failure: { preflight: "service_withdrawn" } };
  const built = buildSearchRequest(
    service.entry.transport,
    { scheme: "https", host: region.host, static: region.static },
    { query: common.query, count: common.count, key: common.key },
  );
  if ("skip" in built) return { empty: true };
  return {
    plan: {
      spec: service.entry.transport,
      request: built,
      count: effectiveCount(common.count),
      timeoutSec: service.limits.timeoutSec,
      custom: false,
      pinned: null,
    },
  };
}

async function planCustom(body: JsonObject, common: CommonFields, deadline: ForwardDeadline): Promise<PlanOutcome> {
  const protocol = body.protocol;
  const base: CustomServiceInput = {
    name: FORWARD_SERVICE_NAME,
    address: body.address,
    protocol,
    platform: "web",
    // "Same as X" stores the mapping snapshot taken at save time; forwarding no longer consults the catalog
    catalogAvailable: true,
    presetActive: true,
    manual: protocol === "manual" ? body.mapping : undefined,
  };
  // Run form validation first (including the Web port allowlist port_not_allowed_on_web), and resolve the address only if it passes
  const checked = validateCustomSearchService({ ...base, addressClass: "public" });
  const mappingErrors = protocol === "same_as" ? validateManualMapping(body.mapping) : [];
  if (!checked.ok || mappingErrors.length > 0 || !checked.origin || !checked.requestPath) {
    return { invalid: [...new Set([...checked.errors, ...mappingErrors])] };
  }
  const origin = parseServiceAddress(checked.origin);
  if (!origin) return { invalid: ["address_invalid"] };

  const spec = protocol === "searxng" ? SEARXNG_SPEC : customMappingSpec(body.mapping as JsonObject);
  const built = buildSearchRequest(
    spec,
    { scheme: origin.scheme, host: origin.host, port: origin.port, path: checked.requestPath },
    { query: common.query, count: common.count, key: spec.auth.kind === "none" ? null : common.key },
  );
  if ("skip" in built) return { empty: true };

  const timeoutSec = Math.min(CUSTOM_TIMEOUT_SEC, HARD_LIMITS.maxTimeoutSec);
  deadline.start(timeoutSec);
  let pinned: LookupAddress;
  try {
    pinned = await resolvePinned(`${checked.origin}${checked.requestPath}`, deadline);
  } catch (error) {
    if (!(error instanceof SsrfBlockedError)) {
      if (deadline.signal.aborted) return { failure: { transportFailure: "timeout" } };
      throw error;
    }
    // The guard only supplies text: "Could not resolve host" = unresolved; anything else (private / reserved / metadata addresses) is treated as LAN
    const addressClass = /could not resolve/i.test(error.message) ? "unresolved" : "lan";
    const rechecked = validateCustomSearchService({ ...base, addressClass });
    return { invalid: rechecked.errors.length ? rechecked.errors : ["private_address_on_web"] };
  }

  return {
    plan: {
      spec,
      request: built,
      count: effectiveCount(common.count),
      timeoutSec,
      custom: true,
      pinned,
    },
  };
}

/** Mapping that already passed validateManualMapping -> rebuild a transport description from known fields only (the path is recomputed by the server, not taken from the mapping). */
function customMappingSpec(mapping: JsonObject): TransportSpec {
  const auth = mapping.auth as { kind: "bearer" | "header" | "none"; name?: string };
  const field = (value: unknown): TransportField | null => {
    if (!isObject(value)) return null;
    const out: TransportField = { field: value.field as string, in: value.in as TransportField["in"] };
    if (typeof value.maxChars === "number") out.maxChars = value.maxChars;
    if (typeof value.max === "number") out.max = value.max;
    return out;
  };
  const staticPart = isObject(mapping.static) ? mapping.static : null;
  const response = mapping.response as JsonObject;
  const pathList = (value: unknown): string[] | undefined => (Array.isArray(value) ? (value as string[]) : undefined);
  const responseMapping: ResponseMapping = {
    results: response.results as string,
    title: pathList(response.title) ?? [],
    url: pathList(response.url) ?? [],
  };
  for (const key of ["snippet", "site", "date"] as const) {
    const list = pathList(response[key]);
    if (list) responseMapping[key] = list;
  }
  if (response.html === true) responseMapping.html = true;
  return {
    method: mapping.method as "GET" | "POST",
    auth: auth.kind === "header" ? { kind: "header", name: auth.name } : { kind: auth.kind },
    query: field(mapping.query) as TransportField,
    count: field(mapping.count),
    static: staticPart
      ? {
        in: staticPart.in === "body" || staticPart.in === "query" ? staticPart.in : undefined,
        params: (isObject(staticPart.params) ? staticPart.params : {}) as Record<string, string | number | boolean>,
      }
      : null,
    response: responseMapping,
    errors: keptErrorRules(mapping.errors),
  };
}

/** A custom mapping's dedicated error rules keep only integer status + known error classes; a malformed match drops the whole rule (never relaxed into an unconditional rule). */
function keptErrorRules(value: unknown): ErrorRule[] {
  if (!Array.isArray(value)) return [];
  const rules: ErrorRule[] = [];
  for (const raw of value) {
    if (!isObject(raw) || !Number.isInteger(raw.status) || typeof raw.class !== "string") continue;
    if (!Object.prototype.hasOwnProperty.call(ERROR_CLASSES, raw.class)) continue;
    const rule: ErrorRule = { status: raw.status as number, class: raw.class as ErrorRule["class"] };
    if (raw.match !== undefined && raw.match !== null) {
      const match = raw.match;
      if (!isObject(match) || typeof match.path !== "string" || (match.equals !== null && typeof match.equals === "object")) continue;
      rule.match = { path: match.path, equals: match.equals };
    }
    rules.push(rule);
  }
  return rules;
}

async function send(plan: ForwardPlan, deadline: ForwardDeadline, otherServices: number): Promise<Response> {
  const fail = (input: SearchErrorInput) =>
    result({ ok: false, ...classifySearchError({ ...input, rules: plan.spec.errors, custom: plan.custom, otherServices }) });

  const req = plan.request;
  let currentURL = new URL(req.url);
  const allowedOrigin = currentURL.origin;
  let currentMethod = req.method;
  let currentBody = req.body === null ? undefined : JSON.stringify(req.body);
  // Presets count from here (first-hop DNS); custom services already started it during validation, so this is a no-op
  deadline.start(plan.timeoutSec);
  let upstream: Response;
  let text: string;
  try {
    let pinned = plan.pinned;
    if (!pinned) {
      try {
        pinned = await resolvePinned(currentURL, deadline);
      } catch (error) {
        // Catalog host resolved to a private / reserved address (DNS rebinding): refuse locally
        if (error instanceof SsrfBlockedError) return fail({ transportFailure: "blocked" });
        throw error;
      }
    }
    let redirectCount = 0;
    while (true) {
      upstream = await getUpstreamRequester()({
        url: currentURL,
        method: currentMethod,
        headers: req.headers,
        body: currentBody,
        signal: deadline.signal,
        address: pinned,
      });
      if (upstream.status < 300 || upstream.status >= 400) break;

      const status = upstream.status;
      const location = upstream.headers.get("Location");
      await cancelResponseBody(upstream);
      // Cross-origin / too many hops / invalid Location / next-hop safety check failed: refuse locally (blocked), not classified by the 3xx status
      if (!location || redirectCount >= MAX_SAME_ORIGIN_REDIRECTS) return fail({ transportFailure: "blocked" });
      let redirectedURL: URL;
      try {
        redirectedURL = new URL(location, currentURL);
      } catch {
        return fail({ transportFailure: "blocked" });
      }
      // The request carries the key: any cross-origin hop (any difference in scheme + host + port) aborts, so the auth header never reaches another host
      if (redirectedURL.origin !== allowedOrigin || redirectedURL.username || redirectedURL.password) {
        return fail({ transportFailure: "blocked" });
      }
      try {
        // Same-origin hops are also re-resolved and pinned each time, to defend against DNS rebinding
        pinned = await resolvePinned(redirectedURL, deadline);
      } catch (error) {
        if (error instanceof SsrfBlockedError) return fail({ transportFailure: "blocked" });
        throw error;
      }
      if (currentMethod === "POST" && (status === 301 || status === 302 || status === 303)) {
        currentMethod = "GET";
        currentBody = undefined;
      }
      currentURL = redirectedURL;
      redirectCount += 1;
    }

    const declared = Number(upstream.headers.get("Content-Length"));
    if (Number.isFinite(declared) && declared > HARD_LIMITS.maxResponseBytes) {
      await cancelResponseBody(upstream);
      return fail({ transportFailure: "too_large" });
    }
    const read = await readLimited(upstream.body, HARD_LIMITS.maxResponseBytes);
    if (read === null) {
      deadline.abort();
      return fail({ transportFailure: "too_large" });
    }
    text = read;
  } catch {
    // The error object may carry request headers or addresses: take only the classification, never echo the raw text
    return fail({ transportFailure: deadline.signal.aborted ? "timeout" : "network" });
  } finally {
    deadline.clear();
  }

  let payload: unknown = undefined;
  let parsedOk = false;
  try {
    payload = text ? JSON.parse(text) : undefined;
    parsedOk = payload !== undefined;
  } catch {
    parsedOk = false;
  }

  if (upstream.status >= 200 && upstream.status < 300) {
    if (!parsedOk) return fail({ parse: "mismatch" });
    const parsed = parseSearchResponse(plan.spec, payload, { count: plan.count });
    if (parsed.kind === "error") return fail({ parse: "mismatch" });
    return result({ ok: true, ...parsed });
  }
  return fail({ status: upstream.status, body: parsedOk ? payload : undefined });
}

/** Read the response body to the end; once the total exceeds limit, cancel immediately and return null. */
async function readLimited(body: ReadableStream<Uint8Array> | null, limit: number): Promise<string | null> {
  if (!body) return "";
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(merged);
}

async function cancelResponseBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // The body of a redirect / oversized response is useless; a failed cancel must not bypass the policy
  }
}

function getUpstreamRequester(): UpstreamRequester {
  return (globalThis as SearchForwardGlobal).__oriveoSearchForwardUpstreamRequester
    ?? ((input) => requestUpstreamWithPinnedAddress(input));
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function result(payload: JsonObject): Response {
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", [ERROR_SOURCE_HEADER]: "oriveo" },
  });
}

function invalid(errors: string[]): Response {
  return new Response(JSON.stringify({ error: "invalid_request", errors }), {
    status: 400,
    headers: { "Content-Type": "application/json", [ERROR_SOURCE_HEADER]: "oriveo" },
  });
}

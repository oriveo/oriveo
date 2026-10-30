// @vitest-environment node
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { POST } from "./route";
import { __resetRateLimitForTests, checkRateLimit } from "../../chat/stream/rate-limit";
import {
  __setSearchCatalogLoaderForTests,
  createSearchCatalogLoader,
} from "../../../../lib/search/search-catalog-loader";

// Search forward route: golden replay (shared/search-contracts/transport-golden.v1.json) + immutable preset hosts, SSRF, rate limiting,
// redirects, oversized responses, auth-header redaction. Upstream is always an injected requester stub and DNS is mocked; no real requests are sent.

const mocks = vi.hoisted(() => ({
  lookup: vi.fn(),
  resolve4: vi.fn(),
  resolve6: vi.fn(),
}));

vi.mock("node:dns/promises", () => ({
  default: { lookup: mocks.lookup, resolve4: mocks.resolve4, resolve6: mocks.resolve6 },
  lookup: mocks.lookup,
  resolve4: mocks.resolve4,
  resolve6: mocks.resolve6,
}));

const REPO_ROOT = join(process.cwd(), "../../..");
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (relative: string): any => JSON.parse(readFileSync(join(REPO_ROOT, relative), "utf8"));
const contract = load("shared/search-contracts/search_catalog_contract.v1.json");
const golden = load("shared/search-contracts/transport-golden.v1.json");

interface CapturedRequest {
  url: URL;
  method: string;
  headers: Record<string, string>;
  body?: string;
  address: { address: string; family: number };
}

type Requester = (input: CapturedRequest) => Promise<Response>;
type TestGlobal = typeof globalThis & { __oriveoSearchForwardUpstreamRequester?: Requester };

function stubUpstream(requester: Requester) {
  const fn = vi.fn(requester);
  (globalThis as TestGlobal).__oriveoSearchForwardUpstreamRequester = fn;
  return fn;
}

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

function post(body: unknown, ip = "198.51.100.20"): Promise<Response> {
  return POST(new Request("http://localhost/api/search/forward", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-forwarded-for": ip },
    body: typeof body === "string" ? body : JSON.stringify(body),
  }));
}

const KEY = "sk-test-0000";
/** Host of that site in the fixture catalog: the one a saved service is bound to */
function catalogHost(serviceId: string, regionId: string): string | undefined {
  const entry = contract.catalog.services.find((s: { id: string }) => s.id === serviceId);
  return entry?.regions?.find((r: { id: string }) => r.id === regionId)?.host;
}
const preset = (serviceId: string, regionId: string, extra: Record<string, unknown> = {}) => ({
  kind: "preset", serviceId, regionId, boundHost: catalogHost(serviceId, regionId) ?? "unknown.example", query: "oriveo web search", key: KEY, ...extra,
});

const MANUAL_MAPPING = {
  method: "POST",
  auth: { kind: "header", name: "X-Search-Token" },
  query: { field: "q", in: "body" },
  count: { field: "n", in: "body" },
  response: { results: "items", title: ["name"], url: ["link"], snippet: ["text"] },
  errors: [
    { status: 418, class: "rate_limited" },
    { status: 419, class: "not_a_class" },
    { status: "420", class: "timeout" },
  ],
};

describe("/api/search/forward", () => {
  beforeEach(() => {
    __resetRateLimitForTests();
    mocks.resolve4.mockResolvedValue(["203.0.113.10"]);
    mocks.resolve6.mockRejectedValue(new Error("ENODATA"));
    mocks.lookup.mockResolvedValue([{ address: "203.0.113.10", family: 4 }]);
    __setSearchCatalogLoaderForTests(createSearchCatalogLoader({
      trustedKeys: { [contract.testKeys.keyId]: contract.testKeys.publicKeyB64 },
      builtin: contract.catalog,
      fetchView: async () => new Response(null, { status: 503 }),
    }));
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    delete (globalThis as TestGlobal).__oriveoSearchForwardUpstreamRequester;
    __setSearchCatalogLoaderForTests(undefined);
    mocks.lookup.mockReset();
    mocks.resolve4.mockReset();
    mocks.resolve6.mockReset();
  });

  it("golden replay: preset requests are built from the catalog, responses / errors mapped by the core layer", async () => {
    let checked = 0;
    for (const c of golden.cases) {
      const regionId = c.regionId ?? contract.catalog.services.find((s: { id: string }) => s.id === c.serviceId).regions[0].id;
      if (c.kind === "request") {
        const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
        const res = await post({ kind: "preset", serviceId: c.serviceId, regionId, boundHost: catalogHost(c.serviceId, regionId), ...c.input });
        expect(res.status, c.caseId).toBe(200);
        if (c.expect.skip) {
          // Empty query: nothing sent upstream, reply with no results
          expect(await res.json(), c.caseId).toEqual({ ok: true, kind: "empty" });
          expect(upstream, c.caseId).not.toHaveBeenCalled();
          checked += 1;
          continue;
        }
        const sent = upstream.mock.calls[0][0];
        const expected = new URL(c.expect.url);
        expect(sent.method, c.caseId).toBe(c.expect.method);
        expect(`${sent.url.origin}${sent.url.pathname}`, c.caseId).toBe(`${expected.origin}${expected.pathname}`);
        expect([...sent.url.searchParams.entries()].sort(), c.caseId).toEqual([...expected.searchParams.entries()].sort());
        expect(sent.headers, c.caseId).toEqual(c.expect.headers);
        expect(sent.body === undefined ? null : JSON.parse(sent.body), c.caseId).toEqual(c.expect.body);
        expect(sent.address, c.caseId).toEqual({ address: "203.0.113.10", family: 4 });
      } else {
        stubUpstream(async () => jsonResponse(c.status, c.body));
        const res = await post(preset(c.serviceId, regionId, { query: "q" }));
        const payload = await res.json();
        if (c.kind === "error") {
          expect(payload, c.caseId).toEqual({ ok: false, ...c.expect });
        } else if (c.expect.kind === "error") {
          expect(payload, c.caseId).toMatchObject({ ok: false, errorClass: "parse_mismatch" });
        } else {
          expect(payload, c.caseId).toEqual({ ok: true, ...c.expect });
        }
      }
      checked += 1;
    }
    expect(checked).toBe(golden.cases.length);
  });

  it("preset host is immutable: url / host / mapping in the body gives 400 and upstream is not called", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    for (const extra of [
      { url: "https://evil.example/search" },
      { host: "evil.example" },
      { mapping: MANUAL_MAPPING },
    ]) {
      const res = await post(preset("deepseek", "cn", extra));
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "invalid_request", errors: ["preset_target_not_allowed"] });
    }
    expect(upstream).not.toHaveBeenCalled();
  });

  it("preset entry missing / site missing / catalog unavailable -> service_withdrawn, no key sent", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    for (const body of [preset("nope", "global"), preset("deepseek", "intl")]) {
      expect(await (await post(body)).json()).toMatchObject({ ok: false, errorClass: "service_withdrawn" });
    }
    __setSearchCatalogLoaderForTests(createSearchCatalogLoader({
      trustedKeys: {},
      builtin: contract.catalog,
      fetchView: async () => new Response(null, { status: 404 }),
    }));
    expect(await (await post(preset("deepseek", "cn"))).json()).toMatchObject({ ok: false, errorClass: "service_withdrawn" });
    expect(upstream).not.toHaveBeenCalled();
  });

  it("host check before sending the key: catalog host changed -> host_changed, upstream received no request; otherServices passes through as secondary actions", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    const res = await post(preset("kimi", "cn", { boundHost: "api.moonshot.ai", otherServices: 2 }));
    expect(await res.json()).toMatchObject({
      ok: false,
      errorClass: "host_changed",
      card: { primaryAction: "reconfirm", secondaryAction: "switch_to_other_service" },
    });
    expect(upstream).not.toHaveBeenCalled();

    const missing = await post({ ...preset("kimi", "cn"), boundHost: undefined });
    expect(await missing.json()).toEqual({ error: "invalid_request", errors: ["bound_host_missing"] });
    const badOther = await post(preset("kimi", "cn", { otherServices: -1 }));
    expect(await badOther.json()).toEqual({ error: "invalid_request", errors: ["other_services_invalid"] });
    expect(upstream).not.toHaveBeenCalled();
  });

  it("empty query sends nothing upstream and returns no results; count 0 / non-integer uses the default 5", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    expect(await (await post(preset("deepseek", "cn", { query: "  " }))).json()).toEqual({ ok: true, kind: "empty" });
    expect(await (await post({ kind: "custom", protocol: "searxng", address: "https://searx.example.com", query: "" })).json())
      .toEqual({ ok: true, kind: "empty" });
    expect(upstream).not.toHaveBeenCalled();
    expect(mocks.resolve4).not.toHaveBeenCalled();

    for (const count of [0, 2.5, "3"]) {
      const res = await post(preset("deepseek", "cn", { count }));
      expect(res.status).toBe(200);
    }
    expect(upstream.mock.calls.map((call) => JSON.parse(call[0].body ?? "{}").count)).toEqual([5, 5, 5]);
  });

  it("custom port not on the Web allowlist: form validation gives 400 directly, no address resolution", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    const res = await post({ kind: "custom", protocol: "searxng", address: "https://searx.example.com:9443", query: "q" });
    expect(res.status).toBe(400);
    expect((await res.json()).errors).toEqual(["port_not_allowed_on_web"]);
    expect(mocks.resolve4).not.toHaveBeenCalled();
    expect(upstream).not.toHaveBeenCalled();
  });

  it("total timeout counts from the first DNS lookup: resolution stuck past the limit = timeout, upstream received no request", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    mocks.resolve4.mockImplementation(() => new Promise(() => {}));
    mocks.resolve6.mockImplementation(() => new Promise(() => {}));
    const pending = post({ kind: "custom", protocol: "searxng", address: "https://searx.example.com", query: "q" });
    await vi.advanceTimersByTimeAsync(20_001);
    expect(await (await pending).json()).toMatchObject({ ok: false, errorClass: "timeout" });
    expect(upstream).not.toHaveBeenCalled();
  });

  it("SSRF: private addresses feed form validation as lan, resolution failures as unresolved, 400 carries errors", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [] }));
    const custom = (address: string) => ({ kind: "custom", protocol: "searxng", address, query: "q" });

    const literal = await post(custom("https://10.0.0.5/searx"));
    expect(literal.status).toBe(400);
    expect((await literal.json()).errors).toContain("private_address_on_web");

    mocks.resolve4.mockResolvedValueOnce(["192.168.1.9"]);
    const rebinding = await post(custom("https://searx.example.com"));
    expect((await rebinding.json()).errors).toContain("private_address_on_web");

    mocks.resolve4.mockRejectedValueOnce(new Error("ENOTFOUND"));
    mocks.lookup.mockRejectedValueOnce(new Error("ENOTFOUND"));
    const unresolved = await post(custom("https://missing.example.com"));
    expect(unresolved.status).toBe(400);
    expect((await unresolved.json()).errors).toContain("address_unresolved");

    const http = await post(custom("http://searx.example.com"));
    expect((await http.json()).errors).toContain("http_not_allowed_on_web");
    expect(upstream).not.toHaveBeenCalled();
  });

  it("custom: target = origin + requestPath (recomputed server-side), SearXNG ignores the mapping, error rules keep only valid items", async () => {
    const upstream = stubUpstream(async () => jsonResponse(200, { results: [{ title: "A", url: "https://a.example/", content: "x" }] }));
    const res = await post({
      kind: "custom", protocol: "searxng", address: "https://searx.example.com/base/", mapping: MANUAL_MAPPING, query: "q",
    });
    expect(await res.json()).toEqual({ ok: true, kind: "results", results: [{ title: "A", url: "https://a.example/", snippet: "x" }] });
    expect(upstream.mock.calls[0][0].url.toString()).toBe("https://searx.example.com/base/search?q=q&format=json");

    stubUpstream(async () => jsonResponse(418, {}));
    const manual = await post({ kind: "custom", protocol: "manual", address: "https://s.example.com/api", mapping: MANUAL_MAPPING, query: "q", key: KEY });
    expect(await manual.json()).toMatchObject({ ok: false, errorClass: "rate_limited" });

    stubUpstream(async () => jsonResponse(419, {}));
    const dropped = await post({ kind: "custom", protocol: "manual", address: "https://s.example.com/api", mapping: MANUAL_MAPPING, query: "q", key: KEY });
    // Invalid error classes are dropped -> generic rule applies; the custom service's primary action becomes "check settings"
    expect(await dropped.json()).toMatchObject({ ok: false, errorClass: "request_rejected", card: { primaryAction: "check_settings" } });

    const bad = await post({ kind: "custom", protocol: "manual", address: "https://s.example.com/api", mapping: { ...MANUAL_MAPPING, method: "PUT" }, query: "q" });
    expect(bad.status).toBe(400);
    expect((await bad.json()).errors).toContain("method_invalid");
  });

  it("rate limit: the search: namespace counts independently, exceeding it gives 429 and does not eat into the relay quota", async () => {
    stubUpstream(async () => jsonResponse(200, { results: [] }));
    const ip = "198.51.100.77";
    for (let i = 0; i < 60; i++) {
      expect((await post("not json", ip)).status).toBe(400);
    }
    const limited = await post("not json", ip);
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBeTruthy();
    expect(checkRateLimit(`relay:${ip}`).allowed).toBe(true);
  });

  it("redirects: same-origin hops are re-pinned each time; cross-origin (with auth) aborts and never carries the key to another host", async () => {
    const sameOrigin = stubUpstream(async (input) => input.url.pathname === "/v1/tools/search"
      ? new Response(null, { status: 307, headers: { Location: "/v2/tools/search" } })
      : jsonResponse(200, { results: [] }));
    expect(await (await post(preset("deepseek", "cn"))).json()).toEqual({ ok: true, kind: "empty" });
    expect(sameOrigin).toHaveBeenCalledTimes(2);
    expect(sameOrigin.mock.calls[1][0].url.toString()).toBe("https://api.deepseek.com/v2/tools/search");
    expect(sameOrigin.mock.calls[1][0].method).toBe("POST");
    expect(mocks.resolve4).toHaveBeenCalledTimes(2);

    const crossOrigin = stubUpstream(async () => new Response(null, { status: 302, headers: { Location: "https://collector.example/steal" } }));
    const payload = await (await post(preset("deepseek", "cn"))).json();
    expect(payload).toMatchObject({ ok: false, errorClass: "request_rejected", retryOnce: false });
    expect(crossOrigin).toHaveBeenCalledTimes(1);
    expect(crossOrigin.mock.calls.map((call) => call[0].url.hostname)).not.toContain("collector.example");

    // https -> http on the same host also counts as cross-origin; the custom service's primary action is "check settings"
    const downgrade = stubUpstream(async () => new Response(null, { status: 301, headers: { Location: "http://s.example.com/api" } }));
    const custom = await (await post({ kind: "custom", protocol: "manual", address: "https://s.example.com/api", mapping: MANUAL_MAPPING, query: "q", key: KEY })).json();
    expect(custom).toMatchObject({ ok: false, errorClass: "request_rejected", card: { primaryAction: "check_settings" } });
    expect(downgrade).toHaveBeenCalledTimes(1);

    // Next same-origin hop resolves to a private address: refused locally
    mocks.resolve4.mockResolvedValueOnce(["203.0.113.10"]).mockResolvedValueOnce(["10.0.0.8"]);
    const rebound = stubUpstream(async () => new Response(null, { status: 307, headers: { Location: "/v2/tools/search" } }));
    expect(await (await post(preset("deepseek", "cn"))).json()).toMatchObject({ ok: false, errorClass: "request_rejected" });
    expect(rebound).toHaveBeenCalledTimes(1);
  });

  it("oversized response (declared length or actual bytes over 2 MB) aborts = response_too_large", async () => {
    stubUpstream(async () => jsonResponse(200, { results: [] }, { "Content-Length": String(3 * 1024 * 1024) }));
    expect(await (await post(preset("deepseek", "cn"))).json()).toMatchObject({ ok: false, errorClass: "response_too_large" });

    const chunk = new Uint8Array(512 * 1024).fill(0x20);
    let sent = 0;
    stubUpstream(async () => new Response(new ReadableStream<Uint8Array>({
      pull(controller) {
        sent += 1;
        if (sent > 5) controller.close();
        else controller.enqueue(chunk);
      },
    }), { status: 200 }));
    expect(await (await post(preset("deepseek", "cn"))).json()).toMatchObject({ ok: false, errorClass: "response_too_large" });
  });

  it("auth-header redaction: when an upstream error carries the key / Authorization, neither the response nor the logs contain it", async () => {
    const consoleSpies = (["log", "info", "warn", "error", "debug"] as const).map((level) => vi.spyOn(console, level));
    stubUpstream(async (input) => {
      throw new Error(`socket hang up Authorization: ${input.headers.Authorization} X-Search-Token: ${input.headers["X-Search-Token"]}`);
    });
    const presetText = await (await post(preset("deepseek", "cn"))).text();
    const customText = await (await post({
      kind: "custom", protocol: "manual", address: "https://s.example.com/api", mapping: MANUAL_MAPPING, query: "q", key: "custom-secret-1234",
    })).text();
    for (const text of [presetText, customText]) {
      expect(JSON.parse(text)).toMatchObject({ ok: false, errorClass: "network" });
      expect(text).not.toContain(KEY);
      expect(text).not.toContain("custom-secret-1234");
      expect(text).not.toMatch(/authorization|x-search-token/i);
    }
    for (const spy of consoleSpies) {
      expect(JSON.stringify(spy.mock.calls)).not.toContain(KEY);
      expect(JSON.stringify(spy.mock.calls)).not.toContain("custom-secret-1234");
    }
  });
});

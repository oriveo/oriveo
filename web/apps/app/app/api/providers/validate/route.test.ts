import { beforeEach, describe, expect, it, vi } from "vitest";
import { brand } from "@oriveo/config";

// relay.example.com is an RFC 2606 reserved test domain and does not resolve in a real
// environment (NXDOMAIN), so the SSRF guard DNS check fails closed with a 403. The official
// provider cases in this file (openAI/anthropic/gemini/...) also pass through that DNS check, so
// DNS resolution is mocked to a fixed public address here. The guard still runs its real
// protocol / port / private-literal / public-domain checks, just without depending on the network.
//
// The guard behavior for unreachable or private addresses is covered separately in
// ssrf-guard.test.ts, including DNS rebinding. This file adds one 403 assertion for a private IP
// literal (see "relay blocks forbidden addresses"): a literal IP is rejected before DNS
// resolution, so the mock above does not affect it, which proves the guard is still active on
// this route.
const dnsMocks = vi.hoisted(() => ({
  resolve4: vi.fn(async () => ["203.0.113.10"]),
  resolve6: vi.fn(async () => {
    throw Object.assign(new Error("ENODATA"), { code: "ENODATA" });
  }),
  lookup: vi.fn(async () => [{ address: "203.0.113.10", family: 4 }]),
}));

vi.mock("node:dns/promises", () => ({
  default: dnsMocks,
  ...dnsMocks,
}));

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function textResponse(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function buildRequest(body: unknown): Request {
  return new Request("http://localhost/api/providers/validate", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/**
 * Mock the validation contract served by runtime metadata, one per provider.
 */
function mockMetadata(
  validationByKind: Record<string, unknown>,
): void {
  vi.doMock("../../chat/stream/runtime", async (importOriginal) => {
    const actual = await importOriginal<typeof import("../../chat/stream/runtime")>();
    const providers: Record<string, { validation: unknown; models: Record<string, unknown> }> = {};
    for (const [kind, validation] of Object.entries(validationByKind)) {
      providers[kind] = { validation, models: {} };
    }
    return {
      ...actual,
      getRuntimeMetadata: vi.fn().mockResolvedValue({ providers }),
    };
  });
}

async function loadRoute() {
  vi.resetModules();
  return import("./route");
}

describe("/api/providers/validate", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.resetModules();
    vi.doUnmock("../../chat/stream/runtime");
  });

  it("official provider with 2xx probe → valid", async () => {
    mockMetadata({
      openAI: { probe: "list_models", probePath: "/models", authMode: "bearer", headerProfile: "none", invalidKeySignals: [{ status: 401 }] },
    });
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      expect(String(input)).toBe("https://api.openai.com/v1/models");
      expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer sk-openai");
      return jsonResponse({ data: [] });
    });

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "openAI", apiKey: "sk-openai" }) as never);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ result: "valid", status: 200 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("official provider hitting invalidKeySignal status (401) → invalid", async () => {
    mockMetadata({
      openAI: { probe: "list_models", probePath: "/models", authMode: "bearer", headerProfile: "none", invalidKeySignals: [{ status: 401 }] },
    });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(textResponse('{"error":"unauthorized"}', 401));

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "openAI", apiKey: "bad" }) as never);

    expect(await response.json()).toEqual({ result: "invalid", status: 401 });
  });

  it("Grok 400 with bodyIncludes (AND) → invalid; 400 without needle → unverified", async () => {
    mockMetadata({
      grok: {
        probe: "list_models",
        probePath: "/models",
        authMode: "bearer",
        headerProfile: "none",
        invalidKeySignals: [
          { status: 400, bodyIncludes: ["Incorrect API key", "invalid argument"] },
          { status: 401 },
        ],
      },
    });

    // Body contains both needles, so the AND matches and the result is invalid
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse("Incorrect API key provided / invalid argument", 400),
    );
    let { POST } = await loadRoute();
    let response = await POST(buildRequest({ providerKind: "grok", apiKey: "bad", baseURL: "https://api.x.ai/v1" }) as never);
    expect(await response.json()).toEqual({ result: "invalid", status: 400 });

    // Body contains only one needle, so the AND does not match and the result is unverified
    vi.resetModules();
    vi.doUnmock("../../chat/stream/runtime");
    mockMetadata({
      grok: {
        probe: "list_models",
        probePath: "/models",
        authMode: "bearer",
        headerProfile: "none",
        invalidKeySignals: [
          { status: 400, bodyIncludes: ["Incorrect API key", "invalid argument"] },
          { status: 401 },
        ],
      },
    });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(textResponse("Incorrect API key only", 400));
    ({ POST } = await loadRoute());
    response = await POST(buildRequest({ providerKind: "grok", apiKey: "bad", baseURL: "https://api.x.ai/v1" }) as never);
    expect(await response.json()).toEqual({ result: "unverified", status: 400 });
  });

  it("joins the Anthropic base URL and probePath without doubling the /v1 prefix", async () => {
    // The contract sets probePath=`/v1/models` while the web default base already ends in `/v1`, so deduplication must not yield `.../v1/v1/models`
    mockMetadata({
      anthropic: {
        probe: "list_models",
        probePath: "/v1/models",
        authMode: "x_api_key",
        headerProfile: "anthropic_v2023_06_01",
        invalidKeySignals: [{ status: 401 }],
      },
    });
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      // Exact-equality assertion: a doubled prefix would show up here as `.../v1/v1/models` and fail immediately
      expect(String(input)).toBe("https://api.anthropic.com/v1/models");
      const headers = init?.headers as Record<string, string>;
      expect(headers["x-api-key"]).toBe("sk-ant");
      expect(headers["anthropic-version"]).toBe("2023-06-01");
      return jsonResponse({ data: [] });
    });

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "anthropic", apiKey: "sk-ant" }) as never);

    expect(await response.json()).toEqual({ result: "valid", status: 200 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("joins the Gemini base URL and probePath and passes the key as a query param", async () => {
    // The contract sets probePath=`/v1beta/models` while the web default base already ends in `/v1beta`, so deduplication must give an exact match
    mockMetadata({
      gemini: {
        probe: "list_models",
        probePath: "/v1beta/models",
        authMode: "query_key",
        headerProfile: "none",
        invalidKeySignals: [
          { status: 400, bodyIncludes: ["API key not valid", "INVALID_ARGUMENT"] },
          { status: 403 },
        ],
      },
    });
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      // Exact equality: a doubled prefix would show up here as `.../v1beta/v1beta/models?key=bad` and fail immediately
      expect(String(input)).toBe(
        "https://generativelanguage.googleapis.com/v1beta/models?key=bad",
      );
      // The key goes in a query param, not in the Authorization header
      expect((init?.headers as Record<string, string>).Authorization).toBeUndefined();
      return textResponse('{"error":{"message":"API key not valid","status":"INVALID_ARGUMENT"}}', 400);
    });

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "gemini", apiKey: "bad" }) as never);

    expect(await response.json()).toEqual({ result: "invalid", status: 400 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("Gemini 403 (no bodyIncludes) → invalid regardless of body", async () => {
    mockMetadata({
      gemini: {
        probe: "list_models",
        probePath: "/v1beta/models",
        authMode: "query_key",
        headerProfile: "none",
        invalidKeySignals: [
          { status: 400, bodyIncludes: ["API key not valid", "INVALID_ARGUMENT"] },
          { status: 403 },
        ],
      },
    });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(textResponse("forbidden", 403));

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "gemini", apiKey: "bad" }) as never);

    expect(await response.json()).toEqual({ result: "invalid", status: 403 });
  });

  it("OpenRouter probes /key with openrouter header profile", async () => {
    mockMetadata({
      openRouter: { probe: "key_info", probePath: "/key", authMode: "bearer", headerProfile: "openrouter", invalidKeySignals: [{ status: 401 }] },
    });
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      expect(String(input)).toBe("https://openrouter.ai/api/v1/key");
      const headers = init?.headers as Record<string, string>;
      expect(headers.Authorization).toBe("Bearer sk-or");
      expect(headers["HTTP-Referer"]).toBe(brand.appUrl);
      expect(headers["X-Title"]).toBe(brand.name);
      return jsonResponse({ data: { label: "key" } });
    });

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "openRouter", apiKey: "sk-or" }) as never);

    expect(await response.json()).toEqual({ result: "valid", status: 200 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("MiniMax only honours HTTP status: 200 body with internal error code → valid", async () => {
    mockMetadata({
      miniMax: { probe: "list_models", probePath: "/models", authMode: "bearer", headerProfile: "none", invalidKeySignals: [{ status: 401 }] },
    });
    // A 200 whose body carries contradictory MiniMax error codes (1004/2049): only the HTTP status counts, so this is valid
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse('{"base_resp":{"status_code":1004,"status_msg":"token expired"}}', 200),
    );

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "miniMax", apiKey: "k", baseURL: "https://api.minimax.io/v1" }) as never);

    expect(await response.json()).toEqual({ result: "valid", status: 200 });
  });

  it("official provider 404/429/5xx not in signals → unverified ( )", async () => {
    mockMetadata({
      openAI: { probe: "list_models", probePath: "/models", authMode: "bearer", headerProfile: "none", invalidKeySignals: [{ status: 401 }] },
    });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(textResponse("rate limited", 429));

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "openAI", apiKey: "k" }) as never);

    expect(await response.json()).toEqual({ result: "unverified", status: 429 });
  });

  it("official provider network error → unverified (no status)", async () => {
    mockMetadata({
      openAI: { probe: "list_models", probePath: "/models", authMode: "bearer", headerProfile: "none", invalidKeySignals: [{ status: 401 }] },
    });
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("ECONNREFUSED"));

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "openAI", apiKey: "k" }) as never);

    expect(await response.json()).toEqual({ result: "unverified" });
  });

  it("missing validation contract falls back to list_models + bearer + 401 signal", async () => {
    mockMetadata({}); // no validation contract for deepseek
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      expect(String(input)).toBe("https://api.deepseek.com/v1/models");
      expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer k");
      return textResponse("unauthorized", 401);
    });

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ providerKind: "deepseek", apiKey: "k", baseURL: "https://api.deepseek.com/v1" }) as never);

    expect(await response.json()).toEqual({ result: "invalid", status: 401 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("relay keeps upstream validation through /models", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === "https://relay.example.com/v1/models") {
          expect((init?.headers as Record<string, string>).Authorization).toBe(
            "Bearer sk-relay-test",
          );
          return jsonResponse({
            data: [{ id: "relay-model" }],
          });
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "relay",
        apiKey: "sk-relay-test",
        baseURL: "https://relay.example.com/v1",
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ valid: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("relay blocks forbidden addresses (SSRF guard stays live in this route)", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch");

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "relay",
        apiKey: "sk-relay-test",
        // Cloud metadata address literal: blocked before DNS resolution, so the DNS mock at the top of this file does not apply.
        baseURL: "https://169.254.169.254/v1",
      }) as never,
    );

    expect(response.status).toBe(403);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects missing fields / unknown provider", async () => {
    const { POST } = await loadRoute();

    const missing = await POST(buildRequest({ providerKind: "openAI" }) as never);
    expect(missing.status).toBe(400);

    const unknown = await POST(buildRequest({ providerKind: "nope", apiKey: "k" }) as never);
    expect(unknown.status).toBe(400);
  });
});

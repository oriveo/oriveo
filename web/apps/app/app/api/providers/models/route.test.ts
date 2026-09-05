import { beforeEach, describe, expect, it, vi } from "vitest";

// relay.example.com is an RFC 2606 reserved test domain and does not resolve (NXDOMAIN), so the
// SSRF guard's DNS check would fail closed with a 403. DNS resolution is mocked here to a fixed
// public address, which keeps the guard's protocol, port, private-literal and public-domain
// checks running through real code without depending on real network resolution.
//
// The guard's own "unresolvable or private address must 403" behavior is covered separately in
// ssrf-guard.test.ts, including DNS rebinding. This file adds one 403 assertion for a private IP
// literal (see "relay blocks forbidden addresses" below): a literal IP is rejected before DNS
// resolution and is therefore unaffected by the mock, which proves the guard is still active on
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

// getRuntimeMetadata is shared with chat/stream, so this is the same lean view. The route only
// reads the keys of providers[kind].models, and lean trims fields inside a model without
// dropping model entries.
const METADATA_URL = "https://api.oriveoai.com/api/metadata?view=lean";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function buildRequest(body: unknown): Request {
  return new Request("http://localhost/api/providers/models", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function buildMetadata(body: Record<string, unknown>) {
  return {
    code: 0,
    message: "ok",
    data: {
      version: 1,
      updatedAt: "2026-04-08T00:00:00Z",
      profiles: {
        reasoning: {},
        webSearch: {},
        imageGen: {},
      },
      ...body,
    },
  };
}

async function loadRoute() {
  vi.resetModules();
  const runtime = await import("../../chat/stream/runtime");
  runtime.__resetRuntimeMetadataCache();
  return import("./route");
}

describe("/api/providers/models", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("official providers return metadata models without pinging upstream", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              providers: {
                qwen: {
                  defaultModelId: "qwen3-max",
                  resolveMap: {
                    "qwen3-max": "qwen3-max",
                    "qwen-plus": "qwen-plus",
                    "qwen-image-2.0": "qwen-image-2.0",
                  },
                  models: {
                    "qwen3-max": {
                      canonicalModelId: "qwen3-max",
                      displayName: "Qwen3 Max",
                      capabilities: ["text", "reasoning"],
                    },
                    "qwen-plus": {
                      canonicalModelId: "qwen-plus",
                      displayName: "Qwen Plus",
                      capabilities: ["text"],
                    },
                    "qwen-image-2.0": {
                      canonicalModelId: "qwen-image-2.0",
                      displayName: "Qwen Image 2.0",
                      capabilities: ["imageGeneration"],
                    },
                  },
                },
              },
            }),
          );
        }

        throw new Error(`Unexpected upstream fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "qwen",
        apiKey: "sk-qwen-test",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      }) as never,
    );

    expect(response.status).toBe(200);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe(METADATA_URL);

    const payload = (await response.json()) as { data: Array<{ id: string }> };
    expect(payload.data.map((model) => model.id)).toEqual([
      "qwen-image-2.0",
      "qwen-plus",
      "qwen3-max",
    ]);
  });

  it("relay keeps upstream model discovery", async () => {
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
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(await response.json()).toEqual({ data: [{ id: "relay-model" }] });
  });

  it("relay blocks forbidden addresses (SSRF guard stays live in this route)", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch");

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "relay",
        apiKey: "sk-relay-test",
        // A cloud metadata address literal is rejected before DNS resolution, so the mock at the top of this file does not apply.
        baseURL: "https://169.254.169.254/v1",
      }) as never,
    );

    expect(response.status).toBe(403);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

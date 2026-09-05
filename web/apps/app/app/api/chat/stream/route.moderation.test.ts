// Content moderation gate on the chat/stream route: it screens image generation requests only and leaves text chat alone.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const trackEventMock = vi.hoisted(() => vi.fn());
const captureMessageMock = vi.hoisted(() => vi.fn());

vi.mock("../../../../lib/core/telemetry", () => ({
  trackEvent: trackEventMock,
}));

vi.mock("@sentry/nextjs", () => ({
  captureMessage: captureMessageMock,
}));

// Exact match: this chain only needs transport, endpoints and profiles, so it uses the lean view
// (full is about 2.4 times larger). Dropping ?view=lean turns this whole file red.
const METADATA_URL = "https://api.oriveoai.com/api/metadata?view=lean";
const MODERATION_URL = "https://moderation.example.invalid/v1/moderation/prompt";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function sseResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/event-stream" },
  });
}

function buildRequest(body: unknown): Request {
  return new Request("http://localhost/api/chat/stream", {
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
      updatedAt: "2026-03-26T10:00:00Z",
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {},
      ...body,
    },
  };
}

function imageGenMetadata() {
  return buildMetadata({
    profiles: {
      reasoning: {},
      webSearch: {},
      imageGen: { oai_images: { route: "images_api" } },
    },
    providers: {
      openAI: {
        resolveMap: { "gpt-image-1": "gpt-image-1" },
        models: {
          "gpt-image-1": {
            canonicalModelId: "gpt-image-1",
            profiles: { imageGen: "oai_images" },
          },
        },
      },
    },
  });
}

function textMetadata() {
  return buildMetadata({
    providers: {
      openAI: {
        resolveMap: { "gpt-4o-mini": "gpt-4o-mini" },
        models: {
          "gpt-4o-mini": { canonicalModelId: "gpt-4o-mini", profiles: {} },
        },
      },
    },
  });
}

async function loadRoute() {
  vi.resetModules();
  const runtime = await import("./runtime");
  runtime.__resetRuntimeMetadataCache();
  return import("./route");
}

describe("/api/chat/stream content moderation", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    trackEventMock.mockClear();
    captureMessageMock.mockClear();
    vi.stubEnv("MODERATION_MODERATION_API_KEY", "moderation_test_key");
    vi.stubEnv("MODERATION_MODERATION_BASE_URL", "https://moderation.example.invalid");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("blocks an image prompt and never calls the image endpoint when moderation denies it", async () => {
    let imageCalled = false;
    let moderationBody: unknown = null;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) return jsonResponse(imageGenMetadata());
      if (url === MODERATION_URL) {
        moderationBody = JSON.parse(String(init?.body));
        return jsonResponse({
          id: "mod_1",
          object: "moderation_result",
          decision: "deny",
        });
      }
      if (url === "https://api.openai.com/v1/images/generations") {
        imageCalled = true;
        return jsonResponse({ data: [{ b64_json: "x" }] });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "gpt-image-1",
        messages: [{ role: "user", content: "disallowed prompt" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain('"type":"error"');
    expect(body).toContain('"errorKind":"moderation"');
    expect(imageCalled).toBe(false);
    expect(moderationBody).toEqual({
      prompt: "disallowed prompt",
      external_id: "openAI:gpt-image-1",
    });
  });

  it("screens then forwards an image prompt when moderation allows it", async () => {
    let moderationCalled = false;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url === METADATA_URL) return jsonResponse(imageGenMetadata());
      if (url === MODERATION_URL) {
        moderationCalled = true;
        return jsonResponse({
          id: "mod_1",
          object: "moderation_result",
          decision: "allow",
        });
      }
      if (url === "https://api.openai.com/v1/images/generations") {
        return jsonResponse({
          data: [{ b64_json: "aGVsbG8=" }],
          usage: { input_tokens: 8, output_tokens: 1 },
        });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "gpt-image-1",
        messages: [{ role: "user", content: "draw a fox" }],
      }) as never,
    );

    expect(moderationCalled).toBe(true);
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("text/event-stream");
    expect(await response.text()).toContain("data:image/png;base64,aGVsbG8=");
  });

  it("does not moderate a plain text chat request", async () => {
    let moderationCalled = false;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url === METADATA_URL) return jsonResponse(textMetadata());
      if (url === MODERATION_URL) {
        moderationCalled = true;
        return jsonResponse({ decision: "deny" });
      }
      if (url === "https://api.openai.com/v1/chat/completions") {
        return sseResponse(
          'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n',
        );
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "gpt-4o-mini",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(moderationCalled).toBe(false);
  });
});

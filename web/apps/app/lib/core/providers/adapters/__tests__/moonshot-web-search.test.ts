/**
 * Regression guard against Kimi reasoning being suppressed on the direct browser path:
 * 1. thinking is decoupled from web search. automatic carries no thinking (k2.5/k2.6
 *    default to enabled upstream and were once forced to disabled, suppressing reasoning),
 *    fast turns it off explicitly and deep turns it on explicitly.
 * 2. Web search only follows the metadata recipe: the official Formula (moonshot.formula.web.v1)
 *    runs the same core Formula/Fiber loop as the proxy route (GET tools, chat, POST fibers,
 *    fill back role=tool); with no Formula recipe the turn runs without web search, and no leg
 *    ever carries the retired built-in `$web_search`.
 * 3. Usage across legs is emitted once through the multi-leg merge entry (priced per leg).
 */
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("../../../metadata/metadata-client", async (importOriginal) => (await import("../../../../__tests__/mocks/metadata-client")).metadataClientMock(importOriginal, {
  initMetadata: vi.fn().mockResolvedValue(undefined),
  refreshMetadata: vi.fn().mockResolvedValue(undefined),
  listProviderModelIds: vi.fn().mockReturnValue([]),
  resolveCatalogModel: vi.fn(),
  getReasoningProfile: vi.fn(),
  getWebSearchProfile: vi.fn(),
  browserOfficialMetadata: vi.fn(),
}));

import {
  resetUnsupportedParamCacheForTesting,
} from "@oriveo/core/providers/unsupported-param";
import {
  browserOfficialMetadata,
  getReasoningProfile,
  getWebSearchProfile,
  resolveCatalogModel,
} from "../../../metadata/metadata-client";
import { sendMessageStream } from "../moonshot";
import type { StreamEvent, StreamUsage } from "../../types";

const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);
const mockGetReasoningProfile = vi.mocked(getReasoningProfile);
const mockGetWebSearchProfile = vi.mocked(getWebSearchProfile);
const mockBrowserOfficialMetadata = vi.mocked(browserOfficialMetadata);

function repoPath(relative: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const next = path.dirname(current);
    if (next === current) throw new Error(relative);
    current = next;
  }
}

/** The same recipe registry the server ships: the Formula recipe is taken verbatim from the shared capability_runtime. */
const runtimeRecipes = (JSON.parse(readFileSync(
  repoPath("shared/capabilityrecipe/capability_runtime.v1.json"),
  "utf8",
)) as { recipes: Record<string, unknown> }).recipes;

/** /api/metadata payload: no webRecipeRef means the model has no web control (the server treats an unnamed model as unknown). */
function moonshotMetadata(modelID: string, webRecipeRef?: string): never {
  return {
    version: 2,
    updatedAt: "2026-10-26T00:00:00Z",
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    capabilityRuntime: {
      schemaVersion: 2, revision: "fixture", generatedAt: "2026-10-26T00:00:00Z",
      recipes: runtimeRecipes, controlDefinitions: {}, sourceIndex: {},
    },
    providers: {
      moonshot: {
        resolveMap: { [modelID]: modelID },
        models: {
          [modelID]: {
            transport: "openai_chat",
            ...(webRecipeRef
              ? { capabilityControls: { web: { state: "auto_available", recipeRef: webRecipeRef } } }
              : {}),
          },
        },
      },
    },
  } as never;
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** The legacy webSearch profile is still in the catalog: assert it is no longer turned into `$web_search`. */
const LEGACY_WEB_SEARCH_PROFILE = {
  name: "kimi_web_search",
  mergeParams: { tools: [{ type: "builtin_function", function: { name: "$web_search" } }] },
  maxToolLoops: 4,
  streamShape: null,
} as never;

function sseResponse(payloads: string[]): Response {
  const body = payloads.map((payload) => `data: ${payload}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "text/event-stream" },
  });
}

async function collect(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const reader = stream.getReader();
  const events: StreamEvent[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  return events;
}

afterEach(() => {
  vi.unstubAllGlobals();
  resetUnsupportedParamCacheForTesting();
  mockResolveCatalogModel.mockReset();
  mockGetReasoningProfile.mockReset();
  mockGetWebSearchProfile.mockReset();
  mockBrowserOfficialMetadata.mockReset();
});

describe("moonshot thinking parameter", () => {
  it("does not inject thinking locally per level when there is no reasoning profile", async () => {
    const fetchMock = vi.fn().mockResolvedValue(sseResponse([]));
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({ profiles: {} } as never);

    const handle = sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "hello" }],
      "https://api.moonshot.cn/v1",
      { reasoning: "deep" },
    );
    await collect(handle.stream);

    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.thinking).toBeUndefined();
    expect(body.tools).toBeUndefined();
  });

  it("merges thinking from params[mode] when a reasoning profile matches", async () => {
    const fetchMock = vi.fn().mockResolvedValue(sseResponse([]));
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({
      profiles: { reasoning: "kimi_thinking" },
    } as never);
    mockGetReasoningProfile.mockReturnValue({
      name: "kimi_thinking",
      levels: ["fast", "deep"],
      params: {
        deep: { thinking: { type: "enabled", budget_tokens: 8192 } },
      },
      streamShape: null,
    } as never);

    const handle = sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "hello" }],
      "https://api.moonshot.cn/v1",
      { reasoning: "deep" },
    );
    await collect(handle.stream);

    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.thinking).toEqual({ type: "enabled", budget_tokens: 8192 });
    expect(mockGetReasoningProfile).toHaveBeenCalledWith("kimi_thinking");
  });
});

describe("moonshot browser-direct web search (official Formula)", () => {
  const BASE = "https://api.moonshot.cn/v1";
  const FORMULA_TOOL = {
    type: "function",
    function: { name: "web_search", description: "search", parameters: { type: "object", properties: {} } },
  };

  it("Formula recipe with web search on: GET tools, chat, POST fibers, fill back role=tool, then the answer", async () => {
    const leg1 = [
      '{"model":"kimi-k2.6","choices":[{"delta":{"reasoning_content":"search first"}}],"usage":null}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":"}}]}}],"usage":null}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Shanghai weather\\"}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cached_tokens":2}}',
    ];
    const leg2 = [
      '{"choices":[{"delta":{"content":"the answer"}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":7,"cached_tokens":3}}',
    ];
    const chatLegs = [sseResponse(leg1), sseResponse(leg2)];
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url.endsWith("/tools")) return jsonResponse({ tools: [FORMULA_TOOL] });
      if (url.endsWith("/fibers")) return jsonResponse({ status: "succeeded", context: { output: "Sunny 25C" } });
      void init;
      return chatLegs.shift()!;
    });
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({ profiles: { webSearch: "kimi_web_search" } } as never);
    mockGetWebSearchProfile.mockReturnValue(LEGACY_WEB_SEARCH_PROFILE);
    mockBrowserOfficialMetadata.mockResolvedValue(moonshotMetadata("kimi-k2.6", "moonshot.formula.web.v1"));

    const events = await collect(sendMessageStream(
      "sk-test",
      "kimi-k2.6",
      [{ role: "user", content: "What is the weather in Shanghai" }],
      BASE,
      { supportsWebSearch: true },
    ).stream);

    expect(mockBrowserOfficialMetadata).toHaveBeenCalledWith("moonshot");
    const calls = fetchMock.mock.calls.map(([url, init]) => [init?.method ?? "GET", url]);
    expect(calls).toEqual([
      ["GET", `${BASE}/formulas/moonshot/web-search:latest/tools`],
      ["POST", `${BASE}/chat/completions`],
      ["POST", `${BASE}/formulas/moonshot/web-search:latest/fibers`],
      ["POST", `${BASE}/chat/completions`],
    ]);
    for (const [, init] of fetchMock.mock.calls) {
      expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer sk-test");
      expect(String(init?.body ?? "")).not.toContain("$web_search");
    }

    // First leg: tools are only the Formula declarations returned by the official GET (verbatim, never rewritten locally)
    const firstBody = JSON.parse(fetchMock.mock.calls[1][1]!.body as string);
    expect(firstBody.tools).toEqual([FORMULA_TOOL]);
    expect(firstBody.messages).toEqual([{ role: "user", content: "What is the weather in Shanghai" }]);
    // Fiber: name plus the raw arguments string, executed as-is
    expect(JSON.parse(fetchMock.mock.calls[2][1]!.body as string)).toEqual({
      name: "web_search",
      arguments: '{"query":"Shanghai weather"}',
    });
    // Second leg feed-back: the assistant echo carries reasoning_content; the tool message is the Fiber context.output
    const secondBody = JSON.parse(fetchMock.mock.calls[3][1]!.body as string);
    expect(secondBody.messages.at(-2)).toMatchObject({ role: "assistant", reasoning_content: "search first" });
    expect(secondBody.messages.at(-1)).toEqual({
      role: "tool", tool_call_id: "call_1", name: "web_search", content: "Sunny 25C",
    });

    expect(events).toContainEqual({ type: "model", modelID: "kimi-k2.6" });
    expect(events.filter((event) => event.type === "tool_result")).toEqual([
      { type: "tool_result", tool: "web_search", summary: "web_search", step: 1 },
    ]);
    const text = events
      .filter((event) => event.type === "delta")
      .map((event) => (event as { content: string }).content)
      .join("");
    expect(text).toBe("the answer");
    expect(events.some((event) => event.type === "reasoning")).toBe(true);
    // The closing usage frame is decoded by the same parser as the proxy route and yields exactly one event; per-leg usage is not forwarded, only this cross-leg merged value.
    const usageEvents = events.filter((event) => event.type === "usage") as Array<{ usage: StreamUsage }>;
    expect(usageEvents).toHaveLength(1);
    const usage = usageEvents[0]!.usage;
    expect(usage.prompt_tokens).toBe(30);
    expect(usage.completion_tokens).toBe(12);
    expect(usage.legs?.map((leg) => leg.breakdown?.cachedInputTokens)).toEqual([2, 3]);
    expect(events.some((event) => event.type === "error")).toBe(false);
    expect(events.at(-1)?.type).toBe("done");
  });

  it("a failed Formula tools GET raises a provider error and sends no chat leg", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ error: { message: "invalid key" } }, 401));
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({ profiles: {} } as never);
    mockBrowserOfficialMetadata.mockResolvedValue(moonshotMetadata("kimi-k2.6", "moonshot.formula.web.v1"));

    const events = await collect(sendMessageStream(
      "sk-test",
      "kimi-k2.6",
      [{ role: "user", content: "What is the weather in Shanghai" }],
      BASE,
      { supportsWebSearch: true },
    ).stream);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(events).toEqual([expect.objectContaining({ type: "error", source: "provider" })]);
  });

  it("web search on but the model has no Formula recipe (or metadata is not loaded): this turn runs without web search, no tools and no $web_search", async () => {
    for (const metadata of [moonshotMetadata("kimi-k2.5"), null]) {
      const fetchMock = vi.fn().mockResolvedValue(
        sseResponse(['{"choices":[{"delta":{"content":"a direct answer"}}],"usage":null}']),
      );
      vi.stubGlobal("fetch", fetchMock);
      mockResolveCatalogModel.mockReturnValue({ profiles: { webSearch: "kimi_web_search" } } as never);
      mockGetWebSearchProfile.mockReturnValue(LEGACY_WEB_SEARCH_PROFILE);
      mockBrowserOfficialMetadata.mockResolvedValue(metadata as never);

      const events = await collect(sendMessageStream(
        "sk-test",
        "kimi-k2.5",
        [{ role: "user", content: "hello" }],
        BASE,
        { supportsWebSearch: true },
      ).stream);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(fetchMock.mock.calls[0][0]).toBe(`${BASE}/chat/completions`);
      const rawBody = fetchMock.mock.calls[0][1].body as string;
      expect(JSON.parse(rawBody).tools).toBeUndefined();
      expect(rawBody).not.toContain("$web_search");
      expect(events.filter((event) => event.type === "delta")).toEqual([{ type: "delta", content: "a direct answer" }]);
      expect(events.at(-1)?.type).toBe("done");
    }
  });

  it("web search off: a plain single-leg request that does not read the metadata recipe", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      sseResponse(['{"choices":[{"delta":{"content":"a direct answer"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}']),
    );
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({ profiles: { webSearch: "kimi_web_search" } } as never);
    mockGetWebSearchProfile.mockReturnValue(LEGACY_WEB_SEARCH_PROFILE);

    const events = await collect(sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "hello" }],
      BASE,
      {},
    ).stream);

    expect(mockBrowserOfficialMetadata).not.toHaveBeenCalled();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body as string)).toEqual({
      model: "kimi-k2.5",
      stream: true,
      stream_options: { include_usage: true },
      messages: [{ role: "user", content: "hello" }],
    });
    expect(events.filter((event) => event.type === "usage")).toHaveLength(1);
    expect(events.at(-1)?.type).toBe("done");
  });

  /**
   * A 400 naming a rejected parameter no longer triggers drop-and-retry:
   * `executeWithUnsupportedParamSelfHeal` only keeps the 404 endpoint fallback, and any 400 is
   * raised to the user on a single leg. The thinking level the user chose goes out as-is, and an
   * upstream rejection is a user-visible error; thinking must not be silently dropped and the
   * request resent as if it had succeeded.
   */
  it("raises a user-visible error on a single leg when the first leg gets a 400 naming thinking, instead of retrying without it", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response('{"error":{"message":"unknown parameter: thinking"}}', { status: 400 }))
      .mockResolvedValueOnce(sseResponse(['{"choices":[{"delta":{"content":"the answer"}}],"usage":null}']));
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({
      profiles: { reasoning: "kimi_thinking" },
    } as never);
    mockGetReasoningProfile.mockReturnValue({
      name: "kimi_thinking",
      levels: ["deep"],
      params: { deep: { thinking: { type: "enabled" } } },
      streamShape: null,
    } as never);
    mockBrowserOfficialMetadata.mockResolvedValue(moonshotMetadata("kimi-k2.5"));

    const handle = sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "look this up online" }],
      "https://api.moonshot.cn/v1",
      { supportsWebSearch: true, reasoning: "deep" },
    );
    const events = await collect(handle.stream);

    // Only one leg is sent: no second leg is the objective evidence that no parameter was silently dropped and retried.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const firstBody = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    // The deep level the user chose really went out; it is not a case of the UI showing a selection with nothing in the request body.
    expect(firstBody.thinking).toEqual({ type: "enabled" });
    // The failure is visible to the user and is never dressed up as a successful answer.
    expect(events.at(-1)).toMatchObject({ type: "error", status: 400 });
    expect(events.some((event) => event.type === "delta")).toBe(false);
  });
});

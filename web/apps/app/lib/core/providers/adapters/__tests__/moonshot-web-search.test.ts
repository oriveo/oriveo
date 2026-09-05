/**
 * Regression guard against Kimi reasoning being suppressed on the direct browser path:
 * 1. thinking is decoupled from web search. automatic carries no thinking (k2.5/k2.6
 *    default to enabled upstream and were once forced to disabled, suppressing reasoning),
 *    fast turns it off explicitly and deep turns it on explicitly.
 * 2. Web search runs as a browser-side streaming tool loop: the assistant tool-call
 *    message fed back in must carry reasoning_content, since Kimi returns 400 when it is
 *    missing while thinking is active.
 * 3. Across multiple legs, reasoning is joined with "\n\n" and usage is captured per leg,
 *    accumulated and emitted once.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  refreshMetadata: vi.fn().mockResolvedValue(undefined),
  listProviderModelIds: vi.fn().mockReturnValue([]),
  resolveCatalogModel: vi.fn(),
  getReasoningProfile: vi.fn(),
  getWebSearchProfile: vi.fn(),
}));

import {
  resetUnsupportedParamCacheForTesting,
} from "@oriveo/core/providers/unsupported-param";
import {
  getReasoningProfile,
  getWebSearchProfile,
  resolveCatalogModel,
} from "../../../metadata/metadata-client";
import { sendMessageStream } from "../moonshot";
import type { StreamEvent } from "../../types";

const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);
const mockGetReasoningProfile = vi.mocked(getReasoningProfile);
const mockGetWebSearchProfile = vi.mocked(getWebSearchProfile);

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

describe("moonshot browser-side streaming tool loop", () => {
  it("does not inject tools or enter the tool loop for supportsWebSearch without a web profile", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      sseResponse(['{"choices":[{"delta":{"content":"a direct answer"}}],"usage":null}']),
    );
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({ profiles: {} } as never);

    const handle = sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "hello" }],
      "https://api.moonshot.cn/v1",
      { supportsWebSearch: true },
    );
    const events = await collect(handle.stream);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.tools).toBeUndefined();
    expect(events.at(-1)?.type).toBe("done");
  });

  it("feeds back reasoning_content, joins legs with a separator and accumulates usage", async () => {
    const leg1 = [
      '{"choices":[{"delta":{"role":"assistant","content":""}}],"usage":null}',
      '{"choices":[{"delta":{"reasoning_content":"let me think"}}],"usage":null}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{\\"search"}}]}}],"usage":null}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"_id\\":\\"abc\\"}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cached_tokens":2}}',
    ];
    const leg2 = [
      '{"choices":[{"delta":{"reasoning_content":"now to sum up"}}],"usage":null}',
      '{"choices":[{"delta":{"content":"the answer"}}],"usage":null}',
      '{"choices":[{"delta":{}}],"usage":{"prompt_tokens":20,"completion_tokens":7,"cached_tokens":3}}',
    ];
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(sseResponse(leg1))
      .mockResolvedValueOnce(sseResponse(leg2));
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({
      profiles: { webSearch: "kimi_web_search" },
    } as never);
    mockGetWebSearchProfile.mockReturnValue({
      name: "kimi_web_search",
      mergeParams: {
        tools: [{ type: "builtin_function", function: { name: "$web_search" } }],
      },
      maxToolLoops: 4,
      streamShape: null,
    } as never);

    const handle = sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "what is the weather in Shanghai" }],
      "https://api.moonshot.cn/v1",
      { supportsWebSearch: true },
    );
    const events = await collect(handle.stream);

    expect(fetchMock).toHaveBeenCalledTimes(2);

    // First leg: automatic carries no thinking and does carry the builtin $web_search tools.
    const firstBody = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(firstBody.thinking).toBeUndefined();
    expect(firstBody.tools).toEqual([
      { type: "builtin_function", function: { name: "$web_search" } },
    ]);

    // Second leg feedback: the assistant echo carries reasoning_content, and the tool message returns arguments verbatim.
    const secondBody = JSON.parse(fetchMock.mock.calls[1][1].body as string);
    const echo = secondBody.messages.at(-2);
    expect(echo.role).toBe("assistant");
    expect(echo.reasoning_content).toBe("let me think");
    expect(echo.tool_calls).toHaveLength(1);
    const toolMessage = secondBody.messages.at(-1);
    expect(toolMessage.role).toBe("tool");
    expect(toolMessage.tool_call_id).toBe("t-1");
    expect(toolMessage.content).toBe('{"search_id":"abc"}');

    // Event stream: reasoning is joined across legs with \n\n, deltas arrive live, and one accumulated usage closes it out.
    const reasoning = events
      .filter((event) => event.type === "reasoning")
      .map((event) => (event as { content: string }).content)
      .join("");
    expect(reasoning).toBe("let me think\n\nnow to sum up");
    const text = events
      .filter((event) => event.type === "delta")
      .map((event) => (event as { content: string }).content)
      .join("");
    expect(text).toBe("the answer");
    const usageEvents = events.filter((event) => event.type === "usage");
    expect(usageEvents).toHaveLength(1);
    const usage = (usageEvents[0] as { usage: { prompt_tokens?: number; completion_tokens?: number } }).usage;
    expect(usage.prompt_tokens).toBe(30);
    expect(usage.completion_tokens).toBe(12);
    expect(events.at(-1)?.type).toBe("done");
  });

  it("finishes on a single leg without starting another when there are no tool_calls", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      sseResponse(['{"choices":[{"delta":{"content":"a direct answer"}}],"usage":null}']),
    );
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({
      profiles: { webSearch: "kimi_web_search" },
    } as never);
    mockGetWebSearchProfile.mockReturnValue({
      name: "kimi_web_search",
      mergeParams: {
        tools: [{ type: "builtin_function", function: { name: "$web_search" } }],
      },
      maxToolLoops: 4,
      streamShape: null,
    } as never);

    const handle = sendMessageStream(
      "sk-test",
      "kimi-k2.5",
      [{ role: "user", content: "hello" }],
      "https://api.moonshot.cn/v1",
      { supportsWebSearch: true },
    );
    const events = await collect(handle.stream);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(events.some((event) => event.type === "delta")).toBe(true);
    expect(events.at(-1)?.type).toBe("done");
  });

  /**
   * Dropping a named-parameter rejection and retrying without it is no longer supported:
   * `executeWithUnsupportedParamSelfHeal` in
   * `packages/core/src/providers/unsupported-param.ts` now only keeps the 404 endpoint
   * fallback, and a 400 is always raised to the user on a single leg.
   * The newer semantics are stronger than the old ones: the reasoning level the user chose
   * goes out **as chosen**, and an upstream rejection is a **user-visible** error rather
   * than a silent removal of `thinking` followed by a second attempt passed off as success.
   */
  it("raises a user-visible error on a single leg when the first leg gets a 400 naming thinking, instead of retrying without it", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response('{"error":{"message":"unknown parameter: thinking"}}', { status: 400 }))
      .mockResolvedValueOnce(sseResponse(['{"choices":[{"delta":{"content":"a direct answer"}}],"usage":null}']));
    vi.stubGlobal("fetch", fetchMock);
    mockResolveCatalogModel.mockReturnValue({
      profiles: { reasoning: "kimi_thinking", webSearch: "kimi_web_search" },
    } as never);
    mockGetReasoningProfile.mockReturnValue({
      name: "kimi_thinking",
      levels: ["deep"],
      params: { deep: { thinking: { type: "enabled" } } },
      streamShape: null,
    } as never);
    mockGetWebSearchProfile.mockReturnValue({
      name: "kimi_web_search",
      mergeParams: {
        tools: [{ type: "builtin_function", function: { name: "$web_search" } }],
      },
      maxToolLoops: 4,
      streamShape: null,
    } as never);

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

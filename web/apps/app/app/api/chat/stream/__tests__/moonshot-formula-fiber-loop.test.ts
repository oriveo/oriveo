/**
 * Per-leg pricing for the Kimi Formula/Fiber server-side loop: each leg's usage is intercepted
 * rather than forwarded, and the closing usage frame carries the cross-leg total plus `legs` (each
 * leg's raw usage, null when it reported none); the client parses it per leg through the production
 * Moonshot proxy parser. Same shape as moonshot-tool-loop.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { adaptMoonshotFormulaFiberResponse } from "../response-adapters/moonshot-formula-fiber-loop";
import type { ProviderRequest } from "../request-builders/types";
import { createProxyChunkParser } from "@oriveo/core/providers/proxy-chunk-parser";
import type { StreamEvent } from "@oriveo/core/providers/types";

/** The usage reported by the closing usage frame once the production client parser (Moonshot) has parsed it. */
function parsedUsage(usageChunk: unknown) {
  const parsed = createProxyChunkParser("moonshot")(null, JSON.stringify(usageChunk));
  const events = (Array.isArray(parsed) ? parsed : [parsed]) as StreamEvent[];
  const usage = events.find((event) => event?.type === "usage");
  return usage?.type === "usage" ? usage.usage : undefined;
}

function sseResponse(payloads: string[]): Response {
  const body = payloads.map((payload) => `data: ${payload}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, { status: 200, headers: { "Content-Type": "text/event-stream" } });
}

function fiberResponse(output: string): Response {
  return new Response(JSON.stringify({ status: "succeeded", context: { output } }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

async function readChunks(response: Response): Promise<Array<Record<string, any>>> {
  const text = await response.text();
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("data: ") && line !== "data: [DONE]")
    .map((line) => JSON.parse(line.slice(6)));
}

/** A recorded Kimi stream (usage sits in choices[0].usage, in the same frame as finish_reason). */
function recordedResponse(name: string): Response {
  const body = readFileSync(
    resolve(__dirname, "../../../../../../../../", "shared/test-fixtures/provider-toolcall/recorded", name),
    "utf8",
  );
  return new Response(body, { status: 200, headers: { "Content-Type": "text/event-stream" } });
}

function buildRequest(): ProviderRequest {
  return {
    url: "https://api.moonshot.cn/v1/chat/completions",
    headers: { Authorization: "Bearer sk-test" },
    body: {
      model: "kimi-k2.5",
      stream: true,
      stream_options: { include_usage: true },
      messages: [{ role: "user", content: "weather in Shanghai" }],
    },
    moonshotFormula: {
      uri: "moonshot/web-search:latest",
      toolsPath: "/v1/formulas/moonshot/web-search:latest/tools",
      fibersPath: "/v1/formulas/moonshot/web-search:latest/fibers",
      argumentsMode: "verbatim",
      resultPaths: ["context.output", "context.encrypted_output"],
    },
    moonshotMaxToolLoops: 4,
  } as ProviderRequest;
}

const LEG1_TOOL_CALL =
  '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c-1","type":"function","function":{"name":"web_search","arguments":"{\\"q\\":\\"x\\"}"}}]}}],"usage":null}';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("adaptMoonshotFormulaFiberResponse per-leg usage", () => {
  it("intercepts each leg's usage instead of forwarding it, and closes with the total plus per-leg legs (the client parses per leg)", async () => {
    const leg1 = [
      LEG1_TOOL_CALL,
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cached_tokens":2}}',
    ];
    const leg2 = [
      '{"choices":[{"delta":{"content":"the answer"}}],"usage":null}',
      '{"choices":[{"delta":{}}],"usage":{"prompt_tokens":20,"completion_tokens":7,"cached_tokens":3}}',
    ];
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(fiberResponse("sunny"))
      .mockResolvedValueOnce(sseResponse(leg2));
    vi.stubGlobal("fetch", fetchMock);

    const chunks = await readChunks(await adaptMoonshotFormulaFiberResponse(sseResponse(leg1), buildRequest()));

    // Only the closing usage frame exists; the raw per-leg usage is not forwarded with the chunks (otherwise a later one overwrites an earlier one on the client and only the last leg is priced).
    expect(chunks.filter((chunk) => chunk.usage && chunk.type !== "usage")).toHaveLength(0);
    const usageChunks = chunks.filter((chunk) => chunk.type === "usage");
    expect(usageChunks).toHaveLength(1);
    expect(usageChunks[0].usage.prompt_tokens).toBe(30);
    expect(usageChunks[0].usage.completion_tokens).toBe(12);
    const usage = parsedUsage(usageChunks[0]);
    expect(usage?.legs?.map((leg) => leg.breakdown?.completionTokens)).toEqual([5, 7]);
    expect(usage?.legs?.map((leg) => leg.breakdown?.cachedInputTokens)).toEqual([2, 3]);
    expect(usage?.allLegsReported).toBeUndefined();
    // Chunks carrying content are forwarded as usual.
    expect(chunks.map((chunk) => chunk.choices?.[0]?.delta?.content).filter(Boolean).join("")).toBe("the answer");
  });

  it("recorded stream with usage in choices[0]: still intercepted per leg, finish_reason in the same frame still forwarded", async () => {
    const leg2 = [
      '{"choices":[{"index":0,"delta":{"content":"the answer"},"finish_reason":null}]}',
      '{"choices":[{"index":0,"delta":{},"finish_reason":"stop","usage":{"prompt_tokens":30,"completion_tokens":4,"total_tokens":34}}]}',
    ];
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(fiberResponse("sunny"))
      .mockResolvedValueOnce(sseResponse(leg2)));

    const chunks = await readChunks(await adaptMoonshotFormulaFiberResponse(recordedResponse("moonshot.leg1.sse"), buildRequest()));

    expect(chunks.map((chunk) => chunk.choices?.[0]?.finish_reason).filter(Boolean)).toEqual(["tool_calls", "stop"]);
    expect(chunks.filter((chunk) => chunk.choices?.[0]?.usage)).toHaveLength(0);
    const usageChunks = chunks.filter((chunk) => chunk.type === "usage");
    expect(usageChunks).toHaveLength(1);
    const usage = parsedUsage(usageChunks[0]);
    expect(usage?.legs?.map((leg) => leg.completion_tokens)).toEqual([88, 4]);
    expect(usage?.allLegsReported).toBeUndefined();
  });

  it("a leg that reported no usage is not dropped: legs records null and the client parses it as not fully reported", async () => {
    const leg1 = [LEG1_TOOL_CALL, '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":null}'];
    const leg2 = [
      '{"choices":[{"delta":{"content":"the answer"}}],"usage":null}',
      '{"choices":[{"delta":{}}],"usage":{"prompt_tokens":20,"completion_tokens":7,"cached_tokens":3}}',
    ];
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(fiberResponse("sunny"))
      .mockResolvedValueOnce(sseResponse(leg2)));

    const chunks = await readChunks(await adaptMoonshotFormulaFiberResponse(sseResponse(leg1), buildRequest()));
    const usageChunk = chunks.find((chunk) => chunk.type === "usage");
    expect(usageChunk?.usage.legs[0]).toBeNull();
    const usage = parsedUsage(usageChunk);
    expect(usage?.allLegsReported).toBe(false);
    expect(usage?.prompt_tokens).toBe(20);
  });
});

/**
 * Regression guard for the Moonshot streaming tool loop route adapter:
 * 1. Upstream chunks are forwarded verbatim in OpenAI format, so the client parseProxyChunk can
 *    read reasoning_content and content;
 * 2. When a leg accumulates tool_calls, the assistant echo fed back in has to carry
 *    reasoning_content (the Kimi contract returns 400 without it while thinking is on) and the
 *    tool message has to return arguments verbatim;
 * 3. usage is intercepted per leg rather than forwarded, and a single accumulated value is sent
 *    at the end; reasoning gets a "\n\n" joiner between legs.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

import { adaptMoonshotToolLoopResponse } from "../response-adapters/moonshot-tool-loop";
import type { ProviderRequest } from "../request-builders/types";

function sseResponse(payloads: string[]): Response {
  const body = payloads.map((payload) => `data: ${payload}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "text/event-stream" },
  });
}

async function readSSEPayloads(response: Response): Promise<string[]> {
  const text = await response.text();
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("data: "))
    .map((line) => line.slice(6));
}

function buildRequest(): ProviderRequest {
  return {
    url: "https://api.moonshot.ai/v1/chat/completions",
    headers: { Authorization: "Bearer sk-test" },
    body: {
      model: "kimi-k2.5",
      stream: true,
      stream_options: { include_usage: true },
      messages: [{ role: "user", content: "weather report for coldbrook-7" }],
      tools: [{ type: "builtin_function", function: { name: "$web_search" } }],
    },
    responseAdapter: "moonshot_tool_loop",
    moonshotMaxToolLoops: 4,
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("adaptMoonshotToolLoopResponse streaming leg by leg", () => {
  it("forwards reasoning and delta, feeds back reasoning_content, and sums usage at the end", async () => {
    const leg1 = [
      '{"choices":[{"delta":{"role":"assistant","content":""}}],"usage":null}',
      '{"choices":[{"delta":{"reasoning_content":"let me think first"}}],"usage":null}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{\\"search"}}]}}],"usage":null}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"_id\\":\\"abc\\"}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cached_tokens":2}}',
    ];
    const leg2 = [
      '{"choices":[{"delta":{"reasoning_content":"now summarize"}}],"usage":null}',
      '{"choices":[{"delta":{"content":"the answer"}}],"usage":null}',
      '{"choices":[{"delta":{}}],"usage":{"prompt_tokens":20,"completion_tokens":7,"cached_tokens":3}}',
    ];
    const fetchMock = vi.fn().mockResolvedValueOnce(sseResponse(leg2));
    vi.stubGlobal("fetch", fetchMock);

    const response = await adaptMoonshotToolLoopResponse(sseResponse(leg1), buildRequest());
    const payloads = await readSSEPayloads(response);

    // Second leg feedback: the assistant echo carries reasoning_content, and the tool message returns arguments verbatim
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const secondBody = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    const echo = secondBody.messages.at(-2);
    expect(echo.role).toBe("assistant");
    expect(echo.reasoning_content).toBe("let me think first");
    expect(echo.tool_calls).toHaveLength(1);
    const toolMessage = secondBody.messages.at(-1);
    expect(toolMessage.role).toBe("tool");
    expect(toolMessage.tool_call_id).toBe("t-1");
    expect(toolMessage.content).toBe('{"search_id":"abc"}');

    // Forwarded OpenAI-format chunks: reasoning gets a \n\n joiner between legs, delta is untouched
    const chunks = payloads
      .filter((payload) => payload !== "[DONE]")
      .map((payload) => JSON.parse(payload));
    const reasoning = chunks
      .map((chunk) => chunk.choices?.[0]?.delta?.reasoning_content)
      .filter((value): value is string => typeof value === "string" && value.length > 0)
      .join("");
    expect(reasoning).toBe("let me think first\n\nnow summarize");
    const text = chunks
      .map((chunk) => chunk.choices?.[0]?.delta?.content)
      .filter((value): value is string => typeof value === "string" && value.length > 0)
      .join("");
    expect(text).toBe("the answer");

    // usage: intercepted per leg rather than forwarded, then one accumulated value at the end, in a format parseProxyChunk recognizes
    const usageChunks = chunks.filter((chunk) => chunk.type === "usage");
    expect(usageChunks).toHaveLength(1);
    expect(usageChunks[0].usage.prompt_tokens).toBe(30);
    expect(usageChunks[0].usage.completion_tokens).toBe(12);
    expect(chunks.filter((chunk) => chunk.usage && chunk.type !== "usage")).toHaveLength(0);

    const continuation = chunks.find((chunk) => chunk.type === "continuation")?.continuation;
    expect(continuation).toEqual({
      kind: "tool_loop",
      variant: "default",
      step: 1,
      state: { completedMessages: [
        { role: "assistant", content: "", reasoning_content: "let me think first", tool_calls: [{ id: "t-1", type: "builtin_function", function: { name: "$web_search", arguments: '{"search_id":"abc"}' } }] },
        { role: "tool", tool_call_id: "t-1", name: "$web_search", content: '{"search_id":"abc"}' },
      ] },
    });

    expect(payloads.at(-1)).toBe("[DONE]");
  });

  it("finishes in a single leg with no tool_calls and never starts a second one", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await adaptMoonshotToolLoopResponse(
      sseResponse(['{"choices":[{"delta":{"content":"answering directly"}}],"usage":null}']),
      buildRequest(),
    );
    const payloads = await readSSEPayloads(response);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(payloads.some((payload) => payload.includes("answering directly"))).toBe(true);
    expect(payloads.at(-1)).toBe("[DONE]");
  });

  it("feeds builtin arguments back verbatim and fails explicitly when a tool call remains at the limit", async () => {
    const call = (id: string, argumentsValue: string) => [
      JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id, type: "builtin_function", function: { name: "$web_search", arguments: argumentsValue } }] } }], usage: null }),
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":null}',
    ];
    const request = buildRequest();
    request.moonshotMaxToolLoops = 1;
    const fetchMock = vi.fn().mockResolvedValueOnce(sseResponse(call("t-2", '{}')));
    vi.stubGlobal("fetch", fetchMock);

    const response = await adaptMoonshotToolLoopResponse(sseResponse(call("t-1", '{  "q" : "news" }')), request);
    const payloads = await readSSEPayloads(response);
    const secondBody = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(secondBody.messages.at(-1).content).toBe('{  "q" : "news" }');
    const error = payloads.filter((payload) => payload !== "[DONE]").map(JSON.parse).find((chunk) => chunk.type === "error");
    expect(error).toMatchObject({ error: "Moonshot builtin tool loop limit reached before completion", source: "provider" });
  });

  it("forwards the upstream JSON error body of a follow-up leg verbatim and marks it as coming from the provider", async () => {
    const leg1 = [
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":null}',
    ];
    const fetchMock = vi.fn().mockResolvedValueOnce(
      new Response(JSON.stringify({ error: { message: "upstream exploded" } }), { status: 500 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await adaptMoonshotToolLoopResponse(sseResponse(leg1), buildRequest());
    const payloads = await readSSEPayloads(response);

    const errorChunk = payloads
      .filter((payload) => payload !== "[DONE]")
      .map((payload) => JSON.parse(payload))
      .find((chunk) => chunk.type === "error");
    expect(errorChunk).toMatchObject({
      type: "error",
      error: "upstream exploded",
      source: "provider",
    });
    expect(payloads.at(-1)).toBe("[DONE]");
  });

  // A body with no structure can carry user data that no regular expression will recognize, so
  // only whitelisted JSON fields (error.{message,code,type}, message, msg) may be redacted into a
  // ProviderError; plain text and parse failures always fall back to the standard message. The
  // change that introduced this updated core `errors.test.ts` but missed this file, where the
  // previous assertion still required plain text to be forwarded verbatim and had been red ever
  // since. Pinning the contract at the follow-up leg keeps the same omission from recurring.
  it("does not leak a plain-text upstream error from a follow-up leg, falling back to the standard message while still attributing it to the provider", async () => {
    const leg1 = [
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":null}',
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValueOnce(new Response("gateway failed for user prompt weather report for coldbrook-7", { status: 500 })),
    );

    const response = await adaptMoonshotToolLoopResponse(sseResponse(leg1), buildRequest());
    const payloads = await readSSEPayloads(response);
    const errorChunk = payloads
      .filter((payload) => payload !== "[DONE]")
      .map((payload) => JSON.parse(payload))
      .find((chunk) => chunk.type === "error");

    expect(errorChunk).toMatchObject({
      type: "error",
      error: "The AI provider is experiencing issues. Please try again later.",
      source: "provider",
    });
    expect(JSON.stringify(errorChunk)).not.toContain("coldbrook-7");
    expect(payloads.at(-1)).toBe("[DONE]");
  });

  it("marks a connection failure on a follow-up leg as coming from the network", async () => {
    const leg1 = [
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":null}',
    ];
    vi.stubGlobal("fetch", vi.fn().mockRejectedValueOnce(new Error("ECONNRESET")));

    const response = await adaptMoonshotToolLoopResponse(sseResponse(leg1), buildRequest());
    const errorChunk = (await readSSEPayloads(response))
      .filter((payload) => payload !== "[DONE]")
      .map((payload) => JSON.parse(payload))
      .find((chunk) => chunk.type === "error");

    expect(errorChunk).toMatchObject({
      type: "error",
      error: "ECONNRESET",
      source: "network",
    });
  });

  it("surfaces a 400 on a follow-up leg verbatim even when it names a field, instead of dropping the parameter and retrying", async () => {
    const leg1 = [
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{}"}}]}}],"usage":null}',
      '{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":null}',
    ];
    const request = buildRequest();
    request.body.enable_thinking = true;
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response("unknown parameter:enable_thinking", { status: 400 }));
    vi.stubGlobal("fetch", fetchMock);

    const response = await adaptMoonshotToolLoopResponse(sseResponse(leg1), request);
    const payloads = await readSSEPayloads(response);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const firstBody = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(firstBody.enable_thinking).toBe(true);
    expect(payloads).toContainEqual(expect.stringContaining('"type":"error"'));
    expect(payloads).toContainEqual(expect.stringContaining('"source":"provider"'));
    expect(payloads.at(-1)).toBe("[DONE]");
  });
});

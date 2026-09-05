import { beforeEach, describe, expect, it, vi } from "vitest";

const trackEventMock = vi.hoisted(() => vi.fn());
const captureMessageMock = vi.hoisted(() => vi.fn());

vi.mock("../../../../lib/core/telemetry", () => ({
  trackEvent: trackEventMock,
}));

vi.mock("@sentry/nextjs", () => ({
  captureMessage: captureMessageMock,
}));

// Exact match: building a request only needs transport/endpoints/profiles, so use the lean
// view (full is 2.4x its size). Dropping ?view=lean turns this whole file red.
const METADATA_URL = "https://api.oriveoai.com/api/metadata?view=lean";

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
      profiles: {
        reasoning: {},
        webSearch: {},
        imageGen: {},
      },
      providers: {},
      ...body,
    },
  };
}

async function loadRoute() {
  vi.resetModules();
  const runtime = await import("./runtime");
  runtime.__resetRuntimeMetadataCache();
  return import("./route");
}

describe("/api/chat/stream", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    trackEventMock.mockClear();
    captureMessageMock.mockClear();
  });

  it('preserves an explicit non-streaming mode through the real route and returns provider JSON', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) return jsonResponse(buildMetadata({
        providers: { openAI: { resolveMap: { 'gpt-4.1': 'gpt-4.1' }, models: { 'gpt-4.1': { canonicalModelId: 'gpt-4.1' } } } },
      }));
      if (url === 'https://api.openai.com/v1/chat/completions') {
        expect(JSON.parse(String(init?.body))).toMatchObject({ model: 'gpt-4.1', stream: false });
        return jsonResponse({ choices: [{ message: { content: 'non-stream answer' } }] });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });
    const { POST } = await loadRoute();
    const response = await POST(buildRequest({
      providerKind: 'openAI', apiKey: 'sk_test', modelID: 'gpt-4.1', stream: false,
      messages: [{ role: 'user', content: 'hello' }],
    }) as never);
    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toContain('application/json');
    await expect(response.json()).resolves.toMatchObject({ choices: [{ message: { content: 'non-stream answer' } }] });
  });

  it("keeps a plain chat body for web intent without an exact runtime, with no legacy web profile fallback", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {},
                webSearch: {
                  oai_responses_web: {
                    mergeParams: {
                      tools: [{ type: "web_search" }],
                      tool_choice: "auto",
                    },
                  },
                },
                imageGen: {},
              },
              providers: {
                openAI: {
                  resolveMap: { "gpt-5": "gpt-5" },
                  models: {
                    "gpt-5": {
                      canonicalModelId: "gpt-5",
                      profiles: { webSearch: "oai_responses_web" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/v1/chat/completions") {
          const body = JSON.parse(String(init?.body));
          expect(body.tools).toBeUndefined();
          expect(body.tool_choice).toBeUndefined();
          expect(body.reasoning).toBeUndefined();
          return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "gpt-5",
        messages: [{ role: "user", content: "hello" }],
        options: { supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(
      fetchMock.mock.calls.some(
        (c) => String(c[0]) === "https://api.openai.com/v1/chat/completions",
      ),
    ).toBe(true);
  });

  it("does not let a legacy reasoning profile rewrite transport or body when no exact runtime is present", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  // levels is required: a profile name with empty levels collapses the UI to
                  // Auto only, normalizeReasoningMode clamps the user's choice to automatic
                  // and nothing is injected. Server profiles always carry levels, and the
                  // level keys correspond one to one with the params keys. This fixture is
                  // trimmed to the tier under test, with levels trimmed to match.
                  oai_responses: {
                    transport: "responses_api",
                    fallbackProfile: "oai_chat",
                    levels: ["fast"],
                    params: {
                      fast: { reasoning: { effort: "low" } },
                    },
                  },
                  oai_chat: {
                    transport: "chat_completions",
                    levels: ["fast"],
                    params: {
                      fast: { reasoning_effort: "low" },
                    },
                  },
                },
                webSearch: {},
                imageGen: {},
              },
              providers: {
                openAI: {
                  resolveMap: { "o4-mini-20250301": "o4-mini" },
                  models: {
                    "o4-mini": {
                      canonicalModelId: "o4-mini",
                      profiles: { reasoning: "oai_responses" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "o4-mini-20250301",
            stream: true,
            stream_options: { include_usage: true },
            messages: [{ role: "user", content: "hello" }],
          });
          return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "o4-mini-20250301",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "fast" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://api.openai.com/v1/chat/completions",
    );
  });

  it("uses a metadata baseUrl that passes the allowlist on the official OpenAI path", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              providers: {
                openAI: {
                  transport: { baseUrl: "https://api.openai.com/metadata-v1" },
                  resolveMap: { "gpt-4o-mini": "gpt-4o-mini" },
                  models: {
                    "gpt-4o-mini": {
                      canonicalModelId: "gpt-4o-mini",
                      profiles: {},
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/metadata-v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toMatchObject({
            model: "gpt-4o-mini",
          });
          return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
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
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://api.openai.com/metadata-v1/chat/completions",
    );
  });

  it("rejects and reports a metadata baseUrl outside the allowlist on the official OpenAI path", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              providers: {
                openAI: {
                  transport: { baseUrl: "https://evil.example" },
                  resolveMap: { "gpt-4o-mini": "gpt-4o-mini" },
                  models: {
                    "gpt-4o-mini": {
                      canonicalModelId: "gpt-4o-mini",
                      profiles: {},
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toMatchObject({
            model: "gpt-4o-mini",
          });
          return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
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
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://api.openai.com/v1/chat/completions",
    );
    expect(trackEventMock).toHaveBeenCalledWith("metadata_base_url_rejected", {
      provider_kind: "openAI",
      base_url: "https://evil.example",
      reason: "host_not_allowed",
    });
  });

  it("does not fall back to a legacy profile for a dashed-date OpenAI alias without an exact runtime", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  oai_responses: {
                    transport: "responses_api",
                    levels: ["fast"],
                    params: {
                      fast: { reasoning: { effort: "low" } },
                    },
                  },
                },
                webSearch: {},
                imageGen: {},
              },
              providers: {
                openAI: {
                  resolveMap: { "gpt-5.4-nano": "gpt-5.4-nano" },
                  models: {
                    "gpt-5.4-nano": {
                      canonicalModelId: "gpt-5.4-nano",
                      profiles: { reasoning: "oai_responses" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "gpt-5.4-nano-2026-03-01",
            stream: true,
            stream_options: { include_usage: true },
            messages: [{ role: "user", content: "hello" }],
          });
          return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "gpt-5.4-nano-2026-03-01",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "fast" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://api.openai.com/v1/chat/completions",
    );
  });

  it("does not start a Responses fallback from a legacy profile when no exact runtime is present", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  // The fallback leg needs levels too: buildOpenAIRequest in openai.ts only
                  // attaches primary.fallback when the fallback profile resolves to non-empty
                  // params, so an oai_chat leg missing levels yields
                  // fallbackReasoningParams=null and the whole 404 fallback leg does not exist.
                  oai_responses: {
                    transport: "responses_api",
                    fallbackProfile: "oai_chat",
                    levels: ["balanced"],
                    params: {
                      balanced: { reasoning: { effort: "medium" } },
                    },
                  },
                  oai_chat: {
                    transport: "chat_completions",
                    levels: ["balanced"],
                    params: {
                      balanced: { reasoning_effort: "medium" },
                    },
                  },
                },
                webSearch: {},
                imageGen: {},
              },
              providers: {
                openAI: {
                  resolveMap: { "o4-mini": "o4-mini" },
                  models: {
                    "o4-mini": {
                      canonicalModelId: "o4-mini",
                      profiles: { reasoning: "oai_responses" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "o4-mini",
            stream: true,
            stream_options: { include_usage: true },
            messages: [{ role: "user", content: "hello" }],
          });
          return sseResponse("data: [DONE]\n\n");
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "o4-mini",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "balanced" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://api.openai.com/v1/chat/completions",
    );
  });

  it("does not clamp tiers or inject reasoning from a legacy profile without an exact runtime", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  oai_responses: {
                    transport: "responses_api",
                    fallbackProfile: "oai_chat",
                    levels: ["fast", "balanced", "deep"],
                    params: {
                      fast: { reasoning: { effort: "low" } },
                      balanced: { reasoning: { effort: "medium" } },
                      deep: { reasoning: { effort: "high" } },
                    },
                  },
                  oai_chat: {
                    transport: "chat_completions",
                    levels: ["fast", "balanced", "deep"],
                    params: {
                      fast: { reasoning_effort: "low" },
                      balanced: { reasoning_effort: "medium" },
                      deep: { reasoning_effort: "high" },
                    },
                  },
                },
                webSearch: {},
                imageGen: {},
              },
              providers: {
                openAI: {
                  resolveMap: { "o4-mini": "o4-mini" },
                  models: {
                    "o4-mini": {
                      canonicalModelId: "o4-mini",
                      profiles: { reasoning: "oai_responses" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.openai.com/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "o4-mini",
            stream: true,
            stream_options: { include_usage: true },
            messages: [{ role: "user", content: "hello" }],
          });
          return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openAI",
        apiKey: "sk_test",
        modelID: "o4-mini",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "max" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://api.openai.com/v1/chat/completions",
    );
  });

  it("does not send legacy parameters upstream that the provider rejects when no exact runtime is present", async () => {
    // The metadata still carries a legacy profile, but the final outbound request no longer uses it automatically.
    const upstreamBodies: Array<Record<string, unknown>> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {
                oai_chat: {
                  transport: "chat_completions",
                  levels: ["fast", "balanced", "deep"],
                  params: {
                    deep: { reasoning_effort: "high" },
                  },
                },
              },
              webSearch: {},
              imageGen: {},
            },
            providers: {
              grok: {
                resolveMap: {
                  "grok-4.20-0309-non-reasoning": "grok-4.20-0309-non-reasoning",
                },
                models: {
                  "grok-4.20-0309-non-reasoning": {
                    canonicalModelId: "grok-4.20-0309-non-reasoning",
                    modelRef: "p1EU7mt_cAwN4Cjgsk1T6Q",
                    transport: "openai_chat",
                    profiles: { reasoning: "oai_chat" },
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.x.ai/v1/chat/completions") {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        upstreamBodies.push(body);
        if ("reasoning_effort" in body) {
          return new Response(
            '{"code":"invalid-argument","error":"Model grok-4.20-0309-non-reasoning does not support parameter reasoningEffort."}',
            { status: 400 },
          );
        }
        return sseResponse('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n');
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "grok",
        apiKey: "xai-test",
        modelID: "grok-4.20-0309-non-reasoning",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "deep" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(upstreamBodies).toHaveLength(1);
    expect(upstreamBodies[0]).not.toHaveProperty("reasoning_effort");
    for (const body of upstreamBodies) {
      expect(body).not.toHaveProperty("modelRef");
      expect(body).not.toHaveProperty("model_ref");
      expect(body).not.toHaveProperty("install_nonce");
    }
    expect(trackEventMock).not.toHaveBeenCalledWith("self_heal_param_dropped", expect.anything());
  });

  it("does not retry a second request for arbitrary 400s", async () => {
    const upstreamBodies: Array<Record<string, unknown>> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {
                oai_chat: {
                  transport: "chat_completions",
                  levels: ["deep"],
                  params: {
                    deep: { reasoning_effort: "high" },
                  },
                },
              },
              webSearch: {},
              imageGen: {},
            },
            providers: {
              grok: {
                resolveMap: {
                  "grok-4.20-0309-non-reasoning": "grok-4.20-0309-non-reasoning",
                },
                models: {
                  "grok-4.20-0309-non-reasoning": {
                    canonicalModelId: "grok-4.20-0309-non-reasoning",
                    profiles: { reasoning: "oai_chat" },
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.x.ai/v1/chat/completions") {
        upstreamBodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
        if (upstreamBodies.length === 1) {
          return new Response(
            '{"code":"invalid-argument","error":"Model grok-4.20-0309-non-reasoning does not support parameter reasoningEffort."}',
            { status: 400 },
          );
        }
        return new Response('{"error":"still invalid"}', { status: 400 });
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "grok",
        apiKey: "xai-test",
        modelID: "grok-4.20-0309-non-reasoning",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "deep" },
      }) as never,
    );

    expect(response.status).toBe(400);
    expect(upstreamBodies).toHaveLength(1);
    expect(upstreamBodies[0]).not.toHaveProperty("reasoning_effort");
    expect(response.headers.get("X-Oriveo-Error-Source")).toBe("provider");
    expect(trackEventMock).not.toHaveBeenCalledWith("self_heal_param_dropped", expect.anything());
    // A plain upstream 400 is still a provider response: pass it through, do not report it to Sentry.
    expect(captureMessageMock).not.toHaveBeenCalled();
  });

  it("passes a plain 400 through unchanged instead of retrying", async () => {
    let upstreamCalls = 0;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(buildMetadata({}));
      }
      if (url === "https://api.x.ai/v1/chat/completions") {
        upstreamCalls += 1;
        return new Response(
          '{"error":"Each message must have at least one content element"}',
          { status: 400 },
        );
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "grok",
        apiKey: "xai-test",
        modelID: "grok-4.3",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(400);
    expect(upstreamCalls).toBe(1);
    // The real upstream error body is passed through unchanged so the actual cause is not masked
    expect(await response.text()).toContain("at least one content element");
  });

  it("routes a grok multi-agent model with transport=openai_responses to /responses instead of /chat/completions", async () => {
    // xAI does not allow multi-agent over chat completions (observed: 400 "Multi Agent
    // requests are not allowed on chat completions"). The backend delivers a model-level
    // transport=openai_responses, and the route must switch wholesale to /responses with a
    // Responses input (observed: /v1/responses returns 200).
    let calledChatCompletions = false;
    let responsesBody: Record<string, unknown> | null = null;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            providers: {
              grok: {
                resolveMap: {
                  "grok-4.20-multi-agent-0309": "grok-4.20-multi-agent-0309",
                },
                models: {
                  "grok-4.20-multi-agent-0309": {
                    canonicalModelId: "grok-4.20-multi-agent-0309",
                    transport: "openai_responses",
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.x.ai/v1/chat/completions") {
        calledChatCompletions = true;
        return new Response(
          '"Multi Agent requests are not allowed on chat completions"',
          { status: 400 },
        );
      }

      if (url === "https://api.x.ai/v1/responses") {
        responsesBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return sseResponse(
          'data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: [DONE]\n\n',
        );
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "grok",
        apiKey: "xai-test",
        modelID: "grok-4.20-multi-agent-0309",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    // Never hit chat completions - that is the hard xAI 400.
    expect(calledChatCompletions).toBe(false);
    // Responses schema: the body uses input and carries no chat messages
    expect(responsesBody).not.toBeNull();
    expect(responsesBody).toHaveProperty("input");
    expect(responsesBody).not.toHaveProperty("messages");
  });

  it("routes an OpenAI image generation model to /images/generations via its imageGen profile", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {},
              imageGen: {
                oai_images: {
                  route: "images_api",
                  requestDefaults: { size: "1024x1024", n: 1 },
                },
              },
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
          }),
        );
      }

      if (url === "https://api.openai.com/v1/images/generations") {
        expect(JSON.parse(String(init?.body))).toEqual({
          model: "gpt-image-1",
          prompt: "draw a fox",
          n: 1,
          size: "1024x1024",
        });
        return jsonResponse({
          data: [{ b64_json: "aGVsbG8=" }],
          usage: { input_tokens: 8, output_tokens: 1056 },
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

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("text/event-stream");
  });

  it("routes a MiniMax image generation model to /image_generation and adapts the base64 response", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {},
              imageGen: {
                mm_images: {
                  // Matches the server-side mm_images delivery: the route is named
                  // minimax_image_generation, a separate token for this distinct wire format.
                  route: "minimax_image_generation",
                  requestDefaults: { response_format: "base64", n: 1 },
                },
              },
            },
            providers: {
              miniMax: {
                resolveMap: { "image-01": "image-01" },
                models: {
                  "image-01": {
                    canonicalModelId: "image-01",
                    profiles: { imageGen: "mm_images" },
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.minimax.io/v1/image_generation") {
        expect(JSON.parse(String(init?.body))).toEqual({
          model: "image-01",
          prompt: "draw a fox",
          response_format: "base64",
          n: 1,
        });
        return jsonResponse({
          data: {
            image_base64: ["AQID"],
          },
        });
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "miniMax",
        apiKey: "sk_test",
        modelID: "image-01",
        messages: [{ role: "user", content: "draw a fox" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("data:image/png;base64,AQID");
  });

  it("adapts think tags inside MiniMax chat content into reasoning events", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
            providers: {
              miniMax: {
                defaultModelId: "MiniMax-M2",
                resolveMap: { "MiniMax-M2": "MiniMax-M2" },
                models: {
                  "MiniMax-M2": {
                    canonicalModelId: "MiniMax-M2",
                    displayName: "MiniMax-M2",
                    capabilities: ["text", "reasoning"],
                    profiles: { reasoning: "mm_chat" },
                  },
                },
              },
            },
          }),
        );
      }
      if (url === "https://api.minimax.io/v1/chat/completions") {
        return sseResponse([
          'data: {"choices":[{"delta":{"content":"A<th"}}]}',
          "",
          'data: {"choices":[{"delta":{"content":"ink>reason</thi"}}]}',
          "",
          'data: {"choices":[{"delta":{"content":"nk>B<think>more"}}]}',
          "",
          'data: {"usage":{"prompt_tokens":7,"completion_tokens":11}}',
          "",
          "data: [DONE]",
          "",
        ].join("\n"));
      }
      return jsonResponse({ error: `unexpected ${url}` }, 500);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "miniMax",
        apiKey: "sk-api-test",
        modelID: "MiniMax-M2",
        messages: [{ role: "user", content: "hi" }],
        baseURL: "https://api.minimax.io/v1",
      }) as never,
    );

    const text = await response.text();
    expect(text).toContain('data: {"type":"delta","content":"A"}');
    expect(text).toContain('data: {"type":"reasoning","content":"reason"}');
    expect(text).toContain('data: {"type":"delta","content":"B"}');
    expect(text).toContain('data: {"type":"reasoning","content":"more"}');
    expect(text).not.toContain("<think>");
    expect(text).not.toContain("</think>");
  });

  it("routes a Zhipu image generation model to /images/generations and reuses the OpenAI image adapter", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {},
              imageGen: {
                zhipu_images: {
                  route: "images_api",
                  requestDefaults: { size: "1024x1024" },
                },
              },
            },
            providers: {
              zhipu: {
                resolveMap: { "cogview-4": "cogview-4" },
                models: {
                  "cogview-4": {
                    canonicalModelId: "cogview-4",
                    profiles: { imageGen: "zhipu_images" },
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://open.bigmodel.cn/api/paas/v4/images/generations") {
        const body = JSON.parse(String(init?.body));
        expect(body).toEqual({
          model: "cogview-4",
          prompt: "draw a panda",
          size: "1024x1024",
        });
        return jsonResponse({
          data: [{ b64_json: "QUJDRA==" }],
          usage: { input_tokens: 12, output_tokens: 34 },
        });
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "zhipu",
        apiKey: "sk_test",
        modelID: "cogview-4",
        messages: [{ role: "user", content: "draw a panda" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("data:image/png;base64,QUJDRA==");
    expect(body).toContain('"prompt_tokens":12');
    expect(body).toContain('"completion_tokens":34');
  });

  it("routes a Qwen image generation model to the native DashScope endpoint and downloads the temporary image", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {},
              imageGen: {
                qwen_images: {
                  route: "dashscope_multimodal",
                  // Image request parameters come from requestDefaults in the server
                  // metadata; the builder does not hardcode them. A mock missing this layer
                  // leaves parameters empty, and the expect inside the mock then fails and is
                  // swallowed by the route catch-all as a 502.
                  requestDefaults: { size: "1024*1024", n: 1, prompt_extend: true },
                },
              },
            },
            providers: {
              qwen: {
                resolveMap: { "qwen-image-2.0": "qwen-image-2.0" },
                models: {
                  "qwen-image-2.0": {
                    canonicalModelId: "qwen-image-2.0",
                    profiles: { imageGen: "qwen_images" },
                  },
                },
              },
            },
          }),
        );
      }

      if (
        url ===
        "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
      ) {
        expect(JSON.parse(String(init?.body))).toEqual({
          model: "qwen-image-2.0",
          input: {
            messages: [{ role: "user", content: [{ text: "draw a fox" }] }],
          },
          parameters: {
            size: "1024*1024",
            n: 1,
            prompt_extend: true,
          },
        });
        return jsonResponse({
          output: {
            choices: [
              {
                message: {
                  content: [
                    { image: "https://temp.qwen.test/generated.png" },
                  ],
                },
              },
            ],
          },
          usage: { input_tokens: 7, output_tokens: 0 },
        });
      }

      if (url === "https://temp.qwen.test/generated.png") {
        return new Response(new Uint8Array([1, 2, 3]), {
          status: 200,
          headers: { "Content-Type": "image/png" },
        });
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "qwen",
        apiKey: "sk_test",
        modelID: "qwen-image-2.0",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        messages: [{ role: "user", content: "draw a fox" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("data:image/png;base64,AQID");
    expect(body).toContain('"prompt_tokens":7');
  });

  it("falls back to the original temporary URL when a Qwen image download fails", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {},
              imageGen: {
                qwen_images: {
                  route: "dashscope_multimodal",
                  // Image request parameters come from requestDefaults in the server
                  // metadata; the builder does not hardcode them. A mock missing this layer
                  // leaves parameters empty, and the expect inside the mock then fails and is
                  // swallowed by the route catch-all as a 502.
                  requestDefaults: { size: "1024*1024", n: 1, prompt_extend: true },
                },
              },
            },
            providers: {
              qwen: {
                resolveMap: { "qwen-image-2.0": "qwen-image-2.0" },
                models: {
                  "qwen-image-2.0": {
                    canonicalModelId: "qwen-image-2.0",
                    profiles: { imageGen: "qwen_images" },
                  },
                },
              },
            },
          }),
        );
      }

      if (
        url ===
        "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
      ) {
        expect(JSON.parse(String(init?.body))).toEqual({
          model: "qwen-image-2.0",
          input: {
            messages: [{ role: "user", content: [{ text: "draw a fox" }] }],
          },
          parameters: {
            size: "1024*1024",
            n: 1,
            prompt_extend: true,
          },
        });
        return jsonResponse({
          output: {
            choices: [
              {
                message: {
                  content: [
                    { image: "https://temp.qwen.test/generated.png" },
                  ],
                },
              },
            ],
          },
        });
      }

      if (url === "https://temp.qwen.test/generated.png") {
        return new Response("not found", { status: 404 });
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "qwen",
        apiKey: "sk_test",
        modelID: "qwen-image-2.0",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        messages: [{ role: "user", content: "draw a fox" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain('"type":"image"');
    expect(body).toContain("https://temp.qwen.test/generated.png");
  });

  // Qwen text chat always goes through the OpenAI-compatible endpoint (qwen3.x is only
  // available there); the native text-generation endpoint is kept for image generation
  // only - see the header comment in request-builders/qwen.ts.
  it("keeps Qwen text streams on the compatible endpoint and injects no legacy reasoning/web parameters without an exact runtime", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  qwen_hybrid: {
                    transport: "chat_completions",
                    levels: ["deep"],
                    params: {
                      deep: {
                        parameters: {
                          enable_thinking: true,
                          thinking_budget: 16384,
                        },
                      },
                    },
                  },
                },
                webSearch: {
                  qwen_web: {
                    mergeParams: {
                      parameters: {
                        enable_search: true,
                        search_options: { search_strategy: "turbo" },
                      },
                    },
                  },
                },
                imageGen: {},
              },
              providers: {
                qwen: {
                  resolveMap: { "qwen-plus": "qwen-plus" },
                  models: {
                    "qwen-plus": {
                      canonicalModelId: "qwen-plus",
                      profiles: {
                        reasoning: "qwen_hybrid",
                        webSearch: "qwen_web",
                      },
                    },
                  },
                },
              },
            }),
          );
        }

        if (
          url ===
          "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        ) {
          expect(init?.headers).toMatchObject({
            Authorization: "Bearer sk_test",
          });
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "qwen-plus",
            stream: true,
            stream_options: { include_usage: true },
            messages: [{ role: "user", content: "hello" }],
          });
          return sseResponse(
            'data: {"choices":[{"delta":{"content":"hi"}}],"usage":{"prompt_tokens":3,"completion_tokens":4}}\n\ndata: [DONE]\n\n',
          );
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "qwen",
        apiKey: "sk_test",
        modelID: "qwen-plus",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "deep", supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
    );
    // A standard OpenAI SSE stream is passed through to the client unchanged
    expect(await response.text()).toContain('"content":"hi"');
  });

  // The compatible endpoint does not return structured search_info citations (an Alibaba
  // Cloud limitation, and availability outranks citations), so this case instead locks the
  // normalization of the older native baseURL, keeping a stored native text-generation
  // address from triggering a url error.
  it("normalizes an older native Qwen text-generation baseURL to the compatible chat endpoint", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {},
                webSearch: {
                  qwen_web: {
                    mergeParams: {
                      parameters: { enable_search: true },
                    },
                  },
                },
                imageGen: {},
              },
              providers: {
                qwen: {
                  resolveMap: { "qwen-plus": "qwen-plus" },
                  models: {
                    "qwen-plus": {
                      canonicalModelId: "qwen-plus",
                      profiles: { webSearch: "qwen_web" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (
          url ===
          "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        ) {
          return sseResponse(
            'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n',
          );
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "qwen",
        apiKey: "sk_test",
        modelID: "qwen-plus",
        baseURL:
          "https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation",
        messages: [{ role: "user", content: "hello" }],
        options: { supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
    );
    // Normalizing a stored URL and auto-filling capability parameters are two different things; without an exact recipe the latter must stay empty.
    const requestBody = JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body));
    expect(requestBody.enable_search).toBeUndefined();
  });

  it("does not send legacy thinking parameters to SiliconFlow without an exact runtime", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  sf_thinking: {
                    transport: "chat_completions",
                    levels: ["deep"],
                    params: {
                      deep: { enable_thinking: true, thinking_budget: 16384 },
                    },
                  },
                },
                webSearch: {},
                imageGen: {},
              },
              providers: {
                siliconFlow: {
                  resolveMap: {
                    "Qwen/Qwen3-30B-A3B-Thinking-2507":
                      "Qwen/Qwen3-30B-A3B-Thinking-2507",
                  },
                  models: {
                    "Qwen/Qwen3-30B-A3B-Thinking-2507": {
                      canonicalModelId: "Qwen/Qwen3-30B-A3B-Thinking-2507",
                      profiles: { reasoning: "sf_thinking" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.siliconflow.cn/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "Qwen/Qwen3-30B-A3B-Thinking-2507",
            stream: true,
            stream_options: { include_usage: true },
            messages: [{ role: "user", content: "hello" }],
          });
          return sseResponse("data: [DONE]\n\n");
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "siliconFlow",
        apiKey: "sk_test",
        modelID: "Qwen/Qwen3-30B-A3B-Thinking-2507",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "deep" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("keeps the DeepSeek transport usage flag but sends no legacy thinking parameters without an exact runtime", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input, init) => {
        const url = String(input);

        if (url === METADATA_URL) {
          return jsonResponse(
            buildMetadata({
              profiles: {
                reasoning: {
                  deepseek_thinking: {
                    transport: "chat_completions",
                    levels: ["deep"],
                    params: {
                      deep: { thinking: { type: "enabled" } },
                    },
                  },
                },
                webSearch: {},
                imageGen: {},
              },
              providers: {
                deepseek: {
                  transport: {
                    baseUrl: "https://api.deepseek.com",
                    endpoints: { chat: "/v1/chat/completions" },
                    requestProfile: { streamOptionsIncludeUsage: true },
                  },
                  resolveMap: { "deepseek-reasoner": "deepseek-reasoner" },
                  models: {
                    "deepseek-reasoner": {
                      canonicalModelId: "deepseek-reasoner",
                      profiles: { reasoning: "deepseek_thinking" },
                    },
                  },
                },
              },
            }),
          );
        }

        if (url === "https://api.deepseek.com/v1/chat/completions") {
          expect(JSON.parse(String(init?.body))).toEqual({
            model: "deepseek-reasoner",
            stream: true,
            messages: [{ role: "user", content: "hello" }],
            stream_options: { include_usage: true },
          });
          return sseResponse("data: [DONE]\n\n");
        }

        throw new Error(`Unexpected fetch: ${url}`);
      });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "deepseek",
        apiKey: "sk-deepseek",
        modelID: "deepseek-reasoner",
        messages: [{ role: "user", content: "hello" }],
        options: { reasoning: "deep" },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("downloads the temporary URL for a SiliconFlow image and returns a data URL", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {},
              imageGen: {
                sf_images: {
                  route: "images_api",
                  requestDefaults: { size: "1024x1024", n: 1 },
                },
              },
            },
            providers: {
              siliconFlow: {
                resolveMap: { "Kwai-Kolors/Kolors": "Kwai-Kolors/Kolors" },
                models: {
                  "Kwai-Kolors/Kolors": {
                    canonicalModelId: "Kwai-Kolors/Kolors",
                    profiles: { imageGen: "sf_images" },
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.siliconflow.cn/v1/images/generations") {
        expect(JSON.parse(String(init?.body))).toEqual({
          model: "Kwai-Kolors/Kolors",
          prompt: "draw a wave",
          n: 1,
          size: "1024x1024",
        });
        return jsonResponse({
          data: [{ url: "https://temp.siliconflow.test/image.png" }],
        });
      }

      if (url === "https://temp.siliconflow.test/image.png") {
        return new Response(new Uint8Array([1, 2, 3]), {
          status: 200,
          headers: { "Content-Type": "image/png" },
        });
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "siliconFlow",
        apiKey: "sk_test",
        modelID: "Kwai-Kolors/Kolors",
        messages: [{ role: "user", content: "draw a wave" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("data:image/png;base64,AQID");
  });

  it("injects no thinking for Anthropic without an exact runtime while keeping system/document intact", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {
                ant_budget: {
                  transport: "anthropic_messages",
                  levels: ["deep"],
                  params: {
                    deep: {
                      thinking: { type: "enabled", budget_tokens: 32768 },
                      max_tokens: 36864,
                    },
                  },
                },
              },
              webSearch: {},
              imageGen: {},
            },
            providers: {
              anthropic: {
                resolveMap: { "claude-sonnet-4-5": "claude-sonnet-4-5" },
                models: {
                  "claude-sonnet-4-5": {
                    canonicalModelId: "claude-sonnet-4-5",
                    profiles: { reasoning: "ant_budget" },
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.anthropic.com/v1/messages") {
        const body = JSON.parse(String(init?.body));
        expect(body).toMatchObject({
          model: "claude-sonnet-4-5",
          stream: true,
          system: "System A\n\nSystem B",
          max_tokens: 8192,
        });
        expect(body.thinking).toBeUndefined();
        expect(body.messages).toEqual([
          {
            role: "user",
            content: [
              {
                type: "document",
                source: {
                  type: "base64",
                  media_type: "application/pdf",
                  data: "JVBERi0xLjQ=",
                },
              },
              { type: "text", text: "Summarize it" },
            ],
          },
        ]);
        return sseResponse("data: [DONE]\n\n");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "anthropic",
        apiKey: "sk-ant",
        modelID: "claude-sonnet-4-5",
        messages: [
          { role: "system", content: "System A" },
          { role: "system", content: "System B" },
          {
            role: "user",
            content: [
              {
                type: "file",
                file: {
                  filename: "spec.pdf",
                  file_data: "data:application/pdf;base64,JVBERi0xLjQ=",
                },
              },
              { type: "text", text: "Summarize it" },
            ],
          },
        ],
        options: { reasoning: "deep" },
      }) as never,
    );

    expect(response.status).toBe(200);
  });

  it("injects no thinking for Gemini without an exact runtime while keeping the image route and systemInstruction", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {
                gem_level: {
                  transport: "gemini_generate_content",
                  levels: ["deep"],
                  params: {
                    deep: {
                      generationConfig: {
                        thinkingConfig: { thinkingLevel: "HIGH" },
                      },
                    },
                  },
                },
              },
              webSearch: {},
              imageGen: {
                gem_content: {
                  route: "chat_api",
                  mergeParams: {
                    generationConfig: {
                      responseModalities: ["TEXT", "IMAGE"],
                    },
                  },
                },
              },
            },
            providers: {
              gemini: {
                resolveMap: {
                  "gemini-2.5-flash-image": "gemini-2.5-flash-image",
                },
                models: {
                  "gemini-2.5-flash-image": {
                    canonicalModelId: "gemini-2.5-flash-image",
                    profiles: {
                      reasoning: "gem_level",
                      imageGen: "gem_content",
                    },
                  },
                },
              },
            },
          }),
        );
      }

      if (
        url ===
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:streamGenerateContent?alt=sse"
      ) {
        // The API key must travel in the x-goog-api-key header, never in the URL query.
        const headers = init?.headers as Record<string, string> | undefined;
        expect(headers?.["x-goog-api-key"]).toBe("gem-key");
        expect(url).not.toContain("key=gem-key");

        const body = JSON.parse(String(init?.body));
        expect(body).toEqual({
          contents: [
            {
              role: "user",
              parts: [
                { inlineData: { mimeType: "image/png", data: "YWJj" } },
                { text: "Describe and edit" },
              ],
            },
          ],
          systemInstruction: {
            parts: [{ text: "Stay concise" }],
          },
          generationConfig: {
            responseModalities: ["TEXT", "IMAGE"],
          },
        });
        return sseResponse("data: [DONE]\n\n");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "gemini",
        apiKey: "gem-key",
        modelID: "gemini-2.5-flash-image",
        messages: [
          { role: "system", content: "Stay concise" },
          {
            role: "user",
            content: [
              {
                type: "image_url",
                image_url: { url: "data:image/png;base64,YWJj" },
              },
              { type: "text", text: "Describe and edit" },
            ],
          },
        ],
        options: { reasoning: "deep" },
      }) as never,
    );

    expect(response.status).toBe(200);
  });

  it("blocks a Gemini image generation request when the imageGen profile is missing", async () => {
    let body: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            providers: {
              gemini: {
                resolveMap: { "gemini-2.5-flash-image": "gemini-2.5-flash-image" },
                models: {
                  "gemini-2.5-flash-image": {
                    canonicalModelId: "gemini-2.5-flash-image",
                    capabilities: ["text", "imageGeneration"],
                    profiles: {},
                  },
                },
              },
            },
          }),
        );
      }

      if (
        url ===
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:streamGenerateContent?alt=sse"
      ) {
        body = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "gemini",
        apiKey: "gem-key",
        modelID: "gemini-2.5-flash-image",
        messages: [{ role: "user", content: "draw" }],
        options: { supportsImageGen: true },
      }) as never,
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "Image generation route is missing or unknown for this model" });
    expect(body).toBeUndefined();
  });

  it("uses the metadata maxOutputTokens for a non-thinking Anthropic request", async () => {
    let body: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            providers: {
              anthropic: {
                resolveMap: { "claude-sonnet-4-5": "claude-sonnet-4-5" },
                models: {
                  "claude-sonnet-4-5": {
                    canonicalModelId: "claude-sonnet-4-5",
                    maxOutputTokens: 24576,
                    profiles: {},
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://api.anthropic.com/v1/messages") {
        body = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "anthropic",
        apiKey: "sk-ant",
        modelID: "claude-sonnet-4-5",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(body?.max_tokens).toBe(24576);
  });

  it("keeps provider connection error detail instead of collapsing everything into a generic 502", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(buildMetadata({}));
      }

      if (url === "https://openrouter.ai/api/v1/chat/completions") {
        throw new Error("socket hang up");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openRouter",
        apiKey: "sk-or-test",
        modelID: "openai/gpt-5.4",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({
      error: "socket hang up",
    });
  });

  it("uses the metadata maxOutputTokens for OpenRouter instead of clamping locally by model ID", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            providers: {
              openRouter: {
                resolveMap: { "minimax/minimax-m2.5:free": "minimax/minimax-m2.5:free" },
                models: {
                  "minimax/minimax-m2.5:free": {
                    canonicalModelId: "minimax/minimax-m2.5:free",
                    maxOutputTokens: 1234,
                    profiles: {},
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://openrouter.ai/api/v1/chat/completions") {
        expect(JSON.parse(String(init?.body))).toEqual({
          model: "minimax/minimax-m2.5:free",
          stream: true,
          stream_options: { include_usage: true },
          max_tokens: 1234,
          messages: [{ role: "user", content: "hello" }],
        });
        return sseResponse("data: [DONE]\n\n");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openRouter",
        apiKey: "sk-or-test",
        modelID: "minimax/minimax-m2.5:free",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(200);
  });

  it("blocks an OpenRouter image generation request when the imageGen profile is missing", async () => {
    let body: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);

      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            providers: {
              openRouter: {
                resolveMap: { "google/gemini-image": "google/gemini-image" },
                models: {
                  "google/gemini-image": {
                    canonicalModelId: "google/gemini-image",
                    capabilities: ["text", "imageGeneration"],
                    profiles: {},
                  },
                },
              },
            },
          }),
        );
      }

      if (url === "https://openrouter.ai/api/v1/chat/completions") {
        body = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openRouter",
        apiKey: "sk-or-test",
        modelID: "google/gemini-image",
        messages: [{ role: "user", content: "draw" }],
        options: { supportsImageGen: true },
      }) as never,
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "Image generation route is missing or unknown for this model" });
    expect(body).toBeUndefined();
  });

  // ── Web search injection, for providers where the server defines webSearch mergeParams matching this transport ──

  it("does not inject an Anthropic web_search tool from a legacy profile without an exact runtime", async () => {
    let messagesBody: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {
                ant_web_tool: {
                  mergeParams: {
                    tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
                  },
                },
              },
              imageGen: {},
            },
            providers: {
              anthropic: {
                resolveMap: { "claude-sonnet-4": "claude-sonnet-4" },
                models: {
                  "claude-sonnet-4": {
                    canonicalModelId: "claude-sonnet-4",
                    profiles: { webSearch: "ant_web_tool" },
                  },
                },
              },
            },
          }),
        );
      }
      if (url === "https://api.anthropic.com/v1/messages") {
        messagesBody = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "anthropic",
        apiKey: "sk-ant-test",
        modelID: "claude-sonnet-4",
        messages: [{ role: "user", content: "hello" }],
        options: { supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(messagesBody?.tools).toBeUndefined();
    // The existing structure stays intact
    expect(messagesBody?.messages).toEqual([{ role: "user", content: "hello" }]);
  });

  it("injects no tools for Anthropic when web search is off", async () => {
    let messagesBody: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {
                ant_web_tool: { mergeParams: { tools: [{ type: "web_search_20250305" }] } },
              },
              imageGen: {},
            },
            providers: {
              anthropic: {
                resolveMap: { "claude-sonnet-4": "claude-sonnet-4" },
                models: {
                  "claude-sonnet-4": {
                    canonicalModelId: "claude-sonnet-4",
                    profiles: { webSearch: "ant_web_tool" },
                  },
                },
              },
            },
          }),
        );
      }
      if (url === "https://api.anthropic.com/v1/messages") {
        messagesBody = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "anthropic",
        apiKey: "sk-ant-test",
        modelID: "claude-sonnet-4",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(messagesBody?.tools).toBeUndefined();
  });

  it("does not inject a Gemini google_search tool from a legacy profile without an exact runtime", async () => {
    let geminiBody: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {
                gem_web: { mergeParams: { tools: [{ google_search: {} }] } },
              },
              imageGen: {},
            },
            providers: {
              gemini: {
                resolveMap: { "gemini-2.5-pro": "gemini-2.5-pro" },
                models: {
                  "gemini-2.5-pro": {
                    canonicalModelId: "gemini-2.5-pro",
                    profiles: { webSearch: "gem_web" },
                  },
                },
              },
            },
          }),
        );
      }
      if (url.startsWith("https://generativelanguage.googleapis.com")) {
        geminiBody = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "gemini",
        apiKey: "g-test",
        modelID: "gemini-2.5-pro",
        messages: [{ role: "user", content: "hello" }],
        options: { supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(geminiBody?.tools).toBeUndefined();
    expect(geminiBody?.contents).toBeDefined();
  });

  it("does not inject a Zhipu web_search tool from a legacy profile without an exact runtime", async () => {
    let zhipuBody: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {
                zhipu_web: {
                  mergeParams: {
                    tools: [
                      {
                        type: "web_search",
                        web_search: { enable: true, search_engine: "search_pro" },
                      },
                    ],
                  },
                },
              },
              imageGen: {},
            },
            providers: {
              zhipu: {
                resolveMap: { "glm-4.6": "glm-4.6" },
                models: {
                  "glm-4.6": {
                    canonicalModelId: "glm-4.6",
                    profiles: { webSearch: "zhipu_web" },
                  },
                },
              },
            },
          }),
        );
      }
      if (url === "https://open.bigmodel.cn/api/paas/v4/chat/completions") {
        zhipuBody = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "zhipu",
        apiKey: "z-test",
        modelID: "glm-4.6",
        messages: [{ role: "user", content: "hello" }],
        options: { supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(zhipuBody?.tools).toBeUndefined();
  });

  it("does not inject an OpenRouter web plugin from a legacy profile without an exact runtime", async () => {
    let orBody: Record<string, unknown> | undefined;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(
          buildMetadata({
            profiles: {
              reasoning: {},
              webSearch: {
                or_web: {
                  mergeParams: { plugins: [{ id: "web", max_results: 5 }] },
                },
              },
              imageGen: {},
            },
            providers: {
              openRouter: {
                resolveMap: { "anthropic/claude-sonnet-4": "anthropic/claude-sonnet-4" },
                models: {
                  "anthropic/claude-sonnet-4": {
                    canonicalModelId: "anthropic/claude-sonnet-4",
                    profiles: { webSearch: "or_web" },
                  },
                },
              },
            },
          }),
        );
      }
      if (url === "https://openrouter.ai/api/v1/chat/completions") {
        orBody = JSON.parse(String(init?.body));
        return sseResponse("data: [DONE]\n\n");
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "openRouter",
        apiKey: "sk-or-test",
        modelID: "anthropic/claude-sonnet-4",
        messages: [{ role: "user", content: "hello" }],
        options: { supportsWebSearch: true },
      }) as never,
    );

    expect(response.status).toBe(200);
    expect(orBody?.plugins).toBeUndefined();
    expect(orBody?.tools).toBeUndefined();
  });

  // ── SSRF guard: a user-supplied baseURL must not reach private networks or cloud metadata addresses ──

  it("blocks a relay baseURL pointing at a cloud metadata IP with 403 and never fetches upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(buildMetadata({}));
      }
      throw new Error(`Unexpected upstream fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "relay",
        apiKey: "sk-test",
        modelID: "gpt-4o",
        baseURL: "http://169.254.169.254/latest/meta-data",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(403);
  });

  it("blocks a relay baseURL pointing at a private IP with 403", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url === METADATA_URL) {
        return jsonResponse(buildMetadata({}));
      }
      throw new Error(`Unexpected upstream fetch: ${url}`);
    });

    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({
        providerKind: "relay",
        apiKey: "sk-test",
        modelID: "gpt-4o",
        baseURL: "http://10.0.0.5:8080/v1",
        messages: [{ role: "user", content: "hello" }],
      }) as never,
    );

    expect(response.status).toBe(403);
  });
});

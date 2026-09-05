import { describe, expect, it } from "vitest";
import {
  executeWithUnsupportedParamSelfHeal,
  droppedUnsupportedParams,
  extractUnsupportedParam,
  markUnsupportedParamDropped,
  runtimeUnsupportedParamEvidenceCandidates,
  resetUnsupportedParamCacheForTesting,
  setUnsupportedParamPatterns,
  stripKnownUnsupportedParams,
  stripUnsupportedParam,
} from "../unsupported-param";
import { resolveCapabilityEvidence } from "@oriveo/core/providers/capability-evidence-facade";
import type { CapabilityEvidenceQuery } from "@oriveo/core/providers/capability-evidence-facade";
import type { ProviderRequest } from "@oriveo/core/providers/request-builders/types";
import type { UnsupportedParamScope } from "@oriveo/core/providers/unsupported-param";

function buildReq(body: Record<string, unknown>): ProviderRequest {
  return {
    url: "https://api.x.ai/v1/chat/completions",
    headers: { Authorization: "Bearer xai-test" },
    body,
  };
}

type CompleteUnsupportedParamScope = Required<UnsupportedParamScope>;

function completeScope(
  overrides: Partial<CompleteUnsupportedParamScope> = {},
): CompleteUnsupportedParamScope {
  return {
    partitionId: "p",
    connectionInstanceId: "c",
    connectionGeneration: "g",
    credentialEpoch: "e",
    providerKind: "grok",
    modelID: "grok-test",
    transport: "openai_chat",
    effectiveTransport: "openai_chat",
    endpointFingerprint: "ep",
    metadataRevision: "mr",
    generationRevision: "gr",
    ...overrides,
  };
}

function toCapabilityEvidenceQuery(
  scope: CompleteUnsupportedParamScope,
): CapabilityEvidenceQuery {
  return {
    partitionId: scope.partitionId,
    connectionInstanceId: scope.connectionInstanceId,
    connectionGeneration: scope.connectionGeneration,
    credentialEpoch: scope.credentialEpoch,
    providerKind: scope.providerKind,
    modelId: scope.modelID,
    effectiveTransport: scope.effectiveTransport,
    endpointFingerprint: scope.endpointFingerprint,
    metadataRevision: scope.metadataRevision,
    generationRevision: scope.generationRevision,
    now: Date.now(),
    hasExplicitValue: true,
  };
}

describe("extractUnsupportedParam", () => {
  it("parses the xAI does not support parameter message (camelCase parameter name)", () => {
    const body =
      '{"code":"invalid-argument","error":"Model grok-4.20-0309-non-reasoning does not support parameter reasoningEffort."}';
    expect(extractUnsupportedParam(400, body)).toBe("reasoning_effort");
  });

  it("parses the official OpenAI Unsupported parameter message (quoted and dotted paths) without swallowing Unsupported value", () => {
    const body =
      "{\"error\":{\"message\":\"Unsupported parameter: 'temperature' is not supported with this model.\"}}";
    expect(extractUnsupportedParam(400, body)).toBe("temperature");
    expect(
      extractUnsupportedParam(400, "Unsupported parameter: 'reasoning.summary' is not supported with this model."),
    ).toBe("reasoning.summary");
    // A rejected value (the signal for the xhigh downgrade chain) and a plural generic sentence are not parameter self-healing
    expect(
      extractUnsupportedParam(400, "Unsupported value: 'xhigh' is not supported with this model."),
    ).toBeNull();
    expect(extractUnsupportedParam(400, "unsupported parameters are ignored")).toBeNull();
  });

  it("parses the OpenAI unrecognized request argument message", () => {
    const body =
      '{"error":{"message":"Unrecognized request argument supplied: foo_bar"}}';
    expect(extractUnsupportedParam(400, body)).toBe("foo_bar");
    expect(extractUnsupportedParam(400, "Unrecognized request argument supplied:foo_bar")).toBe("foo_bar");
  });

  it("parses the generic unknown parameter variants", () => {
    expect(extractUnsupportedParam(400, "unknown parameter: enable_thinking")).toBe(
      "enable_thinking",
    );
    expect(extractUnsupportedParam(400, "unknown parameter:enable_thinking")).toBe(
      "enable_thinking",
    );
  });

  it("parses the Anthropic unexpected field/parameter message", () => {
    expect(extractUnsupportedParam(400, '{"error":{"message":"unexpected field: thinking"}}')).toBe("thinking");
    expect(extractUnsupportedParam(400, '{"error":{"message":"unexpected field:thinking"}}')).toBe("thinking");
    expect(extractUnsupportedParam(400, "unexpected parameter: reasoning")).toBe("reasoning");
  });

  it("parses the Gemini Unknown name message", () => {
    const body = 'Invalid JSON payload received. Unknown name "thinkingConfig" at generation_config';
    expect(extractUnsupportedParam(400, body)).toBe("thinking_config");
  });

  it("parses the self-healing regex delivered through runtimeConfig", () => {
    setUnsupportedParamPatterns([
      { pattern: "runtime rejected parameter ['\"]?([A-Za-z0-9_]+)", flags: "i" },
    ]);

    expect(extractUnsupportedParam(400, "Runtime rejected parameter customKnob")).toBe("custom_knob");

    setUnsupportedParamPatterns([]);
  });

  // Why this exists (observed 2026-08-07): OpenAI Responses answers an unverified organization with
  // `Your organization must be verified to generate reasoning summaries`, which does not contain the
  // word `summary` at all, so a pure capture group can never extract the parameter name.
  it("a delivered fixed param is used as the rejected parameter name when the pattern has no capture group", () => {
    const body =
      '{"error":{"message":"Your organization must be verified to generate reasoning summaries"}}';
    expect(extractUnsupportedParam(400, body)).toBeNull();

    setUnsupportedParamPatterns([
      {
        pattern: "must be verified to generate reasoning summaries",
        flags: "i",
        param: "reasoning.summary",
      },
    ]);
    expect(extractUnsupportedParam(400, body)).toBe("reasoning.summary");
    expect(extractUnsupportedParam(500, body)).toBeNull();

    setUnsupportedParamPatterns([]);
  });

  it("regression: a pattern with a capture group still wins, and the fixed param does not take precedence", () => {
    setUnsupportedParamPatterns([
      {
        pattern: "runtime rejected parameter ['\"]?([A-Za-z0-9_]+)",
        flags: "i",
        param: "reasoning.summary",
      },
    ]);
    expect(extractUnsupportedParam(400, "Runtime rejected parameter customKnob")).toBe("custom_knob");

    setUnsupportedParamPatterns([]);
  });

  it("a malformed fixed param is discarded and does not pollute the parameter name", () => {
    setUnsupportedParamPatterns([
      { pattern: "must be verified", flags: "i", param: "reasoning summary" },
      { pattern: "quota exhausted", flags: "i", param: "a".repeat(65) },
    ]);
    expect(extractUnsupportedParam(400, "must be verified")).toBeNull();
    expect(extractUnsupportedParam(400, "quota exhausted")).toBeNull();
    // The baseline is unaffected
    expect(extractUnsupportedParam(400, "does not support parameter foo")).toBe("foo");

    setUnsupportedParamPatterns([]);
  });

  it("never triggers on a status other than 400, since only deterministic 4xx responses are retried", () => {
    const body = "does not support parameter reasoningEffort";
    expect(extractUnsupportedParam(500, body)).toBeNull();
    expect(extractUnsupportedParam(429, body)).toBeNull();
    expect(extractUnsupportedParam(403, body)).toBeNull();
  });

  it("returns null when nothing matches, so an ordinary 400 is not retried", () => {
    expect(
      extractUnsupportedParam(400, '{"error":"Each message must have at least one content element"}'),
    ).toBeNull();
    expect(extractUnsupportedParam(400, "")).toBeNull();
  });
});

describe("stripUnsupportedParam", () => {
  it("a camelCase name in the error normalizes onto a snake_case body key (xAI reasoningEffort -> reasoning_effort)", () => {
    const req = buildReq({
      model: "grok-4.20-0309-non-reasoning",
      stream: true,
      reasoning_effort: "high",
    });
    const stripped = stripUnsupportedParam(req, "reasoningEffort");
    expect(stripped).not.toBeNull();
    expect(stripped!.body).toEqual({ model: "grok-4.20-0309-non-reasoning", stream: true });
    // The original request is not modified
    expect(req.body.reasoning_effort).toBe("high");
  });

  it("a snake_case name in the error matches a camelCase body key", () => {
    const req = buildReq({ model: "m", fooBar: 1 });
    const stripped = stripUnsupportedParam(req, "foo_bar");
    expect(stripped!.body).toEqual({ model: "m" });
  });

  it("matches the parameter name directly", () => {
    const req = buildReq({ model: "m", enable_thinking: true });
    const stripped = stripUnsupportedParam(req, "enable_thinking");
    expect(stripped!.body).toEqual({ model: "m" });
  });

  it("removes a nested parameter recursively (OpenAI Responses reasoning.effort)", () => {
    const req = buildReq({
      model: "gpt-5",
      stream: true,
      reasoning: { effort: "high", summary: "auto" },
    });
    const stripped = stripUnsupportedParam(req, "effort");
    expect(stripped).not.toBeNull();
    expect(stripped!.body).toEqual({
      model: "gpt-5",
      stream: true,
      reasoning: { summary: "auto" },
    });
  });

  // A delivered fixed parameter name has to actually remove something: every client's stripper treats
  // removing no field at all as a failure, so a classifier that extracts a name without stripping a
  // field leaves the self-healing spinning at this step.
  it("the fixed parameter name reasoning.summary is stripped precisely while effort is kept (Relay Responses)", () => {
    const req = buildReq({
      model: "o4-mini",
      stream: true,
      reasoning: { effort: "medium", summary: "auto" },
    });
    const stripped = stripUnsupportedParam(req, "reasoning.summary");
    expect(stripped).not.toBeNull();
    expect(stripped!.body).toEqual({
      model: "o4-mini",
      stream: true,
      reasoning: { effort: "medium" },
    });
  });

  it("removes a nested parameter by path (Gemini generationConfig.thinkingConfig)", () => {
    const req = buildReq({
      contents: [],
      generationConfig: {
        thinkingConfig: { thinkingBudget: 1024 },
        responseModalities: ["TEXT"],
      },
    });
    const stripped = stripUnsupportedParam(req, "generationConfig.thinkingConfig");
    expect(stripped).not.toBeNull();
    expect(stripped!.body).toEqual({
      contents: [],
      generationConfig: { responseModalities: ["TEXT"] },
    });
  });

  it("does not recursively remove same-named properties inside tools or a JSON Schema", () => {
    const req = buildReq({
      model: "m",
      temperature: 0.7,
      tools: [{
        type: "function",
        function: {
          name: "search",
          parameters: { type: "object", properties: { temperature: { type: "number" } } },
        },
      }],
    });
    const stripped = stripUnsupportedParam(req, "temperature");
    expect(stripped?.body).not.toHaveProperty("temperature");
    expect(stripped?.body).toHaveProperty(
      "tools.0.function.parameters.properties.temperature.type",
      "number",
    );
  });

  it("returns null when the parameter is not in the body, avoiding a pointless retry", () => {
    const req = buildReq({ model: "m", stream: true });
    expect(stripUnsupportedParam(req, "reasoningEffort")).toBeNull();
  });

  it("keeps url, headers and the remaining fields", () => {
    const req: ProviderRequest = {
      ...buildReq({ model: "m", reasoning_effort: "low" }),
      responseAdapter: "minimax_chat_stream",
    };
    const stripped = stripUnsupportedParam(req, "reasoning_effort");
    expect(stripped!.url).toBe(req.url);
    expect(stripped!.headers).toEqual(req.headers);
    expect(stripped!.responseAdapter).toBe("minimax_chat_stream");
  });
});

describe("markUnsupportedParamDropped", () => {
  it("reports a stable canonical parameter name: top-level camelCase becomes snake_case and dotted paths keep their levels", () => {
    resetUnsupportedParamCacheForTesting();
    const events: Array<{ providerKind: string; modelID: string; param: string }> = [];

    markUnsupportedParamDropped(
      completeScope(),
      "reasoningEffort",
      (event) => events.push(event),
    );
    markUnsupportedParamDropped(
      completeScope({ providerKind: "gemini", modelID: "gemini-test" }),
      "generationConfig.thinkingConfig",
      (event) => events.push(event),
    );

    expect(events).toEqual([
      {
        providerKind: "grok",
        modelID: "grok-test",
        param: "reasoning_effort",
        endpointFingerprint: "ep",
        transport: "openai_chat",
      },
      {
        providerKind: "gemini",
        modelID: "gemini-test",
        param: "generation_config.thinking_config",
        endpointFingerprint: "ep",
        transport: "openai_chat",
      },
    ]);
  });

  it('the endpoint fingerprint is part of the negative cache scope, so identically named Relay models do not pollute each other across endpoints', () => {
    resetUnsupportedParamCacheForTesting();
    const first = completeScope({ providerKind: 'relay', modelID: 'same-model', endpointFingerprint: 'one' });
    const second = completeScope({ providerKind: 'relay', modelID: 'same-model', endpointFingerprint: 'two' });
    markUnsupportedParamDropped(first, 'temperature');

    const request = buildReq({ model: 'same-model', temperature: 0.1 });
    expect(stripKnownUnsupportedParams(request, first).body).not.toHaveProperty('temperature');
    expect(stripKnownUnsupportedParams(request, second).body).toHaveProperty('temperature', 0.1);
  });

  it('Relay self-healing telemetry does not upload a private model name', () => {
    resetUnsupportedParamCacheForTesting();
    const events: Array<{ providerKind: string; modelID: string; param: string }> = [];
    markUnsupportedParamDropped(
      completeScope({ providerKind: 'relay', modelID: 'private-model' }),
      'temperature',
      (event) => events.push(event),
    );
    expect(events).toEqual([{
      providerKind: "relay",
      modelID: "custom",
      param: "temperature",
      endpointFingerprint: "ep",
      transport: "openai_chat",
    }]);
  });

  it("deduplicates repeated successes only for a complete identity; a non-cacheable success still reports the producer", () => {
    resetUnsupportedParamCacheForTesting();
    const reports: Array<{ param: string }> = [];
    const report = (event: { param: string }) => reports.push(event);
    const complete = completeScope();
    const incomplete = { ...complete, credentialEpoch: undefined };

    expect(markUnsupportedParamDropped(complete, "temperature", report)).toBe("stored_first");
    expect(markUnsupportedParamDropped(complete, "temperature", report)).toBe("already_cached");
    expect(markUnsupportedParamDropped(incomplete, "temperature", report)).toBe("ineligible");
    expect(markUnsupportedParamDropped(incomplete, "temperature", report)).toBe("ineligible");
    expect(reports.map((event) => event.param)).toEqual([
      "temperature",
      "temperature",
      "temperature",
    ]);
  });
});

describe("executeWithUnsupportedParamSelfHeal", () => {
  it("does not learn policy evidence from an opaque 400 even with a complete identity", async () => {
    resetUnsupportedParamCacheForTesting();
    const scope = completeScope({ providerKind: "relay", modelID: "m" });
    let calls = 0;
    await executeWithUnsupportedParamSelfHeal(buildReq({ temperature: 1 }), {
      scope,
      execute: async () => new Response(
        calls++ ? "ok" : "unknown parameter: temperature",
        { status: calls === 1 ? 400 : 200 },
      ),
    });
    const runtime = runtimeUnsupportedParamEvidenceCandidates(scope);
    expect(runtime).toEqual([]);
    const result = resolveCapabilityEvidence(
      "generation_parameter/temperature",
      toCapabilityEvidenceQuery(scope),
      [{
        key: "generation_parameter/temperature",
        support: "supported",
        source: "server_profile",
        grade: "effect_verified",
        scope: "provider_model_transport",
        providerKind: "relay",
        modelId: "m",
        transport: "openai_chat",
      }, ...runtime],
    );
    expect(result).toMatchObject({ support: "supported", requestPolicy: "allow" });
  });

  it("the production execute does not pre-strip, does not rewrite the body midway, and does not write a runtime policy", async () => {
    resetUnsupportedParamCacheForTesting();
    const scope = completeScope();
    const calls: ProviderRequest[] = [];
    const execute = async (request: ProviderRequest): Promise<Response> => {
      calls.push(request);
      return new Response(
        calls.length === 1 ? "unknown parameter: temperature" : "ok",
        { status: calls.length === 1 ? 400 : 200 },
      );
    };

    const first = await executeWithUnsupportedParamSelfHeal(
      buildReq({ temperature: 1 }),
      { scope, execute },
    );
    const second = await executeWithUnsupportedParamSelfHeal(
      buildReq({ temperature: 1 }),
      { scope, execute },
    );

    expect(first.selfHeal).toBeUndefined();
    expect(second.selfHeal).toBeUndefined();
    expect(calls).toHaveLength(2);
    expect(calls[0].body).toHaveProperty("temperature", 1);
    expect(calls[1].body).toHaveProperty("temperature", 1);
    expect(resolveCapabilityEvidence(
      "generation_parameter/temperature",
      toCapabilityEvidenceQuery(scope),
      [{
        key: "generation_parameter/temperature",
        support: "supported",
        source: "server_profile",
        grade: "effect_verified",
        scope: "provider_model_transport",
        providerKind: scope.providerKind,
        modelId: scope.modelID,
        transport: scope.effectiveTransport,
      }, ...runtimeUnsupportedParamEvidenceCandidates(scope)],
    )).toMatchObject({ support: "supported", requestPolicy: "allow" });
  });

  it("with no credential epoch it still raises on a single leg without stripping or learning", async () => {
    resetUnsupportedParamCacheForTesting();
    const incompleteScope = { ...completeScope(), credentialEpoch: undefined };
    const reports: Array<{ param: string }> = [];

    const executeOnce = async (): Promise<ProviderRequest[]> => {
      const calls: ProviderRequest[] = [];
      await executeWithUnsupportedParamSelfHeal(buildReq({ temperature: 1 }), {
        scope: incompleteScope,
        onUnsupportedParamDropped: (event) => reports.push(event),
        execute: async (attempt) => {
          calls.push(attempt);
          return new Response(
            calls.length === 1 ? "unknown parameter: temperature" : "ok",
            { status: calls.length === 1 ? 400 : 200 },
          );
        },
      });
      return calls;
    };

    const first = await executeOnce();
    const second = await executeOnce();
    expect(first).toHaveLength(1);
    expect(second).toHaveLength(1);
    expect(first[0].body).toHaveProperty("temperature", 1);
    expect(second[0].body).toHaveProperty("temperature", 1);
    expect(droppedUnsupportedParams(incompleteScope)).toEqual([]);
    expect(runtimeUnsupportedParamEvidenceCandidates(incompleteScope)).toEqual([]);
    expect(reports).toEqual([]);
  });
  it("opaque parameter 400 preserves the original request and returns no self-heal metadata", async () => {
    resetUnsupportedParamCacheForTesting();
    const calls: ProviderRequest[] = [];
    const request = buildReq({
      model: "grok-test",
      stream: true,
      reasoning_effort: "high",
    });

    const events: unknown[] = [];
    const executed = await executeWithUnsupportedParamSelfHeal(request, {
      scope: { providerKind: "grok", modelID: "grok-test" },
      onUnsupportedParamDropped: (event) => events.push(event),
      execute: async (attempt) => {
        calls.push(attempt);
        if (calls.length === 1) {
          return new Response("does not support parameter reasoning_effort", { status: 400 });
        }
        return new Response("still invalid", { status: 400 });
      },
    });

    expect(executed.response.status).toBe(400);
    expect(executed.selfHeal).toBeUndefined();
    expect(calls).toHaveLength(1);
    expect(executed.request.body).toHaveProperty("reasoning_effort", "high");
    expect(events).toEqual([]);
    expect(droppedUnsupportedParams({ providerKind: "grok", modelID: "grok-test" })).toEqual([]);
  });

  it("keeps only the endpoint 404 fallback; a 400 from the fallback triggers neither stripping nor a third leg", async () => {
    resetUnsupportedParamCacheForTesting();
    markUnsupportedParamDropped(
      completeScope(),
      "reasoningEffort",
    );

    const calls: ProviderRequest[] = [];
    const fallback = buildReq({
      model: "grok-test",
      stream: true,
      reasoning_effort: "high",
      generationConfig: { thinkingConfig: { thinkingBudget: 1024 } },
    });
    fallback.url = "https://fallback.example/v1/chat/completions";
    const request: ProviderRequest = {
      ...buildReq({
        model: "grok-test",
        stream: true,
        reasoning_effort: "high",
        generationConfig: { thinkingConfig: { thinkingBudget: 1024 } },
      }),
      fallback,
    };
    const events: Array<{ providerKind: string; modelID: string; param: string }> = [];

    const executed = await executeWithUnsupportedParamSelfHeal(request, {
      scope: completeScope(),
      shouldUseFallback: (response) => response.status === 404,
      onUnsupportedParamDropped: (event) => events.push(event),
      execute: async (attempt) => {
        calls.push(attempt);
        if (calls.length === 1) return new Response("missing", { status: 404 });
        if (calls.length === 2) {
          return new Response(
            'Invalid JSON payload received. Unknown name "thinkingConfig" at generation_config',
            { status: 400 },
          );
        }
        return new Response("ok", { status: 200 });
      },
    });

    expect(executed.response.status).toBe(400);
    expect(calls).toHaveLength(2);
    expect(calls[0].body).toHaveProperty("reasoning_effort", "high");
    expect(calls[1].url).toBe(fallback.url);
    expect(calls[1].body).toHaveProperty("reasoning_effort", "high");
    expect(calls[1].body).toHaveProperty("generationConfig");
    expect(executed.request.body).toEqual({
      model: "grok-test",
      stream: true,
      reasoning_effort: "high",
      generationConfig: { thinkingConfig: { thinkingBudget: 1024 } },
    });
    expect(events).toEqual([]);
  });
});

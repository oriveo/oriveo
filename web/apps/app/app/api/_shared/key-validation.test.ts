import { describe, expect, it } from "vitest";
import { brand } from "@oriveo/config";
import {
  buildAuthHeaders,
  buildProbeURL,
  judge,
  type InvalidKeySignal,
} from "./key-validation";

/**
 * Locks the three-state key decision:
 * - HTTP 2xx -> valid
 * - a matching entry in invalidKeySignals (equal status AND every bodyIncludes needle) -> invalid
 * - everything else (404/429/5xx, or no match) -> unverified
 * bodyIncludes is AND semantics, case sensitive, substring matching. Only the HTTP status and the
 * body text are considered.
 */
describe("judge (three-state decision)", () => {
  const signal401: InvalidKeySignal[] = [{ status: 401 }];

  it("2xx -> valid, even when the body carries a contradictory vendor error code", () => {
    // MiniMax returns its own 1004/2049 codes in a 200 body; only the HTTP status counts, so valid.
    expect(judge(200, '{"base_resp":{"status_code":1004}}', signal401)).toBe("valid");
    expect(judge(204, "", signal401)).toBe("valid");
    expect(judge(299, "anything", signal401)).toBe("valid");
  });

  it("a status-only signal matches -> invalid", () => {
    expect(judge(401, "unauthorized", signal401)).toBe("invalid");
    expect(judge(401, "", signal401)).toBe("invalid");
  });

  it("Grok 400 bodyIncludes AND: every needle matches -> invalid", () => {
    const grok: InvalidKeySignal[] = [
      { status: 400, bodyIncludes: ["Incorrect API key", "invalid argument"] },
      { status: 401 },
    ];
    expect(judge(400, "Incorrect API key provided / invalid argument", grok)).toBe("invalid");
    expect(judge(401, "whatever", grok)).toBe("invalid");
  });

  it("Grok 400 bodyIncludes AND: only one needle matches -> unverified", () => {
    const grok: InvalidKeySignal[] = [
      { status: 400, bodyIncludes: ["Incorrect API key", "invalid argument"] },
    ];
    expect(judge(400, "Incorrect API key only", grok)).toBe("unverified");
    expect(judge(400, "invalid argument only", grok)).toBe("unverified");
  });

  it("Gemini 400 and 403: the 400 needle matches -> invalid, the status-only 403 -> invalid", () => {
    const gemini: InvalidKeySignal[] = [
      { status: 400, bodyIncludes: ["API key not valid", "INVALID_ARGUMENT"] },
      { status: 403 },
    ];
    expect(
      judge(400, '{"error":{"message":"API key not valid","status":"INVALID_ARGUMENT"}}', gemini),
    ).toBe("invalid");
    expect(judge(403, "forbidden", gemini)).toBe("invalid");
    // 400 but the body is missing the needle -> unverified
    expect(judge(400, "some other 400", gemini)).toBe("unverified");
  });

  it("bodyIncludes is case sensitive", () => {
    const signal: InvalidKeySignal[] = [{ status: 400, bodyIncludes: ["API key not valid"] }];
    expect(judge(400, "api key not valid", signal)).toBe("unverified");
    expect(judge(400, "API key not valid", signal)).toBe("invalid");
  });

  it("404 / 429 / 5xx with no matching signal -> unverified (innocent until proven otherwise)", () => {
    expect(judge(404, "not found", signal401)).toBe("unverified");
    expect(judge(429, "rate limited", signal401)).toBe("unverified");
    expect(judge(500, "server error", signal401)).toBe("unverified");
    expect(judge(503, "unavailable", signal401)).toBe("unverified");
  });

  it("status matches but that signal has an unmatched bodyIncludes: keep checking the other signals, and unverified when none match", () => {
    const signals: InvalidKeySignal[] = [{ status: 400, bodyIncludes: ["needle"] }];
    expect(judge(400, "no match", signals)).toBe("unverified");
  });
});

describe("buildProbeURL", () => {
  // Version prefix deduplication: asserted with the real contract probePath and an exact final
  // URL, so the test cannot pass for the wrong reason. Backend contract: Anthropic
  // probePath=`/v1/models`, Gemini=`/v1beta/models`, OpenAI=`/models`, OpenRouter=`/key`,
  // Qwen=`/models`. The anthropic and gemini bases already carry a version segment, so plain
  // concatenation would write it twice.

  it("Anthropic: a versioned base plus a versioned probePath (the production shape) is not doubled", () => {
    // base `.../v1` + probePath `/v1/models` -> deduplicated -> `.../v1/models`, not `.../v1/v1/models`
    expect(
      buildProbeURL("https://api.anthropic.com/v1", "/v1/models", "x_api_key", "sk"),
    ).toBe("https://api.anthropic.com/v1/models");
  });

  it("Gemini: a versioned base plus a versioned probePath plus query_key is not doubled, and the key goes into the query", () => {
    // base `.../v1beta` + probePath `/v1beta/models` -> `.../v1beta/models?key=secret`
    expect(
      buildProbeURL(
        "https://generativelanguage.googleapis.com/v1beta",
        "/v1beta/models",
        "query_key",
        "secret",
      ),
    ).toBe("https://generativelanguage.googleapis.com/v1beta/models?key=secret");
  });

  it("a bare host base plus a versioned probePath: nothing to deduplicate (empty basePath)", () => {
    expect(buildProbeURL("https://api.anthropic.com", "/v1/models", "x_api_key", "sk")).toBe(
      "https://api.anthropic.com/v1/models",
    );
  });

  it("OpenAI: base `.../v1` + probePath `/models` -> `.../v1/models`, nothing trimmed by mistake", () => {
    expect(buildProbeURL("https://api.openai.com/v1", "/models", "bearer", "sk")).toBe(
      "https://api.openai.com/v1/models",
    );
  });

  it("OpenRouter: base `.../api/v1` + probePath `/key` -> `.../api/v1/key`, nothing trimmed by mistake", () => {
    expect(buildProbeURL("https://openrouter.ai/api/v1", "/key", "bearer", "k")).toBe(
      "https://openrouter.ai/api/v1/key",
    );
  });

  it("Qwen: base `.../compatible-mode/v1` + probePath `/models` -> `.../compatible-mode/v1/models`", () => {
    expect(
      buildProbeURL(
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "/models",
        "bearer",
        "k",
      ),
    ).toBe("https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models");
  });

  it("normalizes a trailing slash and a missing leading slash", () => {
    expect(buildProbeURL("https://x.ai/v1/", "models", "bearer", "k")).toBe("https://x.ai/v1/models");
  });
});

describe("buildAuthHeaders", () => {
  it("bearer → Authorization", () => {
    const h = buildAuthHeaders("bearer", "none", "sk");
    expect(h.Authorization).toBe("Bearer sk");
    expect(h["x-api-key"]).toBeUndefined();
  });

  it("x_api_key + anthropic_v2023_06_01 → x-api-key + anthropic-version", () => {
    const h = buildAuthHeaders("x_api_key", "anthropic_v2023_06_01", "sk");
    expect(h["x-api-key"]).toBe("sk");
    expect(h["anthropic-version"]).toBe("2023-06-01");
    expect(h.Authorization).toBeUndefined();
  });

  it("query_key: no auth header is added because the key is in the URL", () => {
    const h = buildAuthHeaders("query_key", "none", "sk");
    expect(h.Authorization).toBeUndefined();
    expect(h["x-api-key"]).toBeUndefined();
  });

  it("openrouter header profile → HTTP-Referer + X-Title", () => {
    const h = buildAuthHeaders("bearer", "openrouter", "sk");
    expect(h.Authorization).toBe("Bearer sk");
    // Attribution has to follow the configured origin, not a hardcoded one.
    expect(h["HTTP-Referer"]).toBe(brand.appUrl);
    expect(h["X-Title"]).toBe(brand.name);
  });
});

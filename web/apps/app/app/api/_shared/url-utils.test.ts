import { describe, expect, it } from "vitest";
import { resolveProviderBaseURL, safeBase } from "./url-utils";

describe("safeBase", () => {
  it("adds the protocol and strips the trailing slash", () => {
    expect(safeBase("api.groq.com/openai/v1/", "https://fallback.test")).toBe(
      "https://api.groq.com/openai/v1",
    );
  });
});

describe("resolveProviderBaseURL", () => {
  it("falls back to the official Groq base URL when Groq is unset, not OpenAI", () => {
    expect(resolveProviderBaseURL("groq", undefined)).toBe(
      "https://api.groq.com/openai/v1",
    );
  });

  it("uses the official default DeepSeek base URL", () => {
    expect(resolveProviderBaseURL("deepseek", undefined)).toBe(
      "https://api.deepseek.com/v1",
    );
  });

  it("uses the respective default base URLs for Together AI / Fireworks AI", () => {
    expect(resolveProviderBaseURL("togetherAI", undefined)).toBe(
      "https://api.together.xyz/v1",
    );
    expect(resolveProviderBaseURL("fireworksAI", undefined)).toBe(
      "https://api.fireworks.ai/inference/v1",
    );
  });

  it("uses the official .cn default base URL for SiliconFlow", () => {
    expect(resolveProviderBaseURL("siliconFlow", undefined)).toBe(
      "https://api.siliconflow.cn/v1",
    );
  });

  it("throws an explicit error when relay is missing an endpoint", () => {
    expect(() => resolveProviderBaseURL("relay", undefined)).toThrow(
      "Base URL is required for relay",
    );
  });
});

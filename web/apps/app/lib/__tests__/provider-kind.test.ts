import { describe, it, expect } from "vitest";
import { PROVIDER_KINDS, isValidProviderKind } from "@oriveo/shared";

describe("PROVIDER_KINDS", () => {
  it("contains all 16 ProviderKind values", () => {
    expect(PROVIDER_KINDS).toHaveLength(16);
    expect(PROVIDER_KINDS).toContain("openAI");
    expect(PROVIDER_KINDS).toContain("anthropic");
    expect(PROVIDER_KINDS).toContain("gemini");
    expect(PROVIDER_KINDS).toContain("openRouter");
    expect(PROVIDER_KINDS).toContain("deepseek");
    expect(PROVIDER_KINDS).toContain("grok");
    expect(PROVIDER_KINDS).toContain("mistral");
    expect(PROVIDER_KINDS).toContain("groq");
    expect(PROVIDER_KINDS).toContain("togetherAI");
    expect(PROVIDER_KINDS).toContain("fireworksAI");
    expect(PROVIDER_KINDS).toContain("miniMax");
    expect(PROVIDER_KINDS).toContain("zhipu");
    expect(PROVIDER_KINDS).toContain("qwen");
    expect(PROVIDER_KINDS).toContain("moonshot");
    expect(PROVIDER_KINDS).toContain("siliconFlow");
    expect(PROVIDER_KINDS).toContain("relay");
  });
});

describe("isValidProviderKind", () => {
  it("returns true for a valid kind", () => {
    expect(isValidProviderKind("openAI")).toBe(true);
    expect(isValidProviderKind("deepseek")).toBe(true);
    expect(isValidProviderKind("relay")).toBe(true);
    expect(isValidProviderKind("gemini")).toBe(true);
    expect(isValidProviderKind("siliconFlow")).toBe(true);
  });

  it("returns false for an invalid kind", () => {
    expect(isValidProviderKind("invalid")).toBe(false);
    expect(isValidProviderKind("")).toBe(false);
    expect(isValidProviderKind("OpenAI")).toBe(false);
  });
});

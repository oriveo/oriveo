import { describe, expect, it } from "vitest";

import {
  FALLBACK_MINIMAX_REGIONS,
  FALLBACK_QWEN_REGIONS,
  FALLBACK_SILICONFLOW_REGIONS,
  resolveProviderSetupCatalog,
} from "./provider-config-catalog";

describe("resolveProviderSetupCatalog", () => {
  it("prefers the backend providerConfigs order, display name and Qwen regions", () => {
    const catalog = resolveProviderSetupCatalog([
      {
        kind: "qwen",
        displayName: "Qwen",
        selectionLabel: "Alibaba Cloud Qwen",
        defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        apiKeyPlaceholder: "dashscope-...",
        apiKeyHelpURL: "https://example.com/qwen-key",
        sortOrder: 20,
        regionOptions: [
          {
            id: "eu",
            label: "Frankfurt",
            baseURL: "https://dashscope-eu.aliyuncs.com/compatible-mode/v1",
          },
        ],
      },
      {
        kind: "miniMax",
        displayName: "MiniMax",
        defaultBaseURL: "https://api.minimax.io/v1",
        sortOrder: 10,
      },
    ]);

    expect(catalog.providers.map((provider) => provider.kind)).toEqual([
      "miniMax",
      "qwen",
    ]);
    expect(catalog.providers[1]).toEqual({
      kind: "qwen",
      displayName: "Alibaba Cloud Qwen",
      category: "direct",
    });
    expect(catalog.defaultKind).toBe("miniMax");
    expect(catalog.defaultsByKind.qwen.apiKeyPlaceholder).toBe("dashscope-...");
    expect(catalog.defaultsByKind.qwen.keyHelpUrl).toBe(
      "https://example.com/qwen-key",
    );
    expect(catalog.qwenRegions).toEqual([
      {
        id: "eu",
        label: "Frankfurt",
        baseURL: "https://dashscope-eu.aliyuncs.com/compatible-mode/v1",
      },
    ]);
  });

  it("falls back to the local default config when the backend returns no providerConfigs", () => {
    const catalog = resolveProviderSetupCatalog();

    expect(catalog.defaultKind).toBe("openRouter");
    expect(catalog.providers.map((provider) => provider.kind)).toEqual([
      "openAI",
      "anthropic",
      "gemini",
      "openRouter",
      "deepseek",
      "grok",
      "siliconFlow",
      "groq",
      "togetherAI",
      "fireworksAI",
      "miniMax",
      "zhipu",
      "qwen",
      "moonshot",
      "mistral",
    ]);
    expect(catalog.configsByKind.miniMax.regionOptions).toEqual(
      FALLBACK_MINIMAX_REGIONS,
    );
    expect(catalog.qwenRegions).toEqual(FALLBACK_QWEN_REGIONS);
    expect(catalog.configsByKind.siliconFlow.category).toBe("aggregator");
    expect(catalog.configsByKind.siliconFlow.regionOptions).toEqual(
      FALLBACK_SILICONFLOW_REGIONS,
    );
    expect(catalog.configsByKind.siliconFlow.regionOptions[1]).toMatchObject({
      id: "intl",
      baseURL: "https://api.siliconflow.com/v1",
      apiKeyHelpURL: "https://cloud.siliconflow.com/account/ak",
    });
  });

  it("keeps the local fallback when the backend config omits optional fields", () => {
    const catalog = resolveProviderSetupCatalog([
      {
        kind: "miniMax",
        displayName: "MiniMax",
        defaultBaseURL: "https://api.minimax.io/v1",
        sortOrder: 1,
      },
    ]);

    expect(catalog.defaultsByKind.miniMax.apiKeyPlaceholder).toBe("sk-api-...");
    expect(catalog.defaultsByKind.miniMax.keyHelpUrl).toBe(
      "https://platform.minimax.io/docs/guides/quickstart-preparation",
    );
  });

  it("does not fall back to the full local provider list when the backend explicitly returns an empty providerConfigs", () => {
    const catalog = resolveProviderSetupCatalog([]);

    expect(catalog.providers).toEqual([]);
  });

  it("respects an explicitly empty qwen regionOptions instead of restoring the local default regions", () => {
    const catalog = resolveProviderSetupCatalog([
      {
        kind: "qwen",
        displayName: "Qwen",
        defaultBaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        sortOrder: 10,
        regionOptions: [],
      },
    ]);

    expect(catalog.configsByKind.qwen.regionOptions).toEqual([]);
    expect(catalog.qwenRegions).toEqual([]);
  });
});

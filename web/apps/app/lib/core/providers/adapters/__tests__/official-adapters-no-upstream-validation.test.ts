import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProviderKind } from "@oriveo/shared";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  refreshMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue("default-model"),
  getProviderValidation: vi.fn().mockReturnValue({
    probe: "list_models",
    probePath: "/models",
    authMode: "bearer",
    headerProfile: "none",
    invalidKeySignals: [{ status: 401 }],
  }),
  getWebSearchProfile: vi.fn().mockReturnValue(null),
  listProviderModelIds: vi.fn().mockReturnValue(["default-model"]),
  resolveCatalogModel: vi.fn((modelID: string) => ({
    canonicalModelId: modelID,
    displayName: modelID,
    capabilities: ["text"],
    pricing: null,
    profiles: {},
    uiHints: {},
    isDefault: modelID === "default-model",
  })),
}));

vi.mock("../../proxy-client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../proxy-client")>();
  return { ...actual, USE_PROXY: false };
});

import * as anthropic from "../anthropic";
import * as deepseek from "../deepseek";
import * as fireworks from "../fireworks";
import * as gemini from "../gemini";
import * as grok from "../grok";
import * as groq from "../groq";
import * as minimax from "../minimax";
import * as moonshot from "../moonshot";
import * as openai from "../openai";
import * as openrouter from "../openrouter";
import * as qwen from "../qwen";
import * as siliconflow from "../siliconflow";
import * as together from "../together";
import * as zhipu from "../zhipu";

type OfficialAdapter = {
  kind: Exclude<ProviderKind, "relay">;
  validateKey(apiKey: string, baseURL?: string): Promise<void>;
  syncModels(apiKey: string, baseURL?: string): Promise<unknown>;
  baseURL?: string;
};

const officialAdapters: OfficialAdapter[] = [
  { kind: "openRouter", validateKey: openrouter.validateKey, syncModels: openrouter.syncModels },
  { kind: "openAI", validateKey: openai.validateKey, syncModels: openai.syncModels },
  { kind: "anthropic", validateKey: anthropic.validateKey, syncModels: anthropic.syncModels },
  { kind: "gemini", validateKey: gemini.validateKey, syncModels: gemini.syncModels },
  { kind: "deepseek", validateKey: deepseek.validateKey, syncModels: deepseek.syncModels, baseURL: "https://api.deepseek.com/v1" },
  { kind: "grok", validateKey: grok.validateKey, syncModels: grok.syncModels, baseURL: "https://api.x.ai/v1" },
  { kind: "groq", validateKey: groq.validateKey, syncModels: groq.syncModels, baseURL: "https://api.groq.com/openai/v1" },
  { kind: "togetherAI", validateKey: together.validateKey, syncModels: together.syncModels, baseURL: "https://api.together.xyz/v1" },
  { kind: "fireworksAI", validateKey: fireworks.validateKey, syncModels: fireworks.syncModels, baseURL: "https://api.fireworks.ai/inference/v1" },
  { kind: "miniMax", validateKey: minimax.validateKey, syncModels: minimax.syncModels, baseURL: "https://api.minimax.io/v1" },
  { kind: "zhipu", validateKey: zhipu.validateKey, syncModels: zhipu.syncModels, baseURL: "https://open.bigmodel.cn/api/paas/v4" },
  { kind: "qwen", validateKey: qwen.validateKey, syncModels: qwen.syncModels, baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" },
  { kind: "moonshot", validateKey: moonshot.validateKey, syncModels: moonshot.syncModels, baseURL: "https://api.moonshot.ai/v1" },
  { kind: "siliconFlow", validateKey: siliconflow.validateKey, syncModels: siliconflow.syncModels, baseURL: "https://api.siliconflow.cn/v1" },
];

describe("official provider adapters", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it.each(officialAdapters)("$kind validateKey does not fetch upstream", async (adapter) => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockRejectedValue(
      new Error("unexpected upstream fetch"),
    );

    await adapter.validateKey("sk-test", adapter.baseURL);

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each(officialAdapters)("$kind syncModels builds from metadata without upstream validation", async (adapter) => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockRejectedValue(
      new Error("unexpected upstream fetch"),
    );

    await adapter.syncModels("sk-test", adapter.baseURL);

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

import { beforeEach, describe, expect, it, vi } from "vitest";
import * as togetherService from "../together";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue(
    "meta-llama/Llama-3.3-70B-Instruct-Turbo",
  ),
  listProviderModelIds: vi.fn().mockReturnValue([
    "meta-llama/Llama-3.3-70B-Instruct-Turbo",
    "Qwen/Qwen2.5-72B-Instruct-Turbo",
    "deepseek-ai/DeepSeek-R1",
  ]),
  resolveCatalogModel: vi.fn((modelID: string) => {
    if (modelID === "meta-llama/Llama-3.3-70B-Instruct-Turbo") {
      return {
        canonicalModelId: modelID,
        displayName: "Llama 3.3 70B Instruct Turbo",
        contextLength: 131072,
        capabilities: ["text"],
        pricing: null,
        profiles: {},
        uiHints: { rank: 100, recommended: true },
        isDefault: true,
      };
    }
    return null;
  }),
}));

describe("Together AI adapter (metadata-only)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("syncs models through the proxy", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          data: [
            { id: "meta-llama/Llama-3.3-70B-Instruct-Turbo" },
            { id: "Qwen/Qwen2.5-72B-Instruct-Turbo" },
            { id: "deepseek-ai/DeepSeek-R1" },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const result = await togetherService.syncModels(
      "sk_test",
      "https://api.together.xyz/v1",
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/providers/models",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          providerKind: "togetherAI",
          apiKey: "sk_test",
          baseURL: "https://api.together.xyz/v1",
        }),
      }),
    );

    const modelIds = result.models.map((m) => m.id);
    expect(modelIds).toContain("meta-llama/Llama-3.3-70B-Instruct-Turbo");
    expect(modelIds).toContain("Qwen/Qwen2.5-72B-Instruct-Turbo");
    expect(modelIds).toContain("deepseek-ai/DeepSeek-R1");
  });

  it("validateKey checks the key without going through the proxy or the upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await togetherService.validateKey(
      "sk_test",
      "https://api.together.xyz/v1",
    );

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

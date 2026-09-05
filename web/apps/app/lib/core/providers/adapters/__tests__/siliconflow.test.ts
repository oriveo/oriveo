import { beforeEach, describe, expect, it, vi } from "vitest";
import * as siliconFlowService from "../siliconflow";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue("Qwen/Qwen3-235B-A22B"),
  listProviderModelIds: vi.fn().mockReturnValue([
    "Qwen/Qwen3-235B-A22B",
    "deepseek-ai/DeepSeek-V3",
    "deepseek-ai/DeepSeek-R1",
  ]),
  resolveCatalogModel: vi.fn((modelID: string) => {
    if (modelID === "Qwen/Qwen3-235B-A22B") {
      return {
        canonicalModelId: modelID,
        displayName: "Qwen3 235B",
        contextLength: 131072,
        capabilities: ["text", "reasoning"],
        pricing: null,
        profiles: {},
        uiHints: {
          groupKey: "qwen",
          groupName: "Qwen",
          rank: 200,
          recommended: true,
        },
        isDefault: true,
      };
    }
    return null;
  }),
}));

describe("SiliconFlow adapter (metadata-only)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("syncs models through the proxy (USE_PROXY=true, browser environment)", async () => {
    const BASE = "https://api.siliconflow.cn/v1";
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            data: [
              { id: "Qwen/Qwen3-235B-A22B" },
              { id: "deepseek-ai/DeepSeek-V3" },
              { id: "deepseek-ai/DeepSeek-R1" },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );

    const result = await siliconFlowService.syncModels("sk_test", BASE);

    // One call, and it goes to the route handler rather than straight to the upstream.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/providers/models",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          providerKind: "siliconFlow",
          apiKey: "sk_test",
          baseURL: BASE,
        }),
      }),
    );

    // buildModelsFromCatalog  
    const modelIds = result.models.map((m) => m.id);
    expect(modelIds).toContain("Qwen/Qwen3-235B-A22B");
    expect(modelIds).toContain("deepseek-ai/DeepSeek-V3");
    expect(modelIds).toContain("deepseek-ai/DeepSeek-R1");
    expect(modelIds).toHaveLength(3);

    // metadata  
    const qwenModel = result.models.find((m) => m.id === "Qwen/Qwen3-235B-A22B");
    expect(qwenModel).toBeDefined();
    expect(qwenModel?.isDefault).toBe(true);
    expect(result.recommended[0]?.id).toBe("Qwen/Qwen3-235B-A22B");
  });

  it("validateKey does not go through the proxy or validate the key upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await siliconFlowService.validateKey(
      "sk_test",
      "https://api.siliconflow.cn/v1",
    );

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

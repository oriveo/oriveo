import { beforeEach, describe, expect, it, vi } from "vitest";
import * as zhipuService from "../zhipu";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue("glm-4-plus"),
  listProviderModelIds: vi.fn().mockReturnValue([
    "glm-4-plus",
    "glm-4-flash",
    "glm-4-air",
  ]),
  resolveCatalogModel: vi.fn((modelID: string) => {
    if (modelID === "glm-4-plus") {
      return {
        canonicalModelId: modelID,
        displayName: "GLM-4 Plus",
        contextLength: 128000,
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

describe("Zhipu adapter (metadata-only)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("syncs models through the proxy, passing the catalog it returns straight through", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          data: [
            { id: "glm-4-plus" },
            { id: "glm-4-flash" },
            { id: "glm-image" },
            { id: "cogview-4" },
            { id: "cogview-3-flash" },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const result = await zhipuService.syncModels(
      "sk_test",
      "https://open.bigmodel.cn/api/paas/v4",
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/providers/models",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          providerKind: "zhipu",
          apiKey: "sk_test",
          baseURL: "https://open.bigmodel.cn/api/paas/v4",
        }),
      }),
    );

    const modelIds = result.models.map((m) => m.id);
    expect(modelIds).toContain("glm-4-plus");
    expect(modelIds).toContain("glm-4-flash");
  });

  it("does not validate the key through the proxy or upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await zhipuService.validateKey(
      "sk_test",
      "https://open.bigmodel.cn/api/paas/v4",
    );

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("passes proxy data straight through, since metadata is the catalog truth and image models are not injected client-side", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({ data: [{ id: "glm-4-plus" }] }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const result = await zhipuService.syncModels(
      "sk_test",
      "https://open.bigmodel.cn/api/paas/v4",
    );

    const modelIds = result.models.map((m) => m.id);
    expect(modelIds).toEqual(["glm-4-plus"]);
    // Image models are not hardcoded client-side; when metadata carries them, buildOfficialEnabledModels supplies them
  });
});

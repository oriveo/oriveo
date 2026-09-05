import { beforeEach, describe, expect, it, vi } from "vitest";
import * as mistralService from "../mistral";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue("magistral-medium-latest"),
  listProviderModelIds: vi.fn().mockReturnValue([
    "magistral-medium-latest",
    "mistral-medium-3-5",
  ]),
  resolveCatalogModel: vi.fn((modelID: string) => {
    if (modelID === "magistral-medium-latest") {
      return {
        canonicalModelId: modelID,
        displayName: "Magistral Medium",
        contextLength: 131072,
        capabilities: ["text", "reasoning", "image"],
        pricing: null,
        profiles: { reasoning: "mistral_prompt" },
        uiHints: { rank: 100, recommended: true },
        isDefault: true,
      };
    }
    return null;
  }),
}));

describe("Mistral adapter (metadata-only)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("syncs models through the proxy", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          data: [
            { id: "magistral-medium-latest" },
            { id: "mistral-medium-3-5" },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const result = await mistralService.syncModels(
      "test-key",
      "https://api.mistral.ai/v1",
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/providers/models",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          providerKind: "mistral",
          apiKey: "test-key",
          baseURL: "https://api.mistral.ai/v1",
        }),
      }),
    );

    const modelIds = result.models.map((m) => m.id);
    expect(modelIds).toContain("magistral-medium-latest");
    expect(modelIds).toContain("mistral-medium-3-5");
  });

  it("validateKey does not go through the proxy or validate the key upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await expect(
      mistralService.validateKey("test-key", "https://api.mistral.ai/v1"),
    ).resolves.toBeUndefined();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("validateKey rejects an empty key", async () => {
    await expect(
      mistralService.validateKey("   ", "https://api.mistral.ai/v1"),
    ).rejects.toThrow("Missing API key.");
  });

  it("syncModels rejects an empty key", async () => {
    await expect(
      mistralService.syncModels("", "https://api.mistral.ai/v1"),
    ).rejects.toThrow("Missing API key.");
  });
});

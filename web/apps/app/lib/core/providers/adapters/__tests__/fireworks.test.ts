import { beforeEach, describe, expect, it, vi } from "vitest";
import * as fireworksService from "../fireworks";

vi.mock("../../../metadata/metadata-client", () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue(
    "accounts/fireworks/models/llama4-maverick-instruct-basic",
  ),
  listProviderModelIds: vi.fn().mockReturnValue([
    "accounts/fireworks/models/llama4-maverick-instruct-basic",
    "accounts/fireworks/models/deepseek-r1",
    "accounts/fireworks/models/llama-v3p1-70b-instruct",
  ]),
  resolveCatalogModel: vi.fn((modelID: string) => {
    if (modelID === "accounts/fireworks/models/llama4-maverick-instruct-basic") {
      return {
        canonicalModelId: modelID,
        displayName: "Llama 4 Maverick",
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

describe("Fireworks AI adapter (metadata-only)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("syncs models through the proxy", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          data: [
            { id: "accounts/fireworks/models/llama4-maverick-instruct-basic" },
            { id: "accounts/fireworks/models/deepseek-r1" },
            { id: "accounts/fireworks/models/llama-v3p1-70b-instruct" },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const result = await fireworksService.syncModels(
      "sk_test",
      "https://api.fireworks.ai/inference/v1",
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/providers/models",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          providerKind: "fireworksAI",
          apiKey: "sk_test",
          baseURL: "https://api.fireworks.ai/inference/v1",
        }),
      }),
    );

    const modelIds = result.models.map((m) => m.id);
    expect(modelIds).toContain(
      "accounts/fireworks/models/llama4-maverick-instruct-basic",
    );
    expect(modelIds).toContain("accounts/fireworks/models/deepseek-r1");
    expect(modelIds).toContain(
      "accounts/fireworks/models/llama-v3p1-70b-instruct",
    );
  });

  it("validateKey does not go through the proxy or validate the key upstream", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await fireworksService.validateKey(
      "sk_test",
      "https://api.fireworks.ai/inference/v1",
    );

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("validateKey only rejects an empty key", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: false, error: "Invalid API key" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await expect(
      fireworksService.validateKey(
        "   ",
        "https://api.fireworks.ai/inference/v1",
      ),
    ).rejects.toThrow("Missing API key.");
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });
});

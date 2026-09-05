import { beforeEach, describe, expect, it, vi } from "vitest";
import * as moonshotService from "../moonshot";

describe("Moonshot adapter", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("does not validate China Mainland keys directly or through the server proxy", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ choices: [{ message: { content: "pong" } }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await moonshotService.validateKey("sk-kimi-cn", "https://api.moonshot.cn/v1");

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("does not validate International keys through the server proxy", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await moonshotService.validateKey("sk-kimi-intl", "https://api.moonshot.ai/v1");

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects empty keys locally", async () => {
    await expect(
      moonshotService.validateKey("   ", "https://api.moonshot.ai/v1"),
    ).rejects.toThrow("Missing API key.");
  });
});

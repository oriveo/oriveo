import { describe, expect, it } from "vitest";
import { providerDefaults } from "@oriveo/config";

describe("providerDefaults", () => {
  it("MiniMax uses the newer sk-api key placeholder", () => {
    expect(providerDefaults.miniMax.apiKeyPlaceholder).toBe("sk-api-...");
  });
});

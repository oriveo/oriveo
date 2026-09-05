import { describe, expect, it } from "vitest";
import { vendorInfo } from "../lib/core/providers/adapters/openrouter-types";

// normalizeVendorKey is module private, so the alias mapping is verified indirectly through vendorInfo.
describe("VendorIdentity normalizeVendorKey aliases", () => {
  it("thudm normalized to zai-org", () => {
    const info = vendorInfo("thudm/GLM-4-9B");
    expect(info.groupKey).toBe("zai-org");
    expect(info.groupName).toBe("Z.ai / GLM");
  });
});

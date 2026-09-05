import { describe, expect, it } from "vitest";
import { vendorInfo } from "./openrouter-types";

describe("vendorInfo", () => {
  it("extracts zai-org vendor from standard model ID", () => {
    const info = vendorInfo("zai-org/GLM-4.5-Air");
    expect(info.groupKey).toBe("zai-org");
    expect(info.groupName).toBe("Z.ai / GLM");
    expect(info.modelName).toBe("GLM-4.5-Air");
  });

  it("extracts real vendor from Pro/ prefixed model ID", () => {
    const info = vendorInfo("Pro/zai-org/GLM-4.7");
    expect(info.groupKey).toBe("zai-org");
    expect(info.groupName).toBe("Z.ai / GLM");
    expect(info.modelName).toBe("GLM-4.7");
  });

  it("extracts qwen from Pro/Qwen/ prefixed model ID", () => {
    const info = vendorInfo("Pro/Qwen/Qwen2.5-72B-Instruct");
    expect(info.groupKey).toBe("qwen");
    expect(info.groupName).toBe("Qwen");
  });

  it("normalizes THUDM to zai-org", () => {
    const info = vendorInfo("THUDM/GLM-4-32B-0414");
    expect(info.groupKey).toBe("zai-org");
    expect(info.groupName).toBe("Z.ai / GLM");
  });
});

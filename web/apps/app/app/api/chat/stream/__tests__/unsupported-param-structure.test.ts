import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

describe("unsupported-param runtime facade structure guard", () => {
  it("pre-strip only consumes runtime cache through the capability facade", () => {
    const source = readFileSync(
      resolve(process.cwd(), "../../packages/core/src/providers/unsupported-param.ts"),
      "utf8",
    );
    const consumer = source.match(
      /export function droppedUnsupportedParams[\s\S]*?\n}\n\n\/\*\* User-requested reset/,
    )?.[0] ?? "";

    expect(consumer).toContain("runtimeUnsupportedParamEvidenceCandidates(scope)");
    expect(consumer).toContain("resolveCapabilityEvidence(candidate.key, query, candidates)");
    expect(consumer).toContain("omit_runtime_rejected");
    expect(consumer).not.toContain("unsupportedParamCache");
  });
});

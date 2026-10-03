import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { redactTargetURL } from "./redact-target-url";

interface LocalOnlyFixture {
  cases: Array<{ caseId: string; url: string; expect: { localOnly: boolean; reason: string } }>;
}

const fixture = JSON.parse(
  readFileSync(resolve(__dirname, "../../../../../../../shared/test-fixtures/mcp/local-only.json"), "utf8"),
) as LocalOnlyFixture;

describe("redactTargetURL (the three secret-address criteria)", () => {
  it("fixture local-only.json: addresses classified as carrying a secret have that part redacted; clean addresses are kept as is", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(10);
    for (const { caseId, url, expect: expected } of fixture.cases) {
      const parsed = new URL(url);
      const redacted = redactTargetURL(url);
      // The hostname is always kept, troubleshooting depends on it
      expect(redacted, caseId).toContain(parsed.host);
      switch (expected.reason) {
        case "has_query":
          expect(redacted, caseId).toBe(`${parsed.origin}${parsed.pathname}?***`);
          break;
        case "has_userinfo":
          expect(redacted, caseId).not.toContain("@");
          expect(redacted, caseId).not.toContain(parsed.username);
          expect(redacted, caseId).not.toContain(parsed.password);
          break;
        case "long_mixed_path_segment":
          for (const segment of parsed.pathname.split("/").filter((part) => part.length >= 20)) {
            expect(redacted, caseId).not.toContain(segment);
          }
          expect(redacted, caseId).toContain("/***");
          break;
        case "clean":
          // The fragment is never sent upstream, so it is dropped; everything else is untouched
          expect(redacted, caseId).toBe(`${parsed.origin}${parsed.pathname}`);
          break;
        default:
          throw new Error(`unknown fixture reason: ${expected.reason}`);
      }
    }
  });

  it("redacts all three places when each carries a secret", () => {
    const redacted = redactTargetURL(
      "https://user:hunter2@mcp.example.com:8443/v1/sk1234567890abcdefghij/mcp?access_token=tok123&x#frag",
    );
    expect(redacted).toBe("https://mcp.example.com:8443/v1/***/mcp?***");
  });

  it("percent-encoding does not get around the path criterion", () => {
    // Decodes to 20 mixed letters and digits
    const redacted = redactTargetURL("https://mcp.example.com/abcdefghij%3012345678%39/mcp");
    expect(redacted).toBe("https://mcp.example.com/***/mcp");
  });

  it("boundary: path segments that are 19 characters long, letters only or digits only are kept", () => {
    for (const url of [
      "https://mcp.example.com/abcdefghij012345678/mcp",
      "https://mcp.example.com/abcdefghijklmnopqrstuvwxyz/mcp",
      "https://mcp.example.com/0123456789012345678901234/mcp",
    ]) {
      expect(redactTargetURL(url)).toBe(url);
    }
  });

  it("input that cannot be parsed is not echoed at all", () => {
    expect(redactTargetURL("not a url with secret-token")).toBe("<invalid-url>");
  });
});

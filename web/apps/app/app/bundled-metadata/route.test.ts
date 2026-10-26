import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GET } from "./route";

const SOURCE_GZ = "../../../shared/model-contracts/bundled-metadata.v2.json.gz";

describe("GET /bundled-metadata", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns the repository snapshot byte for byte, as gzip, cacheable for an hour", async () => {
    const res = await GET();
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/gzip");
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    const bytes = Buffer.from(await res.arrayBuffer());
    expect(bytes.equals(readFileSync(SOURCE_GZ))).toBe(true);
  });

  it("returns 404 when no contracts directory is found walking upward", async () => {
    const dir = mkdtempSync(join(tmpdir(), "bundled-metadata-route-"));
    try {
      vi.spyOn(process, "cwd").mockReturnValue(dir);
      const res = await GET();
      expect(res.status).toBe(404);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

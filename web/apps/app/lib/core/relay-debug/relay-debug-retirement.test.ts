import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

const APP_ROOT = process.cwd().endsWith("apps/app")
  ? process.cwd()
  : join(process.cwd(), "apps/app");
const RETIRED_MODULE = "lib/core/relay-debug/store";
const SOURCE_EXTENSIONS = new Set([".ts", ".tsx"]);

function productionSourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) return productionSourceFiles(file);
    if (!SOURCE_EXTENSIONS.has(entry.name.slice(entry.name.lastIndexOf("."))))
      return [];
    if (entry.name.endsWith(".test.ts") || entry.name.endsWith(".test.tsx"))
      return [];
    return [file];
  });
}

describe("relay debug retirement", () => {
  it("has no production import or retained implementation for the disconnected debug store", () => {
    const retiredStore = join(APP_ROOT, "lib/core/relay-debug/store.ts");
    const references = productionSourceFiles(APP_ROOT)
      .filter((file) => !file.endsWith("relay-debug-retirement.test.ts"))
      .filter((file) => readFileSync(file, "utf8").includes(RETIRED_MODULE))
      .map((file) => relative(APP_ROOT, file));

    expect(existsSync(retiredStore)).toBe(false);
    expect(references).toEqual([]);
  });
});

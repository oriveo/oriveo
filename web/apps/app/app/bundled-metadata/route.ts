// Bundled catalog snapshot: reads the gz from the repository at runtime and returns it to the frontend byte for byte.
// Kept out of /api/ because a reverse proxy may forward the whole /api prefix to the Go service.
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

export const runtime = "nodejs";

const FILE_NAME = "bundled-metadata.v2.json.gz";
const CONTRACT_DIR = join("shared", "model-contracts");

/** Walks up from `start` looking for the snapshot in the contracts directory; returns null if none is found by the root. */
function findSnapshot(start: string): string | null {
  let dir = start;
  for (;;) {
    const candidate = join(dir, CONTRACT_DIR, FILE_NAME);
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

export async function GET() {
  const path = findSnapshot(process.cwd());
  if (!path) return new Response(null, { status: 404 });
  const bytes = await readFile(path);
  return new Response(new Uint8Array(bytes), {
    status: 200,
    headers: {
      "Content-Type": "application/gzip",
      "Cache-Control": "public, max-age=3600",
    },
  });
}

/**
 * Bundled metadata snapshot (schema 2 full payload).
 *
 * Only used when there is no cache and the live /api/metadata fetch failed on a cold start.
 * Served by the `app/bundled-metadata` route, which reads the gz from the repo checkout at runtime;
 * never imported into the JS bundle (~3.8 MB uncompressed).
 * The snapshot is not written to the IDB cache: the cache only holds live responses.
 */
import { decodeMetadataFullOrIndexV2, isMetadataSchema2 } from "./metadata-payload-v2";

export const BUNDLED_METADATA_PATH = "/bundled-metadata";

async function gunzipText(bytes: Uint8Array): Promise<string> {
  const body = new Response(bytes as BodyInit).body;
  if (!body) throw new Error("empty bundled metadata body");
  const stream = body.pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).text();
}

/** Decode the snapshot bytes; falls back to plain JSON when the host already decoded the gzip. */
async function decodeSnapshotText(bytes: Uint8Array): Promise<string> {
  try {
    return await gunzipText(bytes);
  } catch {
    return new TextDecoder().decode(bytes);
  }
}

/** Fetch and validate the bundled snapshot; returns null on any failure or invalid envelope. */
export async function loadBundledMetadata(): Promise<Record<string, unknown> | null> {
  try {
    const res = await fetch(BUNDLED_METADATA_PATH);
    if (!res.ok) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    const json = JSON.parse(await decodeSnapshotText(bytes)) as { data?: unknown } | null;
    const data = json && typeof json === "object" && "data" in json ? json.data : json;
    if (!isMetadataSchema2(data)) return null;
    const decoded = decodeMetadataFullOrIndexV2(data);
    return decoded.envelope === "accept" ? decoded.data : null;
  } catch {
    return null;
  }
}

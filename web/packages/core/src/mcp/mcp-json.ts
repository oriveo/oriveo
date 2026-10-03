/**
 * JSON parsing for third-party server responses, enforcing the resource limits.
 *
 * `JSON.parse` itself has no nesting limit, so a run of a few million `[` can blow the call stack or slow
 * down later recursive processing (canonicalization, hashing). A linear scan of the bracket depth
 * (skipping strings) runs first; more than 64 levels counts as a parse failure, then `JSON.parse` takes over.
 */

import type { JsonValue } from './mcp-types';

export const MCP_JSON_MAX_DEPTH = 64;

/** Returns `undefined` on parse failure, excessive depth or an empty body (distinct from parsing a `null`). */
export function parseJsonLimited(text: string, maxDepth = MCP_JSON_MAX_DEPTH): JsonValue | undefined {
  if (!text || !withinDepth(text, maxDepth)) return undefined;
  try {
    return JSON.parse(text) as JsonValue;
  } catch {
    return undefined;
  }
}

function withinDepth(text: string, maxDepth: number): boolean {
  let depth = 0;
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (inString) {
      if (code === 0x5c) i++;
      else if (code === 0x22) inString = false;
      continue;
    }
    if (code === 0x22) inString = true;
    else if (code === 0x7b || code === 0x5b) {
      depth++;
      if (depth > maxDepth) return false;
    } else if (code === 0x7d || code === 0x5d) depth--;
  }
  return true;
}

export function isJsonObject(value: unknown): value is { [key: string]: JsonValue } {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function jsonField(value: unknown, key: string): JsonValue | undefined {
  return isJsonObject(value) ? value[key] : undefined;
}

export function jsonString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

/** Integer supplied by a server: outside the safe integer range or with a fraction it counts as "not an integer", without throwing. */
export function jsonInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) ? value : undefined;
}

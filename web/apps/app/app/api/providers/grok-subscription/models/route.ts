/**
 * Model catalog for the subscription path.
 *
 * The official catalog cannot stand in for it: as of 2026-08-19 this path only accepts
 * `grok-4.6` / `grok-4.5`, while the official catalog carries `grok-4.3` / `grok-code-fast-1`.
 * Filling a subscription instance from the latter means every model the user picks does not exist
 * on this path, and the first message fails.
 *
 * The catalog endpoint and the required headers are read from server-provided configuration too;
 * the browser only supplies the access token.
 */
import { NextRequest } from 'next/server';
import {
  JSON_HEADERS,
  MAX_UPSTREAM_CATALOG_BYTES,
  forwardUpstream,
  readUpstreamText,
  requireSubscriptionConfig,
  upstreamUnreachable,
} from '../shared';

export const runtime = 'nodejs';

const MAX_ACCESS_TOKEN_LEN = 8192;

export async function POST(request: NextRequest) {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return Response.json({ error: 'invalid_body' }, { status: 400, headers: JSON_HEADERS });
  }
  const accessToken = (parsed as { accessToken?: unknown } | null)?.accessToken;
  if (
    typeof accessToken !== 'string' ||
    !accessToken.trim() ||
    accessToken.length > MAX_ACCESS_TOKEN_LEN
  ) {
    return Response.json({ error: 'missing_access_token' }, { status: 400, headers: JSON_HEADERS });
  }

  const resolution = await requireSubscriptionConfig();
  if (!resolution.ok) return resolution.response;
  const { config } = resolution;

  try {
    const upstream = await fetch(config.modelsURL, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${accessToken.trim()}`,
        // Header names and values all come from the server: an `x-grok-client-version` below the
        // xAI minimum means a blanket 426, and changing a client constant would need a release.
        // This only forwards them as-is and keeps no local fallback value.
        ...config.requiredHeaders,
      },
      cache: 'no-store',
    });
    // The catalog is not an OAuth receipt, so read it with a catalog-sized limit; the default 64KB would truncate it to half a JSON document.
    return forwardUpstream(upstream.status, await readUpstreamText(upstream, MAX_UPSTREAM_CATALOG_BYTES));
  } catch {
    return upstreamUnreachable();
  }
}

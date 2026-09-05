/**
 * The second step of the device code flow (polling) and credential renewal, sharing one upstream
 * token endpoint.
 *
 * The browser only sends `deviceCode` or `refreshToken`; the endpoint and `client_id` are resolved
 * server-side. One call is one upstream request: the polling cadence stays in the browser and this
 * route never sleep-loops.
 */
import { NextRequest } from 'next/server';
import {
  JSON_HEADERS,
  forwardUpstream,
  formBody,
  readUpstreamText,
  requireSubscriptionConfig,
  upstreamUnreachable,
} from '../shared';

export const runtime = 'nodejs';

/** device_code and refresh_token are opaque strings; a reasonable one never exceeds 4KB. */
const MAX_TOKEN_INPUT_LEN = 4096;

function readOpaque(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_TOKEN_INPUT_LEN) return null;
  return trimmed;
}

export async function POST(request: NextRequest) {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return Response.json({ error: 'invalid_body' }, { status: 400, headers: JSON_HEADERS });
  }
  const body = (parsed ?? {}) as { deviceCode?: unknown; refreshToken?: unknown };
  const deviceCode = readOpaque(body.deviceCode);
  const refreshToken = readOpaque(body.refreshToken);
  // Exactly one of the two: sending both means the caller has not decided which operation it wants, so reject rather than guess.
  if ((deviceCode && refreshToken) || (!deviceCode && !refreshToken)) {
    return Response.json({ error: 'invalid_grant_input' }, { status: 400, headers: JSON_HEADERS });
  }

  const resolution = await requireSubscriptionConfig();
  if (!resolution.ok) return resolution.response;
  const { config } = resolution;

  const fields: Record<string, string> = deviceCode
    ? {
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        device_code: deviceCode,
        client_id: config.clientId,
      }
    : {
        grant_type: 'refresh_token',
        refresh_token: refreshToken as string,
        client_id: config.clientId,
      };

  try {
    const upstream = await fetch(config.tokenEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body: formBody(fields),
      cache: 'no-store',
    });
    return forwardUpstream(upstream.status, await readUpstreamText(upstream));
  } catch {
    return upstreamUnreachable();
  }
}

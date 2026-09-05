/**
 * Tell upstream to revoke tokens when a subscription connection is disconnected (RFC 7009).
 *
 * Best effort, never blocking the local delete: once the user hits disconnect, no usable token
 * should remain on this machine. If upstream is down, times out or returns an error, local
 * cleanup still has to complete, so this route answers 200 for any well-formed request and puts
 * the revocation result in the body for debugging; the client does not branch on it.
 *
 * The revocation endpoint and `client_id` are resolved from server-side metadata only and have
 * already passed the `trustedAuthHosts` plus https allowlist inside
 * `resolveGrokSubscriptionAuth`. A URL supplied by the browser is never accepted, or this route
 * would be an open proxy. `revocationEndpoint` is optional: when it is absent the call is
 * skipped rather than treated as an error.
 */
import { NextRequest } from 'next/server';
import {
  JSON_HEADERS,
  formBody,
  requireSubscriptionConfig,
} from '../shared';

export const runtime = 'nodejs';

/** access / refresh tokens are opaque strings; a plausible one never exceeds 8KB. */
const MAX_TOKEN_INPUT_LEN = 8192;

/**
 * Timeout for the revocation request. Disconnecting is a synchronous user action, so a stuck
 * upstream must not pin the user on "disconnecting"; on timeout it gives up and local cleanup
 * proceeds as usual.
 */
const REVOKE_TIMEOUT_MS = 5000;

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
  const body = (parsed ?? {}) as { accessToken?: unknown; refreshToken?: unknown };
  const accessToken = readOpaque(body.accessToken);
  const refreshToken = readOpaque(body.refreshToken);
  if (!accessToken && !refreshToken) {
    return Response.json({ error: 'missing_token' }, { status: 400, headers: JSON_HEADERS });
  }

  const resolution = await requireSubscriptionConfig();
  if (!resolution.ok) return resolution.response;
  const { config } = resolution;

  const endpoint = config.revocationEndpoint;
  // A missing optional field is not an error: no revocation endpoint must not make disconnect fail.
  if (!endpoint) {
    return Response.json({ revoked: false, skipped: true }, { status: 200, headers: JSON_HEADERS });
  }

  // Revoke access and refresh separately: RFC 7009's `token_type_hint` is only a hint, and
  // revoking the access token on the xAI side does not necessarily revoke the refresh token.
  // Skipping the latter would leave a path that can still mint new tokens.
  const targets: Array<{ token: string; hint: string }> = [];
  if (accessToken) targets.push({ token: accessToken, hint: 'access_token' });
  if (refreshToken) targets.push({ token: refreshToken, hint: 'refresh_token' });

  const results = await Promise.all(
    targets.map(async ({ token, hint }) => {
      try {
        const upstream = await fetch(endpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            Accept: 'application/json',
          },
          body: formBody({ token, client_id: config.clientId, token_type_hint: hint }),
          cache: 'no-store',
          signal: AbortSignal.timeout(REVOKE_TIMEOUT_MS),
        });
        return upstream.ok;
      } catch {
        return false;
      }
    }),
  );

  // Always 200: a failed revocation is upstream's problem, and the client just goes on deleting the local credential.
  return Response.json(
    { revoked: results.some(Boolean) },
    { status: 200, headers: JSON_HEADERS },
  );
}

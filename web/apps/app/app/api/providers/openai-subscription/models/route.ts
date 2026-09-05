/**
 * Model catalog for the Codex subscription path.
 *
 * **The official catalog cannot stand in for it**: the official catalog describes the pay-as-you-go
 * `api.openai.com` path (gpt-4o / o3 and so on), while the Codex backend exposes a different
 * gpt-5.x line (sol / terra / luna and so on). Filling a subscription instance with the former means
 * every model the user picks does not exist on this path, and the first message fails.
 *
 * Two Codex-specific conventions, confirmed against a real pro account:
 * 1. the `client_version` query parameter is required (its value is the delivered `version` header);
 *    the upstream returns 400 without it;
 * 2. `chatgpt-account-id` must always be sent, and the browser supplies the value it already parsed
 *    and validated during authorization - the server does not re-derive it from the access token,
 *    because the claim lives in the id_token and is not guaranteed to be in the access token.
 */
import { NextRequest } from 'next/server';
import { buildCodexModelsURL } from '@oriveo/core/providers/openai-subscription';
import {
  JSON_HEADERS,
  MAX_UPSTREAM_CATALOG_BYTES,
  forwardUpstream,
  readOpaque,
  readUpstreamText,
  requireSubscriptionConfig,
  upstreamUnreachable,
} from '../shared';

export const runtime = 'nodejs';

const MAX_ACCESS_TOKEN_LEN = 8192;
/** The account id is a short UUID-shaped string; 256 is far above the real length. */
const MAX_ACCOUNT_ID_LEN = 256;

export async function POST(request: NextRequest) {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return Response.json({ error: 'invalid_body' }, { status: 400, headers: JSON_HEADERS });
  }
  const payload = (parsed ?? {}) as { accessToken?: unknown; accountID?: unknown };
  const accessToken = readOpaque(payload.accessToken, MAX_ACCESS_TOKEN_LEN);
  if (!accessToken) {
    return Response.json({ error: 'missing_access_token' }, { status: 400, headers: JSON_HEADERS });
  }
  const accountID = readOpaque(payload.accountID, MAX_ACCOUNT_ID_LEN);
  if (!accountID) {
    // The upstream always rejects a missing account header. Saying so here beats leaving the user to retry against "could not load the model list".
    return Response.json({ error: 'missing_account_id' }, { status: 400, headers: JSON_HEADERS });
  }

  const resolution = await requireSubscriptionConfig();
  if (!resolution.ok) return resolution.response;
  const { config } = resolution;

  try {
    const upstream = await fetch(buildCodexModelsURL(config), {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${accessToken}`,
        'chatgpt-account-id': accountID,
        // Both the header names and values come from the server-delivered configuration: once
        // `version` falls below the OpenAI minimum every call 426s, and changing a client constant
        // would require a release. This only passes them through and keeps no local default.
        ...config.requiredHeaders,
      },
      cache: 'no-store',
    });
    // The catalog is not an OAuth receipt, so read it with a catalog-sized limit (the default 64KB would cut it into half a JSON document).
    return forwardUpstream(
      upstream.status,
      await readUpstreamText(upstream, MAX_UPSTREAM_CATALOG_BYTES),
      'models',
    );
  } catch {
    return upstreamUnreachable('models');
  }
}

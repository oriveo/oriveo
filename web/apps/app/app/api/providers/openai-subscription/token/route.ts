/**
 * Second stage of the two-stage device flow, meaning polling plus the PKCE exchange, and
 * credential renewal.
 *
 * The exchange is folded into the server: polling `deviceTokenEndpoint` yields an
 * `authorization_code` plus `code_verifier`, not a token, so it is immediately exchanged at
 * `tokenEndpoint` within the same round trip. The browser then sees the same state machine as
 * Grok (poll, then tokens) and `code_verifier` never leaves the server.
 *
 * The stage marker (`X-Oriveo-Codex-Stage`) is not decoration: the same 403 means opposite
 * things in the two stages. While polling it means the user has not approved yet; during
 * exchange or renewal it means the account tier is not supported. The route forwards the status
 * code faithfully, and this header tells the browser which reading applies.
 */
import { NextRequest } from 'next/server';
import { decodeCodexAuthorizationGrant } from '@oriveo/core/providers/openai-subscription';
import {
  JSON_HEADERS,
  forwardUpstream,
  formBody,
  readOpaque,
  readUpstreamText,
  requireSubscriptionConfig,
  upstreamUnreachable,
  type CodexAuthStage,
} from '../shared';

export const runtime = 'nodejs';

/** The user code is meant to be read aloud and runs to a few dozen characters at most; 256 is far above any real length. */
const MAX_USER_CODE_LEN = 256;

export async function POST(request: NextRequest) {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return Response.json({ error: 'invalid_body' }, { status: 400, headers: JSON_HEADERS });
  }
  const body = (parsed ?? {}) as {
    deviceAuthID?: unknown;
    userCode?: unknown;
    refreshToken?: unknown;
  };
  const deviceAuthID = readOpaque(body.deviceAuthID);
  const userCode = readOpaque(body.userCode, MAX_USER_CODE_LEN);
  const refreshToken = readOpaque(body.refreshToken);
  const wantsPoll = Boolean(deviceAuthID && userCode);
  // Exactly one of the two: supplying both means the caller has not decided which operation it wants, so reject rather than guess.
  if ((wantsPoll && refreshToken) || (!wantsPoll && !refreshToken)) {
    return Response.json({ error: 'invalid_grant_input' }, { status: 400, headers: JSON_HEADERS });
  }

  const resolution = await requireSubscriptionConfig();
  if (!resolution.ok) return resolution.response;
  const { config } = resolution;

  if (refreshToken) {
    // Renewal is form-encoded, unlike the JSON used by the device stage; the upstream does not accept the other shape.
    return exchange(
      config.tokenEndpoint,
      formBody({
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        client_id: config.clientId,
      }),
      'refresh',
    );
  }

  // ── Stage one: poll the authorization status ──
  let pollStatus: number;
  let pollText: string;
  try {
    const upstream = await fetch(config.deviceTokenEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ device_auth_id: deviceAuthID, user_code: userCode }),
      cache: 'no-store',
    });
    pollStatus = upstream.status;
    pollText = await readUpstreamText(upstream);
  } catch {
    return upstreamUnreachable('poll');
  }

  if (pollStatus !== 200) {
    // Forward faithfully: a 403/404 while polling means pending, and translation is left to `mapCodexDevicePollFailure` in the browser.
    return forwardUpstream(pollStatus, pollText, 'poll');
  }

  let grant: ReturnType<typeof decodeCodexAuthorizationGrant> = null;
  try {
    grant = decodeCodexAuthorizationGrant(JSON.parse(pollText) as unknown);
  } catch {
    grant = null;
  }
  if (!grant) {
    // A 200 with no code is how the upstream says the user has not approved yet; return an explicit error code rather than making the browser guess from an empty body.
    return forwardUpstream(
      400,
      JSON.stringify({ error: 'authorization_pending' }),
      'poll',
    );
  }

  // ── Stage two: the PKCE exchange ──
  return exchange(
    config.tokenEndpoint,
    formBody({
      grant_type: 'authorization_code',
      client_id: config.clientId,
      code: grant.authorizationCode,
      code_verifier: grant.codeVerifier,
      redirect_uri: config.redirectURI,
    }),
    'exchange',
  );
}

async function exchange(endpoint: string, body: string, stage: CodexAuthStage): Promise<Response> {
  try {
    const upstream = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body,
      cache: 'no-store',
    });
    return forwardUpstream(upstream.status, await readUpstreamText(upstream), stage);
  } catch {
    return upstreamUnreachable(stage);
  }
}

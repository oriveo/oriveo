/**
 * First step of the two-stage device flow: request a short code.
 *
 * The request body is empty. Both `client_id` and the endpoints are resolved by the server from its
 * configuration, so the browser cannot pass any parameter in.
 *
 * Two differences from Grok: the body is JSON rather than form-urlencoded, and the response carries no
 * authorization page URL (`verification_uri_complete` is a Grok field). The Codex authorization page
 * comes from the published configuration and the user types the short code into it.
 */
import {
  forwardUpstream,
  readUpstreamText,
  requireSubscriptionConfig,
  upstreamUnreachable,
} from '../shared';

export const runtime = 'nodejs';

export async function POST() {
  const resolution = await requireSubscriptionConfig();
  if (!resolution.ok) return resolution.response;
  const { config } = resolution;

  try {
    const upstream = await fetch(config.deviceAuthorizationEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({ client_id: config.clientId }),
      cache: 'no-store',
    });
    return forwardUpstream(upstream.status, await readUpstreamText(upstream), 'poll');
  } catch {
    return upstreamUnreachable('poll');
  }
}

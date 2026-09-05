/**
 * First step of device code authorization: request a short code and the authorization page URL.
 *
 * The request body is empty: `client_id`, `scope` and the endpoints are all resolved on the server
 * from the served configuration, so the browser cannot pass in a single parameter.
 */
import {
  forwardUpstream,
  formBody,
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
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body: formBody({ client_id: config.clientId, scope: config.scopes }),
      cache: 'no-store',
    });
    return forwardUpstream(upstream.status, await readUpstreamText(upstream));
  } catch {
    return upstreamUnreachable();
  }
}

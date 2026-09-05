/**
 * Shared parsing layer for the three Next routes of Grok subscription login
 * (device-code / token / models).
 *
 * The upstream endpoint is resolved from server-side metadata only; an arbitrary URL supplied
 * by the browser is never accepted. Otherwise these three routes would be an open proxy: anyone
 * could make the server call any address carrying their own headers. The only trusted source is
 * the `subscriptionAuth` block issued by the backend, and it must pass the `trustedAuthHosts`
 * plus https allowlist, which the resolver enforces.
 *
 * The browser polls `token` at `pollIntervalSeconds`; the route forwards a single upstream call
 * and never sleep-loops. A 30-minute polling loop inside a serverless function burns execution
 * time and makes cancelling from the client impossible.
 */
import {
  resolveGrokSubscriptionAuth,
  type GrokSubscriptionAuthConfig,
  type GrokSubscriptionAvailability,
} from '@oriveo/core/providers/grok-subscription';
import { getRuntimeMetadata } from '../../chat/stream/runtime';

export const JSON_HEADERS = {
  Accept: 'application/json',
  'Content-Type': 'application/json',
} as const;

/**
 * No version gate on the server: `minAppVersion` is for the client to evaluate, since only it
 * knows which version it is. The route only answers whether the configuration exists, whether
 * it is enabled, and whether the endpoint is trusted.
 */
export async function resolveSubscriptionAvailability(): Promise<GrokSubscriptionAvailability> {
  const metadata = await getRuntimeMetadata();
  const raw = metadata?.providerConfigs?.find((config) => config.kind === 'grok')
    ?.protocolFeatures?.subscriptionAuth;
  return resolveGrokSubscriptionAuth(raw, { platform: 'web' });
}

export type ConfigResolution =
  | { ok: true; config: GrokSubscriptionAuthConfig }
  | { ok: false; response: Response };

export async function requireSubscriptionConfig(): Promise<ConfigResolution> {
  const availability = await resolveSubscriptionAvailability();
  if (availability.state === 'available') {
    return { ok: true, config: availability.config };
  }
  // 503 rather than 500: nothing here is broken, this route is simply unavailable right now,
  // either not configured or turned off by the kill switch. The client uses `state` to decide
  // whether to hide the entry or show the issued copy, and does not guess any further.
  return {
    ok: false,
    response: Response.json(
      {
        error: 'grok_subscription_unavailable',
        state: availability.state,
        ...(availability.state === 'disabled' && availability.notice
          ? { notice: availability.notice }
          : {}),
      },
      { status: 503, headers: JSON_HEADERS },
    ),
  };
}

/** The upstream OAuth endpoint takes form-urlencoded, not JSON. */
export function formBody(fields: Record<string, string>): string {
  return new URLSearchParams(fields).toString();
}

/**
 * Forward the upstream response to the browser unchanged, status code and body alike.
 *
 * Error semantics are not translated on the server: an intermediate device code state is a 400
 * carrying an error code, and reading the status alone would turn "the user has not approved
 * yet" into a permanent failure. Translation is left to the shared `mapGrokSubscriptionFailure`
 * so both ends use one set of rules.
 */
export function forwardUpstream(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

export function upstreamUnreachable(): Response {
  return Response.json(
    { error: 'upstream_unreachable' },
    { status: 502, headers: JSON_HEADERS },
  );
}

/**
 * Upstream body limit.
 *
 * Two different orders of magnitude that cannot share one number: an OAuth response is a few
 * hundred bytes, while a model catalog is another matter - Codex `/models` carries dozens of
 * fields per model, 700+ bytes each, so the whole document passes 64KB easily.
 *
 * Observed in production: a catalog truncated at 64KB comes back as half a JSON document, the
 * browser's `JSON.parse` fails, `postJSON` reports `upstream`, and the copy ends up saying
 * "cannot connect to Codex" - even though the connection worked and upstream returned 200 with
 * a complete catalog. The user then debugs their network while the real cause is this read limit.
 */
const MAX_UPSTREAM_BODY_BYTES = 64 * 1024;
/** Catalog: leave plenty of headroom. A real catalog is tens to hundreds of KB, so 4MB is the "cannot possibly be a normal catalog" order of magnitude. */
export const MAX_UPSTREAM_CATALOG_BYTES = 4 * 1024 * 1024;

export async function readUpstreamText(
  response: Response,
  maxBytes: number = MAX_UPSTREAM_BODY_BYTES,
): Promise<string> {
  const text = await response.text().catch(() => '');
  if (text.length <= maxBytes) return text;
  // Never return a truncated half JSON document: downstream would parse a successful 200 as a
  // syntax error and translate it into a "cannot connect" message that contradicts the facts.
  // Return a valid error object that states what happened instead.
  return JSON.stringify({ error: 'upstream_body_too_large', bytes: text.length });
}

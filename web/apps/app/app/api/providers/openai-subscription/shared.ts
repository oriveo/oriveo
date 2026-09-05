/**
 * Shared parsing layer for the three Codex subscription sign-in routes (device-code / token / models).
 *
 * The upstream endpoint is resolved only from server-side metadata and never from a URL supplied by
 * the browser. Otherwise these three routes would be an open proxy: anyone could make the server
 * call an arbitrary address carrying its headers. The only trusted source is the `subscriptionAuth`
 * block shipped by the backend, and it must still pass the `trustedAuthHosts` plus https allowlist
 * enforced inside the resolver.
 *
 * The browser polls `token` itself on `pollIntervalSeconds`; each route call forwards upstream once
 * and never sleep-loops. A 15-minute polling loop inside a serverless function burns execution time
 * and makes "user cancelled" impossible to honour.
 *
 * The one structural difference from the Grok routes: Codex has no revocation endpoint, so there is
 * no `revoke`.
 */
import {
  resolveOpenAISubscriptionAuth,
  type OpenAISubscriptionAuthConfig,
  type OpenAISubscriptionAvailability,
} from '@oriveo/core/providers/openai-subscription';
import { getRuntimeMetadata } from '../../chat/stream/runtime';

export const JSON_HEADERS = {
  Accept: 'application/json',
  'Content-Type': 'application/json',
} as const;

/**
 * Stage marker for the two-phase device flow.
 *
 * The same status code means opposite things in the two phases: 403/404 while polling means the
 * user has not authorized yet, whereas a 403 during the PKCE exchange or a refresh means the
 * account tier is not supported. The routes forward upstream status codes verbatim, so this header
 * tells the browser which rules to translate with; otherwise an exchange-phase 403 would be read as
 * pending and polled until timeout.
 */
export const CODEX_STAGE_HEADER = 'X-Oriveo-Codex-Stage';
export type CodexAuthStage = 'poll' | 'exchange' | 'refresh' | 'models';

/**
 * No version gate server-side: `minAppVersion` is for the client to evaluate, since only it knows
 * its own version. These routes answer only whether the configuration exists, is enabled and points
 * at a trusted endpoint.
 */
export async function resolveSubscriptionAvailability(): Promise<OpenAISubscriptionAvailability> {
  const metadata = await getRuntimeMetadata();
  const raw = metadata?.providerConfigs?.find((config) => config.kind === 'openAI')
    ?.protocolFeatures?.subscriptionAuth;
  return resolveOpenAISubscriptionAuth(raw, { platform: 'web' });
}

export type ConfigResolution =
  | { ok: true; config: OpenAISubscriptionAuthConfig }
  | { ok: false; response: Response };

export async function requireSubscriptionConfig(): Promise<ConfigResolution> {
  const availability = await resolveSubscriptionAvailability();
  if (availability.state === 'available') {
    return { ok: true, config: availability.config };
  }
  // 503 rather than 500: nothing here is broken, this path is simply unavailable (not configured,
  // or switched off by the kill switch). The client uses `state` to decide whether to hide the entry
  // point or show the shipped copy, and does not guess further.
  return {
    ok: false,
    response: Response.json(
      {
        error: 'openai_subscription_unavailable',
        state: availability.state,
        ...(availability.state === 'disabled' && availability.notice
          ? { notice: availability.notice }
          : {}),
      },
      { status: 503, headers: JSON_HEADERS },
    ),
  };
}

/** The PKCE exchange and refresh use form-urlencoded; the device stage uses JSON. Upstream accepts neither in place of the other. */
export function formBody(fields: Record<string, string>): string {
  return new URLSearchParams(fields).toString();
}

/**
 * Forward the upstream response to the browser verbatim, status and body both preserved, and tag
 * the current stage.
 *
 * Error semantics are not translated server-side: the intermediate states of a device code are a
 * combination of status code and error code, and translating once here and again in the browser
 * would eventually leave the two rule sets out of sync. Translation is left to the shared
 * `mapOpenAISubscriptionFailure` / `mapCodexDevicePollFailure` so both ends use one rule set.
 */
export function forwardUpstream(status: number, body: string, stage: CodexAuthStage): Response {
  return new Response(body, {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      [CODEX_STAGE_HEADER]: stage,
    },
  });
}

export function upstreamUnreachable(stage: CodexAuthStage): Response {
  return Response.json(
    { error: 'upstream_unreachable' },
    { status: 502, headers: { ...JSON_HEADERS, [CODEX_STAGE_HEADER]: stage } },
  );
}

/**
 * Upstream body limit.
 *
 * Two different magnitudes that cannot share one number: an OAuth response is a few hundred bytes,
 * whereas a model catalog is another matter - Codex `/models` carries dozens of fields per model,
 * 700+ bytes each, so the whole document easily passes 64KB.
 *
 * Observed in production: once a catalog was truncated at 64KB the response was half a JSON
 * document, the browser `JSON.parse` failed, `postJSON` reported `upstream`, and the copy ended up
 * saying the app could not connect to Codex - even though the connection was fine and upstream had
 * returned 200 with a complete catalog. The real cause was this read limit.
 */
const MAX_UPSTREAM_BODY_BYTES = 64 * 1024;
/** Catalogs get plenty of headroom. A real catalog runs from tens to a few hundred KB; 4MB is the "cannot possibly be a normal catalog" mark. */
export const MAX_UPSTREAM_CATALOG_BYTES = 4 * 1024 * 1024;

export async function readUpstreamText(
  response: Response,
  maxBytes: number = MAX_UPSTREAM_BODY_BYTES,
): Promise<string> {
  const text = await response.text().catch(() => '');
  if (text.length <= maxBytes) return text;
  // Never return a truncated half JSON document: downstream would parse a successful 200 as a
  // syntax error and turn it into a "cannot connect" message that contradicts the facts. Return a
  // well-formed error object that says what actually happened.
  return JSON.stringify({ error: 'upstream_body_too_large', bytes: text.length });
}

/** device_auth_id / user_code / refresh_token are opaque strings; a legitimate one never exceeds 4KB. */
const MAX_OPAQUE_INPUT_LEN = 4096;

export function readOpaque(value: unknown, maxLen = MAX_OPAQUE_INPUT_LEN): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLen) return null;
  return trimmed;
}

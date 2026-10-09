/**
 * Client-side helpers that call the /api/* proxy routes instead of
 * hitting provider APIs directly. Used when USE_PROXY is true.
 */

import type { ProviderKind } from '@oriveo/shared';
import type { StreamEvent, ContentPart, StreamHandle, StreamOptions } from './types';
import { createSSEStream } from '../../infra/sse-parser';
import { networkError, toProviderError } from './errors';
import type { RelayErrorContext } from './relay-error-classifier';
import {
  SUBSCRIPTION_CONFIG_REVISION_HEADER,
  SUBSCRIPTION_CONFIG_STALE_HEADER,
  shouldReportSubscriptionVersionRejection,
} from './subscription-version-rejection';
import { createProxyChunkParser, type ContinuationCaptureConfig } from '@oriveo/core/providers/proxy-chunk-parser';
import type { ProxyMessage, ProxyToolDefinition } from '@oriveo/core/providers/request-builders/runtime';
import type { ProviderErrorSource } from '@oriveo/core/providers/errors';
import { selfHealTelemetryTransport } from '@oriveo/core/providers/unsupported-param';
import { refreshMetadata, resolveCatalogModel } from '../metadata/metadata-client';
import { decodeCapabilityResultContext } from '../chat/capability-result-runtime';
import { CUSTOM_FRAGMENT_ERROR_KIND, parseCustomFragmentRejectionCode } from '../chat/custom-fragment-rejection';
import { ADDITIONAL_BODY_ERROR_KIND, validateAdditionalBody } from '@oriveo/core/providers/request-builders/additional-body';
import { additionalBodyRetryEligible } from '../chat/additional-body-retry';
import { generationWriteFacts } from '@oriveo/core/providers/generation-rejection-facts';
import { sanitizeUpstreamErrorText } from '@oriveo/core/providers/upstream-error-text';
import {
  CAPABILITY_RECOVERY_HEADER,
  decodeCapabilityRecoveryDescriptor,
  recordCapabilityRejection,
  type CapabilityRecoveryDescriptor,
} from '../chat/capability-recovery-runtime';

export const USE_PROXY = typeof window !== 'undefined';
const ERROR_SOURCE_HEADER = 'X-Oriveo-Error-Source';
const SELF_HEAL_PARAM_HEADER = 'X-Oriveo-Self-Heal-Param';
const CAPABILITY_RESULT_HEADER = 'X-Oriveo-Capability-Result';

/* ── Validate Key via proxy ──────────────────────────── */

/** Three-state result of validating a BYOK key, matching the Next runtime `/api/providers/validate` verdicts. */
export type KeyValidationResult = 'valid' | 'invalid' | 'unverified';

/**
 * Official providers: probe through the Next runtime proxy and return one of valid, invalid or
 * unverified. The verdict is never thrown (invalid is a normal return value, not an error);
 * only network or routing failures fall back to unverified.
 */
export async function validateKeyProxy(
  providerKind: ProviderKind,
  apiKey: string,
  baseURL?: string,
): Promise<KeyValidationResult> {
  try {
    const res = await fetch('/api/providers/validate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ providerKind, apiKey, baseURL }),
    });

    if (!res.ok) {
      // A routing-level failure (missing field, unknown provider, 502) is not evidence that the key is invalid, so it becomes unverified.
      return 'unverified';
    }

    const payload = (await res.json().catch(() => null)) as { result?: KeyValidationResult } | null;
    const result = payload?.result;
    return result === 'valid' || result === 'invalid' || result === 'unverified'
      ? result
      : 'unverified';
  } catch {
    // A network failure such as an unreachable route is not evidence against the key, so it becomes unverified.
    return 'unverified';
  }
}

/** This function only serves relay key validation, so the context passed to toProviderError is always the relay signal. */
const RELAY_ERROR_CONTEXT: RelayErrorContext = { isRelay: true };

/** Relay keeps the throw-on-error semantics, since custom endpoints have no metadata contract. */
export async function validateRelayKeyProxy(
  apiKey: string,
  baseURL?: string,
): Promise<void> {
  let res: Response;
  try {
    res = await fetch('/api/providers/validate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ providerKind: 'relay', apiKey, baseURL }),
    });
  } catch (err) {
    throw networkError(err);
  }
  if (!res.ok) {
    const detail = await readErrorDetail(res, 'Validation failed');
    if (res.status === 502) throw networkError(detail);
    throw toProviderError(res.status, detail, undefined, RELAY_ERROR_CONTEXT);
  }
}

/* ── Sync Models via proxy ───────────────────────────── */

export async function syncModelsProxy(
  providerKind: ProviderKind,
  apiKey: string,
  baseURL?: string,
): Promise<unknown> {
  let res: Response;
  try {
    res = await fetch('/api/providers/models', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ providerKind, apiKey, baseURL }),
    });
  } catch (err) {
    throw networkError(err);
  }
  if (!res.ok) {
    const detail = await readErrorDetail(res, 'Sync failed');
    if (res.status === 502) throw networkError(detail);
    // syncModelsProxy serves both official providers and relay, split by providerKind, so the
    // relay-specific copy is only produced when a real relay catalog sync fails.
    throw toProviderError(res.status, detail, undefined, providerKind === 'relay' ? RELAY_ERROR_CONTEXT : undefined);
  }
  return res.json();
}

/* ── Stream Chat via proxy ───────────────────────────── */

/**
 * Strip `capabilityIdentity` from options sent to our own server.
 *
 * It is the browser-local negative cache partition identity (partition, connection and
 * credential epoch). The server route shares a process across users and by contract never
 * learns from it (see serverSelfHealScope in `app/api/chat/stream/unsupported-param.ts`), so
 * sending it has no effect other than putting one more local identifier on the wire.
 */
function withoutCapabilityIdentity(options?: StreamOptions): StreamOptions | undefined {
  if (!options?.capabilityIdentity && !options?.capabilityRecoveryIdentity && !options?.capabilityRecipeResendOwners && !options?.continuation && !options?.grokSubscriptionAuth && !options?.openAISubscriptionAuth) return options;
  // `grokSubscriptionAuth` and `openAISubscriptionAuth` travel as a top-level `authMode` on the
  // request body rather than inside options: options is passed through to the builder verbatim,
  // and mixing in a local flag that only picks an endpoint would create two sources of truth.
  //
  // Codex is the exception: `openAISubscriptionAccountID` and `upstreamReasoningLevels` really
  // are request parameters (one becomes a header, the other decides the effort value) and the
  // route needs them to build a valid request, so they stay in options and go with it.
  const { capabilityIdentity: _localOnly, capabilityRecoveryIdentity: _recoveryLocalOnly, capabilityRecipeResendOwners: _resendLocalOnly, continuation: _continuation, grokSubscriptionAuth: _subscriptionLocalOnly, openAISubscriptionAuth: _codexLocalOnly, ...rest } = options;
  return rest;
}

export function sendStreamProxy(
  providerKind: ProviderKind,
  apiKey: string,
  modelID: string,
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
  baseURL?: string,
  options?: StreamOptions,
): StreamHandle {
  const controller = new AbortController();
  let capabilityResultContext: ReturnType<typeof decodeCapabilityResultContext> = null;
  let resolveCapabilityContextReady!: (value: unknown) => void;
  const capabilityResultContextReady = new Promise<unknown>((resolve) => { resolveCapabilityContextReady = resolve; });
  let capabilityCustomRetryEligible = false;
  let additionalBodyRetry = false;
  // "Actually sent" means the route-side merger will merge non-empty content: decided by the same pure function as the route, never by looking at storage.
  const additionalBodyValidation = options?.additionalBody ? validateAdditionalBody(options.additionalBody.raw) : null;
  const additionalBodyApplied = Boolean(additionalBodyValidation?.accepted && Object.keys(additionalBodyValidation.value ?? {}).length > 0);
  const generationWrite = generationWriteFacts(options);
  let capabilityRecoveryDescriptor: CapabilityRecoveryDescriptor | null = null;
  let subscriptionVersionRejectionSkipReport = false;
  const endpoint = '/api/chat/stream';
  const body = JSON.stringify({
      providerKind, apiKey, modelID, messages, baseURL,
      ...(options?.grokSubscriptionAuth || options?.openAISubscriptionAuth
        ? { authMode: 'subscription' }
        : {}),
      options: withoutCapabilityIdentity(options),
      ...(options?.continuation ? { continuation: options.continuation } : {}),
    });

  const stream = new ReadableStream<StreamEvent>({
    async start(ctrl) {
      let res: Response;
      try {
        const requestInit: RequestInit = {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body,
          signal: controller.signal,
        };
        res = await fetch(endpoint, requestInit);
      } catch (err) {
        if (controller.signal.aborted) { ctrl.close(); return; }
        ctrl.enqueue({
          type: 'error',
          error: err instanceof Error ? err.message : 'Network error',
          errorKind: 'network',
          source: 'network',
        });
        ctrl.close();
        return;
      }

      // The route creates this only from its production builder and selected parser binding.
      // A missing or invalid header intentionally leaves the result state unconfirmed rather
      // than reconstructing it from model ids.
      capabilityResultContext = decodeCapabilityResultContext(res.headers.get(CAPABILITY_RESULT_HEADER));
      resolveCapabilityContextReady(capabilityResultContext);
      capabilityRecoveryDescriptor = decodeCapabilityRecoveryDescriptor(res.headers.get(CAPABILITY_RECOVERY_HEADER));
      capabilityCustomRetryEligible = capabilityRecoveryDescriptor?.source === 'custom';
      if (capabilityRecoveryDescriptor && options?.capabilityRecoveryIdentity) {
        // Include the thinking tier that was actually sent: only this tier was rejected, the others stay usable.
        recordCapabilityRejection(options.capabilityRecoveryIdentity, capabilityRecoveryDescriptor, Date.now(), {
          reasoningIntent: options.capabilityPreferences?.reasoningIntent ?? options.reasoning,
        });
      }

      // 426 is the only early signal that xAI raised its minimum client version. The client
      // snapshot has a 24h TTL and refreshes only in the background on a cache hit, so without
      // pulling once here a user could wait a day for a corrected value to take effect.
      if ((options?.grokSubscriptionAuth || options?.openAISubscriptionAuth) && res.status === 426) {
        void refreshMetadata().catch(() => {});
        // The route has force refreshed its server-side snapshot and returned which configuration
        // this request used and whether it changed. That decides whether this 426 is still worth
        // reporting: not when the configuration changed, and once per session otherwise.
        subscriptionVersionRejectionSkipReport = !shouldReportSubscriptionVersionRejection({
          lane: options?.grokSubscriptionAuth ? 'grok' : 'openAI',
          revision: res.headers.get(SUBSCRIPTION_CONFIG_REVISION_HEADER),
          stale: res.headers.get(SUBSCRIPTION_CONFIG_STALE_HEADER) === '1',
        });
      }

      // Custom request fields failing closed with 400: the request was never sent, so this is
      // neither a network fault nor an upstream rejection. It must be checked before the 502
      // branch below and must not land in `errorKind: 'network'`, which would show a problem
      // only fixable by changing configuration as "try again later". Setting
      // `capabilityCustomRetryEligible` lets the recovery card offer "retry without custom
      // fields".
      if (!res.ok && res.status === 400) {
        // Read a clone: when this is not a custom-field rejection, the original body still has to
        // reach createSSEStream below for the server's message. Reading the original would drain it
        // and every 400 would end up as the generic English sentence.
        const rejection = await readCustomFragmentRejection(res.clone());
        if (rejection) {
          capabilityCustomRetryEligible = true;
          ctrl.enqueue({
            type: 'error',
            error: rejection.reason,
            errorKind: CUSTOM_FRAGMENT_ERROR_KIND,
            source: 'oriveo',
          });
          ctrl.close();
          return;
        }
        // A 400 that reaches this point is an upstream rejection (the request was really sent and no upstream event has arrived yet).
        additionalBodyRetry = additionalBodyRetryEligible({
          additionalBodyApplied, receivedUpstreamEvent: false, sideEffects: false, localRejection: false, httpStatus: 400,
        });
      }

      if (!res.ok && res.status === 502) {
        const detail = await readErrorDetail(res, 'Failed to connect to provider');
        ctrl.enqueue({ type: 'error', error: detail, errorKind: 'network', source: 'network' });
        const additionalBodyCode = await readAdditionalBodyRejection(res.clone());
        if (additionalBodyCode) {
          // Local rejection of the additional body: carries only the safe code and does not set capabilityCustomRetryEligible (a local rejection has no retry path).
          ctrl.enqueue({ type: 'error', error: additionalBodyCode, errorKind: ADDITIONAL_BODY_ERROR_KIND, source: 'oriveo' });
          ctrl.close();
          return;
        }
        ctrl.close();
        return;
      }

      const selfHealedParam = res.headers.get(SELF_HEAL_PARAM_HEADER);
      // A capability header makes this a versioned recipe execution. Never
      // let a stale legacy header turn it into provider/model telemetry.
      if (!capabilityResultContext && selfHealedParam && /^[a-z][a-z0-9_.-]{0,79}$/.test(selfHealedParam)) {
        // A diagnostic entry's transport must be the model's protocol transport; providerKind is only a catalog lookup key.
        window.dispatchEvent(new CustomEvent('oriveo:unsupported-param-self-healed', {
          detail: {
            param: selfHealedParam,
            transport: selfHealTelemetryTransport(resolveCatalogModel(modelID, providerKind)?.transport),
          },
        }));
      }

      // Handle the response with createSSEStream, which brings its own error handling, buffer
      // management and trailing-data handling. The parser carries closure state (Anthropic
      // merges input and output tokens across chunks), so a fresh instance is created per
      // stream, and providerKind selects the right UsageBreakdown parser for cache discount
      // breakdowns.
      const parser = createProxyChunkParser(providerKind, continuationCaptureFromHeaders(res.headers));
      // `res.ok` is a precondition: `createJsonProxyStream` is for successful non-streaming
      // responses and feeds the body straight to the protocol parser. Upstream errors also come
      // back as `application/json`, and that path would reduce them to a generic "Invalid
      // non-streaming provider response", losing the specific meaning of 401, 403 or 429.
      // Anything not ok goes to `createSSEStream`, which has a dedicated error branch
      // (toProviderError plus errorKind).
      const inner = res.ok && res.headers.get('Content-Type')?.includes('application/json')
        ? createJsonProxyStream(res, parser, responseErrorSource(res) ?? 'provider')
        : createSSEStream(res, parser, {
        signal: controller.signal,
        errorSource: responseErrorSource(res) ?? 'provider',
        // The same 401 or 403 means something entirely different on a subscription path than in key mode, and classification has to know that.
        ...(options?.grokSubscriptionAuth ? { grokSubscriptionAuth: true } : {}),
        ...(options?.openAISubscriptionAuth ? { openAISubscriptionAuth: true } : {}),
      });
      const reader = inner.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          // An in-stream error frame is the upstream's raw text: scrub this request's key / subscription token (in subscription mode it is also sent via apiKey) and truncate to 2 KB.
          const outgoing = value.type === 'error' && value.streamErrorFrame
            ? { ...value, error: sanitizeUpstreamErrorText(value.error, [apiKey]) }
            : value;
          ctrl.enqueue(outgoing.type === 'error' && subscriptionVersionRejectionSkipReport
            ? { ...outgoing, skipReport: true }
            : outgoing);
        }
      } catch {
        // The inner stream has already handled the error
      }
      ctrl.close();
    },
  });

  return {
    stream,
    abort: () => controller.abort(),
    getCapabilityResultContext: () => capabilityResultContext,
    capabilityResultContextReady,
    getCapabilityCustomRetryEligible: () => capabilityCustomRetryEligible,
    getAdditionalBodyRetryEligible: () => additionalBodyRetry,
    getAdditionalBodyApplied: () => additionalBodyApplied,
    getGenerationWrite: () => generationWrite,
    getCapabilityRecoveryDescriptor: () => capabilityRecoveryDescriptor,
  };
}

/** Non-streaming official transports still enter the same StreamEvent pipeline. The proxy route
 * preserves upstream application/json; decode that single production payload with the exact
 * parser used for SSE rather than pretending JSON is an SSE data line. */
function createJsonProxyStream(res: Response, parser: ReturnType<typeof createProxyChunkParser>, source: ProviderErrorSource): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    async start(controller) {
      try {
        const text = await res.text();
        const parsed = parser(null, text);
        for (const event of parsed ? (Array.isArray(parsed) ? parsed : [parsed]) : []) controller.enqueue(event);
        controller.enqueue({ type: 'done' });
      } catch (error) {
        controller.enqueue({ type: 'error', error: error instanceof Error ? error.message : 'Invalid non-streaming provider response', errorKind: 'upstream', source });
      }
      controller.close();
    },
  });
}

function continuationCaptureFromHeaders(headers: Headers): ContinuationCaptureConfig | undefined {
  const kind = headers.get('X-Oriveo-Continuation-Kind');
  const protocol = headers.get('X-Oriveo-Continuation-Protocol');
  const responseParserKind = headers.get('X-Oriveo-Continuation-Parser');
  const safe = (value: string | null): value is string => value != null && /^[a-z][a-z0-9_]{0,79}$/.test(value);
  return safe(kind) && safe(protocol) && safe(responseParserKind) ? { kind, protocol, responseParserKind } : undefined;
}

/**
 * One stateless Library agent leg. Kept separate from ordinary chat so tool messages and
 * schemas cannot leak into regular sends or a user-owned provider.
 */
export function sendLibraryAgentLeg(
  providerKind: ProviderKind,
  apiKey: string,
  modelID: string,
  messages: ProxyMessage[],
  tools: ProxyToolDefinition[],
  baseURL?: string,
  options?: StreamOptions,
  toolChoice: 'auto' | 'none' | 'required' = 'auto',
): StreamHandle {
  const controller = new AbortController();
  let toolCallRejectionContext: unknown;
  const stream = new ReadableStream<StreamEvent>({
    async start(ctrl) {
      try {
        const response = await fetch('/api/chat/stream', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            providerKind,
            apiKey,
            modelID,
            messages,
            ...(tools.length > 0 ? { tools, toolChoice } : {}),
            baseURL,
            ...(options?.grokSubscriptionAuth || options?.openAISubscriptionAuth
              ? { authMode: 'subscription' }
              : {}),
            options: withoutCapabilityIdentity(options),
          }),
          signal: controller.signal,
        });
        if (!response.ok) {
          // A route-side local rejection of the additional body: recognized the same way as on a normal send, and must not be treated as an upstream 400.
          const additionalBodyCode = response.status === 400 ? await readAdditionalBodyRejection(response.clone()) : null;
          if (additionalBodyCode) {
            ctrl.enqueue({ type: 'error', error: additionalBodyCode, errorKind: ADDITIONAL_BODY_ERROR_KIND, source: 'oriveo' });
            ctrl.close();
            return;
          }
          const payload = await readErrorPayload(response, 'Library model request failed');
          if (payload.structuredError !== undefined) {
            toolCallRejectionContext = {
              status: response.status,
              structuredError: payload.structuredError,
            };
          }
          ctrl.enqueue({
            type: 'error',
            error: payload.detail,
            errorKind: response.status === 429 ? 'rate_limited' : 'unknown',
            source: responseErrorSource(response) ?? 'provider',
            status: response.status,
          });
          ctrl.close();
          return;
        }
        const inner = createSSEStream(
          response,
          createProxyChunkParser(providerKind, continuationCaptureFromHeaders(response.headers)),
          {
          signal: controller.signal,
          errorSource: responseErrorSource(response) ?? 'provider',
          },
        );
        const reader = inner.getReader();
        try {
          while (true) {
            const next = await reader.read();
            if (next.done) break;
            ctrl.enqueue(next.value);
          }
          ctrl.close();
        } finally {
          reader.releaseLock();
        }
      } catch (error) {
        if (!controller.signal.aborted) {
          ctrl.enqueue({
            type: 'error',
            error: error instanceof Error ? error.message : 'Network error',
            errorKind: 'network',
            source: 'network',
          });
        }
        ctrl.close();
      }
    },
    cancel() { controller.abort(); },
  });
  return {
    stream,
    abort: () => controller.abort(),
    getToolCallRejectionContext: () => toolCallRejectionContext,
  };
}

async function readErrorDetail(res: Response, fallback: string): Promise<string> {
  return (await readErrorPayload(res, fallback)).detail;
}

async function readErrorPayload(
  res: Response,
  fallback: string,
): Promise<{ detail: string; structuredError?: unknown }> {
  const text = await res.text().catch(() => '');
  if (!text) return { detail: fallback };

  try {
    const parsed = JSON.parse(text) as unknown;
    if (typeof parsed === 'object' && parsed !== null) {
      const record = parsed as { error?: unknown; message?: unknown };
      const error = typeof record.error === 'string' ? record.error : undefined;
      const message = typeof record.message === 'string' ? record.message : undefined;
      return { detail: error || message || text, structuredError: parsed };
    }
    return { detail: text };
  } catch {
    return { detail: text };
  }
}

async function readAdditionalBodyRejection(res: Response): Promise<string | null> {
  const text = await res.text().catch(() => '');
  if (!text) return null;
  try {
    const parsed = JSON.parse(text) as { errorKind?: unknown; code?: unknown };
    if (parsed.errorKind !== ADDITIONAL_BODY_ERROR_KIND) return null;
    return typeof parsed.code === 'string' && parsed.code.startsWith('additional_body_rejected:')
      ? parsed.code
      : 'additional_body_rejected';
  } catch {
    return null;
  }
}

/**
 * Only the route's dedicated shape is accepted (`errorKind` plus a `reason` from a closed
 * vocabulary); nothing is inferred from the status code or the error text. 400 is shared by a
 * dozen different causes, and guessing would show "attachment too large" as "invalid custom
 * field". Returns null when it cannot be read, leaving the generic branch below to handle it.
 */
async function readCustomFragmentRejection(res: Response): Promise<{ reason: string } | null> {
  const text = await res.text().catch(() => '');
  if (!text) return null;
  try {
    const parsed = JSON.parse(text) as { errorKind?: unknown; reason?: unknown; code?: unknown };
    if (parsed.errorKind !== CUSTOM_FRAGMENT_ERROR_KIND) return null;
    // Use the safe code (with section name and line number) when present; a legacy response carries only a bare reason.
    if (typeof parsed.code === 'string' && parseCustomFragmentRejectionCode(parsed.code).owner) return { reason: parsed.code };
    return { reason: typeof parsed.reason === 'string' ? parsed.reason : '' };
  } catch {
    return null;
  }
}

function responseErrorSource(response: Response): ProviderErrorSource | undefined {
  const value = response.headers.get(ERROR_SOURCE_HEADER);
  return value === 'provider'
    || value === 'network'
    || value === 'oriveo'
    || value === 'desktop'
    || value === 'unknown'
    ? value
    : undefined;
}

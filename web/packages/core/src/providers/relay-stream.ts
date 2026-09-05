/**
 * The Relay streaming fetch chain.
 *
 * Upstream HTTP goes through the injected UpstreamTransport (the web build injects a window.fetch
 * wrapper, the desktop main process injects undici plus SSRF checks), so core is not coupled to a
 * global fetch. The signal is forwarded throughout to keep cross-process cancellation working.
 * buildRelayFetchArgs (three-state typeof window), the send* entry points and
 * buildRelayProxyConfig stay in apps/app, since they involve the browser reverse proxy and crypto.
 *
 * Shared by all 4 transports (openai_chat/responses, anthropic, gemini):
 *   - fetchRelayRequest: a single upstream POST
 *   - fetchRelayWithXHighRetry / fetchRelayWithFallbacks: the names are kept, but only one request is sent
 *   - createRelaySSEStream / createRelayJSONStream: streaming and non-streaming wrappers (they take a request callback that already carries the transport)
 *   - createRelayResponsesStreamWithRetry: the name is kept, and rejections are rethrown unchanged
 */

import type { StreamEvent } from './types';
import { createSSEStream } from './sse-parser';
import { toProviderError } from './errors';
import type { RelayErrorContext } from './relay-error-classifier';
import {
  executeWithUnsupportedParamSelfHeal,
  type CapabilityLearningIdentity,
  type UnsupportedParamDroppedReporter,
  type UnsupportedParamScope,
} from './unsupported-param';
import type { UpstreamTransport } from '../ports';
import { redactRelayCredentials } from '@oriveo/shared/relay/endpoint-policy';

/** The browser reverse proxy puts the real upstream URL in this header; core only uses it to restore the upstream address in toProviderError. */
export const RELAY_UPSTREAM_URL_HEADER = 'X-Relay-Upstream-URL';
const ERROR_SOURCE_HEADER = 'X-Oriveo-Error-Source';

/**
 * Every function in this file serves relay only (the 4-transport orchestration) and is never
 * called by an official adapter. This is the one reliable signal passed to
 * classifyRelayHTTPError, so that plain status-code rules for 429/401/404 apply to relay alone;
 * official providers used to hit the same relay-specific copy.
 */
const RELAY_ERROR_CONTEXT: RelayErrorContext = { isRelay: true };

export interface RelayRequest {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
  /**
   * The model ID actually sent. llama.cpp native request bodies have no model and Gemini puts the
   * model in the URL, so the self-healing scope cannot be inferred from the body alone.
   */
  modelID?: string;
  /**
   * Irreversible fingerprint of the real upstream URL. The public web path rewrites `url` to
   * `/api/relay/forward`, so the capability partition cannot be derived from the rewritten `url`.
   */
  endpointFingerprint?: string;
  /**
   * The **protocol transport literal** this request actually uses (`openai_responses` /
   * `anthropic_messages` and so on). The negative cache partition and the self-healing telemetry
   * share it. providerKind must not stand in for it, so the orchestration layer fills it from
   * `options.relayTransport` rather than guessing it from the URL here.
   */
  transport?: string;
  /**
   * Connection-level capability identity, a plain value object injected by each surface (web
   * renderer, or desktop renderer to main). When absent the negative cache fails closed, and a
   * rejected parameter never triggers a silent drop-and-resend.
   */
  capabilityIdentity?: CapabilityLearningIdentity;
  reasoningEffort?: 'low' | 'medium' | 'high' | 'xhigh';
}

export interface RelayRetryHints {
  reasoningEffortOverride?: 'high';
  removeTools?: boolean;
}

export interface RelayResponsesRetryDetector {
  triggered: boolean;
}

type RelayParseChunk = (
  eventType: string | null,
  data: string,
) => StreamEvent | StreamEvent[] | null;

export function createRelaySSEStream(
  request: (signal?: AbortSignal) => Promise<Response>,
  parseChunk: RelayParseChunk,
  signal?: AbortSignal,
  sensitiveCredentialValues: readonly string[] = [],
): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      let response: Response;
      try {
        response = await request(signal);
      } catch (error) {
        if (signal?.aborted) {
          ctrl.close();
          return;
        }
        ctrl.enqueue({
          type: 'error',
          error: redactRelayCredentials(
            error instanceof Error ? error.message : 'Network error',
            sensitiveCredentialValues,
          ),
          errorKind: 'network',
          source: 'network',
        });
        ctrl.close();
        return;
      }

      const inner = createSSEStream(response, parseChunk, {
        signal,
        errorSource: responseErrorSource(response) ?? 'provider',
        sensitiveCredentialValues,
        relayErrorContext: RELAY_ERROR_CONTEXT,
      });
      const reader = inner.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          ctrl.enqueue(redactRelayStreamEvent(value, sensitiveCredentialValues));
        }
      } finally {
        try { reader.releaseLock(); } catch { /* noop */ }
      }
      ctrl.close();
    },
  });
}

export function createRelayJSONStream(
  request: (signal?: AbortSignal) => Promise<Response>,
  parseResponse: (payload: unknown) => StreamEvent[],
  signal?: AbortSignal,
  sensitiveCredentialValues: readonly string[] = [],
): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      let response: Response;
      try {
        response = await request(signal);
      } catch (error) {
        if (signal?.aborted) {
          ctrl.close();
          return;
        }
        ctrl.enqueue({
          type: 'error',
          error: redactRelayCredentials(
            error instanceof Error ? error.message : 'Network error',
            sensitiveCredentialValues,
          ),
          errorKind: 'network',
          source: 'network',
        });
        ctrl.close();
        return;
      }

      if (!response.ok) {
        const detail = await response.text().catch(() => '');
        const providerError = toProviderError(
          response.status,
          detail,
          response.headers.get(RELAY_UPSTREAM_URL_HEADER) ?? response.url,
          RELAY_ERROR_CONTEXT,
          sensitiveCredentialValues,
        );
        ctrl.enqueue({
          type: 'error',
          error: providerError.message,
          errorDetail: providerError.detail,
          errorKind: providerError.kind,
          source: responseErrorSource(response) ?? providerError.source,
          status: providerError.status,
          upstreamURL: providerError.upstreamURL,
        });
        ctrl.close();
        return;
      }

      let payload: unknown;
      try {
        payload = await response.json();
      } catch (error) {
        // An abort that interrupts the body read closes quietly instead of surfacing a fake upstream error (matching the network catch in this file and the sse-parser semantics).
        if (signal?.aborted) { ctrl.close(); return; }
        ctrl.enqueue({
          type: 'error',
          error: error instanceof Error ? error.message : 'Invalid JSON response',
          errorKind: 'upstream',
          source: 'provider',
        });
        ctrl.close();
        return;
      }

      for (const event of parseResponse(payload)) {
        ctrl.enqueue(redactRelayStreamEvent(event, sensitiveCredentialValues));
      }
      if (!signal?.aborted) {
        ctrl.enqueue({ type: 'done' });
      }
      ctrl.close();
    },
  });
}

export async function fetchRelayRequest(
  request: RelayRequest,
  signal: AbortSignal | undefined,
  transport: UpstreamTransport,
  onUnsupportedParamDropped?: UnsupportedParamDroppedReporter,
): Promise<Response> {
  const scope = relayUnsupportedParamScope(request);
  const executed = await executeWithUnsupportedParamSelfHeal(request, {
    scope,
    signal,
    onUnsupportedParamDropped,
    execute: (activeRequest) => transport.fetch(activeRequest.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...activeRequest.headers },
      body: JSON.stringify(activeRequest.body),
      signal,
    }),
  });
  return executed.response;
}

/**
 * Negative cache scope: the 4 fields carried by the request (providerKind / modelID / transport /
 * endpointFingerprint) are derived by core from the real request, and the remaining 6 connection
 * identity fields are forwarded as-is. When identity is absent the returned scope is incomplete
 * and `markUnsupportedParamDropped` honestly reports it as ineligible.
 */
export function relayUnsupportedParamScope(request: RelayRequest): UnsupportedParamScope {
  const modelID = request.modelID
    ?? (typeof request.body.model === 'string' ? request.body.model : '');
  return {
    providerKind: 'relay',
    modelID,
    endpointFingerprint: request.endpointFingerprint ?? relayEndpointFingerprint(request.url),
    ...(request.transport ? { transport: request.transport } : {}),
    ...(request.capabilityIdentity ?? {}),
  };
}

/**
 * Irreversible endpoint identifier used for the capability negative cache partition and for
 * observability. Request addresses must not leave the device, so even a URL already stripped of
 * query and userInfo must not be returned as plain origin/path.
 */
export function relayEndpointFingerprint(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    const path = parsed.pathname.replace(/\/+$/, '') || '/';
    return `ep_${fnv1a32(`${parsed.protocol}//${parsed.host}${path}`)}`;
  } catch {
    return undefined;
  }
}

function fnv1a32(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

export async function fetchRelayWithXHighRetry(
  buildRequest: (reasoningEffortOverride?: 'high') => RelayRequest,
  signal: AbortSignal | undefined,
  transport: UpstreamTransport,
  onUnsupportedParamDropped?: UnsupportedParamDroppedReporter,
): Promise<Response> {
  // A rejected reasoning setting is user-visible recovery state. Never
  // silently rewrite xhigh to high and dispatch a second request.
  return fetchRelayRequest(buildRequest(), signal, transport, onUnsupportedParamDropped);
}

/** Legacy fetch fallback signature for Codex / Responses. Only the first leg is sent, and rejections are rethrown unchanged. */
export async function fetchRelayWithFallbacks(
  buildRequest: (hints?: RelayRetryHints) => RelayRequest,
  initialHints: RelayRetryHints | undefined,
  signal: AbortSignal | undefined,
  transport: UpstreamTransport,
  onUnsupportedParamDropped?: UnsupportedParamDroppedReporter,
): Promise<Response> {
  // A model-control or tool rejection is never a permission to mutate the body
  // and dispatch again. The original response stays readable by the caller.
  return fetchRelayRequest(buildRequest(initialHints), signal, transport, onUnsupportedParamDropped);
}

/**
 * Stream wrapper for the Codex / Responses transport. The old name and parameters are kept for
 * call-site compatibility, but both HTTP and in-stream rejections now rethrow the original error
 * instead of dropping tools or downgrading and sending a second leg.
 */
export function createRelayResponsesStreamWithRetry(
  buildRequest: (hints?: RelayRetryHints) => RelayRequest,
  parseChunk: RelayParseChunk,
  _detector: RelayResponsesRetryDetector,
  signal: AbortSignal | undefined,
  transport: UpstreamTransport,
  onUnsupportedParamDropped?: UnsupportedParamDroppedReporter,
  sensitiveCredentialValues: readonly string[] = [],
): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      const attempt = async (hints: RelayRetryHints | undefined): Promise<{ retried: boolean }> => {
        let response: Response;
        try {
          response = hints?.removeTools
            ? await fetchRelayRequest(buildRequest(hints), signal, transport, onUnsupportedParamDropped)
            : await fetchRelayWithFallbacks(buildRequest, hints, signal, transport, onUnsupportedParamDropped);
        } catch (error) {
          if (signal?.aborted) return { retried: false };
          ctrl.enqueue({
            type: 'error',
            error: redactRelayCredentials(
              error instanceof Error ? error.message : 'Network error',
              sensitiveCredentialValues,
            ),
            errorKind: 'network',
            source: 'network',
          });
          return { retried: false };
        }

        if (!response.ok) {
          const detail = await response.text().catch(() => '');
          const providerError = toProviderError(
            response.status,
            detail,
            response.headers.get(RELAY_UPSTREAM_URL_HEADER) ?? response.url,
            RELAY_ERROR_CONTEXT,
            sensitiveCredentialValues,
          );
          ctrl.enqueue({
            type: 'error',
            error: providerError.message,
            errorDetail: providerError.detail,
            errorKind: providerError.kind,
            source: responseErrorSource(response) ?? providerError.source,
            status: providerError.status,
            upstreamURL: providerError.upstreamURL,
          });
          return { retried: false };
        }

        const inner = createSSEStream(response, parseChunk, {
          signal,
          errorSource: responseErrorSource(response) ?? 'provider',
          sensitiveCredentialValues,
          relayErrorContext: RELAY_ERROR_CONTEXT,
        });
        const reader = inner.getReader();
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            ctrl.enqueue(redactRelayStreamEvent(value, sensitiveCredentialValues));
          }
        } finally {
          try { reader.releaseLock(); } catch { /* noop */ }
        }
        return { retried: false };
      };

      const first = await attempt(undefined);
      void first;
      ctrl.close();
    },
  });
}

function redactRelayStreamEvent(
  event: StreamEvent,
  sensitiveCredentialValues: readonly string[],
): StreamEvent {
  if (event.type !== 'error' || sensitiveCredentialValues.length === 0) return event;
  return {
    ...event,
    error: redactRelayCredentials(event.error, sensitiveCredentialValues),
    ...(event.errorDetail
      ? { errorDetail: redactRelayCredentials(event.errorDetail, sensitiveCredentialValues) }
      : {}),
  };
}

function responseErrorSource(response: Response): 'provider' | 'network' | 'oriveo' | 'desktop' | 'unknown' | undefined {
  const value = response.headers.get(ERROR_SOURCE_HEADER);
  return value === 'provider'
    || value === 'network'
    || value === 'oriveo'
    || value === 'desktop'
    || value === 'unknown'
    ? value
    : undefined;
}

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
 *   - fetchRelayWithFallbacks: the name is kept, but only one request is sent (the re-send at a lower tier after a rejected reasoning tier lives in the Web send side's rejection loop)
 *   - createRelaySSEStream / createRelayJSONStream: streaming and non-streaming wrappers (they take a request callback that already carries the transport)
 *   - createRelayResponsesStreamWithRetry: the name is kept, and rejections are rethrown unchanged
 */

import { sanitizeUpstreamErrorText } from './upstream-error-text';
import type { StreamEvent } from './types';
import { createSSEStream } from './sse-parser';
import { isRelayGenerationSuccessResponse } from './relay-generation-response';
import { toProviderError } from './errors';
import { classifyRelayKeyAccess, type RelayKeyAccessOutcome } from './relay-key-access';
import { relayErrorBodyNamesReasoning } from './relay-reasoning-rejection';
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
  removeTools?: boolean;
}

export interface RelayResponsesRetryDetector {
  triggered: boolean;
}

/**
 * The same sentence as the 1-token probe: the error body for a 2xx that is actually a web page. The English source sentence matches iOS,
 * and apps/app `error-i18n.ts` looks up `errors.relay.webPageReturned`.
 */
export const RELAY_HTML_PAGE_ERROR = 'This connection returned a web page instead of a model response. Check the request URL and the protocol set for this model.';

/**
 * A 2xx whose response headers declare a web page (a gateway's SPA fallback page): this path is not an API route. Before reading the stream, close it out as a
 * pre-output error event marked `relayHTMLPage`, and the send side switches protocol on it as a route-level rejection. Detection reuses the probe's success-shape check.
 */
function relayHTMLPageErrorEvent(response: Response): StreamEvent | null {
  if (!response.ok || isRelayGenerationSuccessResponse('', response.headers.get('Content-Type'))) return null;
  return htmlPageEvent(response);
}

function htmlPageEvent(response: Response): StreamEvent {
  return {
    type: 'error',
    error: RELAY_HTML_PAGE_ERROR,
    errorKind: 'upstream',
    source: responseErrorSource(response) ?? 'provider',
    status: response.status,
    upstreamURL: response.headers.get(RELAY_UPSTREAM_URL_HEADER) ?? response.url,
    relayHTMLPage: true,
    // The web-page sentence is also relay guidance: the chat failure card takes the same localized branch.
    relayGuidance: true,
  };
}

/** The longest prefix the check needs (`<!doctype html`); if the first non-whitespace character is not `<`, it answers no immediately. */
const HTML_SNIFF_CHARS = 16;

/**
 * A streaming 200 that declares `text/event-stream` but whose body is a web page: before any output, decide on the first non-empty line;
 * if it is a web page, report the web-page sentence (also marked `relayHTMLPage`, which feeds the route-level rejection check); otherwise splice the bytes already read back unchanged and hand them to the SSE parser.
 */
async function sniffRelayStreamHTMLPage(response: Response): Promise<{ htmlPage: StreamEvent | null; response: Response }> {
  if (!response.ok || !response.body) return { htmlPage: null, response };
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const buffered: Uint8Array[] = [];
  let text = '';
  let done = false;
  let readError: unknown;
  let failed = false;
  while (true) {
    const lead = text.replace(/^\uFEFF/, '').trimStart();
    if (lead && (lead[0] !== '<' || lead.length >= HTML_SNIFF_CHARS || /[\r\n]/.test(lead))) break;
    let chunk: ReadableStreamReadResult<Uint8Array>;
    try {
      chunk = await reader.read();
    } catch (error) {
      // A cancel / broken stream goes back to the SSE parser to wrap up with its original semantics; here we only splice the error back unchanged.
      readError = error;
      failed = true;
      break;
    }
    if (chunk.done) { done = true; break; }
    buffered.push(chunk.value);
    text += decoder.decode(chunk.value, { stream: true });
  }
  if (!failed && !isRelayGenerationSuccessResponse(text.split(/\r?\n/).find((line) => line.trim()) ?? '')) {
    void reader.cancel().catch(() => undefined);
    return { htmlPage: htmlPageEvent(response), response };
  }
  const replay = new ReadableStream<Uint8Array>({
    start(ctrl) {
      for (const chunk of buffered) ctrl.enqueue(chunk);
      if (failed) ctrl.error(readError);
      else if (done) ctrl.close();
    },
    async pull(ctrl) {
      const chunk = await reader.read();
      if (chunk.done) ctrl.close();
      else ctrl.enqueue(chunk.value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
  const rebuilt = new Response(replay, { status: response.status, statusText: response.statusText, headers: response.headers });
  // The Response constructor does not take a url; the downstream SSE parser still needs it when X-Relay-Upstream-URL is absent.
  Object.defineProperty(rebuilt, 'url', { value: response.url });
  return { htmlPage: null, response: rebuilt };
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

      const htmlPage = relayHTMLPageErrorEvent(response);
      if (htmlPage) {
        ctrl.enqueue(htmlPage);
        ctrl.close();
        return;
      }
      const sniffed = await sniffRelayStreamHTMLPage(response);
      if (sniffed.htmlPage) {
        ctrl.enqueue(sniffed.htmlPage);
        ctrl.close();
        return;
      }
      response = sniffed.response;

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
          ...relayKeyAccessField(response.status, detail),
          ...(relayErrorBodyNamesReasoning(detail) ? { relayReasoningNamed: true as const } : {}),
          ...(providerError.relayGuidance ? { relayGuidance: true as const } : {}),
        });
        ctrl.close();
        return;
      }

      const htmlPage = relayHTMLPageErrorEvent(response);
      if (htmlPage) {
        ctrl.enqueue(htmlPage);
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
            ...relayKeyAccessField(response.status, detail),
            ...(relayErrorBodyNamesReasoning(detail) ? { relayReasoningNamed: true as const } : {}),
            ...(providerError.relayGuidance ? { relayGuidance: true as const } : {}),
          });
          return { retried: false };
        }

        const htmlPage = relayHTMLPageErrorEvent(response);
        if (htmlPage) {
          ctrl.enqueue(htmlPage);
          return { retried: false };
        }
        const sniffed = await sniffRelayStreamHTMLPage(response);
        if (sniffed.htmlPage) {
          ctrl.enqueue(sniffed.htmlPage);
          return { retried: false };
        }
        response = sniffed.response;

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

/** Key verdict for a non-2xx before any output: computed from the raw response body, and the event carries only the conclusion; none is omitted. */
function relayKeyAccessField(status: number, body: string): { relayKeyAccess?: Exclude<RelayKeyAccessOutcome, 'none'> } {
  const outcome = classifyRelayKeyAccess(status, body);
  return outcome === 'none' ? {} : { relayKeyAccess: outcome };
}

function redactRelayStreamEvent(
  event: StreamEvent,
  sensitiveCredentialValues: readonly string[],
): StreamEvent {
  if (event.type !== 'error') return event;
  // An in-stream error frame is the upstream's raw text: scrub credentials first, then truncate to 2 KB (same pure function as the official route).
  if (event.streamErrorFrame) {
    return { ...event, error: sanitizeUpstreamErrorText(redactRelayCredentials(event.error, sensitiveCredentialValues)) };
  }
  if (sensitiveCredentialValues.length === 0) return event;
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

/**
 * Generic SSE stream parser
 *
 * Parses the ReadableStream of a fetch Response into structured StreamEvent values, removing ~200
 * lines of duplicated scaffolding across the anthropic/openai/gemini/openrouter providers.
 *
 * Per-provider differences in event format stay in the parseChunk callback.
 *
 * The fetch behind `createSSEFetchStream` is injected through TransportPort: core does not bundle a
 * global fetch, because the transport implementation puts an SSRF guard in front that must not be
 * bypassable. `createSSEStream` takes an abstract `TransportResponse` (structurally compatible with a
 * DOM Response, which web passes straight through).
 */

import type { TransportPort, TransportResponse } from '../ports';
import { toProviderError } from './errors';
import type { ProviderErrorSource } from './errors';
import type { RelayErrorContext } from './relay-error-classifier';
import type { StreamEvent } from './types';

/**
 * Event parsing callback implemented by each provider
 *
 * @param eventType SSE event type (Anthropic uses `event: xxx`, other providers pass null)
 * @param data the JSON string following `data: `
 * @returns a StreamEvent, an array of StreamEvent, or null to skip the event.
 *          Arrays are supported because one SSE chunk from providers such as Gemini can carry several events
 */
export type ParseChunkFn = (
  eventType: string | null,
  data: string,
) => StreamEvent | StreamEvent[] | null;

/**
 * Structured event produced by splitting SSE lines
 */
export interface SSEEntry {
  event: string | null;
  data: string;
}

/**
 * Splits raw SSE text into an array of structured events
 */
export function parseSSELines(raw: string): SSEEntry[] {
  const entries: SSEEntry[] = [];
  const lines = raw.split('\n');
  let currentEvent: string | null = null;

  for (const line of lines) {
    const trimmed = line.trim();

    // A blank line resets the current event type
    if (!trimmed) {
      currentEvent = null;
      continue;
    }

    // SSE comment (starts with :)
    if (trimmed.startsWith(':')) continue;

    // event: xxx
    if (trimmed.startsWith('event: ')) {
      currentEvent = trimmed.slice(7);
      continue;
    }

    // data: xxx
    if (trimmed.startsWith('data: ')) {
      entries.push({ event: currentEvent, data: trimmed.slice(6) });
    }
  }

  return entries;
}

export interface CreateSSEStreamOptions {
  /** End-of-stream token, "[DONE]" by default */
  doneToken?: string;
  /** AbortController signal used to cancel the stream */
  signal?: AbortSignal;
  upstreamURL?: string;
  relayErrorContext?: RelayErrorContext;
  /** Plaintext credential actually sent upstream, used only to redact it before an error is shown. */
  sensitiveCredentialValues?: readonly string[];
  /** A reverse proxy route can override the responsibility boundary through response headers; direct upstreams default to provider. */
  errorSource?: ProviderErrorSource;
  /**
   * This request used Grok subscription (OAuth) credentials.
   *
   * The same 401/403 means something entirely different on the subscription path than with a BYOK key:
   * without this flag, "your xAI subscription tier does not allow third-party apps" is classified as
   * "your API key is invalid".
   */
  grokSubscriptionAuth?: boolean;
  /**
   * This request used Codex (ChatGPT subscription login) credentials.
   *
   * Without this flag, "your ChatGPT tier does not allow Codex in third-party apps" is classified as
   * "your API key is invalid", pointing the user at something they can never fix.
   */
  openAISubscriptionAuth?: boolean;
}

/**
 * Creates an SSE ReadableStream that parses a fetch Response body into StreamEvent values
 *
 * @param response TransportResponse (structurally compatible with a DOM Response; it may be non-ok, errors are handled)
 * @param parseChunk Event parsing function implemented by each provider
 * @param options Optional configuration
 */
export function createSSEStream(
  response: TransportResponse,
  parseChunk: ParseChunkFn,
  options?: CreateSSEStreamOptions,
): ReadableStream<StreamEvent> {
  const doneToken = options?.doneToken ?? '[DONE]';
  const signal = options?.signal;

  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      // Handle non-ok responses
      if (!response.ok) {
        const text = await response.text().catch(() => '');
        const pe = toProviderError(
          response.status,
          text,
          options?.upstreamURL ?? response.headers.get('X-Relay-Upstream-URL') ?? response.url,
          options?.relayErrorContext,
          options?.sensitiveCredentialValues,
          options?.grokSubscriptionAuth
            ? { grokSubscriptionAuth: true }
            : options?.openAISubscriptionAuth
              ? { openAISubscriptionAuth: true }
              : undefined,
        );
        ctrl.enqueue({
          type: 'error',
          error: pe.message,
          errorDetail: pe.detail,
          errorKind: pe.kind,
          source: options?.errorSource ?? pe.source,
          retryable: pe.retryable,
          status: pe.status,
          upstreamURL: pe.upstreamURL,
          quotaSource: pe.quotaSource,
          nextAction: pe.nextAction,
          severity: pe.severity,
        });
        ctrl.close();
        return;
      }

      if (!response.body) {
        ctrl.enqueue({
          type: 'error',
          error: 'No response body',
          errorKind: 'emptyResponse',
          source: options?.errorSource ?? 'provider',
          status: response.status,
          upstreamURL: options?.upstreamURL ?? response.url,
        });
        ctrl.close();
        return;
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let hasError = false;
      let currentEvent: string | null = null;
      // A non-SyntaxError thrown by parseChunk (a real parsing bug) and a connection reset from
      // reader.read() both bubble to the outer catch. This flag separates them: real bugs are reported
      // as upstream (user visible), transport resets are downgraded to network noise.
      let parseChunkFailed = false;

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() ?? '';
          for (const line of lines) {
            const trimmed = line.trim();

            if (!trimmed) {
              currentEvent = null;
              continue;
            }

            // SSE comment
            if (trimmed.startsWith(':')) continue;

            // event: xxx (Anthropic format)
            if (trimmed.startsWith('event: ')) {
              currentEvent = trimmed.slice(7);
              continue;
            }

            if (!trimmed.startsWith('data: ')) continue;
            const payload = trimmed.slice(6);

            // End-of-stream token
            if (payload === doneToken) {
              ctrl.enqueue({ type: 'done' });
              ctrl.close();
              return;
            }

            // Hand off to the provider-specific parser.
            // Only JSON parse failures (illegal bytes from upstream) are swallowed here. A catch-all
            // would drop the whole chunk, delta text included, whenever parseChunk threw (failed type
            // assertion, NPE on a missing field), leaving the user with an empty response and no clue.
            try {
              const result = parseChunk(currentEvent, payload);
              if (result) {
                if (Array.isArray(result)) {
                  for (const event of result) ctrl.enqueue(event);
                } else {
                  ctrl.enqueue(result);
                }
              }
            } catch (err) {
              // SyntaxError = JSON.parse failed (illegal bytes from upstream), so skip this chunk;
              // anything else = a real parseChunk bug, flagged and surfaced as an outer error event (reported as upstream).
              if (!(err instanceof SyntaxError)) { parseChunkFailed = true; throw err; }
            }
          }
        }
        // Handle the last partial line left in the buffer once the stream ends
        const residual = buffer.trim();
        if (residual && residual.startsWith('data: ')) {
          const payload = residual.slice(6);
          if (payload && payload !== doneToken) {
            try {
              const result = parseChunk(currentEvent, payload);
              if (result) {
                if (Array.isArray(result)) {
                  for (const event of result) ctrl.enqueue(event);
                } else {
                  ctrl.enqueue(result);
                }
              }
            } catch (err) {
              if (!(err instanceof SyntaxError)) { parseChunkFailed = true; throw err; }
            }
          }
        }
      } catch (err) {
        if (!signal?.aborted) {
          // Both error classes land here and are split by origin:
          //  - non-SyntaxError thrown by parseChunk (NPE on a missing field, failed type assertion and
          //    other real parsing bugs) -> upstream: reaches Sentry and shows "Provider Error"; it must
          //    not be swallowed as network noise.
          //  - thrown by reader.read() (connection reset: app backgrounded, network lost, relay drop)
          //    -> network transport failure, downgraded by shouldReportProviderError per kind so the
          //    user sees the more accurate network failure copy.
          ctrl.enqueue({
            type: 'error',
            error: err instanceof Error ? err.message : 'Stream error',
            errorKind: parseChunkFailed ? 'upstream' : 'network',
            source: parseChunkFailed ? 'unknown' : 'network',
          });
        }
        hasError = true;
      }

      // Stream ended normally without a doneToken (as with Gemini).
      // No done event is appended after an error, matching the underlying provider behavior.
      if (!hasError && !signal?.aborted) {
        ctrl.enqueue({ type: 'done' });
      }
      ctrl.close();
    },
  });
}

export interface SSEFetchDeps extends CreateSSEStreamOptions {
  /** Transport that actually performs HTTP (web injects a window.fetch adapter, the desktop main process injects undici plus SSRF guards). */
  transport: TransportPort;
  signal?: AbortSignal;
}

/**
 * Full flow for an SSE streaming request (transport.fetch plus parsing)
 *
 * Providers only supply URL, headers, body and parseChunk; the caller injects the transport, since
 * core must not bundle a global fetch (an SSRF architecture requirement).
 */
export function createSSEFetchStream(
  url: string,
  init: {
    headers: Record<string, string>;
    body: string;
  },
  parseChunk: ParseChunkFn,
  deps: SSEFetchDeps,
): ReadableStream<StreamEvent> {
  const { transport, signal } = deps;

  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      let res: TransportResponse;
      try {
        res = await transport.fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...init.headers },
          body: init.body,
          ...(signal ? { signal } : {}),
        });
      } catch (err) {
        if (signal?.aborted) { ctrl.close(); return; }
        ctrl.enqueue({
          type: 'error',
          error: err instanceof Error ? err.message : 'Network error',
          errorKind: 'network',
          source: 'network',
        });
        ctrl.close();
        return;
      }

      // Reuse createSSEStream to handle the response
      const inner = createSSEStream(res, parseChunk, deps);
      const reader = inner.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          ctrl.enqueue(value);
        }
      } catch {
        // The inner stream already handled the error
      }
      ctrl.close();
    },
  });
}

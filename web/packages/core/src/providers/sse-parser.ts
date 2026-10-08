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
import { isSubscriptionErrorKind, toProviderError } from './errors';
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

/** One dispatched SSE event. */
export interface SSEFrame {
  /** Event name; null when the event carried no `event` field, or an empty one. */
  event: string | null;
  /** The data lines joined with LF, never trimmed. */
  data: string;
  /** The data lines before joining, so a caller can fall back to one message per line. */
  dataLines: string[];
  /** Parallel to dataLines: the event name in effect when that data line arrived. */
  dataLineEvents: Array<string | null>;
  /** The last id seen up to this event; null before the first. */
  id: string | null;
  /** The retry value of this event in milliseconds; null when it carried none. */
  retry: number | null;
}

const LINE_END = /[\r\n]/g;
const DIGITS_ONLY = /^[0-9]+$/;

/**
 * SSE framing decoder following the WHATWG EventSource parsing algorithm:
 *   - a line ends with CRLF, a lone LF or a lone CR; a CRLF cut across two chunks is still one line end
 *   - a byte order mark at the start of the stream is dropped once, later ones are data
 *   - a line that starts with a colon is a comment; the first colon separates field name and value,
 *     and only the single space right after it is removed from the value (no trimming)
 *   - the data lines of one event are joined with LF; a blank line dispatches the event, and an event
 *     without a data line is not dispatched
 *
 * One deliberate difference from the specification, because upstreams routinely close the connection
 * right after `data: [DONE]`: when the stream ends without a line end or without the final blank
 * line, {@link finish} still counts the last line and dispatches the pending event, where the
 * specification discards both.
 *
 * The end sentinel (`[DONE]`) is an ordinary event at this level; the protocol above gives it meaning.
 */
export class SSEFrameDecoder {
  /** Number of comment lines seen so far. */
  comments = 0;

  private readonly textDecoder = new TextDecoder();
  private buffer = '';
  /** The previous chunk ended with CR: a leading LF in the next one belongs to the same line end. */
  private skipLeadingLF = false;
  private atStreamStart = true;
  private dataLines: string[] = [];
  private dataLineEvents: Array<string | null> = [];
  private eventName = '';
  private lastId: string | null = null;
  private retry: number | null = null;

  /** Feeds a chunk of bytes (a multi-byte character may be cut between chunks) and returns the events it completes. */
  push(chunk: Uint8Array): SSEFrame[] {
    // TextDecoder drops a leading byte order mark once by default, so the byte path needs no handling of its own.
    this.atStreamStart = false;
    return this.consume(this.textDecoder.decode(chunk, { stream: true }));
  }

  /** Feeds already decoded text. */
  pushText(text: string): SSEFrame[] {
    if (this.atStreamStart && text.length > 0) {
      this.atStreamStart = false;
      if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    }
    return this.consume(text);
  }

  /** End of stream: the last line counts even without a line end, and a pending event is dispatched. */
  finish(): SSEFrame[] {
    const frames = this.consume(this.textDecoder.decode());
    if (this.buffer.length > 0) {
      const line = this.buffer;
      this.buffer = '';
      this.processLine(line, frames);
    }
    this.dispatch(frames);
    return frames;
  }

  private consume(text: string): SSEFrame[] {
    const frames: SSEFrame[] = [];
    if (text.length === 0) return frames;
    if (this.skipLeadingLF) {
      this.skipLeadingLF = false;
      if (text.charCodeAt(0) === 0x0a) text = text.slice(1);
    }
    this.buffer += text;

    let start = 0;
    while (true) {
      LINE_END.lastIndex = start;
      const match = LINE_END.exec(this.buffer);
      if (!match) break;
      const end = match.index;
      const line = this.buffer.slice(start, end);
      start = end + 1;
      if (this.buffer.charCodeAt(end) === 0x0d) {
        if (start < this.buffer.length) {
          if (this.buffer.charCodeAt(start) === 0x0a) start += 1;
        } else {
          this.skipLeadingLF = true;
        }
      }
      this.processLine(line, frames);
    }
    this.buffer = this.buffer.slice(start);
    return frames;
  }

  private processLine(line: string, frames: SSEFrame[]): void {
    if (line.length === 0) {
      this.dispatch(frames);
      return;
    }
    const colon = line.indexOf(':');
    if (colon === 0) {
      this.comments += 1;
      return;
    }
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? '' : line.slice(colon + 1);
    if (value.charCodeAt(0) === 0x20) value = value.slice(1);

    switch (field) {
      case 'data':
        this.dataLines.push(value);
        this.dataLineEvents.push(this.eventName.length > 0 ? this.eventName : null);
        break;
      case 'event':
        this.eventName = value;
        break;
      case 'id':
        if (!value.includes('\u0000')) this.lastId = value;
        break;
      case 'retry':
        if (DIGITS_ONLY.test(value)) this.retry = Number(value);
        break;
      default:
        break;
    }
  }

  private dispatch(frames: SSEFrame[]): void {
    const dataLines = this.dataLines;
    const dataLineEvents = this.dataLineEvents;
    const event = this.eventName;
    const retry = this.retry;
    this.dataLines = [];
    this.dataLineEvents = [];
    this.eventName = '';
    this.retry = null;
    if (dataLines.length === 0) return;
    frames.push({
      event: event.length > 0 ? event : null,
      data: dataLines.join('\n'),
      dataLines,
      dataLineEvents,
      id: this.lastId,
      retry,
    });
  }
}

/**
 * Splits raw SSE text into an array of structured events
 */
export function parseSSELines(raw: string): SSEEntry[] {
  const decoder = new SSEFrameDecoder();
  return [...decoder.pushText(raw), ...decoder.finish()].map(({ event, data }) => ({ event, data }));
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
          // The classifier decides the source of a subscription failure (see toProviderError).
          // The proxy route only knows that the upstream answered non-2xx and says `provider`,
          // which must not override it.
          source: isSubscriptionErrorKind(pe.kind) ? pe.source : options?.errorSource ?? pe.source,
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
      const decoder = new SSEFrameDecoder();
      let hasError = false;
      // A non-SyntaxError thrown by parseChunk (a real parsing bug) and a connection reset from
      // reader.read() both bubble to the outer catch. This flag separates them: real bugs are reported
      // as upstream (user visible), transport resets are downgraded to network noise.
      let parseChunkFailed = false;

      // Hand off to the provider-specific parser; false means the payload was not valid JSON.
      // Only JSON parse failures (illegal bytes from upstream) are swallowed here. A catch-all
      // would drop the whole chunk, delta text included, whenever parseChunk threw (failed type
      // assertion, NPE on a missing field), leaving the user with an empty response and no clue.
      const deliver = (event: string | null, payload: string): boolean => {
        try {
          const result = parseChunk(event, payload);
          if (result) {
            if (Array.isArray(result)) {
              for (const streamEvent of result) ctrl.enqueue(streamEvent);
            } else {
              ctrl.enqueue(result);
            }
          }
          return true;
        } catch (err) {
          // SyntaxError = JSON.parse failed (illegal bytes from upstream), so skip this chunk;
          // anything else = a real parseChunk bug, flagged and surfaced as an outer error event (reported as upstream).
          if (!(err instanceof SyntaxError)) { parseChunkFailed = true; throw err; }
          return false;
        }
      };

      /** Handles one event; true means the end-of-stream token was seen. */
      const handleFrame = (frame: SSEFrame): boolean => {
        if (frame.data === doneToken) return true;
        if (deliver(frame.event, frame.data) || frame.dataLines.length < 2) return false;
        // Some upstreams separate several JSON messages with a single line break and no blank line
        // between events, so the data joined per the specification is not valid JSON. Deliver each
        // line on its own, with the event name that was in effect when it arrived, so that "every
        // data line is a message" keeps working and the text of such a stream is not lost.
        for (let index = 0; index < frame.dataLines.length; index += 1) {
          const line = frame.dataLines[index]!;
          if (line === doneToken) return true;
          deliver(frame.dataLineEvents[index] ?? null, line);
        }
        return false;
      };

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          for (const frame of decoder.push(value)) {
            if (handleFrame(frame)) {
              ctrl.enqueue({ type: 'done' });
              ctrl.close();
              return;
            }
          }
        }
        // Handle the last line and the pending event once the stream ends. Seeing the end token here
        // is the same as the stream ending, so the done event comes from the common tail below.
        for (const frame of decoder.finish()) {
          if (handleFrame(frame)) break;
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

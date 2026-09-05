/**
 * The SSE parser lives in @oriveo/core, so the web and desktop builds import the same one.
 *
 * `parseSSELines` and `createSSEStream` are re-exported directly. `createSSEFetchStream` requires a
 * TransportPort to be injected in core, since core carries no global fetch by design; this module
 * supplies the web adapter, a TransportPort backed by window.fetch, so existing web callers keep
 * their signatures.
 */
import {
  createSSEFetchStream as coreCreateSSEFetchStream,
  createSSEStream,
  parseSSELines,
  type CreateSSEStreamOptions,
  type ParseChunkFn,
  type SSEEntry,
} from '@oriveo/core/providers/sse-parser';
import type { TransportPort } from '@oriveo/core';
import type { StreamEvent } from '@oriveo/core/providers/types';

export { createSSEStream, parseSSELines };
export type { CreateSSEStreamOptions, ParseChunkFn, SSEEntry };

/** Web transport: window.fetch directly, in the renderer context. */
const webTransport: TransportPort = {
  fetch: (url, init) =>
    fetch(url, {
      method: init.method,
      headers: init.headers,
      body: init.body,
      signal: init.signal,
    }),
};

export function createSSEFetchStream(
  url: string,
  init: {
    headers: Record<string, string>;
    body: string;
  },
  parseChunk: ParseChunkFn,
  options?: CreateSSEStreamOptions & { signal?: AbortSignal },
): ReadableStream<StreamEvent> {
  return coreCreateSSEFetchStream(url, init, parseChunk, { ...options, transport: webTransport });
}

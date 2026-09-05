/**
 * Shared helpers for the request builders.
 * The upstream fetch in executeProviderRequest goes through an injected UpstreamTransport
 * (web injects window.fetch, the desktop main process injects undici plus SSRF checks), so
 * core is not coupled to a global fetch. The 120s timeout and the clientSignal bridge stay
 * here as pure logic.
 */

import type { ReasoningMode } from '@oriveo/shared/pure-types';
import type { UpstreamTransport } from '../../ports';
import type { ProviderRequest } from './types';

export function buildRelayReasoningParams(
  reasoningMode: ReasoningMode | undefined,
): Record<string, unknown> | null {
  if (!reasoningMode || reasoningMode === 'automatic') return null;

  // Relay is an explicit exception and heuristics are allowed: a user-defined endpoint has no official profile to rely on.
  return {
    reasoning_effort:
      reasoningMode === 'fast'
        ? 'low'
        : reasoningMode === 'balanced'
          ? 'medium'
          : 'high',
  };
}

// Total timeout for connecting upstream and receiving the first packet, so a slow upstream
// cannot hang forever after connecting and hold the function open.
// The value follows the first-packet protection window used for relay/forward (30s), relaxed
// to 120s because the first chat packet can be slow with a long context.
// Note that this covers everything before the response headers arrive; after that the stream
// passes through and is bounded by the upstream or client disconnecting instead.
const UPSTREAM_REQUEST_TIMEOUT_MS = 120_000;

/**
 * Send a request to the upstream provider through the injected transport.
 * - honours the clientSignal passed in by the route or main process, so a client disconnect
 *   or cancellation aborts the upstream and releases the connection promptly
 * - adds a 120s timeout as protection against a slow upstream connect; either one aborts
 *
 * AbortSignal.any/timeout are not used because the jsdom test environment implements
 * neither static method; bridging by hand keeps both sides consistent.
 */
export async function executeProviderRequest(
  req: ProviderRequest,
  transport: UpstreamTransport,
  clientSignal?: AbortSignal,
  options: { timeoutMs?: number } = {},
): Promise<Response> {
  const controller = new AbortController();
  const timeoutMs =
    typeof options.timeoutMs === 'number' && Number.isFinite(options.timeoutMs) && options.timeoutMs > 0
      ? options.timeoutMs
      : UPSTREAM_REQUEST_TIMEOUT_MS;
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  const onClientAbort = () => controller.abort();
  if (clientSignal) {
    if (clientSignal.aborted) {
      controller.abort();
    } else {
      clientSignal.addEventListener('abort', onClientAbort, { once: true });
    }
  }

  try {
    return await transport.fetch(req.url, {
      method: 'POST',
      headers: req.headers,
      body: JSON.stringify(req.body),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
    clientSignal?.removeEventListener('abort', onClientAbort);
  }
}

export function describeProviderRequestError(error: unknown): string {
  if (!(error instanceof Error)) {
    return 'Failed to connect to provider';
  }

  const cause = error.cause;
  const causeMessage =
    cause &&
    typeof cause === 'object' &&
    'message' in cause &&
    typeof cause.message === 'string'
      ? cause.message
      : null;

  if (causeMessage && causeMessage !== error.message) {
    return `${error.message}: ${causeMessage}`;
  }

  return error.message || 'Failed to connect to provider';
}

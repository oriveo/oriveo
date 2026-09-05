/**
 * Relay (custom endpoint pass-through) web adapter: a thin wrapper.
 *
 * The send* orchestration, the pure computation and the fetch chain all live in @oriveo/core, so
 * only the web-specific injection is left here:
 * - webRelayTransport: the global fetch, resolved at call time so tests can vi.stubGlobal('fetch')
 * - buildRelayFetchArgs: a direct connection under Node (SSR and tests); in the browser traffic is
 *   split by target address, with public addresses going through the /api/relay/forward proxy
 *   because relay endpoints send no CORS headers, and private or LAN addresses connecting directly
 *   since a server cannot reach the user's intranet. The browser branch drops the forbidden
 *   User-Agent header, and the transport explicitly refuses to carry Oriveo cookies.
 * sendMessageStream keeps its signature and simply calls core sendRelayStream with relayDeps injected.
 */
import type { ContentPart, StreamHandle, StreamOptions } from '../types';
import { getRelayRuntimeConfig } from '../../metadata/metadata-client';
import { reportUnsupportedParamDropped } from '../unsupported-param-telemetry';
import type { UpstreamTransport } from '@oriveo/core';
import {
  applyDirectCustomHeaders,
  applyDirectQueryParams,
  type RelayDirectFetchConfig,
} from '@oriveo/core/providers/relay-adapter';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import { buildBrowserRelayFetchArgs, fetchBrowserRelayDirect } from '../relay-browser-direct';

/** Web upstream transport: the global fetch, resolved at call time so tests can vi.stubGlobal('fetch'). */
const webRelayTransport: UpstreamTransport = {
  fetch: (url, init) => typeof window === 'undefined'
    ? fetch(url, init)
    : fetchBrowserRelayDirect(url, init),
};

/**
 * The browser splits traffic by target address (see shouldProxyRelayViaServer): public addresses go
 * through the server-side proxy to work around CORS, while private and LAN addresses connect
 * directly and follow the browser's TLS and Local Network Access policies.
 * Node (SSR and tests) always connects directly; the direct-connection arguments are computed in
 * the core relay adapter, with randomUUID injected.
 */
function buildRelayFetchArgs(
  upstreamURL: string,
  directHeaders: Record<string, string>,
  config: RelayDirectFetchConfig,
): { url: string; headers: Record<string, string> } {
  if (typeof window === 'undefined') {
    return {
      url: applyDirectQueryParams(upstreamURL, config),
      headers: applyDirectCustomHeaders(directHeaders, config, () => crypto.randomUUID()),
    };
  }
  return buildBrowserRelayFetchArgs(upstreamURL, directHeaders, config);
}

const relayDeps: RelayOrchestratorDeps = {
  transport: webRelayTransport,
  buildFetchArgs: buildRelayFetchArgs,
  getRelayRuntimeConfig,
  onUnsupportedParamDropped: reportUnsupportedParamDropped,
};

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
  baseURL?: string,
  options?: StreamOptions,
): StreamHandle {
  return sendRelayStream(apiKey, modelID, messages, baseURL, options, relayDeps);
}

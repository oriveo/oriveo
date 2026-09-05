import type { RelayRequestedConfig } from '@oriveo/shared/pure-types';
import { requireSecureRelayEndpoint, type RelayConnectionSecurityMode } from '@oriveo/shared/relay/endpoint-policy';

/**
 * Relay endpoint URL construction, pure computation with no IO and no window access.
 * Fills in the version segment for the 4 transports (/v1, /v1beta) and maps the endpoint paths.
 */

export type RelayEndpointTransport = Exclude<RelayRequestedConfig['transport'], 'auto'>;

type RelayEndpoint =
  | 'chatCompletions'
  | 'models'
  | 'responses'
  | 'messages'
  | 'imagesGenerations'
  | 'llamaCompletion'
  | 'geminiGenerateContent'
  | 'geminiStreamGenerateContent';

const VERSION_SEGMENT_RE = /^v\d+(?:alpha|beta)?$/i;

export function normalizeRelayBaseURL(
  baseURL: string | undefined,
  transport: RelayEndpointTransport,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string {
  const url = new URL(requireSecureRelayEndpoint(baseURL, securityMode));
  url.hash = '';
  url.search = '';
  url.pathname = normalizeVersionPath(url.pathname, versionForTransport(transport));
  return url.toString().replace(/\/+$/, '');
}

export function buildRelayEndpointURL(input: {
  baseURL: string | undefined;
  transport: RelayEndpointTransport;
  endpoint: RelayEndpoint;
  modelID?: string;
  /** Discovery already resolved the exact API root; do not append a version segment. */
  exactBaseURL?: boolean;
  /** Same security mode as the initial Relay endpoint validation; never silently upgrade a local HTTP endpoint to HTTPS-only here. */
  securityMode?: RelayConnectionSecurityMode;
}): string {
  const base = input.exactBaseURL
    ? normalizeExactRelayBaseURL(input.baseURL, input.securityMode)
    : normalizeRelayBaseURL(input.baseURL, input.transport, input.securityMode);
  const path = endpointPath(input.endpoint, input.modelID);
  return `${base}/${path}`;
}

function normalizeExactRelayBaseURL(
  baseURL: string | undefined,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string {
  const url = new URL(requireSecureRelayEndpoint(baseURL, securityMode));
  url.hash = '';
  url.search = '';
  return url.toString().replace(/\/+$/, '');
}

function versionForTransport(transport: RelayEndpointTransport): string {
  if (transport === 'llamacpp_native') return '';
  return transport === 'gemini_generate_content' ? 'v1beta' : 'v1';
}

function normalizeVersionPath(pathname: string, version: string): string {
  if (!version) return pathname || '/';
  const segments = pathname.split('/').filter(Boolean);
  if (segments.some((segment) => VERSION_SEGMENT_RE.test(segment))) {
    return `/${segments.join('/')}`;
  }
  return `/${[...segments, version].join('/')}`;
}

function endpointPath(endpoint: RelayEndpoint, modelID?: string): string {
  switch (endpoint) {
    case 'chatCompletions':
      return 'chat/completions';
    case 'models':
      return 'models';
    case 'responses':
      return 'responses';
    case 'messages':
      return 'messages';
    case 'imagesGenerations':
      return 'images/generations';
    case 'llamaCompletion':
      return 'completion';
    case 'geminiGenerateContent':
      return `models/${encodeURIComponent(modelID ?? '')}:generateContent`;
    case 'geminiStreamGenerateContent':
      return `models/${encodeURIComponent(modelID ?? '')}:streamGenerateContent?alt=sse`;
  }
}

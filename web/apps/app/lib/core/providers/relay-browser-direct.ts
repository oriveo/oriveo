import {
  applyDirectCustomHeaders,
  applyDirectQueryParams,
  type RelayDirectFetchConfig,
} from '@oriveo/core/providers/relay-adapter';
import { isForbiddenIPv4, isForbiddenIPv6 } from '@oriveo/core/providers/ssrf';
import { registerRelayRequestURL } from '../../sentry/redact-url';

const RELAY_FORWARD_PATH = '/api/relay/forward';
const RELAY_UPSTREAM_URL_HEADER = 'X-Relay-Upstream-URL';
const RELAY_UPSTREAM_METHOD_HEADER = 'X-Relay-Upstream-Method';
const RELAY_PROXY_CONFIG_HEADER = 'X-Relay-Proxy-Config';

/**
 * Port allowlist of the server-side SSRF guard (ALLOWED_PORTS in `api/_shared/ssrf-guard.ts`).
 * A port outside the list is guaranteed to be rejected by the proxy with a 403, so a direct
 * connection is the better option: if the upstream enables CORS it works, and at worst the
 * refusal does not come from here.
 */
const PROXYABLE_PORTS = new Set(['', '443', '80', '8080', '8443']);

/** LAN / mDNS suffixes: the server cannot reach a user's private network, so only the browser can connect. */
const PRIVATE_HOST_SUFFIXES = ['.local', '.internal', '.home.arpa', '.localhost'];

/**
 * Whether the browser should go through the server-side proxy or connect directly.
 *
 * - Public endpoint -> proxy: third-party relays rarely allow this site through CORS, so a direct
 *   browser connection fails preflight (`Failed to fetch`) and the proxy is the only option.
 * - Private or LAN endpoint -> direct: the server cannot reach the user's private network, so the
 *   proxy is bound to fail, and the server-side SSRF guard rejects those addresses with a 403
 *   anyway. A self-hosted relay can only be reached by connecting from the browser.
 *
 * The private-address decision reuses the same pure `isForbiddenIPv4/6` helpers as the server
 * guard, so the two boundaries cannot drift apart and leave the dead end of "classified as
 * public -> sent to the proxy -> rejected by SSRF with 403".
 */
export function shouldProxyRelayViaServer(upstreamURL: string): boolean {
  let url: URL;
  try {
    url = new URL(upstreamURL);
  } catch {
    return false;
  }

  if (!PROXYABLE_PORTS.has(url.port)) return false;

  const hostname = url.hostname.toLowerCase();

  // A WHATWG URL wraps an IPv6 hostname in brackets; strip them before the pure check.
  if (hostname.startsWith('[') && hostname.endsWith(']')) {
    return !isForbiddenIPv6(hostname.slice(1, -1));
  }
  if (/^\d+\.\d+\.\d+\.\d+$/.test(hostname)) {
    return !isForbiddenIPv4(hostname);
  }
  if (hostname === 'localhost') return false;
  if (PRIVATE_HOST_SUFFIXES.some((suffix) => hostname.endsWith(suffix))) return false;
  // A bare hostname with no dot (https://nas:8443, say) can only be a machine name on the local network.
  if (!hostname.includes('.')) return false;

  return true;
}

/**
 * Builds the fetch arguments for the target, split by shouldProxyRelayViaServer:
 * - public: rewritten to the local reverse proxy `/api/relay/forward`, with the real upstream
 *   address and auth configuration in custom headers, sent on by the Node runtime, which is not
 *   subject to CORS.
 * - private: connects to the user endpoint directly. The browser owns User-Agent, so that
 *   forbidden header is dropped while the other relay compatibility headers are kept.
 */
export function buildBrowserRelayFetchArgs(
  upstreamURL: string,
  directHeaders: Record<string, string>,
  config: RelayDirectFetchConfig,
): { url: string; headers: Record<string, string> } {
  const explicitlyLocal = config.securityMode === 'local_http' || config.securityMode === 'private_vpn';
  if (!explicitlyLocal && shouldProxyRelayViaServer(upstreamURL)) {
    return {
      url: RELAY_FORWARD_PATH,
      headers: {
        [RELAY_UPSTREAM_URL_HEADER]: upstreamURL,
        [RELAY_UPSTREAM_METHOD_HEADER]: config.method ?? 'POST',
        [RELAY_PROXY_CONFIG_HEADER]: JSON.stringify({
          transport: config.transport,
          authMode: config.authMode,
          apiKey: config.apiKey,
          codexCompatIdentity: config.codexCompatIdentity,
          customUserAgent: config.customUserAgent,
          headers: config.headers,
          queryParams: config.queryParams,
        }),
      },
    };
  }

  const headers = applyDirectCustomHeaders(directHeaders, config, () => crypto.randomUUID());
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === 'user-agent') delete headers[key];
  }
  return {
    url: applyDirectQueryParams(upstreamURL, config),
    headers,
  };
}

/** Explicitly omit first-party cookies and credentials even if the configured URL is same-origin. */
export function fetchBrowserRelayDirect(url: string, init: RequestInit): Promise<Response> {
  registerRelayRequestURL(url);
  return fetch(url, {
    ...init,
    credentials: 'omit',
    redirect: 'manual',
    referrerPolicy: 'no-referrer',
    ...( { targetAddressSpace: 'local' } as RequestInit ),
  });
}

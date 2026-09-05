/** Relay endpoint policy shared by forms and the final network boundary. */
export const RELAY_HTTPS_REQUIRED_MESSAGE =
  'Use an HTTPS endpoint. Local network and VPN addresses are supported when they use a valid TLS certificate.';

const SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//;

/** The single masking placeholder used across the UI; there is no reveal toggle. */
export const RELAY_REDACTED_PLACEHOLDER = '***hidden';

/**
 * The single list of sensitive names: redaction on send, the save-time interlock and the masking
 * applied when a failure card or diagnostics view shows an upstream payload all read this one list.
 * Copying it elsewhere is forbidden: a second copy drifts out of step and the two ends stop
 * agreeing on what counts as sensitive.
 */
export function isSensitiveRelayName(raw: string): boolean {
  const value = raw.toLowerCase();
  return value === 'x-api-key' || value === 'api-key' || value === 'x-goog-api-key'
    || value === 'key' || value === 'api_key' || value === 'apikey'
    // Account identity material: it must not go out over a cleartext connection either, and is always masked in the UI.
    || value === 'openai-organization'
    || value.includes('authorization') || value.includes('token')
    || value.includes('secret') || value.endsWith('key');
}

/**
 * Replace any occurrence of a credential in plain text. Upstreams, self-hosted gateways and relays
 * in particular, often echo the key they received straight back in an error body
 * (`Invalid API key: sk-...`), which turns failure cards, diagnostic history, screenshots and
 * support threads into a second leak surface. Anything the request actually carried must be
 * replaced; credential length is not evidence of safety, so short keys are redacted too.
 */
export function redactRelayCredentials(text: string, credentials: readonly string[]): string {
  let output = text;
  for (const raw of credentials) {
    const credential = raw.trim();
    if (!credential) continue;
    output = output.split(credential).join(RELAY_REDACTED_PLACEHOLDER);
  }
  return output;
}

export type RelayConnectionSecurityMode =
  | 'remote_https'
  | 'local_http'
  | 'private_vpn'
  | 'tofu_https';

export interface RelayEndpointCredentials {
  authMode?: string;
  hasKey?: boolean;
  sensitiveHeaders?: string[];
  sensitiveQueryKeys?: string[];
}

export interface RelayEndpointClassificationInput {
  raw: string;
  securityMode?: RelayConnectionSecurityMode;
  resolvedIPs?: string[];
  recheckResolvedIPs?: string[];
  redirects?: string[];
  credentials?: RelayEndpointCredentials;
}

export interface RelayEndpointClassification {
  allowed: boolean;
  reason: string;
  normalized?: string;
  pinnedIPs: string[];
}

/**
 * The connection-mode picker only needs to answer whether an address is eligible for cleartext
 * mode, and must not carry its own weakened host-string guesswork just to offer the UI a hint. It
 * reuses the same URL / IP classifier as the network boundary; when the browser cannot see the DNS
 * result it honestly returns `unknown_address`, which the UI disables with an explanation. Unknown
 * is never treated as private.
 *
 * The one exception is the RFC 6762 / WICG LNA special-use `.local` name: it only means local may
 * be attempted, and a real browser fetch must still pass `targetAddressSpace:'local'`. If DNS
 * resolves to a non-local address, the LNA check rejects the connection afterwards. `.internal` and
 * bare hostnames carry no such standard evidence and stay fail-safe.
 *
 * The only difference from `classifyRelayEndpoint` is that this deliberately does not treat the
 * http/https scheme the user typed as an address class, so `https://192.168.1.20` is still
 * recognized as private_lan. Saving is still blocked by the form-level scheme x mode check, which
 * requires the user to change the address explicitly rather than silently rewriting the scheme.
 */
export function classifyRelayCleartextAddress(input: {
  raw: string;
  securityMode: Extract<RelayConnectionSecurityMode, 'local_http' | 'private_vpn'>;
  resolvedIPs?: string[];
}): RelayEndpointClassification {
  const trimmed = input.raw.trim();
  if (!trimmed) return denied('invalid_url');
  const withScheme = SCHEME_RE.test(trimmed) ? trimmed : `http://${trimmed}`;

  let url: URL;
  try {
    url = new URL(withScheme);
  } catch {
    return denied('invalid_url');
  }
  if (!url.hostname) return denied('invalid_url');
  if (url.username || url.password) return denied('userinfo');
  if (url.search) return denied('embedded_query');
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return denied('unsupported_scheme');

  const ips = unique(input.resolvedIPs?.length ? input.resolvedIPs : literalHostIPs(url.hostname));
  if (ips.length === 0 && input.securityMode === 'local_http' && isSpecialUseLocalName(url.hostname)) {
    return { allowed: true, reason: 'local_name', normalized: normalizeURL(url), pinnedIPs: [] };
  }
  const result = classifyResolvedSet(ips, input.securityMode);
  return result.allowed
    ? { allowed: true, reason: result.reason, normalized: normalizeURL(url), pinnedIPs: ips }
    : denied(result.reason);
}

export function classifyRelayEndpoint(
  input: RelayEndpointClassificationInput,
): RelayEndpointClassification {
  const securityMode = input.securityMode ?? 'remote_https';
  const trimmed = input.raw.trim();
  if (!trimmed) return denied('invalid_url');
  const localMode = securityMode === 'local_http' || securityMode === 'private_vpn';
  const withScheme = SCHEME_RE.test(trimmed)
    ? trimmed
    : `${localMode ? 'http' : 'https'}://${trimmed}`;

  let url: URL;
  try {
    url = new URL(withScheme);
  } catch {
    return denied('invalid_url');
  }
  if (!url.hostname) return denied('invalid_url');
  if (url.username || url.password) return denied('userinfo');
  if (url.search) return denied('embedded_query');

  const normalized = normalizeURL(url);
  if (url.protocol === 'https:') {
    return { allowed: true, reason: 'encrypted_remote', normalized, pinnedIPs: unique(input.resolvedIPs) };
  }
  if (url.protocol !== 'http:') return denied('unsupported_scheme');
  if (!localMode) return denied('cleartext_not_allowed');
  if (hasCleartextCredentials(input.credentials)) return denied('cleartext_credentials');

  const initialIPs = unique(input.resolvedIPs?.length ? input.resolvedIPs : literalHostIPs(url.hostname));
  const specialUseLocalName = securityMode === 'local_http'
    && initialIPs.length === 0
    && isSpecialUseLocalName(url.hostname);
  const initial = specialUseLocalName
    ? { allowed: true, reason: 'local_name' }
    : classifyResolvedSet(initialIPs, securityMode);
  if (!initial.allowed) return denied(initial.reason);

  if (input.recheckResolvedIPs) {
    const recheckedIPs = unique(input.recheckResolvedIPs);
    const rechecked = classifyResolvedSet(recheckedIPs, securityMode);
    if (!rechecked.allowed || !sameSet(initialIPs, recheckedIPs)) return denied('dns_rebinding');
  }

  for (const rawRedirect of input.redirects ?? []) {
    let redirect: URL;
    try {
      redirect = new URL(rawRedirect, url);
    } catch {
      return denied('invalid_redirect');
    }
    if (redirect.origin !== url.origin) return denied('cross_origin_redirect');
    if (redirect.protocol !== 'http:') return denied('redirect_scheme_changed');
  }

  return { allowed: true, reason: initial.reason, normalized, pinnedIPs: initialIPs };
}

export function normalizeSecureRelayEndpoint(
  raw: string | null | undefined,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string | null {
  const trimmed = raw?.trim() ?? '';
  if (!trimmed) return null;
  const result = classifyRelayEndpoint({ raw: trimmed, securityMode });
  return result.allowed ? result.normalized ?? null : null;
}

export function requireSecureRelayEndpoint(
  raw: string | null | undefined,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string {
  const normalized = normalizeSecureRelayEndpoint(raw, securityMode);
  if (!normalized) throw new Error(RELAY_HTTPS_REQUIRED_MESSAGE);
  return normalized;
}

function hasCleartextCredentials(credentials: RelayEndpointCredentials | undefined): boolean {
  if (!credentials) return false;
  return credentials.authMode !== undefined && credentials.authMode !== 'none'
    || credentials.hasKey === true
    || (credentials.sensitiveHeaders?.length ?? 0) > 0
    || (credentials.sensitiveQueryKeys?.length ?? 0) > 0;
}

function classifyResolvedSet(
  ips: string[],
  securityMode: RelayConnectionSecurityMode,
): { allowed: boolean; reason: string } {
  if (ips.length === 0) return { allowed: false, reason: 'unknown_address' };
  const kinds = ips.map((ip) => classifyIP(ip, securityMode));
  const allowed = kinds.filter((item) => item.allowed);
  if (allowed.length > 0 && allowed.length !== kinds.length) {
    return { allowed: false, reason: 'mixed_resolution' };
  }
  if (allowed.length === 0) return { allowed: false, reason: 'public_address' };
  const reasons = new Set(allowed.map((item) => item.reason));
  if (reasons.has('private_vpn')) return { allowed: true, reason: 'private_vpn' };
  if (reasons.has('link_local')) return { allowed: true, reason: 'link_local' };
  if (reasons.has('private_lan')) return { allowed: true, reason: 'private_lan' };
  return { allowed: true, reason: 'loopback' };
}

function classifyIP(ip: string, securityMode: RelayConnectionSecurityMode) {
  const value = ip.toLowerCase().replace(/^\[|\]$/g, '');
  const ipv4 = parseIPv4(value);
  if (ipv4) {
    const [a, b] = ipv4;
    if (a === 127) return { allowed: true, reason: 'loopback' };
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) {
      return { allowed: true, reason: 'private_lan' };
    }
    if (a === 169 && b === 254) return { allowed: true, reason: 'link_local' };
    if (a === 100 && b >= 64 && b <= 127 && securityMode === 'private_vpn') {
      return { allowed: true, reason: 'private_vpn' };
    }
    return { allowed: false, reason: 'public_address' };
  }
  if (value === '::1') return { allowed: true, reason: 'loopback' };
  if (value.startsWith('fd7a:115c:a1e0:')) {
    return securityMode === 'private_vpn'
      ? { allowed: true, reason: 'private_vpn' }
      : { allowed: false, reason: 'public_address' };
  }
  const first = Number.parseInt(value.split(':')[0] || '0', 16);
  if ((first & 0xfe00) === 0xfc00) return { allowed: true, reason: 'private_lan' };
  if ((first & 0xffc0) === 0xfe80) return { allowed: true, reason: 'link_local' };
  return { allowed: false, reason: 'public_address' };
}

function parseIPv4(value: string): number[] | null {
  const parts = value.split('.');
  if (parts.length !== 4 || parts.some((part) => !/^\d+$/.test(part))) return null;
  const numbers = parts.map(Number);
  return numbers.every((part) => part >= 0 && part <= 255) ? numbers : null;
}

function literalHostIPs(hostname: string): string[] {
  const unwrapped = hostname.replace(/^\[|\]$/g, '');
  return parseIPv4(unwrapped) || unwrapped.includes(':') ? [unwrapped] : [];
}

function isSpecialUseLocalName(hostname: string): boolean {
  return hostname.toLowerCase().endsWith('.local');
}

function normalizeURL(url: URL): string {
  url.pathname = url.pathname.replace(/\/+$/, '');
  return url.toString().replace(/\/$/, '');
}

function unique(values: string[] | undefined): string[] {
  return [...new Set(values ?? [])];
}

function sameSet(lhs: string[], rhs: string[]): boolean {
  return lhs.length === rhs.length && lhs.every((value) => rhs.includes(value));
}

function denied(reason: string): RelayEndpointClassification {
  return { allowed: false, reason, pinnedIPs: [] };
}

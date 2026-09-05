import {
  classifyRelayCleartextAddress,
  classifyRelayEndpoint,
  type RelayConnectionSecurityMode,
} from '@oriveo/shared/relay/endpoint-policy';

/** TOFU has no browser-side certificate fingerprint confirmation flow, so it is never offered to the user. */
export type RelaySelectableSecurityMode = Exclude<RelayConnectionSecurityMode, 'tofu_https'>;

export const RELAY_SELECTABLE_SECURITY_MODES: readonly RelaySelectableSecurityMode[] = [
  'remote_https',
  'local_http',
  'private_vpn',
];

export type RelaySecurityModeUnavailableReason =
  | 'endpoint_required'
  | 'https_scheme_required'
  | 'plain_http_scheme_required'
  | 'unknown_address'
  | 'public_address'
  | 'mixed_resolution'
  | 'invalid_address';

export interface RelaySecurityModeOptionDecision {
  mode: RelaySelectableSecurityMode;
  enabled: boolean;
  addressClass?: string;
  unavailableReason?: RelaySecurityModeUnavailableReason;
}

export interface RelaySecurityModeDecision {
  options: readonly RelaySecurityModeOptionDecision[];
  /** The classifier only suggests; callers must not write this straight into state. */
  suggestion?: Extract<RelaySelectableSecurityMode, 'local_http' | 'private_vpn'>;
}

const SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//;

/**
 * The only decision entry point for the connection mode picker. The address class comes from the
 * production endpoint policy. With no DNS evidence available in the browser, `unknown_address` must
 * be disabled rather than guessed private from a `.local` suffix, a hostname's shape or user intent.
 */
export function relaySecurityModeDecision(endpoint: string): RelaySecurityModeDecision {
  const trimmed = endpoint.trim();
  const scheme = explicitScheme(trimmed);
  const local = cleartextOption(trimmed, 'local_http', scheme);
  const vpn = cleartextOption(trimmed, 'private_vpn', scheme);
  const remote: RelaySecurityModeOptionDecision = {
    mode: 'remote_https',
    enabled: trimmed.length > 0 && scheme !== 'http',
    unavailableReason: trimmed.length === 0
      ? 'endpoint_required'
      : scheme === 'http' ? 'https_scheme_required' : undefined,
  };

  // Only three cases may trigger a suggestion: a private address with no scheme, an explicit http
  // scheme, and Tailscale. An explicit https scheme shows the address class only, with no downgrade
  // suggested or allowed even for a private host; the user has to change it to http first.
  const maySuggestDowngrade = scheme === undefined || scheme === 'http';
  const suggestion = maySuggestDowngrade
    ? vpn.enabled && vpn.addressClass === 'private_vpn'
      ? 'private_vpn' as const
      : local.enabled ? 'local_http' as const : undefined
    : undefined;

  return { options: [remote, local, vpn], suggestion };
}

/** Called only after the user confirms. A missing scheme is filled in from the chosen mode and written back; an explicitly incompatible scheme returns null. */
export function normalizeEndpointForSecurityMode(
  endpoint: string,
  mode: RelaySelectableSecurityMode,
): string | null {
  const result = classifyRelayEndpoint({
    raw: endpoint,
    securityMode: mode,
    credentials: { authMode: 'none', hasKey: false },
  });
  return result.allowed ? result.normalized ?? null : null;
}

function cleartextOption(
  endpoint: string,
  mode: Extract<RelaySelectableSecurityMode, 'local_http' | 'private_vpn'>,
  scheme: 'http' | 'https' | 'other' | undefined,
): RelaySecurityModeOptionDecision {
  if (!endpoint) {
    return { mode, enabled: false, unavailableReason: 'endpoint_required' };
  }
  if (scheme === 'https') {
    return { mode, enabled: false, unavailableReason: 'plain_http_scheme_required' };
  }
  if (scheme === 'other') {
    return { mode, enabled: false, unavailableReason: 'invalid_address' };
  }

  const classification = classifyRelayCleartextAddress({ raw: endpoint, securityMode: mode });
  if (classification.allowed) {
    return { mode, enabled: true, addressClass: classification.reason };
  }
  return {
    mode,
    enabled: false,
    unavailableReason: mapUnavailableReason(classification.reason),
  };
}

function explicitScheme(endpoint: string): 'http' | 'https' | 'other' | undefined {
  if (!SCHEME_RE.test(endpoint)) return undefined;
  const raw = endpoint.slice(0, endpoint.indexOf(':')).toLowerCase();
  if (raw === 'http' || raw === 'https') return raw;
  return 'other';
}

function mapUnavailableReason(reason: string): RelaySecurityModeUnavailableReason {
  if (reason === 'unknown_address') return 'unknown_address';
  if (reason === 'public_address') return 'public_address';
  if (reason === 'mixed_resolution') return 'mixed_resolution';
  return 'invalid_address';
}

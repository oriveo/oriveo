import { requireSecureRelayEndpoint, type Provider, type RelayConnectionSecurityMode } from '@oriveo/shared';
import { connectionTransport, verifiedConnectionAPIRoot } from '@oriveo/core/providers/relay-effective';
import { normalizeRelayBaseURL, type RelayEndpointTransport } from '@oriveo/core/providers/relay-endpoints';

export type RelayProbeTransportKind =
  | 'openai_responses'
  | 'openai_chat_completions'
  | 'anthropic_messages'
  | 'gemini_generate_content';

export type RelayEndpointCandidateEvidence =
  | 'explicit_route'
  | 'explicit_version'
  | 'default_version'
  | 'alternate_version'
  | 'versionless_fallback';

export interface RelayEndpointDescriptor {
  normalizedInput: string;
  origin: string;
  pathPrefix: string;
  explicitVersion?: 'v1' | 'v1beta';
  explicitTransport?: RelayProbeTransportKind;
  containsEmbeddedQuery: boolean;
  containsFragment: boolean;
}

export interface RelayEndpointCandidate {
  apiBaseURL: string;
  transport: RelayProbeTransportKind;
  evidence: RelayEndpointCandidateEvidence;
}

const KNOWN_VERSIONS = new Set(['v1', 'v1beta']);

/**
 * Strip an embedded query or fragment, and record honestly that the original address
 * carried one.
 *
 * Why the raw string is not simply handed to `requireSecureRelayEndpoint`: the reason from
 * `if (url.search) return denied('embedded_query')` in `classifyRelayEndpoint` is flattened
 * to null by `normalizeSecureRelayEndpoint`, so `describeRelayEndpoint` throws and
 * probe-runner can only report the generic `invalid_endpoint`, rendered as "Use an HTTPS
 * request URL". The user did paste an HTTPS address, only with a `?key=...` tail, so that
 * message is wrong. The `relay.embeddedQuery` string ("Remove query parameters...")
 * localized in 16 languages describes this state, and the `embedded_query` branch in
 * `probe-runner.ts` together with the two descriptor fields exists for it; a rewrite of the
 * address policy turned all of them into dead code.
 *
 * The security surface is unaffected: HTTPS, userInfo and address classification remain
 * entirely gated by `requireSecureRelayEndpoint`, and the query is stripped here so it can
 * never reach an outbound URL (probing refuses with zero requests on
 * `containsEmbeddedQuery`, and `appendRelayEndpointPath` clears it as a second guard).
 */
function splitEndpointTail(input: string): {
  base: string;
  containsEmbeddedQuery: boolean;
  containsFragment: boolean;
} {
  const trimmed = input.trim();
  const hashIndex = trimmed.indexOf('#');
  const withoutFragment = hashIndex >= 0 ? trimmed.slice(0, hashIndex) : trimmed;
  const queryIndex = withoutFragment.indexOf('?');
  return {
    base: queryIndex >= 0 ? withoutFragment.slice(0, queryIndex) : withoutFragment,
    // Matching URL semantics: a bare `?` or `#` yields an empty search or hash, which does not count as carrying a query or fragment.
    containsEmbeddedQuery: queryIndex >= 0 && queryIndex < withoutFragment.length - 1,
    containsFragment: hashIndex >= 0 && hashIndex < trimmed.length - 1,
  };
}

export function describeRelayEndpoint(
  input: string,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): RelayEndpointDescriptor {
  const tail = splitEndpointTail(input);
  const normalizedInput = requireSecureRelayEndpoint(tail.base, securityMode);
  const parsed = new URL(normalizedInput);
  const segments = parsed.pathname.split('/').filter(Boolean);
  const explicitTransport = trimTerminalRoute(segments);
  const lastSegment = segments.at(-1)?.toLowerCase();
  const explicitVersion = lastSegment && KNOWN_VERSIONS.has(lastSegment)
    ? lastSegment as 'v1' | 'v1beta'
    : undefined;
  if (explicitVersion) segments.pop();

  return {
    normalizedInput,
    origin: parsed.origin,
    pathPrefix: segments.length > 0 ? `/${segments.join('/')}` : '',
    explicitVersion,
    explicitTransport,
    containsEmbeddedQuery: tail.containsEmbeddedQuery,
    containsFragment: tail.containsFragment,
  };
}

export function buildRelayEndpointCandidates(
  descriptor: RelayEndpointDescriptor,
  transport: RelayProbeTransportKind,
): RelayEndpointCandidate[] {
  const candidates: RelayEndpointCandidate[] = [];
  const append = (
    version: string | undefined,
    evidence: RelayEndpointCandidateEvidence,
  ) => {
    const suffix = [descriptor.pathPrefix.replace(/^\/+|\/+$/g, ''), version]
      .filter((value): value is string => Boolean(value))
      .join('/');
    const apiBaseURL = suffix ? `${descriptor.origin}/${suffix}` : descriptor.origin;
    if (candidates.some((candidate) => candidate.apiBaseURL === apiBaseURL)) return;
    candidates.push({ apiBaseURL, transport, evidence });
  };

  if (descriptor.explicitTransport && !descriptor.explicitVersion) {
    append(undefined, 'explicit_route');
  }
  if (descriptor.explicitVersion) {
    append(
      descriptor.explicitVersion,
      descriptor.explicitTransport ? 'explicit_route' : 'explicit_version',
    );
  }

  preferredVersions(transport).forEach((version, index) => {
    append(version, index === 0 ? 'default_version' : 'alternate_version');
  });
  append(undefined, 'versionless_fallback');
  return candidates;
}

/**
 * Root address for the "Will request ..." preview on the add page (fixture address-normalize.v1.json previewCases):
 * strip the terminal route, then append the version by the protocol of the explicit terminal route (otherwise Chat Completions). Returns null when it cannot be a safe request address
 * (empty, userinfo, embedded query, non-local plaintext http), and the preview row is hidden.
 */
export function previewAPIRoot(
  input: string,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string | null {
  let descriptor: RelayEndpointDescriptor;
  try {
    descriptor = describeRelayEndpoint(input, securityMode);
  } catch {
    return null;
  }
  if (descriptor.containsEmbeddedQuery) return null;
  const transport = descriptor.explicitTransport ?? 'openai_chat_completions';
  try {
    return versionCompletedRoot(descriptor, transport, securityMode);
  } catch {
    return null;
  }
}

/**
 * Root address for every catalog GET (fixture catalogCases): the connection-level verified root address wins;
 * otherwise baseURL with the terminal route stripped, plus the version by the connection protocol. Catalog URL = root + `/models`.
 * Returns undefined when the address fails the security policy, and the party sending the request reports the error.
 */
export function catalogAPIRoot(
  provider: Pick<Provider, 'baseURLText' | 'relayRequested'>,
): string | undefined {
  const verified = verifiedConnectionAPIRoot(provider);
  if (verified) return verified;
  const securityMode = provider.relayRequested?.securityMode;
  try {
    const descriptor = describeRelayEndpoint(provider.baseURLText ?? '', securityMode);
    return versionCompletedRoot(descriptor, connectionTransport(provider), securityMode);
  } catch {
    return undefined;
  }
}

/**
 * After stripping the terminal route, append the version with the same rule as effectiveAPIRoot: if any path segment is already v<N>[alpha|beta] use it as is
 * (e.g. /api/paas/v4 must not become /v4/v1), llamacpp_native appends nothing, the others append that protocol's standard version.
 */
function versionCompletedRoot(
  descriptor: RelayEndpointDescriptor,
  transport: RelayEndpointTransport,
  securityMode: RelayConnectionSecurityMode | undefined,
): string {
  const path = [descriptor.pathPrefix, descriptor.explicitVersion ? `/${descriptor.explicitVersion}` : '']
    .join('');
  return normalizeRelayBaseURL(`${descriptor.origin}${path}`, transport, securityMode);
}

export function appendRelayEndpointPath(
  apiBaseURL: string,
  endpointPath: string,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string {
  // As in describeRelayEndpoint, query and fragment are stripped before the security policy
  // runs; otherwise a candidate address carrying a query would throw here instead of being
  // cleaned. This function is defined never to send a query or fragment out with the joined
  // path.
  const base = new URL(requireSecureRelayEndpoint(splitEndpointTail(apiBaseURL).base, securityMode));
  base.search = '';
  base.hash = '';
  base.pathname = [base.pathname.replace(/\/+$/, ''), endpointPath.replace(/^\/+/, '')]
    .filter(Boolean)
    .join('/');
  return base.toString();
}

function preferredVersions(transport: RelayProbeTransportKind): string[] {
  return transport === 'gemini_generate_content'
    ? ['v1beta', 'v1']
    : ['v1', 'v1beta'];
}

function trimTerminalRoute(segments: string[]): RelayProbeTransportKind | undefined {
  const lower = segments.map((segment) => segment.toLowerCase());
  const lastIndex = lower.length - 1;
  if (lastIndex >= 1 && lower[lastIndex - 1] === 'chat' && lower[lastIndex] === 'completions') {
    segments.splice(-2);
    return 'openai_chat_completions';
  }
  if (lower[lastIndex] === 'responses') {
    segments.pop();
    return 'openai_responses';
  }
  if (lower[lastIndex] === 'messages') {
    segments.pop();
    return 'anthropic_messages';
  }
  if (
    lastIndex >= 1
    && lower[lastIndex - 1] === 'models'
    && /:(?:stream)?generatecontent$/i.test(lower[lastIndex])
  ) {
    segments.splice(-2);
    return 'gemini_generate_content';
  }
  if (lower[lastIndex] === 'models') segments.pop();
  return undefined;
}

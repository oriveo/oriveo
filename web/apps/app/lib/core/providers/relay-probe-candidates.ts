import type { RelayModelTransport } from '@oriveo/shared';
import { isRelayGenerationSuccessResponse } from '@oriveo/core/providers/relay-generation-response';
import { unescapeRelayJSONSlashes } from '@oriveo/core/providers/relay-client-gate';
import { cachedModelFamilyByModel, lookupModelFamilyByModel } from '../metadata/metadata-client';

/**
 * Candidate order of relay per-model probing (C3 section 3.1; fixture `probe-orchestration.v1.json` candidateRules).
 * Candidates only decide which transport the 1-token probe tries first: they are not a source, not persisted, not displayed.
 */

const ENDPOINT_TYPE_TO_TRANSPORT: Readonly<Record<string, RelayModelTransport>> = {
  openai: 'openai_chat_completions',
  'openai-response': 'openai_responses',
  anthropic: 'anthropic_messages',
  gemini: 'gemini_generate_content',
};

const FAMILY_TO_TRANSPORTS: Readonly<Record<string, readonly RelayModelTransport[]>> = {
  anthropic: ['anthropic_messages', 'openai_chat_completions'],
  google: ['gemini_generate_content', 'openai_chat_completions'],
  openai: ['openai_responses', 'openai_chat_completions'],
};

const DEFAULT_TRANSPORTS: readonly RelayModelTransport[] = ['openai_chat_completions'];
const MAX_CANDIDATES = 2;

/**
 * Route-level rejection (fixture `negative-cache.v1.json` protocolFallbackRules): this transport path does not accept this request.
 * Per-model probing "switch to the next candidate" and the send-time transport fallback recognize only this one criterion; other failures (key, rate limit, parameters, upstream fault, network)
 * cannot show whether the transport is right, so the transport is not switched.
 * A 2xx that is a web page (the gateway's SPA fallback page) counts too: this path is not an API route; "is it a web page" uses the existing probe success shape.
 */
const ROUTE_REJECTION_STATUSES: ReadonlySet<number> = new Set([404, 405, 415]);
const ROUTE_REJECTION_PHRASE_STATUSES: ReadonlySet<number> = new Set([403]);
/** The verbatim words with which sub2api rejects /v1/messages for groups without messages dispatch enabled; a 403 without it is a key / account problem. */
const ROUTE_REJECTION_PHRASES: readonly string[] = ['does not allow /v1/messages dispatch'];

export function isRelayRouteRejection(input: {
  status: number | null | undefined;
  body?: string | null;
  /** Treated as application/json when omitted. */
  contentType?: string | null;
}): boolean {
  if (typeof input.status !== 'number') return false;
  if (input.status >= 200 && input.status < 300) {
    return !isRelayGenerationSuccessResponse(input.body ?? '', input.contentType);
  }
  if (ROUTE_REJECTION_STATUSES.has(input.status)) return true;
  if (!ROUTE_REJECTION_PHRASE_STATUSES.has(input.status)) return false;
  // JSON may escape `/` as `\/`: restore it before comparing, so a phrase is registered in only one spelling. The official CLI gate is not in this list and never switches transport.
  const body = unescapeRelayJSONSlashes(input.body ?? '').toLowerCase();
  return ROUTE_REJECTION_PHRASES.some((phrase) => body.includes(phrase));
}

/** new-api `supported_endpoint_types` mapped in array order; unknown values and duplicates are dropped. */
export function relayProbeCandidatesFromEndpointTypes(
  types: readonly unknown[] | null | undefined,
): RelayModelTransport[] {
  const result: RelayModelTransport[] = [];
  for (const type of types ?? []) {
    if (typeof type !== 'string' || !Object.hasOwn(ENDPOINT_TYPE_TO_TRANSPORT, type)) continue;
    const transport = ENDPOINT_TYPE_TO_TRANSPORT[type]!;
    if (!result.includes(transport)) result.push(transport);
  }
  return result.slice(0, MAX_CANDIDATES);
}

/** Family path: a known family hit takes the family candidates; a miss / unknown family / unavailable view all try Chat only. */
export function relayProbeCandidatesForFamily(family: string | undefined): RelayModelTransport[] {
  const transports = family && Object.hasOwn(FAMILY_TO_TRANSPORTS, family)
    ? FAMILY_TO_TRANSPORTS[family]!
    : DEFAULT_TRANSPORTS;
  return transports.slice(0, MAX_CANDIDATES);
}

/**
 * If endpoint types map to something, use it; only otherwise lazily query the by-model view for the family.
 * `lookupFamily` defaults to the by-model view of metadata-client.
 */
export async function resolveRelayProbeCandidates(input: {
  modelID: string;
  supportedEndpointTypes?: readonly unknown[] | null;
  lookupFamily?: (modelID: string) => Promise<string | undefined>;
}): Promise<RelayModelTransport[]> {
  const fromTypes = relayProbeCandidatesFromEndpointTypes(input.supportedEndpointTypes);
  if (fromTypes.length > 0) return fromTypes;
  const lookupFamily = input.lookupFamily ?? lookupModelFamilyByModel;
  let family: string | undefined;
  try {
    family = await lookupFamily(input.modelID);
  } catch {
    family = undefined;
  }
  return relayProbeCandidatesForFamily(family);
}

/**
 * Generation-route discovery only at add time (no catalog; fixture generationRouteCases): the transport found comes first,
 * followed by the result of the candidate rules, de-duplicated, at most MAX_CANDIDATES.
 */
export function relayGenerationRouteCandidates(
  route: RelayModelTransport,
  ruleCandidates: readonly RelayModelTransport[],
): RelayModelTransport[] {
  const result: RelayModelTransport[] = [route];
  for (const transport of ruleCandidates) {
    if (!result.includes(transport)) result.push(transport);
  }
  return result.slice(0, MAX_CANDIDATES);
}

/**
 * Same combination as `resolveRelayProbeCandidates` (endpoint types first, otherwise the family path), but the family reads only the cached
 * by-model view and sends no request: the ratio bar on the add page groups by it; models absent from the cache fall to Chat.
 */
export function cachedRelayProbeCandidates(input: {
  modelID: string;
  supportedEndpointTypes?: readonly unknown[] | null;
  cachedFamily?: (modelID: string) => string | undefined;
}): RelayModelTransport[] {
  const fromTypes = relayProbeCandidatesFromEndpointTypes(input.supportedEndpointTypes);
  if (fromTypes.length > 0) return fromTypes;
  return relayProbeCandidatesForFamily((input.cachedFamily ?? cachedModelFamilyByModel)(input.modelID));
}

/**
 * `supported_endpoint_types` of each model in each connection's latest catalog result (memory only, not persisted, not synced).
 * When unavailable (catalog never pulled / after a page refresh) use the family path.
 */
const catalogEndpointTypesByConnection = new Map<string, Readonly<Record<string, readonly string[]>>>();

export function rememberRelayCatalogEndpointTypes(
  connectionKey: string,
  endpointTypes: Readonly<Record<string, readonly string[]>> | undefined,
): void {
  if (!connectionKey) return;
  if (!endpointTypes) {
    catalogEndpointTypesByConnection.delete(connectionKey);
    return;
  }
  catalogEndpointTypesByConnection.set(connectionKey, endpointTypes);
}

export function relayCatalogEndpointTypes(
  connectionKey: string,
  modelID: string,
): readonly string[] | undefined {
  const types = catalogEndpointTypesByConnection.get(connectionKey);
  return types && Object.hasOwn(types, modelID) ? types[modelID] : undefined;
}

/** Take `supported_endpoint_types` from a catalog entry; accept only string arrays, ignore the rest. */
export function catalogEntryEndpointTypes(entry: unknown): string[] | undefined {
  if (!entry || typeof entry !== 'object') return undefined;
  const raw = (entry as Record<string, unknown>).supported_endpoint_types;
  if (!Array.isArray(raw)) return undefined;
  return raw.filter((value): value is string => typeof value === 'string');
}

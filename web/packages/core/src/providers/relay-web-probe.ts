import type { RelayWebFragment, RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { sha256Hex } from '../mcp/mcp-pure';
import type { UpstreamTransport } from '../ports';
import {
  classifyRelayCapabilityTestOutcome,
  type RelayCapabilityTestReason,
} from './relay-capability-test';
import { sendRelayStream, type RelayMessages } from './relay-orchestrator';
import type { StreamEvent } from './types';

/**
 * Pure parts of the relay web-search probe: fixed prompt, time limit and output cap, response classification, fragment hash, record merge.
 * Fixture source of truth: `relay/web-probe.v1.json`.
 * The request is produced by the same builder as ordinary chat (capability-test path + the stored fragment for that protocol); no request body is crafted here.
 */

export const RELAY_WEB_PROBE_PROMPT = "Search the web and give one source URL for today's top news.";
/** The output cap goes through the builder's own max-tokens channel (`relayMaxOutputTokens`). */
export const RELAY_WEB_PROBE_MAX_OUTPUT_TOKENS = 256;
/** Total time limit: from sending to reading the last byte. */
export const RELAY_WEB_PROBE_DEADLINE_MS = 30_000;

export type RelayWebProbeResult = 'searched' | 'silent' | 'rejected' | 'undetermined';
/** Result written into the record (undetermined is not written). */
export type RelayWebProbeRecordResult = Exclude<RelayWebProbeResult, 'undetermined'>;

export interface RelayWebProbeRecord {
  result: RelayWebProbeRecordResult;
  /** tested = obtained by probing; observed = the parser found evidence in a real chat. */
  source: 'tested' | 'observed';
  /** ISO 8601. */
  at: string;
  /** Hash of that protocol's fragment when the record was produced; a different value from the current fragment counts as untested. */
  fragmentHash: string;
}

export interface RelayWebProbeVerdict {
  result: RelayWebProbeResult;
  reason: RelayCapabilityTestReason;
  /** URLs referenced by the parser, deduplicated in order of appearance; only searched may be non-empty. */
  evidenceUrls: string[];
}

export type RelayWebProbeResponseInput =
  | { status: number; contentType: string | null; body: string }
  | { failure: 'timeout' | 'network' | 'cancelled' };

export function relayWebProbeMessages(): RelayMessages {
  return [{ role: 'user', content: RELAY_WEB_PROBE_PROMPT }];
}

/** Feed the whole 2xx response body to the production streaming parser for that protocol (relay-orchestrator) and collect evidence. */
export async function relayWebProbeEvidence(
  transport: RelayWebTransport,
  response: { status: number; contentType: string | null; body: string },
): Promise<{ searched: boolean; evidenceUrls: string[]; errored: boolean }> {
  const upstream: UpstreamTransport = {
    fetch: async () => new Response(response.body, {
      status: response.status,
      headers: { 'Content-Type': response.contentType ?? 'text/event-stream' },
    }),
  };
  const handle = sendRelayStream(
    '',
    'relay-web-probe',
    relayWebProbeMessages(),
    'https://relay-web-probe.invalid/v1',
    { relayTransport: transport, relayAuthMode: 'bearer' },
    {
      transport: upstream,
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    },
  );
  let searchRan = false;
  let errored = false;
  let citations: Extract<StreamEvent, { type: 'citations' }>['citations'] = [];
  const reader = handle.stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.type === 'citations') {
        citations = value.citations;
        if (value.searchRan) searchRan = true;
      } else if (value.type === 'error') {
        errored = true;
      }
    }
  } catch {
    errored = true;
  }
  const evidenceUrls: string[] = [];
  for (const citation of citations) {
    const url = (citation.url ?? '').trim();
    if (url && !evidenceUrls.includes(url)) evidenceUrls.push(url);
  }
  return { searched: searchRan || evidenceUrls.length > 0, evidenceUrls, errored };
}

/**
 * One probe response (or no response) -> result. Status classification follows the capability test (rejection is only recognized before any text);
 * a 2xx then goes through the production parser: evidence means searched, none means silent; an error frame after text is undetermined.
 */
export async function judgeRelayWebProbeResponse(
  transport: RelayWebTransport,
  input: RelayWebProbeResponseInput,
): Promise<RelayWebProbeVerdict> {
  if ('failure' in input) {
    return { result: 'undetermined', reason: input.failure === 'timeout' ? 'timeout' : 'network', evidenceUrls: [] };
  }
  const outcome = classifyRelayCapabilityTestOutcome(input);
  if (outcome.verdict !== 'accepted') {
    return { result: outcome.verdict, reason: outcome.reason, evidenceUrls: [] };
  }
  const evidence = await relayWebProbeEvidence(transport, input);
  if (evidence.errored) return { result: 'undetermined', reason: 'server', evidenceUrls: [] };
  return evidence.searched
    ? { result: 'searched', reason: 'ok', evidenceUrls: evidence.evidenceUrls }
    : { result: 'silent', reason: 'ok', evidenceUrls: [] };
}

function compareCodePoints(a: string, b: string): number {
  const left = Array.from(a);
  const right = Array.from(b);
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const diff = left[index]!.codePointAt(0)! - right[index]!.codePointAt(0)!;
    if (diff !== 0) return diff;
  }
  return left.length - right.length;
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).filter((key) => record[key] !== undefined).sort(compareCodePoints);
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJSON(record[key])}`).join(',')}}`;
  }
  return JSON.stringify(value) ?? 'null';
}

/** Canonical fragment JSON: keys of every level sorted by code point, arrays keep order, no whitespace. */
export function canonicalRelayWebFragmentJSON(fragment: RelayWebFragment): string {
  return canonicalJSON(fragment);
}

/** Fragment hash: lowercase hex SHA-256 of the canonical JSON in UTF-8. */
export function relayWebFragmentHash(fragment: RelayWebFragment): string {
  return sha256Hex(canonicalJSON(fragment));
}

/**
 * Merging records for the same connection x model x protocol: a different hash (fragment changed) simply replaces the record;
 * with the same hash, rejected / searched replace any old value, and silent only replaces silent / rejected, never erasing searched.
 */
export function mergeRelayWebProbeRecord(
  existing: RelayWebProbeRecord | null | undefined,
  incoming: RelayWebProbeRecord,
): RelayWebProbeRecord {
  if (!existing || existing.fragmentHash !== incoming.fragmentHash) return incoming;
  if (incoming.result === 'silent' && existing.result === 'searched') return existing;
  return incoming;
}

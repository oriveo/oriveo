/**
 * Narrow signature matching for upstream rejections of media / parameters.
 *
 * The signature table is generated from the shared fixture by scripts/generate-rejection-signatures.mjs and only holds byWireFamily / byProtocol;
 * candidates take no part in matching. An error not in the table returns null and the caller shows the upstream error as is, with no inference.
 */
import {
  REJECTION_SIGNATURES_BY_PROTOCOL,
  REJECTION_SIGNATURES_BY_WIRE_FAMILY,
  type RejectionSignatureEntry,
} from './rejection-signatures.generated';

export interface RejectionSignatureInput {
  /** Protocol used by the request, for example anthropic / openai_chat. */
  protocol: string;
  /** Media wire families the request actually carried (for example openai_chat.image_url); one or more, omitted when no media was sent. */
  wireFamily?: string | readonly string[] | null;
  /** Upstream HTTP status code. */
  status: number;
  /** Upstream response body: parsed JSON or raw text. */
  body: unknown;
}

export type RejectionSignatureMatch =
  | { signatureId: string; kind: 'input_rejected'; capabilityKey: string }
  | { signatureId: string; kind: 'param_rejected'; parameter: string };

interface UpstreamError {
  type?: string;
  code?: string;
  message?: string;
}

const patternCache = new Map<string, RegExp>();

function compile(pattern: string): RegExp {
  let re = patternCache.get(pattern);
  if (!re) {
    re = new RegExp(pattern, 'i');
    patternCache.set(pattern, re);
  }
  return re;
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

/** Extract the error object from the response body (supports `{error:{...}}`, Anthropic's `{type:'error', error:{...}}` and JSON text). */
function extractError(body: unknown): UpstreamError | null {
  let parsed = body;
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      return null;
    }
  }
  if (!parsed || typeof parsed !== 'object') return null;
  const error = (parsed as Record<string, unknown>).error;
  if (!error || typeof error !== 'object') return null;
  const record = error as Record<string, unknown>;
  return {
    type: asString(record.type),
    code: asString(record.code),
    message: asString(record.message),
  };
}

function matches(entry: RejectionSignatureEntry, status: number, error: UpstreamError): boolean {
  if (entry.httpStatus !== status) return false;
  if (entry.errorCode !== undefined && entry.errorCode !== error.type && entry.errorCode !== error.code) {
    return false;
  }
  if (error.message === undefined) return false;
  return compile(entry.messagePattern).test(error.message);
}

function toMatch(entry: RejectionSignatureEntry): RejectionSignatureMatch | null {
  if (entry.kind === 'input_rejected' && entry.capabilityKey) {
    return { signatureId: entry.signatureId, kind: entry.kind, capabilityKey: entry.capabilityKey };
  }
  if (entry.kind === 'param_rejected' && entry.parameter) {
    return { signatureId: entry.signatureId, kind: entry.kind, parameter: entry.parameter };
  }
  return null;
}

/** Return the first hit in fixture order (byWireFamily first, then byProtocol); null when nothing matches. */
export function matchRejectionSignature(input: RejectionSignatureInput): RejectionSignatureMatch | null {
  const error = extractError(input.body);
  if (!error) return null;
  const families =
    input.wireFamily == null ? [] : typeof input.wireFamily === 'string' ? [input.wireFamily] : input.wireFamily;
  const ordered: RejectionSignatureEntry[] = [];
  for (const [family, entries] of Object.entries(REJECTION_SIGNATURES_BY_WIRE_FAMILY)) {
    if (families.includes(family)) ordered.push(...entries);
  }
  ordered.push(...(REJECTION_SIGNATURES_BY_PROTOCOL[input.protocol] ?? []));
  for (const entry of ordered) {
    if (matches(entry, input.status, error)) return toMatch(entry);
  }
  return null;
}

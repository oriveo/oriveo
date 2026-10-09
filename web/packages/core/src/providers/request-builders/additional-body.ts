/**
 * Additional request body (shared contract generation_parameter_contract.v1.json #additionalBodyRules).
 *
 * A JSON object written by the user, merged into the request body after panel parameters and the capability writer,
 * as the very last step of building the body.
 * Pure functions: the browser (Relay, pre-send check) and the Next route (official providers, subscription sign-in)
 * share the same decision logic.
 *
 * A rejection carries only a reason from a closed vocabulary, the name of a protected field / blocked segment,
 * and the line number of a syntax error: other keys and values written by the user never reach
 * errors, logs or telemetry.
 */
import { BUILDER_OWNED_ROOT_FIELDS } from './generation-parameters';

export const ADDITIONAL_BODY_MAX_BYTES = 65_536;
export const ADDITIONAL_BODY_MAX_DEPTH = 32;
/** errorKind: the route's 400 response body and the browser-side error object use the same name. */
export const ADDITIONAL_BODY_ERROR_KIND = 'additionalBodyRejected';

const BLOCKED_SEGMENTS = new Set(['__proto__', 'prototype', 'constructor']);

export type AdditionalBodyRejectReason =
  | 'invalid_json'
  | 'not_object'
  | 'protected_field'
  | 'blocked_segment'
  | 'too_large'
  | 'too_deep';

export interface AdditionalBodyRejection {
  reason: AdditionalBodyRejectReason;
  /** Only set for protected_field / blocked_segment. */
  field?: string;
  /** Only set for invalid_json: the line (1-based) where parsing stopped. */
  line?: number;
}

export type AdditionalBodyValidation =
  | { accepted: true; value: Record<string, unknown> | null }
  | { accepted: false; rejection: AdditionalBodyRejection };

export type AdditionalBodyMergeResult =
  | { accepted: true; body: Record<string, unknown> }
  | { accepted: false; rejection: AdditionalBodyRejection; body: Record<string, unknown> };

/** Local rejection: the request was never sent. The message is the safe code and never contains user-written keys or values. */
export class AdditionalBodyRejectedError extends Error {
  readonly kind = ADDITIONAL_BODY_ERROR_KIND;
  readonly errorKind = ADDITIONAL_BODY_ERROR_KIND;
  readonly source = 'oriveo' as const;
  readonly code: string;
  readonly rejection: AdditionalBodyRejection;

  constructor(rejection: AdditionalBodyRejection) {
    const code = additionalBodyRejectionCode(rejection);
    super(code);
    this.name = 'AdditionalBodyRejectedError';
    this.code = code;
    this.rejection = rejection;
  }
}

export function isAdditionalBodyRejectedError(error: unknown): error is AdditionalBodyRejectedError {
  return error instanceof AdditionalBodyRejectedError
    || (typeof error === 'object' && error !== null
      && (error as { errorKind?: unknown }).errorKind === ADDITIONAL_BODY_ERROR_KIND
      && typeof (error as { code?: unknown }).code === 'string');
}

/** `additional_body_rejected:<reason>[:<field>][@line]` */
export function additionalBodyRejectionCode(rejection: AdditionalBodyRejection): string {
  return `additional_body_rejected:${rejection.reason}`
    + (rejection.field ? `:${rejection.field}` : '')
    + (rejection.line ? `@${rejection.line}` : '');
}

/** Decision order: size -> JSON syntax -> root is an object -> depth -> blocked segments -> protected root fields. Blank content counts as not enabled. */
export function validateAdditionalBody(raw: string): AdditionalBodyValidation {
  if (!raw.trim()) return { accepted: true, value: null };
  if (new TextEncoder().encode(raw).length > ADDITIONAL_BODY_MAX_BYTES) {
    return { accepted: false, rejection: { reason: 'too_large' } };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    const line = syntaxErrorLine(raw);
    return { accepted: false, rejection: { reason: 'invalid_json', ...(line ? { line } : {}) } };
  }
  if (!isRecord(parsed)) return { accepted: false, rejection: { reason: 'not_object' } };
  if (exceedsDepth(parsed, 1)) return { accepted: false, rejection: { reason: 'too_deep' } };
  const blocked = findBlockedSegment(parsed);
  if (blocked) return { accepted: false, rejection: { reason: 'blocked_segment', field: blocked } };
  const protectedFields = Object.keys(parsed).filter((key) => BUILDER_OWNED_ROOT_FIELDS.has(key)).sort(compareCodePoints);
  if (protectedFields.length > 0) {
    return { accepted: false, rejection: { reason: 'protected_field', field: protectedFields[0] } };
  }
  return { accepted: true, value: parsed };
}

/** Merges objects level by level; arrays and scalars are replaced wholesale, and the additional body wins on equal names. The input body is never rewritten. */
export function mergeAdditionalBody(body: Record<string, unknown>, raw: string): AdditionalBodyMergeResult {
  const validation = validateAdditionalBody(raw);
  if (!validation.accepted) return { accepted: false, rejection: validation.rejection, body };
  if (!validation.value) return { accepted: true, body };
  return { accepted: true, body: deepMerge(body, validation.value) };
}

/** For production outbound use: returns the body unchanged without an additional body, and throws `AdditionalBodyRejectedError` on rejection. */
export function applyAdditionalBodyOrThrow(
  body: Record<string, unknown>,
  additionalBody: { raw: string } | undefined,
): Record<string, unknown> {
  if (!additionalBody) return body;
  const result = mergeAdditionalBody(body, additionalBody.raw);
  if (!result.accepted) throw new AdditionalBodyRejectedError(result.rejection);
  return result.body;
}

/** Whole-request variant: replaces only `body` and keeps every other field (url / headers / capabilityExecution ...) as is. */
export function applyAdditionalBodyToRequest<T extends { body: Record<string, unknown> }>(
  request: T,
  additionalBody: { raw: string } | undefined,
): T {
  if (!additionalBody) return request;
  return { ...request, body: applyAdditionalBodyOrThrow(request.body, additionalBody) };
}

/** Pre-send check: throws when invalid and changes nothing. The first line of defence in the browser and at every outbound boundary. */
export function assertAdditionalBodyAccepted(additionalBody: { raw: string } | undefined): void {
  if (!additionalBody) return;
  const validation = validateAdditionalBody(additionalBody.raw);
  if (!validation.accepted) throw new AdditionalBodyRejectedError(validation.rejection);
}

/** True when the merger would produce non-empty content (the send-path fact "an additional body is really attached", decided by the same validator as the merge). */
export function additionalBodyHasContent(additionalBody: { raw: string } | undefined): boolean {
  if (!additionalBody) return false;
  const validation = validateAdditionalBody(additionalBody.raw);
  return validation.accepted && Object.keys(validation.value ?? {}).length > 0;
}

export function applyAdditionalBodyInPlace(
  body: Record<string, unknown>,
  additionalBody: { raw: string } | undefined,
): void {
  if (!additionalBody) return;
  Object.assign(body, applyAdditionalBodyOrThrow(body, additionalBody));
}

function deepMerge(base: Record<string, unknown>, patch: Record<string, unknown>): Record<string, unknown> {
  const output: Record<string, unknown> = { ...base };
  for (const [key, value] of Object.entries(patch)) {
    const current = output[key];
    output[key] = isRecord(value) && isRecord(current) ? deepMerge(current, value) : value;
  }
  return output;
}

function exceedsDepth(value: unknown, depth: number): boolean {
  if (depth > ADDITIONAL_BODY_MAX_DEPTH) return true;
  const children = Array.isArray(value) ? value : isRecord(value) ? Object.values(value) : [];
  return children.some((child) => (Array.isArray(child) || isRecord(child)) && exceedsDepth(child, depth + 1));
}

function findBlockedSegment(value: unknown): string | null {
  if (Array.isArray(value)) {
    for (const child of value) {
      const found = findBlockedSegment(child);
      if (found) return found;
    }
    return null;
  }
  if (!isRecord(value)) return null;
  for (const [key, child] of Object.entries(value)) {
    if (BLOCKED_SEGMENTS.has(key)) return key;
    const found = findBlockedSegment(child);
    if (found) return found;
  }
  return null;
}

function compareCodePoints(left: string, right: string): number {
  const a = Array.from(left);
  const b = Array.from(right);
  for (let index = 0; index < Math.min(a.length, b.length); index += 1) {
    const diff = a[index]!.codePointAt(0)! - b[index]!.codePointAt(0)!;
    if (diff !== 0) return diff;
  }
  return a.length - b.length;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * JSON.parse error messages differ between engines (some include a position, some do not), so the line number cannot be
 * extracted from the message. Instead the text is scanned once against the JSON grammar and the line of the position where
 * the scan stopped is returned; no line is reported when the scan disagrees with the parser.
 */
function syntaxErrorLine(text: string): number | undefined {
  const offset = syntaxErrorOffset(text);
  if (offset === null) return undefined;
  let line = 1;
  for (let index = 0; index < Math.min(offset, text.length); index += 1) {
    if (text.charCodeAt(index) === 10) line += 1;
  }
  return line;
}

function syntaxErrorOffset(text: string): number | null {
  let i = 0;
  const fail = (): never => { throw new JsonScanStop(i); };
  const skipWhitespace = () => {
    while (i < text.length && (text[i] === ' ' || text[i] === '\t' || text[i] === '\n' || text[i] === '\r')) i += 1;
  };
  const expectLiteral = (literal: string) => {
    for (const char of literal) {
      if (text[i] !== char) fail();
      i += 1;
    }
  };
  const scanString = () => {
    i += 1;
    while (true) {
      if (i >= text.length) fail();
      const code = text.charCodeAt(i);
      if (code === 0x22) { i += 1; return; }
      if (code < 0x20) fail();
      if (code === 0x5c) {
        i += 1;
        const escape = text[i];
        if (escape === 'u') {
          i += 1;
          for (let n = 0; n < 4; n += 1) {
            if (!/[0-9a-fA-F]/.test(text[i] ?? '')) fail();
            i += 1;
          }
          continue;
        }
        if (escape === undefined || !'"\\/bfnrt'.includes(escape)) fail();
      }
      i += 1;
    }
  };
  const scanDigits = () => {
    const start = i;
    while (i < text.length && text[i]! >= '0' && text[i]! <= '9') i += 1;
    if (i === start) fail();
  };
  const scanNumber = () => {
    if (text[i] === '-') i += 1;
    if (text[i] === '0') i += 1;
    else scanDigits();
    if (text[i] === '.') { i += 1; scanDigits(); }
    if (text[i] === 'e' || text[i] === 'E') {
      i += 1;
      if (text[i] === '+' || text[i] === '-') i += 1;
      scanDigits();
    }
  };
  const scanValue = (): void => {
    skipWhitespace();
    const char = text[i];
    if (char === '{') {
      i += 1;
      skipWhitespace();
      if (text[i] === '}') { i += 1; return; }
      while (true) {
        skipWhitespace();
        if (text[i] !== '"') fail();
        scanString();
        skipWhitespace();
        if (text[i] !== ':') fail();
        i += 1;
        scanValue();
        skipWhitespace();
        if (text[i] === ',') { i += 1; continue; }
        if (text[i] === '}') { i += 1; return; }
        fail();
      }
    }
    if (char === '[') {
      i += 1;
      skipWhitespace();
      if (text[i] === ']') { i += 1; return; }
      while (true) {
        scanValue();
        skipWhitespace();
        if (text[i] === ',') { i += 1; continue; }
        if (text[i] === ']') { i += 1; return; }
        fail();
      }
    }
    if (char === '"') return scanString();
    if (char === '-' || (char !== undefined && char >= '0' && char <= '9')) return scanNumber();
    if (char === 't') return expectLiteral('true');
    if (char === 'f') return expectLiteral('false');
    if (char === 'n') return expectLiteral('null');
    fail();
  };
  try {
    scanValue();
    skipWhitespace();
    if (i < text.length) fail();
    return null;
  } catch (error) {
    if (error instanceof JsonScanStop) return error.offset;
    // Extremely deep nesting would blow the scan stack: do not invent a line number
    return null;
  }
}

class JsonScanStop {
  constructor(readonly offset: number) {}
}

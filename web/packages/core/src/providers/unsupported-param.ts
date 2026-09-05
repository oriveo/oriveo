import {
  resolveCapabilityEvidence,
  type CapabilityEvidenceCandidate,
  type CapabilityEvidenceQuery,
} from './capability-evidence-facade';

type RequestWithBody = {
  body: Record<string, unknown>;
};

export type UnsupportedParamExecutableRequest<T = unknown> = RequestWithBody & {
  fallback?: T;
};

export interface UnsupportedParamScope {
  partitionId?: string;
  connectionInstanceId?: string;
  connectionGeneration?: string;
  credentialEpoch?: string;
  providerKind?: string;
  modelID?: string;
  /** Two relay endpoints can expose different capabilities for the same model, so the fingerprint must partition the negative cache. */
  endpointFingerprint?: string;
  /**
   * The protocol transport the request actually used (`openai_chat_completions` /
   * `anthropic_messages` and so on), filled in by the caller from metadata it already holds. The
   * `transport` field on the telemetry allowlist accepts only this value; providerKind must never
   * stand in for it. Left empty when it cannot be resolved, and the reporter then sends `unknown`.
   */
  transport?: string;
  effectiveTransport?: string;
  metadataRevision?: string;
  generationRevision?: string;
}

/**
 * Connection-level identity required by the cross-request negative cache. Plain value object.
 *
 * Core cannot derive these itself - partition, connection and credential epoch live in the
 * renderer's local storage, and the two revisions are held by each client's metadata layer - so
 * the caller always injects them. With any part missing, `scopePrefix` stays fail-closed and
 * production requests will not drop parameters or retry off a legacy identity.
 */
export interface CapabilityLearningIdentity {
  partitionId: string;
  connectionInstanceId: string;
  connectionGeneration: string;
  credentialEpoch: string;
  metadataRevision: string;
  generationRevision: string;
}

export interface UnsupportedParamDroppedEvent {
  providerKind: string;
  modelID: string;
  param: string;
  endpointFingerprint?: string;
  /** See {@link UnsupportedParamScope.transport}; absent when it cannot be resolved. */
  transport?: string;
}

export type UnsupportedParamDroppedReporter = (event: UnsupportedParamDroppedEvent) => void;

/**
 * Cache admission API kept for older callers. Production execution does not reach it: nothing
 * scans an error body or retries silently any more.
 */
export type UnsupportedParamLearningOutcome =
  | 'stored_first'
  | 'already_cached'
  | 'ineligible';

export interface UnsupportedParamPatternDefinition {
  pattern: string;
  flags?: string;
  /**
   * Fixed parameter name, used as the rejected parameter when the pattern matches but carries no
   * capture group (or the group did not participate in the match).
   *
   * It exists because some upstream 400 bodies never name the parameter at all: as of 2026-08,
   * OpenAI Responses answers an unverified organization with `Your organization must be verified
   * to generate reasoning summaries`, which never contains the word `summary`, so no capture group
   * could extract it. When both are available the capture group wins, being more precise.
   */
  param?: string;
}

export interface ExecuteWithUnsupportedParamSelfHealOptions<
  T extends UnsupportedParamExecutableRequest<T>,
> {
  scope: UnsupportedParamScope;
  execute: (request: T) => Promise<Response>;
  shouldUseFallback?: (response: Response, request: T) => boolean;
  onUnsupportedParamDropped?: UnsupportedParamDroppedReporter;
  signal?: AbortSignal;
}

export interface ExecuteWithUnsupportedParamSelfHealResult<T> {
  response: Response;
  request: T;
  selfHeal?: {
    param: string;
  };
}

const UNSUPPORTED_PARAM_PATTERNS = [
  /does not support parameter ['"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/i,
  // OpenAI (o-series and Responses): "Unsupported parameter: 'temperature' is not supported with this model."
  // `\b` blocks the plural "unsupported parameters ..." catch-all so it cannot capture garbage.
  // "Unsupported value: 'xhigh'" carries no literal "parameter" and therefore never matches; that
  // is a value rejection, handled by the xhigh downgrade chain.
  /Unsupported parameter\b:?\s*['"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/i,
  /unrecognized request arguments? supplied:?\s*['"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/i,
  /unknown (?:parameter|field|argument):?\s*['"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/i,
  /unexpected (?:field|parameter):?\s*['"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/i,
  /Unknown name ['"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/i,
];

const UNSUPPORTED_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_UNSUPPORTED_CACHE_ENTRIES = 500;
const unsupportedParamCache = new Map<string, { param: string; updatedAt: number }>();

/** Incremental recognition layer shipped by the backend. `param` is the fixed fallback name for patterns without a capture group; baseline entries always leave it undefined. */
let runtimeUnsupportedParamPatterns: Array<{ regex: RegExp; param?: string }> = [];

/** Allowed shape of a fixed parameter name, using the same character set the backend enforces. */
const FIXED_PARAM_SHAPE = /^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*$/;

function sanitizeFixedParam(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim();
  if (!trimmed || trimmed.length > 64 || !FIXED_PARAM_SHAPE.test(trimmed)) return undefined;
  return trimmed;
}

export function setUnsupportedParamPatterns(patterns: UnsupportedParamPatternDefinition[]): void {
  runtimeUnsupportedParamPatterns = patterns.flatMap((item) => {
    if (!item.pattern || item.pattern.length > 200) return [];
    const flags = item.flags === 'i' ? 'i' : '';
    try {
      // A malformed param only drops the fixed name; the pattern itself stays in use with capture-group semantics.
      return [{ regex: new RegExp(item.pattern, flags), param: sanitizeFixedParam(item.param) }];
    } catch {
      return [];
    }
  });
}

export function extractUnsupportedParam(status: number, errorBody: string): string | null {
  if (status !== 400 || !errorBody) return null;
  const candidates = [
    ...UNSUPPORTED_PARAM_PATTERNS.map((regex) => ({ regex, param: undefined as string | undefined })),
    ...runtimeUnsupportedParamPatterns,
  ];
  // Name precedence: capture group over the shipped fixed name. The capture group is read out of
  // the actual body and is more precise; the fixed name is the only way out for those 400 bodies
  // that never name the parameter.
  for (const candidate of candidates) {
    const match = candidate.regex.exec(errorBody);
    if (!match) continue;
    if (match[1]) return canonicalParamName(match[1]);
    if (candidate.param) return canonicalParamName(candidate.param);
  }
  return null;
}

export function stripUnsupportedParam<T extends RequestWithBody>(req: T, param: string): T | null {
  const body = cloneRecord(req.body);
  let changed = false;
  const markChanged = (): void => {
    changed = true;
  };

  let result = stripPath(body, [param], markChanged);
  for (const path of candidateNestedPaths(param)) {
    result = stripPath(result, path, markChanged);
  }

  return changed ? { ...req, body: result } : null;
}

export function stripKnownUnsupportedParams<T extends RequestWithBody>(
  req: T,
  scope: UnsupportedParamScope,
): T {
  let current = req;
  for (const param of droppedUnsupportedParams(scope)) {
    current = stripUnsupportedParam(current, param) ?? current;
  }
  return current;
}

export async function executeWithUnsupportedParamSelfHeal<
  T extends UnsupportedParamExecutableRequest<T>,
>(
  req: T,
  options: ExecuteWithUnsupportedParamSelfHealOptions<T>,
): Promise<ExecuteWithUnsupportedParamSelfHealResult<T>> {
  const shouldUseFallback =
    options.shouldUseFallback ?? ((response: Response, request: T) => response.status === 404 && Boolean(request.fallback));
  // R3: never pre-strip a user setting from a prior opaque/body-text inference.
  // Reviewed structured capability rejection state is handled by the explicit
  // resend descriptor path, not by this legacy helper.
  let activeRequest = req;
  let response = await options.execute(activeRequest);

  if (!options.signal?.aborted && !response.ok && shouldUseFallback(response, activeRequest) && activeRequest.fallback) {
    activeRequest = activeRequest.fallback;
    response = await options.execute(activeRequest);
  }

  if (options.signal?.aborted || response.ok) {
    return { response, request: activeRequest };
  }

  const errorText = await response.text().catch(() => '');
  return { response: responseWithConsumedText(response, errorText), request: activeRequest };
}

export function markUnsupportedParamDropped(
  scope: UnsupportedParamScope,
  param: string,
  reporter?: UnsupportedParamDroppedReporter,
): UnsupportedParamLearningOutcome {
  const key = cacheKey(scope, param);
  if (!key) {
    reportUnsupportedParamDropped(scope, param, reporter);
    return 'ineligible';
  }
  pruneUnsupportedParamCache();
  const firstTime = !unsupportedParamCache.has(key);
  unsupportedParamCache.set(key, { param: canonicalParamName(param), updatedAt: Date.now() });
  if (unsupportedParamCache.size > MAX_UNSUPPORTED_CACHE_ENTRIES) {
    const oldest = [...unsupportedParamCache.entries()].sort((left, right) => left[1].updatedAt - right[1].updatedAt);
    for (const [oldestKey] of oldest.slice(0, unsupportedParamCache.size - MAX_UNSUPPORTED_CACHE_ENTRIES)) {
      unsupportedParamCache.delete(oldestKey);
    }
  }
  if (firstTime && reporter) reportUnsupportedParamDropped(scope, param, reporter);
  return firstTime ? 'stored_first' : 'already_cached';
}

/** Projects only a complete local negative-cache entry into the pure facade. */
export function runtimeUnsupportedParamEvidenceCandidates(
  scope: UnsupportedParamScope,
): CapabilityEvidenceCandidate[] {
  const prefix = scopePrefix(scope);
  const transport = resolvedScopeTransport(scope);
  if (!prefix || !transport) return [];
  pruneUnsupportedParamCache();
  return [...unsupportedParamCache.entries()].flatMap(([key, entry]) => {
    if (!key.startsWith(prefix)) return [];
    return [{
      key: `generation_parameter/${entry.param}`,
      support: 'unknown',
      source: 'runtime_observation',
      grade: 'observed',
      scope: 'exact_request',
      policy: 'runtime_rejected',
      partitionId: scope.partitionId,
      connectionInstanceId: scope.connectionInstanceId,
      connectionGeneration: scope.connectionGeneration,
      credentialEpoch: scope.credentialEpoch,
      endpointFingerprint: scope.endpointFingerprint,
      providerKind: scope.providerKind!,
      modelId: scope.modelID!,
      transport,
      metadataRevision: scope.metadataRevision,
      generationRevision: scope.generationRevision,
      observedAt: entry.updatedAt,
      expiresAt: entry.updatedAt + UNSUPPORTED_CACHE_TTL_MS,
    }];
  });
}

function reportUnsupportedParamDropped(
  scope: UnsupportedParamScope,
  param: string,
  reporter: UnsupportedParamDroppedReporter | undefined,
): void {
  if (!reporter || !scope.providerKind || !scope.modelID) return;
  reporter({
    providerKind: scope.providerKind,
    modelID: scope.providerKind === 'relay' ? 'custom' : scope.modelID,
    param: canonicalParamName(param),
    ...(scope.endpointFingerprint ? { endpointFingerprint: scope.endpointFingerprint } : {}),
    ...(scope.transport ? { transport: scope.transport } : {}),
  });
}

/**
 * The single normalization rule for the `transport` field in self-heal telemetry.
 *
 * Only a protocol transport literal is accepted; empty, overlong or malformed input returns
 * `'unknown'`. Callers must never pass providerKind: the reporting allowlist forbids reporting
 * provider kind, and passing it here is exactly how it once leaked into analytics.
 */
export function selfHealTelemetryTransport(raw: string | null | undefined): string {
  const value = raw?.trim().toLowerCase() ?? '';
  return /^[a-z][a-z0-9_]{0,63}$/.test(value) ? value : 'unknown';
}

export function droppedUnsupportedParams(scope: UnsupportedParamScope): string[] {
  const query = runtimeCapabilityEvidenceQuery(scope);
  const candidates = runtimeUnsupportedParamEvidenceCandidates(scope);
  if (!query || candidates.length === 0) return [];
  return candidates.flatMap((candidate) => {
    const decision = resolveCapabilityEvidence(candidate.key, query, candidates);
    if (decision.requestPolicy !== 'omit_runtime_rejected') return [];
    return [candidate.key.slice('generation_parameter/'.length)];
  });
}

/** User-requested reset: clears every entry learned for this connection + model, across all
 *  endpoint, transport and revision variants. The write threshold is unchanged (all 10 parts are
 *  still required), but clearing matches on the first 6 only - by the time the user taps "clear
 *  learned capabilities" the metadata ETag, the generation revision or even the endpoint may have
 *  drifted, and matching on the full identity would silently clear nothing.
 */
export function clearUnsupportedParamLearning(scope: UnsupportedParamScope): void {
  const prefix = connectionScopePrefix(scope);
  if (!prefix) return;
  for (const key of unsupportedParamCache.keys()) {
    if (key.startsWith(prefix)) unsupportedParamCache.delete(key);
  }
}

export function resetUnsupportedParamCacheForTesting(): void {
  unsupportedParamCache.clear();
  runtimeUnsupportedParamPatterns = [];
}

function stripPath(
  value: Record<string, unknown>,
  path: string[],
  onChange: () => void,
): Record<string, unknown> {
  if (path.length === 0) return value;
  const [head, ...rest] = path;
  const headNorm = normalizeParamSegment(head);
  const out: Record<string, unknown> = {};

  for (const [key, child] of Object.entries(value)) {
    if (normalizeParamSegment(key) !== headNorm) {
      out[key] = child;
      continue;
    }
    if (rest.length === 0) {
      onChange();
      continue;
    }
    if (isPlainObject(child)) {
      out[key] = stripPath(child, rest, onChange);
    } else {
      out[key] = child;
    }
  }
  return out;
}

function cloneRecord(value: Record<string, unknown>): Record<string, unknown> {
  return cloneJSONLike(value) as Record<string, unknown>;
}

function cloneJSONLike(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(cloneJSONLike);
  if (!isPlainObject(value)) return value;
  const out: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value)) {
    out[key] = cloneJSONLike(child);
  }
  return out;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function splitParamPath(param: string): string[] {
  if (param.includes('.')) {
    return param.split('.').filter(Boolean);
  }
  if (param.includes('_')) {
    return param.split('_').filter(Boolean);
  }
  return param.split(/(?<=[a-z0-9])(?=[A-Z])/).filter(Boolean);
}

/** Only known generation-parameter containers in the request protocol are inspected; never recurse into tools, JSON Schema or messages. */
function candidateNestedPaths(param: string): string[][] {
  const canonical = canonicalParamName(param);
  const explicit = param.includes('.') ? [param.split('.').filter(Boolean)] : [];
  const wordPath = splitParamPath(param);
  const paths = [...explicit];
  if (wordPath.length === 2 && ['reasoning', 'text', 'output', 'generation'].includes(wordPath[0])) {
    paths.push(wordPath);
  }
  const leafAliases = [canonical, snakeToCamel(canonical)];
  for (const wrapper of ['generationConfig', 'generation_config', 'extra_body', 'output_config']) {
    for (const leaf of leafAliases) paths.push([wrapper, leaf]);
  }
  if (canonical === 'thinking_config') {
    paths.push(['generationConfig', 'thinkingConfig'], ['generation_config', 'thinking_config']);
  }
  if (canonical === 'reasoning_effort' || canonical === 'effort') paths.push(['reasoning', 'effort']);
  return paths;
}

function snakeToCamel(value: string): string {
  return value.replace(/_([a-z0-9])/g, (_, next: string) => next.toUpperCase());
}

function normalizeParamSegment(name: string): string {
  return name.replace(/[_.]/g, '').toLowerCase();
}

function canonicalParamName(param: string): string {
  if (param.includes('.')) {
    return param
      .split('.')
      .filter(Boolean)
      .map((segment) => camelToSnake(segment))
      .join('.');
  }
  return camelToSnake(param);
}

function camelToSnake(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
}

function responseWithConsumedText(response: Response, text: string): Response {
  return new Response(text, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

function cacheKey(scope: UnsupportedParamScope, param: string): string | null {
  const prefix = scopePrefix(scope);
  return prefix ? `${prefix}${canonicalParamName(param)}` : null;
}

/**
 * The connection segment of the cache key (the first 6 parts). It is the source of truth for clear
 * granularity and is reused by {@link scopePrefix}; both need the same order and encoding, so
 * there is exactly one implementation and the field list is never duplicated.
 */
function connectionScopePrefix(scope: UnsupportedParamScope): string | null {
  if (
    !scope.partitionId || !scope.connectionInstanceId || !scope.connectionGeneration
    || !scope.credentialEpoch || !scope.providerKind || !scope.modelID
  ) return null;
  return [
    scope.partitionId,
    scope.connectionInstanceId,
    scope.connectionGeneration,
    scope.credentialEpoch,
    scope.providerKind,
    scope.modelID,
  ].map(encodeURIComponent).join('|') + '|';
}

function scopePrefix(scope: UnsupportedParamScope): string | null {
  const transport = resolvedScopeTransport(scope);
  const connection = connectionScopePrefix(scope);
  if (
    !connection || !transport
    || !scope.endpointFingerprint || !scope.metadataRevision || !scope.generationRevision
  ) return null;
  return connection + [
    transport,
    scope.endpointFingerprint,
    scope.metadataRevision,
    scope.generationRevision,
  ].map(encodeURIComponent).join('|') + '|';
}

function resolvedScopeTransport(scope: UnsupportedParamScope): string | undefined {
  if (scope.transport && scope.effectiveTransport && scope.transport !== scope.effectiveTransport) return undefined;
  return scope.effectiveTransport ?? scope.transport;
}

/** Builds the pure facade query only after the complete local cache gate passes. */
function runtimeCapabilityEvidenceQuery(
  scope: UnsupportedParamScope,
): CapabilityEvidenceQuery | null {
  const transport = resolvedScopeTransport(scope);
  if (!scopePrefix(scope) || !transport) return null;
  return {
    partitionId: scope.partitionId!,
    connectionInstanceId: scope.connectionInstanceId!,
    connectionGeneration: scope.connectionGeneration!,
    credentialEpoch: scope.credentialEpoch!,
    providerKind: scope.providerKind!,
    modelId: scope.modelID!,
    effectiveTransport: transport,
    endpointFingerprint: scope.endpointFingerprint,
    metadataRevision: scope.metadataRevision,
    generationRevision: scope.generationRevision,
    now: Date.now(),
    hasExplicitValue: true,
  };
}

function pruneUnsupportedParamCache(): void {
  const cutoff = Date.now() - UNSUPPORTED_CACHE_TTL_MS;
  for (const [key, value] of unsupportedParamCache) {
    if (value.updatedAt < cutoff) unsupportedParamCache.delete(key);
  }
}

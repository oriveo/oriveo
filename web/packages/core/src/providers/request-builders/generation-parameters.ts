import type {
  GenerationParameterOverride,
  GenerationParameterOverrides,
  GenerationParameterProfile,
  GenerationParameterValue,
} from './types';

type JsonObject = Record<string, unknown>;
type ValueOverride = Extract<GenerationParameterOverride<GenerationParameterValue>, { state: 'value' }>;

// Wire path hardening.
// Thresholds, enums and tiers remain fully authoritative from the server, but the wire is a write
// path: trust the semantics, not the shape. A structurally invalid wire drops that parameter and
// records a local diagnostic; it never throws, because malformed metadata must not stop a user
// from sending a message.
const WIRE_SEGMENT_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const BLOCKED_WIRE_SEGMENTS = new Set(['__proto__', 'prototype', 'constructor']);
const MAX_WIRE_SEGMENTS = 4;
/** Root fields owned by the builder: the request skeleton belongs to the builder and a wire may never overwrite it. */
export const BUILDER_OWNED_ROOT_FIELDS: ReadonlySet<string> = new Set([
  'model', 'messages', 'input', 'contents', 'prompt', 'attachments', 'instructions', 'system', 'stream', 'stream_options', 'tools', 'tool_choice', 'plugins',
]);

export type WireRejectionReason =
  | 'blocked_segment'
  | 'invalid_segment'
  | 'depth_exceeded'
  | 'owned_root_field';

export interface WireHardeningDiagnostic {
  parameterId: string;
  wirePath: string;
  reason: WireRejectionReason;
}

const DIAGNOSTIC_CAPACITY = 50;
const wireDiagnostics: WireHardeningDiagnostic[] = [];

/** Reason a wire path is rejected, or null when it is structurally valid. Checks run in the order defined by the shared contract. */
export function wireRejectionReason(wirePath: string): WireRejectionReason | null {
  const segments = wirePath.split('.');
  for (const segment of segments) {
    if (BLOCKED_WIRE_SEGMENTS.has(segment)) return 'blocked_segment';
    if (!WIRE_SEGMENT_PATTERN.test(segment)) return 'invalid_segment';
  }
  if (segments.length > MAX_WIRE_SEGMENTS) return 'depth_exceeded';
  if (BUILDER_OWNED_ROOT_FIELDS.has(segments[0])) return 'owned_root_field';
  return null;
}

/** Local diagnostics (never reported, never shown in the UI): evidence that "set in the panel but not on the wire" is not a random dropped parameter. */
export function readWireHardeningDiagnostics(): readonly WireHardeningDiagnostic[] {
  return wireDiagnostics;
}

export function clearWireHardeningDiagnostics(): void {
  wireDiagnostics.length = 0;
}

function recordWireRejection(parameterId: string, wirePath: string, reason: WireRejectionReason): void {
  wireDiagnostics.push({ parameterId, wirePath, reason });
  if (wireDiagnostics.length > DIAGNOSTIC_CAPACITY) wireDiagnostics.shift();
}

/** Deduplicated variant: profile resolution runs on every render, so one malformed delivery leaves a single diagnostic. */
export function recordWireRejectionOnce(parameterId: string, wirePath: string, reason: WireRejectionReason): void {
  const seen = wireDiagnostics.some((item) =>
    item.parameterId === parameterId && item.wirePath === wirePath && item.reason === reason);
  if (!seen) recordWireRejection(parameterId, wirePath, reason);
}

/**
 * Keep only the parameter ids declared in the local constant table on a synthesized relay profile
 * wire, and run each through structural hardening. A relay catalog comes from the user's own
 * machine, so key/value pairs appearing in an upstream response must never become a write path.
 */
export function restrictWireToDeclaredParameters<
  T extends { wire: Record<string, string>; parameters: Array<{ id?: string }> },
>(profile: T): T {
  const declared = new Set(
    profile.parameters.map((parameter) => parameter.id).filter((id): id is string => Boolean(id)),
  );
  const wire: Record<string, string> = {};
  for (const [id, path] of Object.entries(profile.wire)) {
    if (!declared.has(id)) continue;
    const rejection = wireRejectionReason(path);
    if (rejection) {
      recordWireRejection(id, path, rejection);
      continue;
    }
    wire[id] = path;
  }
  return { ...profile, wire };
}

export type GenerationDropReason =
  | 'invalid_value'
  | 'conflict'
  | 'requirement_unmet'
  | 'required_field'
  | 'thinking_incompatible'
  | 'thinking_budget';

export interface DroppedGenerationParameter {
  parameterId: string;
  reason: GenerationDropReason;
}

export interface GenerationParameterWriteResult {
  dropped: DroppedGenerationParameter[];
  written: string[];
}

/** Wire fields the upstream requires, which "do not send" cannot delete. */
export const REQUIRED_WIRE_FIELDS: Readonly<Record<string, readonly string[]>> = {
  anthropic_messages: ['max_tokens'],
};
/** Keys the builder writes into the request that take part in conflict resolution. */
const BUILDER_PRESENCE_KEYS = ['tools'] as const;

/**
 * Per-parameter outbound decision: an invalid parameter drops only itself, conflicts resolve in the
 * profile's declaration order, an unmet requirement drops only the dependent parameter, and
 * everything else is written. Returns the list of dropped parameters. Parameter problems no longer
 * throw: a thrown error surfaces from the route as a provider failure, which shows the user the
 * wrong cause and loses the remaining parameters as well. A parameter whose wire fails structural
 * hardening is still skipped silently (local diagnostic only, not in the list).
 */
export function writeGenerationParameters(
  body: JsonObject,
  overrides: GenerationParameterOverrides | undefined,
  profile: GenerationParameterProfile | undefined,
  options: { toolsActive?: boolean } = {},
): GenerationParameterWriteResult {
  const dropped: DroppedGenerationParameter[] = [];
  const written: string[] = [];
  if (!profile?.template) return { dropped, written };
  // Alias normalization ignores overrides: a default the builder wrote under the other name must
  // also move over when the parameter is left to inherit.
  normalizeMaxTokensAlias(body, profile.wire.max_output_tokens);
  if (!overrides) return { dropped, written };
  const template = profile.template;

  // Candidates follow the profile's declaration order, which decides who is accepted first when
  // conflicts are resolved.
  const candidates = profile.parameters.flatMap((parameter) => {
    const override = overrides[parameter.id];
    const wirePath = profile.wire[parameter.id];
    if (!override || override.state === 'inherit' || !wirePath) return [];
    const rejection = wireRejectionReason(wirePath);
    if (rejection) {
      recordWireRejection(parameter.id, wirePath, rejection);
      return [];
    }
    return [{ key: parameter.id, override, parameter, wirePath }];
  });

  const presentKeys = new Set<string>(
    BUILDER_PRESENCE_KEYS.filter((key) => key === 'tools' ? options.toolsActive || isPresent(body[key]) : isPresent(body[key])),
  );
  const accepted: Array<(typeof candidates)[number] & { override: ValueOverride }> = [];
  for (const candidate of candidates) {
    if (candidate.override.state !== 'value') continue;
    if (!isValidValue(candidate.override.value, candidate.parameter)) {
      dropped.push({ parameterId: candidate.key, reason: 'invalid_value' });
      continue;
    }
    const ownConflicts = candidate.parameter.conflictsWith ?? [];
    const conflicted = ownConflicts.some((key) => presentKeys.has(key))
      || accepted.some((peer) => ownConflicts.includes(peer.key) || (peer.parameter.conflictsWith ?? []).includes(candidate.key));
    if (conflicted) {
      dropped.push({ parameterId: candidate.key, reason: 'conflict' });
      continue;
    }
    accepted.push(candidate as (typeof accepted)[number]);
  }
  const activeValues = new Map(accepted.map((item) => [item.key, item.override.value]));
  const requirementUnmet = new Set(accepted.filter((item) => (item.parameter.requires ?? []).some((requirement) => {
    const key = typeof requirement.key === 'string' ? requirement.key : undefined;
    return !key || !activeValues.has(key) || ('value' in requirement && activeValues.get(key) !== requirement.value);
  })).map((item) => item.key));

  const requiredWires = REQUIRED_WIRE_FIELDS[template] ?? [];
  for (const candidate of candidates) {
    if (candidate.override.state === 'omit') {
      if (requiredWires.includes(candidate.wirePath)) {
        dropped.push({ parameterId: candidate.key, reason: 'required_field' });
        continue;
      }
      deleteAtPath(body, candidate.wirePath);
      continue;
    }
    if (!activeValues.has(candidate.key)) continue;
    if (requirementUnmet.has(candidate.key)) {
      dropped.push({ parameterId: candidate.key, reason: 'requirement_unmet' });
      continue;
    }
    setGenerationValue(body, candidate.key, candidate.wirePath, activeValues.get(candidate.key)!, template, candidate.parameter.strict === true);
    written.push(candidate.key);
  }
  return { dropped: mergeDroppedGenerationParameters(dropped), written };
}

/** The two names of one upstream field: a request body may carry only one of them. */
const MAX_TOKENS_ALIASES = ['max_tokens', 'max_completion_tokens'] as const;

function normalizeMaxTokensAlias(body: JsonObject, wirePath: string | undefined): void {
  if (wirePath !== 'max_tokens' && wirePath !== 'max_completion_tokens') return;
  const other = MAX_TOKENS_ALIASES.find((name) => name !== wirePath)!;
  if (!(other in body)) return;
  // The value is unchanged and not counted as dropped; a value already on the resolved path wins.
  if (!(wirePath in body)) body[wirePath] = body[other];
  delete body[other];
}

/** Merge several dropped-parameter lists, ordered by parameterId code point. */
export function mergeDroppedGenerationParameters(
  ...lists: ReadonlyArray<readonly DroppedGenerationParameter[]>
): DroppedGenerationParameter[] {
  return lists.flat().sort((a, b) => (a.parameterId < b.parameterId ? -1 : a.parameterId > b.parameterId ? 1 : 0));
}

/**
 * Legacy entry point: the signature is unchanged and it delegates to the per-parameter writer.
 * Callers that need the dropped list use `writeGenerationParameters` instead. The numeric value 0
 * is a valid explicit value and is never treated as missing.
 */
export function applyGenerationParameters(
  body: JsonObject,
  overrides: GenerationParameterOverrides | undefined,
  profile: GenerationParameterProfile | undefined,
  options: { toolsActive?: boolean } = {},
): void {
  writeGenerationParameters(body, overrides, profile, options);
}

function isPresent(value: unknown): boolean {
  return Array.isArray(value) ? value.length > 0 : value !== undefined && value !== null;
}

function isValidValue(
  value: GenerationParameterValue | undefined,
  parameter: GenerationParameterProfile['parameters'][number],
): value is GenerationParameterValue {
  if (value === undefined || value === null) return false;
  try {
    assertValidValue(parameter.id, value, parameter);
    // response_format values are only recognized at encoding time, so reject them here to avoid throwing during the write.
    if (parameter.id === 'response_format' && value !== 'text' && value !== 'json') return false;
    if (parameter.id === 'json_schema') validateJSONSchema(value);
  } catch {
    return false;
  }
  return true;
}

/** A JSON Schema is an output contract: only the schema itself is validated, and it must never become a channel for overriding the request body. */
export function validateJSONSchema(value: unknown): asserts value is Record<string, unknown> {
  if (!isPlainObject(value)) throw new TypeError('json_schema must be a JSON object');
  const serialized = JSON.stringify(value);
  if (serialized.length > 64 * 1024) throw new RangeError('json_schema exceeds 64 KiB');
  validateSchemaNode(value, 0);
}

function validateSchemaNode(node: JsonObject, depth: number): void {
  if (depth > 32) throw new RangeError('json_schema exceeds the nesting limit');
  if ('$schema' in node && typeof node.$schema !== 'string') throw new TypeError('json_schema.$schema must be a string');
  if ('type' in node) {
    const valid = typeof node.type === 'string'
      || (Array.isArray(node.type) && node.type.every((entry) => typeof entry === 'string'));
    if (!valid) throw new TypeError('json_schema.type must be a string or string list');
  }
  if ('required' in node && (!Array.isArray(node.required) || !node.required.every((entry) => typeof entry === 'string'))) {
    throw new TypeError('json_schema.required must be a string list');
  }
  if ('properties' in node && !isPlainObject(node.properties)) throw new TypeError('json_schema.properties must be an object');
  for (const key of ['properties', '$defs', 'definitions', 'patternProperties'] as const) {
    const values = node[key];
    if (!isPlainObject(values)) continue;
    for (const child of Object.values(values)) {
      if (!isPlainObject(child)) throw new TypeError(`json_schema.${key} entries must be objects`);
      validateSchemaNode(child, depth + 1);
    }
  }
  for (const key of ['items', 'additionalProperties', 'contains', 'not', 'if', 'then', 'else'] as const) {
    const child = node[key];
    if (child === undefined || typeof child === 'boolean') continue;
    if (!isPlainObject(child)) throw new TypeError(`json_schema.${key} must be an object or boolean`);
    validateSchemaNode(child, depth + 1);
  }
  for (const key of ['allOf', 'anyOf', 'oneOf', 'prefixItems'] as const) {
    const children = node[key];
    if (children === undefined) continue;
    if (!Array.isArray(children) || !children.every(isPlainObject)) throw new TypeError(`json_schema.${key} must be an object list`);
    children.forEach((child) => validateSchemaNode(child, depth + 1));
  }
}

function isPlainObject(value: unknown): value is JsonObject {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function setGenerationValue(
  body: JsonObject,
  key: string,
  wirePath: string,
  value: GenerationParameterValue,
  template: string,
  strict = false,
): void {
  if (key === 'json_schema') {
    validateJSONSchema(value);
    const name = typeof value.title === 'string' && value.title.trim() ? value.title.trim() : 'oriveo_response';
    // strict is written only when the parameter is delivered with true; by default the key is omitted.
    const strictField = strict ? { strict: true } : {};
    if (template === 'openai_chat_completions' || template === 'vllm_extra_body') {
      setAtPath(body, wirePath, { type: 'json_schema', json_schema: { name, ...strictField, schema: value } });
      return;
    }
    if (template === 'openai_responses') {
      setAtPath(body, wirePath, { type: 'json_schema', name, ...strictField, schema: value });
      return;
    }
    if (template === 'anthropic_messages') {
      setAtPath(body, wirePath, { type: 'json_schema', schema: value });
      return;
    }
    setAtPath(body, wirePath, value);
    if (template === 'gemini_generate_content') setAtPath(body, 'generationConfig.responseMimeType', 'application/json');
    return;
  }
  if (key === 'response_format') {
    if (value === 'text') {
      deleteAtPath(body, wirePath);
      if (template === 'gemini_generate_content') deleteAtPath(body, 'generationConfig.responseJsonSchema');
      return;
    }
    if (value !== 'json') throw new RangeError('response_format must be text or json');
    const encoded = template === 'gemini_generate_content'
      ? 'application/json'
      : { type: 'json_object' };
    setAtPath(body, wirePath, encoded);
    return;
  }
  setAtPath(body, wirePath, value);
}

export function credentialHeader(name: string, value: string): Record<string, string> {
  const credential = value.trim();
  return credential ? { [name]: credential } : {};
}

function assertValidValue(
  key: string,
  value: GenerationParameterValue,
  parameter: GenerationParameterProfile['parameters'][number] | undefined,
): void {
  const schema = parameter?.valueSchema;
  const numeric = typeof value === 'number';
  if (numeric && !Number.isFinite(value)) throw new TypeError(`${key} must be a finite number`);
  if (schema === 'number' && !numeric) throw new TypeError(`${key} must be a number`);
  if (schema === 'integer' && (!numeric || !Number.isInteger(value))) {
    throw new TypeError(`${key} must be an integer`);
  }
  if (schema === 'string-list' && (!Array.isArray(value) || !value.every((item) => typeof item === 'string'))) {
    throw new TypeError(`${key} must be a string list`);
  }
  if (schema === 'boolean' && typeof value !== 'boolean') throw new TypeError(`${key} must be a boolean`);
  if (schema === 'json-schema') validateJSONSchema(value);
  if (schema === 'enum' && typeof value !== 'string') throw new TypeError(`${key} must be an enum value`);
  if (parameter?.enumValues?.length && !parameter.enumValues.includes(value as string | number)) {
    throw new RangeError(`${key} must use a value declared by the profile`);
  }
  if (numeric && parameter?.range) {
    if (parameter.range.min != null && value < parameter.range.min) {
      throw new RangeError(`${key} must be at least ${parameter.range.min}`);
    }
    if (parameter.range.max != null && value > parameter.range.max) {
      throw new RangeError(`${key} must be at most ${parameter.range.max}`);
    }
    if (parameter.range.minExclusive != null && value <= parameter.range.minExclusive) {
      throw new RangeError(`${key} must be greater than ${parameter.range.minExclusive}`);
    }
    if (parameter.range.maxExclusive != null && value >= parameter.range.maxExclusive) {
      throw new RangeError(`${key} must be less than ${parameter.range.maxExclusive}`);
    }
  }
}

function setAtPath(body: JsonObject, path: string, value: unknown): void {
  const segments = path.split('.');
  const last = segments.pop();
  if (!last) return;
  let target = body;
  for (const segment of segments) {
    const current = target[segment];
    if (current && typeof current === 'object' && !Array.isArray(current)) {
      target = current as JsonObject;
      continue;
    }
    const nested: JsonObject = {};
    target[segment] = nested;
    target = nested;
  }
  target[last] = value;
}

function deleteAtPath(body: JsonObject, path: string): void {
  const segments = path.split('.');
  const last = segments.pop();
  if (!last) return;
  let target: JsonObject | undefined = body;
  for (const segment of segments) {
    const current = target?.[segment];
    if (!current || typeof current !== 'object' || Array.isArray(current)) return;
    target = current as JsonObject;
  }
  delete target?.[last];
}

/**
 * Safe custom is limited to leaf wires declared by the current generation template. Recipe
 * paths win: a parent/child overlap is rejected by omitting that custom path from the schema.
 *
 * This lives in the leaf module rather than in `dispatch` because the relay orchestration layer
 * needs the same writable-leaf decision: the only authority for relay custom fields is the exact
 * local transport profile, and importing `dispatch` from there would pull the whole builder graph
 * into the bundle.
 */
export function safeCustomOwners(
  generationProfile: GenerationParameterProfile | null | undefined,
): Record<string, 'generation'> {
  return Object.fromEntries(Object.entries(safeCustomDeclaredOwners(generationProfile))
    .filter((entry): entry is [string, 'generation'] => entry[1] === 'generation'));
}

export function safeCustomDeclaredOwners(
  generationProfile: GenerationParameterProfile | null | undefined,
): Record<string, 'web' | 'reasoning' | 'generation'> {
  const generationPointers = generationProfile ? Object.values(generationProfile.wire)
    .filter((wire): wire is string => typeof wire === 'string' && wireRejectionReason(wire) == null)
    .map((wire) => `/${wire.split('.').map(escapeSafeCustomPointer).join('/')}`)
    .map((pointer) => [pointer, 'generation'] as const) : [];
  return Object.fromEntries(generationPointers);
}

function escapeSafeCustomPointer(value: string): string {
  return value.replace(/~/g, '~0').replace(/\//g, '~1');
}

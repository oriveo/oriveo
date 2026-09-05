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
const BUILDER_OWNED_ROOT_FIELDS = new Set([
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

/**
 * Write parameter intents already decided by the app facade into the production body. Raw support
 * and relay flags are not reinterpreted here: the only outbound decision is
 * `resolveGenerationParameterEvidence(...).requestPolicy`, and this writer only hardens wire,
 * conflicts, dependencies and ranges. The numeric value 0 is a valid explicit value and is never
 * treated as missing.
 */
export function applyGenerationParameters(
  body: JsonObject,
  overrides: GenerationParameterOverrides | undefined,
  profile: GenerationParameterProfile | undefined,
  options: { toolsActive?: boolean } = {},
): void {
  if (!overrides) return;

  // Conflict, requires and range checks may only look at the set that will really go out. The app
  // has already filtered overrides by the facade requestPolicy; candidates here are formed purely
  // from wire presence plus structural hardening, otherwise malformed metadata would throw a
  // RangeError before being discarded and block the whole chat request.
  const outboundCandidates = Object.entries(overrides).flatMap(([key, override]) => {
    if (!override || override.state === 'inherit') return [];
    const parameter = profile?.parameters.find((item) => item.id === key);
    const wirePath = profile?.wire[key];
    const template = profile?.template;
    if (!parameter || !wirePath || !template) return [];
    const rejection = wireRejectionReason(wirePath);
    if (rejection) {
      recordWireRejection(key, wirePath, rejection);
      return [];
    }
    return [{ key, override, parameter, wirePath, template }];
  });
  const values: Array<[string, ValueOverride]> = outboundCandidates.flatMap((candidate) =>
    candidate.override.state === 'value' ? [[candidate.key, candidate.override]] : []);
  const activeKeys = values.map(([key]) => key);
  if (options.toolsActive) activeKeys.push('tools');
  assertNoActiveConflicts(activeKeys, profile);
  assertRequirements(values, profile);

  for (const { key, override, parameter, wirePath, template } of outboundCandidates) {
    if (override.state === 'omit') {
      deleteAtPath(body, wirePath);
      continue;
    }
    assertValidValue(key, override.value, parameter);
    setGenerationValue(body, key, wirePath, override.value, template);
  }
}

function assertRequirements(
  values: Array<[string, ValueOverride]>,
  profile: GenerationParameterProfile | undefined,
): void {
  const active = new Map(values.map(([key, override]) => [key, override.value]));
  for (const parameter of profile?.parameters ?? []) {
    if (!active.has(parameter.id)) continue;
    for (const requirement of parameter.requires ?? []) {
      const key = typeof requirement.key === 'string' ? requirement.key : undefined;
      if (!key || !active.has(key) || ('value' in requirement && active.get(key) !== requirement.value)) {
        throw new RangeError(`${parameter.id} requires ${key ?? 'a profile dependency'}`);
      }
    }
  }
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
): void {
  if (key === 'json_schema') {
    validateJSONSchema(value);
    const name = typeof value.title === 'string' && value.title.trim() ? value.title.trim() : 'oriveo_response';
    if (template === 'openai_chat_completions' || template === 'vllm_extra_body') {
      setAtPath(body, wirePath, { type: 'json_schema', json_schema: { name, strict: true, schema: value } });
      return;
    }
    if (template === 'openai_responses') {
      setAtPath(body, wirePath, { type: 'json_schema', name, strict: true, schema: value });
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

function assertNoActiveConflicts(keys: string[], profile: GenerationParameterProfile | undefined): void {
  const active = new Set(keys);
  for (const parameter of profile?.parameters ?? []) {
    if (!active.has(parameter.id)) continue;
    const conflict = parameter.conflictsWith?.find((key) => active.has(key));
    if (conflict) {
      throw new RangeError(`${parameter.id} conflicts with ${conflict}`);
    }
  }
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

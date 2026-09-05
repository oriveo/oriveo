import type {
  GenerationParameterOverrides,
  GenerationParameterProfile,
  GenerationParameterValue,
} from './request-builders/types';
import { validateJSONSchema } from './request-builders/generation-parameters';

export interface CustomGenerationParameterDefinition {
  id: string;
  valueSchema: 'number' | 'integer' | 'enum' | 'string' | 'boolean' | 'string-list';
  min?: number;
  max?: number;
  enumValues?: Array<string | number>;
  wire: string;
}

const RESERVED_ROOT_KEYS = new Set([
  'model', 'messages', 'input', 'system', 'instructions', 'tools', 'tool_choice', 'stream',
]);
const SENSITIVE_TOKENS = ['auth', 'authorization', 'api_key', 'apikey', 'access_token', 'bearer', 'secret', 'password', 'credential', 'header', 'query', 'url', 'endpoint', 'host'];
const CUSTOM_ID = /^[a-z][a-z0-9_]{0,63}$/;

/** Relay custom parameters accept only the restricted structured definition, never a raw JSON body override. */
export function validateCustomGenerationParameter(
  definition: CustomGenerationParameterDefinition,
): CustomGenerationParameterDefinition {
  const id = definition.id.trim().toLowerCase();
  if (!CUSTOM_ID.test(id)) throw new TypeError('Custom parameter keys must use lower snake_case');
  assertSafeKey(id);
  const wire = definition.wire.trim();
  const allowedWire = wire === id || wire === `extra_body.${id}`;
  if (!allowedWire) throw new TypeError('Custom parameter wire paths may only be top-level or extra_body');
  wire.split('.').forEach(assertSafeKey);
  if (definition.min != null && definition.max != null && definition.min > definition.max) {
    throw new RangeError('Custom parameter min must not exceed max');
  }
  if (definition.valueSchema === 'enum' && !definition.enumValues?.length) {
    throw new TypeError('Custom enum parameters require declared values');
  }
  return { ...definition, id: `custom.${id}`, wire };
}

function assertSafeKey(key: string): void {
  const normalized = key.toLowerCase();
  if (RESERVED_ROOT_KEYS.has(normalized) || SENSITIVE_TOKENS.some((token) => normalized.includes(token))) {
    throw new TypeError(`Reserved or sensitive parameter key: ${key}`);
  }
}

export interface GenerationCompatibilityIssue {
  key: string;
  kind: 'conflict' | 'requires' | 'rendering' | 'streaming';
  conflictsWith?: string;
}

export function previewGenerationCompatibility(input: {
  profile: GenerationParameterProfile;
  overrides: GenerationParameterOverrides;
  toolsActive?: boolean;
  streaming?: boolean;
}): GenerationCompatibilityIssue[] {
  const active = new Set(Object.entries(input.overrides)
    .filter(([, value]) => value?.state === 'value')
    .map(([key]) => key));
  if (input.toolsActive) active.add('tools');
  const issues: GenerationCompatibilityIssue[] = [];
  for (const parameter of input.profile.parameters) {
    if (!active.has(parameter.id)) continue;
    for (const conflict of parameter.conflictsWith ?? []) {
      if (active.has(conflict)) issues.push({ key: parameter.id, kind: 'conflict', conflictsWith: conflict });
    }
    for (const requirement of parameter.requires ?? []) {
      const requiredKey = typeof requirement.key === 'string' ? requirement.key : undefined;
      if (requiredKey && !active.has(requiredKey)) issues.push({ key: parameter.id, kind: 'requires', conflictsWith: requiredKey });
    }
  }
  if (active.has('json_schema') || active.has('response_format')) {
    issues.push({ key: active.has('json_schema') ? 'json_schema' : 'response_format', kind: 'rendering' });
    if (input.streaming) issues.push({ key: active.has('json_schema') ? 'json_schema' : 'response_format', kind: 'streaming' });
  }
  return dedupeIssues(issues);
}

export function removeGenerationConflicts(
  overrides: GenerationParameterOverrides,
  issues: GenerationCompatibilityIssue[],
): GenerationParameterOverrides {
  const next = { ...overrides };
  for (const issue of issues) {
    if (issue.kind === 'conflict' || issue.kind === 'requires') delete next[issue.key];
  }
  return next;
}

export function validateOutputContractValue(key: string, value: GenerationParameterValue): void {
  if (key === 'json_schema') validateJSONSchema(value);
  if (key === 'response_format' && value !== 'text' && value !== 'json') {
    throw new RangeError('response_format must be text or json');
  }
}

function dedupeIssues(issues: GenerationCompatibilityIssue[]): GenerationCompatibilityIssue[] {
  const seen = new Set<string>();
  return issues.filter((issue) => {
    const key = `${issue.key}|${issue.kind}|${issue.conflictsWith ?? ''}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

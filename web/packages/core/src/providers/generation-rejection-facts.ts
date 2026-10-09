import { validateAdditionalBody } from './request-builders/additional-body';
import { writeGenerationParameters } from './request-builders/generation-parameters';
import type { StreamOptions } from './types';

/**
 * Structured fields in an upstream error body that can be used for exact location (the shape of
 * `locator.errorFields` in the shared contract's resolverCases). It is a closed list: only the raw
 * field value counts, and parameter names are never searched for in prose such as the message.
 */
const LOCATOR_ERROR_FIELDS: ReadonlyArray<{ pointer: string; path: readonly string[] }> = [
  { pointer: '/error/param', path: ['error', 'param'] },
];
const FIELD_VALUE_PATTERN = /^[A-Za-z_][A-Za-z0-9_.]{0,79}$/;

export function structuredErrorFields(text: string): Record<string, string> | undefined {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { return undefined; }
  const fields: Record<string, string> = {};
  for (const { pointer, path } of LOCATOR_ERROR_FIELDS) {
    let current: unknown = parsed;
    for (const segment of path) {
      current = current && typeof current === 'object' && !Array.isArray(current)
        ? (current as Record<string, unknown>)[segment]
        : undefined;
    }
    if (typeof current === 'string' && FIELD_VALUE_PATTERN.test(current)) fields[pointer] = current;
  }
  return Object.keys(fields).length > 0 ? fields : undefined;
}

export interface GenerationWriteFacts {
  /** Ids of the parameters whose panel value actually reached the wire in this request. */
  written: string[];
  /** Parameter id -> wire path (from the same profile). */
  wire: Record<string, string>;
}

/**
 * Send-path facts: the outbound options go through the same `writeGenerationParameters` the outbound
 * path uses to compute `written` (the same approach as `additionalBodyHasContent` deciding "really
 * sent": one decision function and one input, never the stored state).
 * A value on the wire that the panel did not write does not count: when the additional body sets a
 * root field of the same name (it is the last step of the body and wins on name clashes) that item
 * is removed; with a custom fragment that carries generation parameters nothing counts (a fragment
 * can rewrite any declared field).
 */
export function generationWriteFacts(options: StreamOptions | undefined): GenerationWriteFacts {
  const profile = options?.generationProfile;
  if (!profile || !options?.generationParameters) return { written: [], wire: {} };
  if (options.customFragment || options.customFragments?.generation) return { written: [], wire: {} };
  const { written } = writeGenerationParameters({}, options.generationParameters, profile);
  const additional = options.additionalBody ? validateAdditionalBody(options.additionalBody.raw) : null;
  const overriddenRoots = new Set(additional?.accepted ? Object.keys(additional.value ?? {}) : []);
  const wire: Record<string, string> = {};
  const effective = written.filter((id) => {
    const path = profile.wire[id];
    if (!path || overriddenRoots.has(path.split('.')[0])) return false;
    wire[id] = path;
    return true;
  });
  return { written: effective, wire };
}

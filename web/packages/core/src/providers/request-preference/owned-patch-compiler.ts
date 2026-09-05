import { validateAssignments, type OwnerAssignment } from './preference-resolution';
import { validateOverlay, type OverlayIntent, type OverlayOperation } from './safe-overlay';
import type { OwnerId } from './types';

export interface CompiledContribution { owner: OwnerId; target: 'tools' | 'plugins'; operation: string; identity: string; value: unknown }
export type CompileResult = { accepted: true; delta: Record<string, unknown>; preview: Record<string, unknown> } | { accepted: false; reason: string };

/** Transport-neutral P3a compiler. Provider builders consume its delta in P3b. */
export function compileOwnedPatches(
  overlay: OverlayIntent,
  conflicts: readonly (readonly [string, string])[],
  base: Readonly<Record<string, unknown>>,
  contributions: readonly CompiledContribution[],
): CompileResult {
  const overlayResult = validateOverlay(overlay);
  if (!overlayResult.accepted) return { accepted: false, reason: overlayResult.reason ?? 'invalid_overlay' };
  const assignments: OwnerAssignment[] = overlay.operations.map(({ owner, pointer }) => ({ owner, pointer }));
  const assignmentResult = validateAssignments(assignments, conflicts);
  if (!assignmentResult.accepted) return { accepted: false, reason: assignmentResult.reason! };
  const delta: Record<string, unknown> = {};
  const normalized = [...contributions];
  try { for (const operation of overlay.operations) {
    if (operation.op === 'upsert_owned_element') {
      const parsed = normalizeUpsert(operation);
      if (!parsed) return { accepted: false, reason: 'invalid_typed_contribution' };
      normalized.push(parsed);
    } else applyOperation(delta, operation);
  } } catch (error) { return { accepted: false, reason: error instanceof Error ? error.message : 'pointer_parent_conflict' }; }
  for (const target of ['tools', 'plugins'] as const) {
    const targetContributions = normalized.filter((item) => item.target === target);
    if (targetContributions.length === 0) continue;
    const values = Array.isArray(base[target]) ? [...base[target] as unknown[]] : [];
    const seen = new Set(values.map(identity));
    for (const contribution of targetContributions) {
      if (contribution.operation !== 'append_owned') return { accepted: false, reason: 'non_append_operation' };
      if (contribution.owner !== 'web' || seen.has(contribution.identity)) return { accepted: false, reason: contribution.owner !== 'web' ? 'owner_not_allowed' : 'duplicate_identity' };
      seen.add(contribution.identity); values.push(contribution.value);
    }
    if (values.length !== (base[target] as unknown[] | undefined)?.length) delta[target] = values;
  }
  return { accepted: true, delta, preview: redact(delta) };
}

function applyOperation(target: Record<string, unknown>, operation: OverlayOperation) {
  if (operation.op === 'omit') return;
  const segments = operation.pointer.slice(1).split('/');
  let cursor = target;
  for (const segment of segments.slice(0, -1)) {
    const existing = cursor[segment];
    if (existing != null && (typeof existing !== 'object' || Array.isArray(existing))) throw new Error('pointer_parent_conflict');
    cursor = (existing as Record<string, unknown> | undefined) ?? (cursor[segment] = {} as Record<string, unknown>) as Record<string, unknown>;
  }
  cursor[segments.at(-1)!] = operation.value;
}
function normalizeUpsert(operation: OverlayOperation): CompiledContribution | null {
  const target = operation.pointer.slice(1);
  if ((target !== 'tools' && target !== 'plugins') || !operation.value || typeof operation.value !== 'object' || Array.isArray(operation.value)) return null;
  const value = operation.value as Record<string, unknown>;
  return typeof value.identity === 'string' && 'value' in value
    ? { owner: operation.owner, target, operation: 'append_owned', identity: value.identity, value: value.value }
    : null;
}
function identity(value: unknown) { return stableJson(value); }
function stableJson(value: unknown): string {
  if (value == null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  return `{${Object.keys(value as Record<string, unknown>).sort().map((key) => `${JSON.stringify(key)}:${stableJson((value as Record<string, unknown>)[key])}`).join(',')}}`;
}
const REDACTED = new Set(['api_key', 'authorization', 'prompt', 'messages', 'attachments', 'full_endpoint', 'response', 'raw_custom_fragment']);
function redact(value: unknown): any {
  if (Array.isArray(value)) return value.map(redact);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, item]) => [key, REDACTED.has(key.toLowerCase()) ? '[REDACTED]' : redact(item)]));
}

/**
 * Request preference resolution: layer resolution, selection policy and conflict rules.
 *
 * Covers three groups of semantics:
 * - resolveLayers: inherit passes through while omit and value terminate, across the seven scope
 *   levels (a numeric 0 is an explicit value).
 * - resolveSelection: preset requires an official server recipe, and a managed_only recipe can only
 *   be selected by a managed identity; custom requires a BYOK/Relay developer identity and an
 *   availability that permits custom fragments.
 * - validateAssignments: a duplicate pointer for the same scope and owner is rejected, two owners
 *   colliding on one pointer is rejected, and semantic conflicts declared by the recipe are
 *   rejected. lastWriteWins is always false.
 */

import { SCOPE_PRIORITY, type ConnectionAccess, type ControlAvailability, type OwnerId, type ScopeId, type ValueMode } from './types';

export interface ScopeOverride {
  state: 'inherit' | 'value' | 'omit';
  /** Required in the value state, including a numeric 0; not read for inherit/omit. */
  value?: unknown;
}

export interface ScopeLayer {
  scope: ScopeId;
  override: ScopeOverride;
}

export type ResolutionResult =
  | { state: 'value'; value: unknown; source: ScopeId }
  | { state: 'omit'; source: ScopeId; reason?: string };

const SCOPE_ORDER = new Map(SCOPE_PRIORITY.map((scope, index) => [scope, index]));

/** Resolves the layered overrides of one owner across the seven scope levels, highest first. A missing layer counts as inherit. */
export function resolveLayers(layers: readonly ScopeLayer[]): ResolutionResult {
  const sorted = [...layers].sort((left, right) => {
    const leftIndex = SCOPE_ORDER.get(left.scope);
    const rightIndex = SCOPE_ORDER.get(right.scope);
    if (leftIndex == null) throw new RangeError(`unknown scope: ${left.scope}`);
    if (rightIndex == null) throw new RangeError(`unknown scope: ${right.scope}`);
    return leftIndex - rightIndex;
  });

  for (const layer of sorted) {
    const { override } = layer;
    if (override.state === 'inherit') continue;
    if (override.state === 'omit') return { state: 'omit', source: layer.scope };
    if (!('value' in override)) throw new RangeError(`${layer.scope}: value state requires a value`);
    return { state: 'value', value: override.value, source: layer.scope };
  }

  // Every layer inherits, or no layer gave an explicit value at all: the result is omit, sourced as provider_default.
  return { state: 'omit', source: 'provider_default', reason: 'no_explicit_or_recipe_value' };
}

export interface SelectionIntent {
  availability: ControlAvailability;
  selection: ValueMode;
  access: ConnectionAccess;
}

export type SelectionRejectReason =
  | 'auto_recipe_unavailable'
  | 'custom_forbidden'
  | 'control_unknown'
  | 'custom_unavailable';

export interface SelectionResult {
  allowed: boolean;
  reason: SelectionRejectReason | null;
}

/** preset and custom are mutually exclusive; unknown or unavailable injects nothing. */
export function resolveSelection({ availability, selection, access }: SelectionIntent): SelectionResult {
  if (selection === 'preset') {
    if (availability === 'auto_available') return { allowed: true, reason: null };
    if (availability === 'managed_only' && access === 'managed') return { allowed: true, reason: null };
    if (availability === 'unknown') return { allowed: false, reason: 'control_unknown' };
    return { allowed: false, reason: 'auto_recipe_unavailable' };
  }

  // selection === 'custom': reaching here means access is not managed, which was intercepted above
  if (availability === 'managed_only' || access === 'managed') {
    return { allowed: false, reason: 'custom_forbidden' };
  }
  if (availability === 'custom_only' && (access === 'byok_developer' || access === 'relay_developer')) {
    return { allowed: true, reason: null };
  }
  if (availability === 'auto_available') return { allowed: true, reason: null };
  if (availability === 'unknown') return { allowed: false, reason: 'control_unknown' };
  return { allowed: false, reason: 'custom_unavailable' };
}

export interface OwnerAssignment {
  owner: OwnerId;
  pointer: string;
}

export type ConflictRejectReason = 'duplicate_pointer' | 'owner_conflict' | 'semantic_conflict';

export interface ConflictResult {
  accepted: boolean;
  reason: ConflictRejectReason | null;
}

/**
 * Validates a set of owner-to-pointer assignments: first duplicates and cross-owner pointer
 * collisions, then the semantic exclusions declared by the recipe, such as temperature versus top_p.
 */
export function validateAssignments(
  assignments: readonly OwnerAssignment[],
  declaredConflicts: readonly (readonly [string, string])[],
): ConflictResult {
  const seen = new Map<string, OwnerId>();
  for (const assignment of assignments) {
    const existingOwner = seen.get(assignment.pointer);
    if (existingOwner != null) {
      return {
        accepted: false,
        reason: existingOwner === assignment.owner ? 'duplicate_pointer' : 'owner_conflict',
      };
    }
    seen.set(assignment.pointer, assignment.owner);
  }

  const active = new Set(assignments.map((item) => item.pointer));
  if (declaredConflicts.some(([left, right]) => active.has(left) && active.has(right))) {
    return { accepted: false, reason: 'semantic_conflict' };
  }
  return { accepted: true, reason: null };
}

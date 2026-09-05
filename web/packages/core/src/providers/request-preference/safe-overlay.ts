/**
 * request_preference_contract.v2 safeOverlay.
 *
 * Hardening checks applied before a custom JSON fragment is accepted: only the body_fragment
 * channel, rfc6901 pointers, a whitelist of ops, caps on size, depth, node count and operand
 * count, recursive rejection of __proto__/prototype/constructor, rejection of root fields the
 * builder owns itself (tools and plugins go through the typed append in tool-contributions.ts,
 * not set/omit here), and pointer ownership as declared in declaredOwners, where a pointer
 * belonging to another owner or to no declaration at all is rejected.
 */

import { OWNER_IDS, type OwnerId } from './types';

const SEGMENT_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const BLOCKED_SEGMENTS_RECURSIVE = new Set(['__proto__', 'prototype', 'constructor']);
const BUILDER_OWNED_ROOT_FIELDS = new Set([
  'model', 'messages', 'input', 'contents', 'prompt', 'attachments', 'instructions', 'system',
  'stream', 'stream_options', 'tools', 'tool_choice', 'plugins',
]);
const TYPED_CONTRIBUTION_ONLY_ROOTS = new Set(['tools', 'plugins']);
const ALLOWED_OPERATIONS = new Set(['set', 'omit', 'upsert_owned_element']);

const LIMITS = { maxBytes: 65536, maxDepth: 32, maxNodes: 2048, maxOperations: 128 } as const;

export interface OverlayOperation {
  owner: OwnerId;
  op: string;
  pointer: string;
  value?: unknown;
}

export interface OverlayIntent {
  channel: string;
  metrics: { bytes: number; depth: number; nodes: number };
  /** rfc6901 pointer -> the owner that pointer belongs to under the selected recipe. Any pointer not declared here counts as unknown. */
  declaredOwners: Readonly<Record<string, OwnerId>>;
  operations: readonly OverlayOperation[];
}

export type OverlayRejectReason =
  | 'forbidden_channel'
  | 'size_exceeded'
  | 'depth_exceeded'
  | 'node_limit_exceeded'
  | 'operation_limit_exceeded'
  | 'unknown_owner'
  | 'unknown_operation'
  | 'duplicate_pointer'
  | 'invalid_pointer'
  | 'blocked_segment'
  | 'typed_contribution_required'
  | 'builder_owned_root'
  | 'blocked_value_key'
  | 'unknown_pointer'
  | 'cross_owner';

export interface OverlayResult {
  accepted: boolean;
  reason: OverlayRejectReason | null;
}

export function validateOverlay(intent: OverlayIntent): OverlayResult {
  if (intent.channel !== 'body_fragment') return { accepted: false, reason: 'forbidden_channel' };
  if (intent.metrics.bytes > LIMITS.maxBytes) return { accepted: false, reason: 'size_exceeded' };
  if (intent.metrics.depth > LIMITS.maxDepth) return { accepted: false, reason: 'depth_exceeded' };
  if (intent.metrics.nodes > LIMITS.maxNodes) return { accepted: false, reason: 'node_limit_exceeded' };
  if (intent.operations.length > LIMITS.maxOperations) {
    return { accepted: false, reason: 'operation_limit_exceeded' };
  }

  const seenPointers = new Set<string>();
  for (const operation of intent.operations) {
    if (!OWNER_IDS.includes(operation.owner)) return { accepted: false, reason: 'unknown_owner' };
    if (!ALLOWED_OPERATIONS.has(operation.op)) return { accepted: false, reason: 'unknown_operation' };
    if (seenPointers.has(operation.pointer)) return { accepted: false, reason: 'duplicate_pointer' };
    seenPointers.add(operation.pointer);

    const segments = operation.pointer.split('/').slice(1);
    if (!operation.pointer.startsWith('/') || segments.some((segment) => !SEGMENT_PATTERN.test(segment))) {
      return { accepted: false, reason: 'invalid_pointer' };
    }
    if (segments.some((segment) => BLOCKED_SEGMENTS_RECURSIVE.has(segment))) {
      return { accepted: false, reason: 'blocked_segment' };
    }
    // tools/plugins may only enter through the normalized typed upsert operation.
    // Generic set/omit would replace a builder-owned array and is never safe.
    if (TYPED_CONTRIBUTION_ONLY_ROOTS.has(segments[0]) && operation.op === 'upsert_owned_element'
      && segments.length === 1) {
      if (operation.owner !== 'web') return { accepted: false, reason: 'cross_owner' };
      continue;
    }
    if (BUILDER_OWNED_ROOT_FIELDS.has(segments[0])) {
      return {
        accepted: false,
        reason: TYPED_CONTRIBUTION_ONLY_ROOTS.has(segments[0]) ? 'typed_contribution_required' : 'builder_owned_root',
      };
    }
    if (hasBlockedValueKey(operation.value)) {
      return { accepted: false, reason: 'blocked_value_key' };
    }
    const declaredOwner = intent.declaredOwners[operation.pointer];
    if (declaredOwner == null) return { accepted: false, reason: 'unknown_pointer' };
    if (declaredOwner !== operation.owner) return { accepted: false, reason: 'cross_owner' };
  }
  return { accepted: true, reason: null };
}

/** Recursively look for __proto__/prototype/constructor keys inside the value, to keep JSON deserialization from polluting the prototype chain. */
function hasBlockedValueKey(value: unknown): boolean {
  if (Array.isArray(value)) return value.some((item) => hasBlockedValueKey(item));
  if (value == null || typeof value !== 'object') return false;
  return Object.entries(value as Record<string, unknown>).some(
    ([key, item]) => BLOCKED_SEGMENTS_RECURSIVE.has(key) || hasBlockedValueKey(item),
  );
}

/** Lossless custom body fragment compiler. Raw JSON is parsed once with duplicate-key
 * detection before values reach JavaScript objects, then uses the normal owned-patch compiler. */
import { compileOwnedPatches } from '../request-preference/owned-patch-compiler';
import type { OwnerId } from '../request-preference/types';

const MAX_BYTES = 64 * 1024;
const MAX_DEPTH = 32;
const MAX_NODES = 2048;
const FORBIDDEN_ROOTS = new Set(['auth', 'headers', 'query', 'endpoint', 'base_url', 'transport_route', 'model_route', 'continuation_state']);
const BLOCKED = new Set(['__proto__', 'prototype', 'constructor']);

/**
 * Rejection vocabulary. Every token is a structured identifier that never echoes user JSON, so it
 * can travel to the UI and to error responses as-is.
 *
 * The last group is forwarded straight from the owned-patch compiler. It used to be collapsed into
 * `invalid_fragment`, which made the editor call a blocked pointer or an operation-count overflow a
 * *syntax* error and tell the user to check their JSON — advice that can never fix it. The compiler
 * already knows which one it is; the only reason the UI could not say so was this lossy cast.
 */
export type SafeCustomFragmentRejection =
  // Shape of the fragment itself.
  | 'duplicate_json_key' | 'invalid_json' | 'invalid_fragment'
  // Size / complexity limits.
  | 'too_large' | 'depth_exceeded' | 'node_limit_exceeded' | 'size_exceeded' | 'operation_limit_exceeded'
  // Path ownership and blocked write channels.
  | 'forbidden_root' | 'forbidden_channel' | 'forbidden_key' | 'unknown_owned_path' | 'cross_owner' | 'conflict'
  | 'invalid_pointer' | 'blocked_segment' | 'builder_owned_root' | 'typed_contribution_required' | 'blocked_value_key'
  /** Compiler rejections with no dedicated bucket yet. Fails into the "not allowed" copy. */
  | 'compile_rejected';

export type SafeCustomFragmentResult =
  | { accepted: true; delta: Record<string, unknown>; preview: Record<string, unknown>; pointers: string[] }
  | { accepted: false; reason: SafeCustomFragmentRejection };

/** Compiler reasons that keep their own identity on the way out; everything else is `compile_rejected`. */
const FORWARDED_COMPILER_REASONS = new Set<SafeCustomFragmentRejection>([
  'invalid_pointer', 'blocked_segment', 'builder_owned_root', 'typed_contribution_required', 'blocked_value_key',
  'forbidden_channel', 'size_exceeded', 'depth_exceeded', 'node_limit_exceeded', 'operation_limit_exceeded',
  'cross_owner',
]);

function forwardCompilerRejection(reason: string): SafeCustomFragmentRejection {
  // `unknown_pointer` is the compiler's name for the path this owner never declared; the fragment
  // vocabulary has always called that `unknown_owned_path`, and the UI copy keys off that name.
  if (reason === 'unknown_pointer') return 'unknown_owned_path';
  return FORWARDED_COMPILER_REASONS.has(reason as SafeCustomFragmentRejection)
    ? (reason as SafeCustomFragmentRejection)
    : 'compile_rejected';
}

export function compileSafeCustomFragment(
  raw: string,
  owner: OwnerId,
  declaredOwners: Readonly<Record<string, OwnerId>>,
  base: Readonly<Record<string, unknown>>,
): SafeCustomFragmentResult {
  if (new TextEncoder().encode(raw).byteLength > MAX_BYTES) return { accepted: false, reason: 'too_large' };
  let parsed: unknown; let metrics: Metrics;
  try { const parser = new LosslessJsonParser(raw); parsed = parser.parse(); metrics = parser.metrics; }
  catch (error) { return { accepted: false, reason: error instanceof ParseError ? error.reason : 'invalid_json' }; }
  if (metrics.depth > MAX_DEPTH) return { accepted: false, reason: 'depth_exceeded' };
  if (metrics.nodes > MAX_NODES) return { accepted: false, reason: 'node_limit_exceeded' };
  if (!isRecord(parsed)) return { accepted: false, reason: 'invalid_fragment' };
  const entries = Object.entries(parsed);
  for (const [key] of entries) {
    if (BLOCKED.has(key)) return { accepted: false, reason: 'forbidden_key' };
    if (FORBIDDEN_ROOTS.has(key)) return { accepted: false, reason: 'forbidden_channel' };
    if (['model', 'messages', 'input', 'contents', 'prompt', 'attachments', 'instructions', 'system', 'stream', 'stream_options', 'tools', 'tool_choice', 'plugins'].includes(key)) return { accepted: false, reason: 'forbidden_root' };
  }
  const operations = ownedLeafOperations(parsed, owner, declaredOwners);
  if (operations.some((operation) => pointerExists(base, operation.pointer))) return { accepted: false, reason: 'conflict' };
  const compiled = compileOwnedPatches({
    channel: 'body_fragment', metrics: { bytes: new TextEncoder().encode(raw).byteLength, depth: metrics.depth, nodes: metrics.nodes }, declaredOwners,
    operations,
  }, [], base, []);
  if (!compiled.accepted) return { accepted: false, reason: forwardCompilerRejection(compiled.reason) };
  return { ...compiled, pointers: operations.map((operation) => operation.pointer) };
}

/** Objects are always walked to leaf paths. A declaration for `/generationConfig` must never
 * authorize arbitrary descendants that could overwrite a recipe-owned child; arrays remain an
 * atomic value at their declared parent because they have no JSON-pointer object namespace. */
function ownedLeafOperations(
  value: Record<string, unknown>,
  owner: OwnerId,
  declaredOwners: Readonly<Record<string, OwnerId>>,
): Array<{ owner: OwnerId; op: 'set'; pointer: string; value: unknown }> {
  const operations: Array<{ owner: OwnerId; op: 'set'; pointer: string; value: unknown }> = [];
  const visit = (item: unknown, pointer: string) => {
    if (isRecord(item)) {
      const entries = Object.entries(item);
      if (entries.length === 0) operations.push({ owner, op: 'set', pointer, value: item });
      else for (const [key, nested] of entries) visit(nested, `${pointer}/${escapePointer(key)}`);
      return;
    }
    // Arrays are values, not a path namespace. Their owner must declare the parent pointer.
    operations.push({ owner, op: 'set', pointer, value: item });
  };
  for (const [key, nested] of Object.entries(value)) visit(nested, `/${escapePointer(key)}`);
  return operations;
}

function escapePointer(key: string): string { return key.replace(/~/g, '~0').replace(/\//g, '~1'); }
function pointerExists(base: Readonly<Record<string, unknown>>, pointer: string): boolean {
  let current: unknown = base;
  for (const segment of pointer.slice(1).split('/').map((part) => part.replace(/~1/g, '/').replace(/~0/g, '~'))) {
    if (!isRecord(current) || !Object.prototype.hasOwnProperty.call(current, segment)) return false;
    current = current[segment];
  }
  return true;
}

interface Metrics { depth: number; nodes: number }
type ParseReason = 'duplicate_json_key' | 'forbidden_key' | 'depth_exceeded' | 'node_limit_exceeded' | 'invalid_json';
class ParseError extends Error { constructor(readonly reason: ParseReason) { super(reason); } }
class LosslessJsonParser {
  private at = 0; readonly metrics: Metrics = { depth: 0, nodes: 0 };
  constructor(private readonly source: string) {}
  parse(): unknown { this.ws(); const out = this.value(0); this.ws(); if (this.at !== this.source.length) throw new ParseError('invalid_json'); return out; }
  private value(depth: number): unknown { if (depth > MAX_DEPTH) throw new ParseError('depth_exceeded'); this.metrics.depth = Math.max(this.metrics.depth, depth); if (++this.metrics.nodes > MAX_NODES) throw new ParseError('node_limit_exceeded'); this.ws(); const c = this.source[this.at]; if (c === '{') return this.object(depth + 1); if (c === '[') return this.array(depth + 1); if (c === '"') return this.string(); if (this.source.startsWith('true', this.at)) { this.at += 4; return true; } if (this.source.startsWith('false', this.at)) { this.at += 5; return false; } if (this.source.startsWith('null', this.at)) { this.at += 4; return null; } return this.number(); }
  private object(depth: number): Record<string, unknown> { if (depth > MAX_DEPTH) throw new ParseError('depth_exceeded'); this.metrics.depth = Math.max(this.metrics.depth, depth); this.at++; this.ws(); const out: Record<string, unknown> = {}; const seen = new Set<string>(); if (this.take('}')) return out; while (true) { this.ws(); if (this.source[this.at] !== '"') throw new ParseError('invalid_json'); const key = this.string(); if (seen.has(key)) throw new ParseError('duplicate_json_key'); if (BLOCKED.has(key)) throw new ParseError('forbidden_key'); seen.add(key); this.ws(); if (!this.take(':')) throw new ParseError('invalid_json'); out[key] = this.value(depth); this.ws(); if (this.take('}')) return out; if (!this.take(',')) throw new ParseError('invalid_json'); } }
  private array(depth: number): unknown[] { if (depth > MAX_DEPTH) throw new ParseError('depth_exceeded'); this.metrics.depth = Math.max(this.metrics.depth, depth); this.at++; this.ws(); const out: unknown[] = []; if (this.take(']')) return out; while (true) { out.push(this.value(depth)); this.ws(); if (this.take(']')) return out; if (!this.take(',')) throw new ParseError('invalid_json'); } }
  private string(): string { const start = this.at++; let escaped = false; while (this.at < this.source.length) { const c = this.source[this.at++]; if (escaped) { escaped = false; continue; } if (c === '\\') { escaped = true; continue; } if (c === '"') { try { return JSON.parse(this.source.slice(start, this.at)) as string; } catch { throw new ParseError('invalid_json'); } } if (c.charCodeAt(0) < 0x20) throw new ParseError('invalid_json'); } throw new ParseError('invalid_json'); }
  private number(): number { const start = this.at; while (this.at < this.source.length && /[0-9eE+\-.]/.test(this.source[this.at])) this.at++; const token = this.source.slice(start, this.at); const value = Number(token); if (!token || !Number.isFinite(value) || !/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(token)) throw new ParseError('invalid_json'); return value; }
  private ws() { while (/\s/.test(this.source[this.at] ?? '')) this.at++; }
  private take(c: string) { if (this.source[this.at] !== c) return false; this.at++; return true; }
}
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value != null && !Array.isArray(value); }

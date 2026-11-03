/**
 * BYOK image task management: pure logic shared with iOS / Android through the
 * fixture byok_image_tasks.v1.json (per-attempt timeout, retry decision, fetch
 * error -> phase, split-batch aggregation, 4-slot FIFO queue reducer, launch
 * reconciliation). No UI, no I/O.
 */
import type { ImageErrorKind } from './image-error';

export type ByokPhase = 'pre_connect' | 'after_send' | 'timeout' | 'cancelled';

export type ByokRoundStatus = 'completed' | 'partial' | 'failed' | 'cancelled';

export type ByokReconcileAction =
  | 'keep'
  | 'process'
  | 'keep_running'
  | 'interrupted'
  | 'failed_timeout';

export const BYOK_IMAGE_TASK_SPEC = {
  defaultTimeoutSeconds: 180,
  maxTimeoutSeconds: 180,
  maxConcurrentRounds: 4,
  maxAutoRetries: 1,
  phases: ['pre_connect', 'after_send', 'timeout', 'cancelled'] as readonly ByokPhase[],
  reconcileActions: [
    'keep',
    'process',
    'keep_running',
    'interrupted',
    'failed_timeout',
  ] as readonly ByokReconcileAction[],
  roundStatuses: ['completed', 'partial', 'failed', 'cancelled'] as readonly ByokRoundStatus[],
} as const;

export interface ByokRetryDecision {
  retry: boolean;
  errorKind: Extract<ImageErrorKind, 'network' | 'timeout'> | null;
  retried: boolean;
  mayBeBilled: boolean;
}

export interface ByokBatchResult {
  images: number;
  errorKind?: ImageErrorKind | null;
}

export interface ByokAggregate {
  status: ByokRoundStatus;
  delivered: number;
  errorKind: ImageErrorKind | null;
}

export interface ByokQueueState {
  readonly running: readonly string[];
  readonly queued: readonly string[];
}

export interface ByokQueueEvent {
  type: 'submit' | 'finish' | 'cancel' | 'response';
  id: string;
}

export type ByokQueueEffect =
  | { type: 'start'; id: string }
  | { type: 'cancelled'; id: string; mayBeBilled: boolean }
  | { type: 'accept'; id: string }
  | { type: 'drop'; id: string };

export interface ByokQueueResult {
  state: ByokQueueState;
  effects: ByokQueueEffect[];
}

export const BYOK_EMPTY_QUEUE: ByokQueueState = { running: [], queued: [] };

/** Fetch failure codes (error.cause.code) raised before any request byte left the machine. */
const PRE_CONNECT_CAUSE_CODES: ReadonlySet<string> = new Set([
  'ENOTFOUND',
  'EAI_AGAIN',
  'ECONNREFUSED',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'UND_ERR_CONNECT_TIMEOUT',
  'CERT_HAS_EXPIRED',
  'DEPTH_ZERO_SELF_SIGNED_CERT',
  'SELF_SIGNED_CERT_IN_CHAIN',
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
  'ERR_TLS_CERT_ALTNAME_INVALID',
]);

const TIMEOUT_CAUSE_CODES: ReadonlySet<string> = new Set([
  'UND_ERR_HEADERS_TIMEOUT',
  'UND_ERR_BODY_TIMEOUT',
]);

/** Per-attempt total timeout: missing or <= 0 falls back to the default, capped at the max. */
export function byokEffectiveTimeoutSeconds(timeoutSeconds: number | null | undefined): number {
  // Non-integers (NaN included) fall back like missing, matching the reference implementation.
  if (timeoutSeconds == null || !Number.isInteger(timeoutSeconds) || timeoutSeconds <= 0) {
    return BYOK_IMAGE_TASK_SPEC.defaultTimeoutSeconds;
  }
  return Math.min(timeoutSeconds, BYOK_IMAGE_TASK_SPEC.maxTimeoutSeconds);
}

/** Only a pre_connect failure on the first attempt is retried (once). */
export function byokRetryDecision(phase: ByokPhase, attempt: number): ByokRetryDecision {
  const retried = attempt > 0;
  switch (phase) {
    case 'pre_connect':
      if (attempt < BYOK_IMAGE_TASK_SPEC.maxAutoRetries) {
        return { retry: true, errorKind: null, retried, mayBeBilled: false };
      }
      return { retry: false, errorKind: 'network', retried, mayBeBilled: false };
    case 'after_send':
      return { retry: false, errorKind: 'network', retried, mayBeBilled: true };
    case 'timeout':
      return { retry: false, errorKind: 'timeout', retried, mayBeBilled: true };
    case 'cancelled':
      return { retry: false, errorKind: null, retried, mayBeBilled: false };
  }
}

function errorName(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null) return undefined;
  const name = (error as { name?: unknown }).name;
  return typeof name === 'string' ? name : undefined;
}

const MAX_CAUSE_DEPTH = 8;

/** Phase from the first layer (the error itself, then its cause chain outer-first) carrying a known code. */
function causeChainPhase(error: unknown): ByokPhase | undefined {
  let node: unknown = error;
  for (let depth = 0; depth <= MAX_CAUSE_DEPTH && typeof node === 'object' && node !== null; depth += 1) {
    const code = (node as { code?: unknown }).code;
    if (typeof code === 'string') {
      if (TIMEOUT_CAUSE_CODES.has(code)) return 'timeout';
      if (PRE_CONNECT_CAUSE_CODES.has(code)) return 'pre_connect';
    }
    node = (node as { cause?: unknown }).cause;
  }
  return undefined;
}

/** Maps a fetch rejection to a phase; anything unknown is after_send (never retried). */
export function byokTransportPhase(error: unknown): ByokPhase {
  const name = errorName(error);
  if (name === 'AbortError') return 'cancelled';
  if (name === 'TimeoutError') return 'timeout';
  return causeChainPhase(error) ?? 'after_send';
}

/** Sums each batch's images capped at its batch size; results past batches.length are ignored; cancelled wins and drops everything. */
export function byokAggregate(
  n: number,
  batches: readonly number[],
  results: readonly ByokBatchResult[],
  cancelled: boolean,
): ByokAggregate {
  if (cancelled) return { status: 'cancelled', delivered: 0, errorKind: null };
  let delivered = 0;
  let firstKind: ImageErrorKind | null = null;
  for (let index = 0; index < batches.length; index += 1) {
    const result = results[index];
    if (result === undefined) continue;
    delivered += Math.max(0, Math.min(result.images, batches[index]));
    if (firstKind === null && result.errorKind != null) firstKind = result.errorKind;
  }
  if (delivered >= n) return { status: 'completed', delivered: n, errorKind: null };
  if (delivered > 0) return { status: 'partial', delivered, errorKind: firstKind ?? 'partial' };
  return { status: 'failed', delivered: 0, errorKind: firstKind ?? 'decode_failed' };
}

function promote(running: string[], queued: string[], effects: ByokQueueEffect[]): void {
  while (running.length < BYOK_IMAGE_TASK_SPEC.maxConcurrentRounds && queued.length > 0) {
    const id = queued.shift() as string;
    running.push(id);
    effects.push({ type: 'start', id });
  }
}

/** FIFO queue with maxConcurrentRounds slots; never mutates the input state. */
export function byokQueueReduce(state: ByokQueueState, event: ByokQueueEvent): ByokQueueResult {
  const running = [...state.running];
  const queued = [...state.queued];
  const effects: ByokQueueEffect[] = [];
  const { id } = event;
  switch (event.type) {
    case 'submit':
      if (running.includes(id) || queued.includes(id)) return { state, effects };
      queued.push(id);
      promote(running, queued, effects);
      break;
    case 'finish': {
      const at = running.indexOf(id);
      if (at < 0) return { state, effects };
      running.splice(at, 1);
      promote(running, queued, effects);
      break;
    }
    case 'cancel': {
      const runAt = running.indexOf(id);
      if (runAt >= 0) {
        running.splice(runAt, 1);
        effects.push({ type: 'cancelled', id, mayBeBilled: true });
        promote(running, queued, effects);
        break;
      }
      const queueAt = queued.indexOf(id);
      if (queueAt < 0) return { state, effects };
      queued.splice(queueAt, 1);
      effects.push({ type: 'cancelled', id, mayBeBilled: false });
      break;
    }
    case 'response':
      effects.push({ type: running.includes(id) ? 'accept' : 'drop', id });
      return { state, effects };
  }
  return { state: { running, queued }, effects };
}

/** Launch-time decision for a persisted round; rules are checked in contract order. */
export function byokReconcile(
  status: string,
  startedAtMs: number | null | undefined,
  nowMs: number,
  timeoutSeconds: number | null | undefined,
  responseReceived: boolean,
  transferActive: boolean,
): ByokReconcileAction {
  if (status !== 'queued' && status !== 'running') return 'keep';
  if (status === 'queued') return 'interrupted';
  if (responseReceived) return 'process';
  if (transferActive) return 'keep_running';
  if (startedAtMs == null || nowMs < startedAtMs) return 'interrupted';
  if (nowMs - startedAtMs >= byokEffectiveTimeoutSeconds(timeoutSeconds) * 1000) {
    return 'failed_timeout';
  }
  return 'interrupted';
}

/**
 * Pre-send cap / price-line confirmation gate.
 * Sits after pre-send compaction and before the transport: decides with decideCapConfirm on the window this
 * plan used, and when the decision asks, suspends the send until the user answers. Confirm records the local
 * state and sends; cancel throws CapConfirmCancelledError so the caller rolls the turn back.
 * At most one pending confirmation per conversation: a newer one in the same conversation replaces the older
 * (the older settles as cancel). Bound to an AbortSignal, no timeout.
 */
import type { StoreApi } from 'zustand';
import type { AIModel, Provider } from '@oriveo/shared';
import type { AppStore } from '../../store/app-store';
import { normalizeUUID } from '../../../utils/id-utils';
import type { ChatPlanWindow } from '../context-pipeline/chat-context';
import { capPricingOf } from './cap-presentation';
import {
  type CapConfirmAttempt,
  type CapConfirmDecision,
  capConfirmInputOf,
  capConfirmModelName,
  decideCapConfirm,
  recordCapConfirm,
} from './cap-confirm';

export interface CapConfirmRequest {
  id: string;
  conversationId: string;
  decision: CapConfirmDecision;
  /** Plan estimate P-hat at the gate. */
  estimatedInput: number;
  B: number | null;
  priceLineTokens: number | null;
  /** {model} in the copy (capConfirmModelName). */
  modelName: string;
}

export type CapConfirmChoice = { kind: 'confirm'; dontAsk: boolean } | { kind: 'cancel' };

/** The user cancelled at the gate (or stopped while it waited): roll the turn back, report nothing. */
export class CapConfirmCancelledError extends Error {
  constructor() {
    super('Send cancelled at the context cap confirmation');
    this.name = 'CapConfirmCancelledError';
  }
}

type PendingCapConfirm = {
  key: string;
  store: StoreApi<AppStore>;
  request: CapConfirmRequest;
  settle: (choice: CapConfirmChoice) => void;
};

const CANCEL: CapConfirmChoice = { kind: 'cancel' };
/** Normalized conversation id -> its pending confirmation. */
const pending = new Map<string, PendingCapConfirm>();

/** Store key of a conversation's pending confirmation (ids compare normalized). */
export function capConfirmKeyOf(conversationId: string): string {
  return normalizeUUID(conversationId);
}

/** The pending confirmation of this conversation in the store, if any. */
export function pendingCapConfirmationOf(
  state: Pick<AppStore, 'contextCapConfirmations'>,
  conversationId: string | null | undefined,
): CapConfirmRequest | null {
  if (!conversationId) return null;
  return state.contextCapConfirmations?.[capConfirmKeyOf(conversationId)] ?? null;
}

function release(entry: PendingCapConfirm): void {
  if (pending.get(entry.key) === entry) pending.delete(entry.key);
  const state = entry.store.getState();
  if (state.contextCapConfirmations[entry.key]?.id === entry.request.id) state.setContextCapConfirmation(entry.key, null);
}

export function requestCapConfirmation(
  store: StoreApi<AppStore>,
  request: CapConfirmRequest,
  signal: AbortSignal,
): Promise<CapConfirmChoice> {
  if (signal.aborted) return Promise.resolve(CANCEL);
  const key = capConfirmKeyOf(request.conversationId);
  // Same conversation: the newer request replaces the older one, which settles as cancel.
  pending.get(key)?.settle(CANCEL);
  return new Promise((resolve) => {
    let settled = false;
    const finish = (choice: CapConfirmChoice) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener('abort', onAbort);
      release(entry);
      resolve(choice);
    };
    const onAbort = () => finish(CANCEL);
    const entry: PendingCapConfirm = { key, store, request, settle: finish };
    signal.addEventListener('abort', onAbort, { once: true });
    pending.set(key, entry);
    store.getState().setContextCapConfirmation(key, request);
  });
}

/** The dialog (or stop) answers this conversation's pending confirmation. */
export function resolveCapConfirmation(conversationId: string, choice: CapConfirmChoice): void {
  pending.get(capConfirmKeyOf(conversationId))?.settle(choice);
}

let requestSeq = 0;

/**
 * The shared gate for the main send, library agent and MCP first leg.
 * B / limitedBy / T come from `window`, the window input this plan was assembled with (not re-read from the store).
 * Resolves when nothing is asked or the user confirmed (state recorded); throws CapConfirmCancelledError on cancel.
 */
export async function gateCapConfirm(input: {
  store: StoreApi<AppStore>;
  conversationId: string;
  provider: Provider;
  model: AIModel;
  attempt: CapConfirmAttempt;
  /** The plan's window input (chatPlanWindowOf / ToolLoopContext.window). */
  window: ChatPlanWindow;
  /** plan.budget.estimatedInput at the gate; null = nothing to ask. */
  estimatedInput: number | null;
  signal: AbortSignal;
  /** Called right before the gate suspends to ask (not when nothing is asked): the caller takes over stop here. */
  onAsk?: () => void;
}): Promise<void> {
  const { store, conversationId, provider, model, window } = input;
  if (input.estimatedInput === null) return;
  const preferences = store.getState().preferences;
  const priceLineTokens = window.priceLineTokens ?? null;
  const decisionInput = capConfirmInputOf({
    presentation: {
      W: window.W,
      windowKind: window.windowKind,
      maxOutput: window.maxOutput,
      priceLineTokens,
      conversationCap: window.budgetCap,
      globalCap: window.budgetCap,
      pricing: capPricingOf(provider, model, priceLineTokens),
    },
    attempt: input.attempt,
    modelId: model.id,
    estimatedInput: input.estimatedInput,
    preferences,
    conversationId,
  });
  const decision = decideCapConfirm(decisionInput);
  if (decision.kind === 'none') return;
  input.onAsk?.();
  requestSeq += 1;
  const choice = await requestCapConfirmation(store, {
    id: `cap-confirm-${conversationId}-${requestSeq}`,
    conversationId,
    decision,
    estimatedInput: input.estimatedInput,
    B: decisionInput.B,
    priceLineTokens: decisionInput.priceLineTokens,
    modelName: capConfirmModelName(model),
  }, input.signal);
  if (choice.kind === 'cancel') throw new CapConfirmCancelledError();
  recordCapConfirm(conversationId, decision, choice.dontAsk);
}

/** Wrap a callback so it runs at most once (after the gate, or on the failure path if the gate was never reached). */
export function onceCallback(fn: (() => void) | undefined): () => void {
  let called = false;
  return () => {
    if (called || !fn) return;
    called = true;
    fn();
  };
}

/** Map the telemetry attempt kind onto the confirm attempt (only send / edit ask). */
export function capConfirmAttemptOf(attemptKind: string | undefined): CapConfirmAttempt {
  switch (attemptKind) {
    case undefined:
    case 'send':
      return 'send';
    case 'edit':
    case 'regenerate':
    case 'retry':
    case 'continue':
      return attemptKind;
    default:
      return 'retry';
  }
}

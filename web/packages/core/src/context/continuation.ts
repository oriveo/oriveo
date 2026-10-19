/**
 * Stateful continuation decision (shared contract wire-system.v1.json continuationPlan / continuationCases).
 * Pure functions: whether a continue leg may chain on previous_response_id, and the resulting wire shape.
 */

export type ContinuationInstructionsMode = 'resend' | 'omit';

export interface ContinuationState {
  previousResponseId?: string | null;
  /** Absent / null: the family has no confirmed stateful mode, always full plan. */
  instructionsMode?: ContinuationInstructionsMode | null;
  systemChangedSinceLastLeg: boolean;
  modelChanged: boolean;
  checkpointChanged: boolean;
}

export type ContinuationDecision =
  | { kind: 'fullPlan' }
  | { kind: 'stateful'; previousResponseId: string; sendInstructions: boolean };

export interface ContinuationPlanMessage {
  role: 'user' | 'assistant';
  text: string;
}

/** The full continue plan: system, history cut at the target assistant, fixed continue prompt. */
export interface ContinuationPlan {
  system: string | null;
  history: ContinuationPlanMessage[];
  current: string;
}

export interface ContinuationInputMessage {
  role: 'user' | 'assistant';
  content: string;
}

export interface ContinuationProjection {
  instructions?: string;
  previous_response_id?: string;
  input: ContinuationInputMessage[];
}

const FULL_PLAN: ContinuationDecision = { kind: 'fullPlan' };

function decideContinuation(state: ContinuationState): ContinuationDecision {
  const previousResponseId = state.previousResponseId ?? '';
  const mode = state.instructionsMode ?? null;
  if (previousResponseId.length === 0) return FULL_PLAN;
  if (mode !== 'resend' && mode !== 'omit') return FULL_PLAN;
  if (state.systemChangedSinceLastLeg || state.modelChanged || state.checkpointChanged) return FULL_PLAN;
  return { kind: 'stateful', previousResponseId, sendInstructions: mode === 'resend' };
}

function projectContinuation(decision: ContinuationDecision, plan: ContinuationPlan): ContinuationProjection {
  const current: ContinuationInputMessage = { role: 'user', content: plan.current };
  const instructions = plan.system !== null && plan.system.length > 0 ? { instructions: plan.system } : {};
  if (decision.kind === 'stateful') {
    // In omit mode (e.g. Grok), sending both instructions and previous_response_id is rejected.
    return {
      ...(decision.sendInstructions ? instructions : {}),
      previous_response_id: decision.previousResponseId,
      input: [current],
    };
  }
  return {
    ...instructions,
    input: [...plan.history.map((m) => ({ role: m.role, content: m.text })), current],
  };
}

export const ContextContinuation = {
  decideContinuation,
  projectContinuation,
};

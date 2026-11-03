/**
 * Usage of a reply the user stopped midway on a non-managed connection.
 *
 * The stopped leg is always estimated (any usage it already streamed is ignored): input = the request's input
 * estimate (budget estimatedInput), output = estimateText(visible text) + estimateText(visible reasoning), each
 * ceil(utf8Bytes * rhoHi). Legs that finished before the stop keep their reported usage and are added field by field;
 * when any counted leg has no input the whole input stays empty (output is still added).
 */

import type { StreamUsage } from '@oriveo/core/providers/types';
import { ContextBudget } from '@oriveo/core/context/budget';
import { mergeToolLoopUsage } from '@oriveo/core/tools/tool-call-loop';

export interface InterruptedTurnUsageInput {
  /** Input estimate of the stopped request; null / undefined leaves input empty and the cost unknown. */
  estimatedInput?: number | null;
  /** rhoHi of this turn. */
  rhoHi: number;
  /** Text of the stopped leg the user saw. */
  visibleText: string;
  /** Reasoning of the stopped leg the user saw. */
  reasoningText: string;
  /** Usage of the legs that finished before the stop (already merged); undefined when none. */
  finishedLegs?: StreamUsage;
}

/** Estimated usage of the stopped leg; undefined when it showed nothing. */
export function stoppedLegUsage(input: Omit<InterruptedTurnUsageInput, 'finishedLegs'>): StreamUsage | undefined {
  if (input.visibleText === '' && input.reasoningText === '') return undefined;
  const completionTokens = ContextBudget.estimateText(input.visibleText, input.rhoHi)
    + ContextBudget.estimateText(input.reasoningText, input.rhoHi);
  const estimatedInput = input.estimatedInput;
  if (estimatedInput == null) {
    // No input estimate: output still counts, the cost stays unknown.
    return { completion_tokens: completionTokens, total_tokens: completionTokens, allLegsReported: false };
  }
  return { prompt_tokens: estimatedInput, completion_tokens: completionTokens, total_tokens: estimatedInput + completionTokens };
}

/**
 * Usage of the whole stopped turn: finished legs plus the stopped leg's estimate. When the stopped leg showed
 * nothing only the finished legs count (undefined when there are none: nothing is recorded).
 */
export function interruptedTurnUsage(input: InterruptedTurnUsageInput): StreamUsage | undefined {
  const stopped = stoppedLegUsage(input);
  if (!stopped) return input.finishedLegs;
  if (!input.finishedLegs) return stopped;
  const merged = mergeToolLoopUsage(input.finishedLegs, stopped);
  if (!merged || !anyLegMissingInput(input.finishedLegs, stopped)) return merged;
  // A partial input sum would understate the turn: leave input empty, keep the output.
  const { prompt_tokens: _partialInput, ...withoutInput } = merged;
  return { ...withoutInput, total_tokens: merged.completion_tokens ?? 0, allLegsReported: false };
}

function anyLegMissingInput(finishedLegs: StreamUsage, stopped: StreamUsage): boolean {
  const legs = finishedLegs.legs ?? [finishedLegs];
  return stopped.prompt_tokens == null || legs.some((leg) => leg.prompt_tokens == null);
}

type SettlementTokenFields = {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
};

/**
 * Tokens to write for a settled managed stop: the settlement is added onto the tokens the message already carries
 * (a continued message keeps its earlier rounds); fields the settlement lacks keep the message's value. Returns
 * undefined when there is nothing to write: no settled tokens, or the message's settlement is already completed
 * (the same settlement is applied once).
 */
export function accumulatedSettlementTokens(
  message: SettlementTokenFields & { managedSettlementStatus?: 'pending' | 'completed' },
  settled: SettlementTokenFields | undefined,
): SettlementTokenFields | undefined {
  if (!settled || message.managedSettlementStatus === 'completed') return undefined;
  const result: SettlementTokenFields = {};
  for (const key of ['inputTokens', 'outputTokens', 'cachedInputTokens', 'cacheCreationInputTokens'] as const) {
    const value = settled[key];
    if (value != null) result[key] = (message[key] ?? 0) + value;
  }
  return result;
}

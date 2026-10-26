/**
 * Usage tracking helpers: conversation cost recalculation and the provider reporting switch.
 *
 * - `recalculateConversationCostTotals`: a pure function and the single recalculation point for conversation
 *   totals; when the thread is complete it sums delivered messages per currency, otherwise it starts from the
 *   conversation's current totals and adds the local change delta.
 * - `shouldTrackProviderUsage`: platform-proxied providers do not enter BYOK local usage
 *   reporting.
 */

import { isValidProviderKind, type ChatMessage, type Conversation, type Provider } from '@oriveo/shared';
import { COST_EPSILON } from '../../utils/format-utils';
import type { NonUsdCostTotals } from '../cost/cost-currency';

/** Conversation totals: estimatedCost is the USD total; nonUsdCostTotals sums each currency on its own, never across currencies, and is omitted when there is no non-USD cost. */
export type ConversationCostTotals = Pick<Conversation, 'estimatedCost' | 'nonUsdCostTotals'>;

/**
 * Conversation-side input for recalculation: the current conversation totals (latest remote value), the
 * local "thread complete" flag, and the local messages from before this change.
 * Messages present both before and after the local change (including windows merged in from the cloud)
 * cancel each other out and produce no delta.
 */
export interface ConversationCostThread {
  conversation: Pick<Conversation, 'estimatedCost' | 'nonUsdCostTotals' | 'localThreadComplete'>;
  previousMessages: readonly ChatMessage[];
}

/**
 * Sums local messages per currency: only delivered ones count; non-USD parts whose amount is unavailable
 * (costSource 'unknown') are skipped. Raw per-message amounts are added first and the epsilon
 * (COST_EPSILON) is applied only to the total (cost-currency.v1 tiny_parts_summed_before_epsilon).
 */
function sumMessageCostTotals(messages: readonly ChatMessage[]): ConversationCostTotals {
  let usdSum = 0;
  const rawNonUsd: Record<string, number> = {};
  for (const m of messages) {
    if (m.state !== 'delivered') continue;
    // Add only finite parts > 0 (negative_parts_not_added); keep a total only when it is strictly > epsilon.
    if (Number.isFinite(m.estimatedCost) && m.estimatedCost > 0) usdSum += m.estimatedCost;
    const part = m.nonUsdCost;
    if (part && part.costSource !== 'unknown' && Number.isFinite(part.amount) && part.amount > 0) {
      rawNonUsd[part.currencyCode] = (rawNonUsd[part.currencyCode] ?? 0) + part.amount;
    }
  }
  const estimatedCost = usdSum > COST_EPSILON ? usdSum : 0;
  let nonUsd: NonUsdCostTotals | undefined;
  for (const [code, amount] of Object.entries(rawNonUsd)) {
    if (amount > COST_EPSILON) nonUsd = { ...nonUsd, [code]: amount };
  }
  return nonUsd ? { estimatedCost, nonUsdCostTotals: nonUsd } : { estimatedCost };
}

/**
 * Conversation cost total - the single totalling function behind every recalculation entry point here
 * (cost-currency.v1 totalCases / totalsIncompleteThreadCases, contract section 5.7 "conversation totals
 * and local thread completeness").
 * - `thread` is null (the conversation does not exist yet) or the local thread-complete flag is true:
 *   recompute USD and every currency from all local `messages`.
 * - Flag missing or false: do not recompute wholesale; start from the conversation's current totals and add,
 *   per currency, the difference between `messages` and `previousMessages` (added / deleted / cost changed),
 *   with each currency floored at 0, zero non-USD currencies left out, and an empty table omitted.
 */
export function recalculateConversationCostTotals(
  messages: readonly ChatMessage[],
  thread: ConversationCostThread | null,
): ConversationCostTotals {
  if (!thread || thread.conversation.localThreadComplete === true) return sumMessageCostTotals(messages);
  const after = sumMessageCostTotals(messages);
  const before = sumMessageCostTotals(thread.previousMessages);
  const base = thread.conversation;
  const estimatedCost = Math.max(0, (base.estimatedCost ?? 0) + after.estimatedCost - before.estimatedCost);
  const codes = new Set([
    ...Object.keys(base.nonUsdCostTotals ?? {}),
    ...Object.keys(after.nonUsdCostTotals ?? {}),
    ...Object.keys(before.nonUsdCostTotals ?? {}),
  ]);
  let nonUsd: NonUsdCostTotals | undefined;
  for (const code of codes) {
    const amount = (base.nonUsdCostTotals?.[code] ?? 0)
      + (after.nonUsdCostTotals?.[code] ?? 0)
      - (before.nonUsdCostTotals?.[code] ?? 0);
    if (amount > COST_EPSILON) nonUsd = { ...nonUsd, [code]: amount };
  }
  return nonUsd ? { estimatedCost, nonUsdCostTotals: nonUsd } : { estimatedCost };
}

export function shouldTrackProviderUsage(provider: Provider): boolean {
  return isValidProviderKind(provider.kind);
}

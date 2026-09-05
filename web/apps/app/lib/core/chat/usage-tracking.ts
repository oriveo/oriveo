/**
 * Usage tracking helpers: conversation cost recalculation and the provider reporting switch.
 *
 * - `recalculateConversationCost`: a pure function summing delivered messages, filtering out
 *   noise below COST_EPSILON.
 * - `shouldTrackProviderUsage`: platform-proxied providers do not enter BYOK local usage
 *   reporting.
 */

import { isValidProviderKind, type ChatMessage, type Provider } from '@oriveo/shared';
import { COST_EPSILON } from '../../utils/format-utils';

/** Sum a conversation's cost - a deterministic pure function */
export function recalculateConversationCost(messages: ChatMessage[]): number {
  return messages
    .filter((m) => m.state === 'delivered' && m.estimatedCost > COST_EPSILON)
    .reduce((sum, m) => sum + m.estimatedCost, 0);
}

export function shouldTrackProviderUsage(provider: Provider): boolean {
  return isValidProviderKind(provider.kind);
}

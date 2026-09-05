import { normalizeUUID } from '../../utils/id-utils';

let pendingPromotionId: string | null = null;

/** Marks the URL promotion performed after creating a conversation on the new-chat surface. */
export function markNewConversationRoutePromotion(conversationId: string): void {
  pendingPromotionId = normalizeUUID(conversationId);
}

export function isNewConversationRoutePromotion(conversationId: string): boolean {
  return pendingPromotionId === normalizeUUID(conversationId);
}

export function clearNewConversationRoutePromotion(conversationId: string): void {
  if (isNewConversationRoutePromotion(conversationId)) pendingPromotionId = null;
}

export function resetNewConversationRoutePromotionForTests(): void {
  pendingPromotionId = null;
}

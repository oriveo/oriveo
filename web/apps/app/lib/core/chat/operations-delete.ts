/**
 * deleteMessage: remove a single message.
 *
 * - drops it from the conversation and re-aggregates cost
 * - only reports the delete to the syncer for delivered messages; streaming or undelivered ones
 *   are not synced
 * - cleans up attachment resources
 */
import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';
import { getSyncAdapter } from '../sync-port';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { cleanupCloudAttachments } from './cleanup-attachments';
import { recalculateConversationCost } from './usage-tracking';
import { deleteLocalMessageContinuation } from './continuation-lifecycle';

export function deleteMessage(
  store: StoreApi<AppStore>,
  convId: string,
  msgId: string,
) {
  const state = store.getState();
  const conv = state.conversations.find((c) => c.id === convId);
  if (!conv) return;

  const msg = conv.messages.find((m) => m.id === msgId);
  if (!msg) return;
  deleteLocalMessageContinuation(convId, msgId);

  const remaining = conv.messages.filter((m) => m.id !== msgId);
  const remainingLastDelivered = [...remaining].reverse().find((m) => m.state === 'delivered');

  // Bring remoteMessageCount back in line with the delivered count after the delete.
  // Reaching this point means the conversation's messages are hydrated in the store, since a
  // summary-only conversation returns early when the message is not found, so remaining is the
  // real full set. Without this, deleting every message leaves remoteMessageCount above zero,
  // the "messages.length===0 && remoteMessageCount>0" branch in
  // putConversationPreservingHydratedMessages fires by mistake, and the messages already deleted
  // from IDB are written back, so deleted messages reappear.
  // Syncing users are safe too: the delete reaches the cloud through didDeleteMessages, so the
  // cloud never pushes a deleted message back.
  const deliveredCount = remaining.filter((m) => m.state === 'delivered').length;

  state.updateConversation(convId, {
    messages: remaining,
    remoteMessageCount: deliveredCount,
    ...deriveConversationMetadata(conv, remaining),
    estimatedCost: recalculateConversationCost(remaining),
    updatedAt: computeConversationActivityAt(remaining, conv.createdAt),
  });

  // Only delivered messages have their deletion synced
  if (msg.state === 'delivered') {
    getSyncAdapter()?.didDeleteMessages([msgId], convId, remainingLastDelivered);
  }

  // Clean up this message's attachments
  if (msg.attachments?.length) {
    cleanupCloudAttachments([msg]);
  }
}

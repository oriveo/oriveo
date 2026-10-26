import type { Conversation } from '@oriveo/shared';
import { getActiveUIDSync } from './partition';
import { putConversationPreservingHydratedMessagesReportingDroppedKeys } from './idb';
import { purgeUnreferencedImages } from './image-orphan-sweeper';

/**
 * Whole-conversation write plus image cleanup after messages were dropped.
 * Only after the write transaction completes are the attachment keys of the dropped messages handed
 * to purgeUnreferencedImages; the purge reads the committed reference set of the whole partition
 * and never writes the conversation store. Kept as its own module so idb and image-orphan-sweeper
 * do not import each other.
 */
export async function putConversationAndPurgeDroppedImages(
  conversation: Conversation,
  expectedUID?: string,
): Promise<boolean> {
  const uid = expectedUID ?? getActiveUIDSync();
  const result = await putConversationPreservingHydratedMessagesReportingDroppedKeys(conversation, expectedUID);
  if (result.written && result.droppedImageKeys.length > 0) {
    void purgeUnreferencedImages(result.droppedImageKeys, uid).catch(() => {
      // When the reference set cannot be read the purge itself deletes nothing; this only swallows the abort from a partition switch in flight and does not affect the committed write.
    });
  }
  return result.written;
}

/**
 * Clean up cloud attachments: collect storageRef values from a message list and call the sync
 * adapter asynchronously to delete the Cloud Storage files.
 */

import type { ChatMessage } from '@oriveo/shared';
import { deleteAttachments } from '../sync-port';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { withErrorReporting } from '../../sentry/report-silent';

export function cleanupCloudAttachments(messages: ChatMessage[]): void {
  const refs = Array.from(new Set(
    messages.flatMap((msg) => msg.attachments?.map((att) => att.storageRef).filter((ref): ref is string => Boolean(ref)) ?? []),
  ));
  if (refs.length === 0) return;
  // Capture the partition key synchronously and guard against guest, on the same terms as
  // conversation-ops and stream-image-utils: resolving the uid inside the promise instead would,
  // after a logout, delete storageRefs belonging to the previous account under the guest Storage path.
  const uid = getActiveUIDSync();
  if (uid === 'guest') return;
  Promise.resolve(deleteAttachments(uid, refs)).catch(withErrorReporting('attachments.cleanup'));
}

import type { ChatMessage } from '@oriveo/shared';

/**
 * Collect the image candidate keys of message attachments: both the attachment's
 * localImageID and its attachment.id (used for remote downloads) count.
 * Only used to pick candidates on delete paths; whether an image is really deleted is decided
 * by purgeUnreferencedImages against the committed reference set.
 */
export function collectAttachmentKeys(
  messages: readonly ChatMessage[] | undefined,
  into: Set<string> = new Set(),
): Set<string> {
  for (const message of messages ?? []) {
    for (const attachment of message.attachments ?? []) {
      if (attachment.id) into.add(attachment.id);
      if (attachment.localImageID) into.add(attachment.localImageID);
    }
  }
  return into;
}

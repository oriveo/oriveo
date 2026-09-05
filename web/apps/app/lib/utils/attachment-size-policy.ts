/**
 * Attachment size policy.
 *
 * The limit comes from the server entitlement (`limits.singleFileBytes`):
 *  - Free 25 MB
 *  - Pro / Lifetime 100 MB
 *
 * Callers pass the runtime limit; without one the 50 MB fallback applies, which only matters in the
 * narrow window before the entitlement has hydrated.
 */

export const FALLBACK_ATTACHMENT_BYTES = 50 * 1024 * 1024;

/** @deprecated Use entitlement.limits.singleFileBytes; kept only as a fallback for older imports. */
export const MAX_CHAT_ATTACHMENT_BYTES = FALLBACK_ATTACHMENT_BYTES;

export function isOversizedChatAttachment(file: File, limitBytes: number = FALLBACK_ATTACHMENT_BYTES): boolean {
  if (limitBytes <= 0) return false;
  return file.size > limitBytes;
}

/**
 * Hard cap on the number of attachments in a single message.
 *
 * Semantics:
 *  - Images, files and videos count together, never separately.
 *  - Accept the prefix that fits the remaining quota and reject the rest, reporting how many were
 *    rejected. The whole batch is never rejected.
 *  - A limit of 0 or less rejects everything.
 *
 * The limit comes from `resolveFileExtractionLimits(model).maxFiles`, which is always 3 here: see
 * that function's comment for why maxFiles is a product constraint that deliberately does not accept
 * a model override. The managed path has its own equivalent gate in
 * `partitionManagedAttachmentFiles`.
 *
 * Beyond the "lost in the middle" problem with many files, this gate also protects the sync backend:
 * hundreds of attachments on one message push the attachments array, which carries a base64
 * thumbnail per item, past the 1MiB per-document limit. That limit is only checked at commit time on
 * the server, so the whole batch of messages would be permanently rejected.
 */
export function limitAttachmentCount<T>(
  existingCount: number,
  incoming: T[],
  maxAttachments: number,
): { accepted: T[]; rejectedCount: number } {
  const availableSlots = maxAttachments > 0 ? Math.max(maxAttachments - existingCount, 0) : 0;
  if (incoming.length <= availableSlots) return { accepted: incoming, rejectedCount: 0 };
  return {
    accepted: incoming.slice(0, availableSlots),
    rejectedCount: incoming.length - availableSlots,
  };
}

export function partitionFilesByAttachmentSize(
  files: File[],
  limitBytes: number = FALLBACK_ATTACHMENT_BYTES,
): { accepted: File[]; oversized: File[] } {
  return files.reduce(
    (result, file) => {
      if (isOversizedChatAttachment(file, limitBytes)) {
        result.oversized.push(file);
      } else {
        result.accepted.push(file);
      }
      return result;
    },
    { accepted: [] as File[], oversized: [] as File[] },
  );
}

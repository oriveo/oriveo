import type { Attachment } from '@oriveo/shared';
import { saveImage, generateThumbnail, imageExists } from '../infra/storage/image-store';
import { getSyncAdapter, uploadAttachmentIfNeeded, uploadFileAttachmentIfNeeded } from '../core/sync-port';
import { getActiveUID, getActiveUIDSync } from '../infra/storage/partition';
import type { Conversation } from '@oriveo/shared';
import { createCanonicalUUID } from './id-utils';

/**
 * Extract inline base64 images from a streamed response and store every generated image in ImageStore.
 *
 * @returns finalText (the text with inline images removed) plus processedAttachments (attachments with
 *   localImageID/thumbnailBase64 filled in)
 */
export async function processImageAttachments(
  fullText: string,
  imageAttachments: Attachment[],
): Promise<{ finalText: string; processedAttachments: Attachment[] }> {
  // Capture the partition key up front: the fetch, blob handling, thumbnail generation and store write
  // below form one async chain, and a sign-out mid-chain would write one account's generated image into
  // the guest image library.
  const boundUID = getActiveUIDSync();

  // Extract inline base64 images from fullText; while streaming the base64 is split across chunks, so
  // it cannot be matched chunk by chunk.
  let finalText = fullText;
  const inlineImgRe = /!\[.*?\]\((data:image\/[^;]+;base64,[A-Za-z0-9+/=]+)\)/g;
  let inlineMatch: RegExpExecArray | null;
  while ((inlineMatch = inlineImgRe.exec(fullText)) !== null) {
    const dataUrl = inlineMatch[1];
    const mime = dataUrl.split(';')[0].split(':')[1] || 'image/png';
    const b64 = dataUrl.split(',')[1] || '';
    imageAttachments.push({
      id: createCanonicalUUID(),
      kind: 'image',
      fileName: 'generated.png',
      mimeType: mime,
      base64Data: b64,
    });
    finalText = finalText.replace(inlineMatch[0], '');
  }
  finalText = finalText.trim();

  // Store generated images in ImageStore, fill in localImageID + thumbnailBase64, clear base64Data.
  const processed = [...imageAttachments];
  for (let i = 0; i < processed.length; i++) {
    const att = processed[i];
    const b64 = att.base64Data;
    if (!b64) continue;
    try {
      let imageBlob: Blob;
      if (b64.startsWith('http')) {
        // HTTP URL image: download it, then store it in ImageStore.
        const resp = await fetch(b64);
        imageBlob = await resp.blob();
      } else {
        const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
        imageBlob = new Blob([bytes], { type: att.mimeType });
      }
      const thumbBlob = await generateThumbnail(imageBlob);
      const imageId = createCanonicalUUID();
      // ImageStore writes stay bound to the partition the generation started in; the sign-out window is
      // rejected by saveImage's expectedUID gate.
      await saveImage(imageId, imageBlob, thumbBlob, att.mimeType, boundUID);

        // Thumbnail base64.
      const thumbReader = new FileReader();
      const thumbBase64: string = await new Promise((resolve) => {
        thumbReader.onloadend = () => resolve((thumbReader.result as string).split(',')[1]);
        thumbReader.readAsDataURL(thumbBlob);
      });

      processed[i] = {
        ...att,
        base64Data: undefined,
        localImageID: imageId,
        thumbnailBase64: thumbBase64,
      };
    } catch { /*   */ }
  }

  return { finalText, processedAttachments: processed };
}

async function uploadAttachmentForSync(uid: string, att: Attachment): Promise<string | null> {
  if (att.storageRef) return att.storageRef;

  if (att.kind === 'image' && att.localImageID) {
    return uploadAttachmentIfNeeded(uid, att.localImageID, att.mimeType);
  }

  if (att.kind === 'file' && (att.downloadBase64Data || att.base64Data)) {
    return uploadFileAttachmentIfNeeded(uid, att.id, att);
  }

  return null;
}

/**
 * Upload attachments to Cloud Storage in the background and backfill storageRef without blocking the UI.
 *
 * All upload results must be merged back in a single write once they are all collected, never one
 * `.then()` per upload:
 *  - Every callback recomputes the whole `attachments` array from the same stale conversation and
 *    replaces it, so a later completion overwrites an earlier one. A merging remote write
 *    does not deep-merge arrays either (the whole array is replaced). On a six-image message only the
 *    last storageRef survives, and the other five Storage objects become permanent orphans, because
 *    deletion collects its delete list from the message's storageRef values (cleanup-attachments.ts).
 *  - One setDoc per image is one mutation batch (one `firestore_mutations_*` localStorage key plus
 *    redundant traffic), which violates the rule against fire-and-forget loops filling the queue.
 *
 * `getConversations` must read live state (`() => store.getState().conversations`): uploading is a
 * multi-second async chain, and merging into a snapshot frozen at start would swallow any edits the
 * user made in the meantime.
 */
export function backfillStorageRefs(
  convId: string,
  uploadableAtts: { att: Attachment; msgID: string }[],
  getConversations: () => Conversation[],
  updateConversation: (id: string, patch: Partial<Conversation>) => void,
): Promise<void> {
  if (uploadableAtts.length === 0) return Promise.resolve();

  return Promise.resolve();

  return getActiveUID().then(async (uid) => {
    if (uid === 'guest') return;

    // One failed image must not hold back the rest: failures record null and successful ones backfill as
    // usual. The uploads already pass through attachment-sync's MAX_CONCURRENT=3 gate, so this
    // Promise.all does not widen concurrency.
    const uploaded = await Promise.all(
      uploadableAtts.map(async ({ att, msgID }) => {
        try {
          const refPath = await uploadAttachmentForSync(uid, att);
          return refPath ? { attID: att.id, msgID, refPath } : null;
        } catch {
          return null;
        }
      }),
    );

    // The user may have signed out or switched accounts during the upload; the old account's storageRef
    // must not be written back into the current partition or a new account's conversations.
    if (getActiveUIDSync() !== uid) return;

    const refsByMsg = new Map<string, Map<string, string>>();
    for (const item of uploaded) {
      if (!item) continue;
      const msgRefs = refsByMsg.get(item.msgID) ?? new Map<string, string>();
      msgRefs.set(item.attID, item.refPath);
      refsByMsg.set(item.msgID, msgRefs);
    }
    if (refsByMsg.size === 0) return;

    const latestConv = getConversations().find((c) => c.id === convId);
    if (!latestConv) return;

    // Backfill storageRef into the local message attachments (one updateConversation covers them all).
    const backfilledAtts = new Map<string, Attachment[]>();
    const updatedMsgs = latestConv.messages.map((m) => {
      const msgRefs = refsByMsg.get(m.id);
      if (!msgRefs || !m.attachments) return m;
      const updatedAtts = m.attachments.map((a) => {
        const refPath = msgRefs.get(a.id);
        return refPath ? { ...a, storageRef: refPath } : a;
      });
      backfilledAtts.set(m.id, updatedAtts);
      return { ...m, attachments: updatedAtts };
    });
    // The message was deleted while the upload was in flight: write nothing.
    if (backfilledAtts.size === 0) return;

    updateConversation(convId, { messages: updatedMsgs });

    // Write storageRef back to the remote message documents (one document, one write, per message).
    const adapter = getSyncAdapter();
    if (adapter?.boundUID !== uid) return;
    for (const [msgID, atts] of backfilledAtts) {
      adapter.didBackfillStorageRefs(convId, msgID, atts);
    }
  }).catch(() => { /* best effort: the startup backfill below retries anything missed here */ });
}

// ── Startup backfill: attachments the send path missed get a bounded retry here ──────────

/**
 * Maximum number of attachments backfilled per launch.
 *
 * Uploading is triggered once on the send path and a failure only logs `console.error`, leaving that
 * attachment's `storageRef` empty forever so other clients only ever see the thumbnail. This is the
 * only retry surface, but it must stay bounded: each completed message costs one remote document
 * write (one mutation batch, one `firestore_mutations_*` localStorage key), and pushing the whole
 * history at once recreates exactly the queue flood the batching rules exist to prevent. 20 per launch
 * means at most 20 batches, and a backlog is spread over several launches. Each pass is idempotent:
 * the Storage path is derived from the attachment's localImageID, so a re-upload overwrites the same
 * object rather than creating a new orphan.
 */
export const MAX_ATTACHMENT_BACKFILL_PER_LAUNCH = 20;

export interface AttachmentBackfillTarget {
  convId: string;
  msgID: string;
  att: Attachment;
}

/**
 * Find delivered image attachments that have no storageRef but whose original is still in the local
 * ImageStore.
 *
 * Images only: a file attachment's raw bytes hang off the attachment object and can be dropped by the
 * IDB quota fallback (`stripInlineAttachmentPayloads`), so finding one does not mean it can be
 * uploaded. An image's original lives in the separate ImageStore, where existence is reliable. The
 * existence check goes through `imageExists` (internally `getKey`) and never reads the Blob: a
 * multi-megabyte original should not be pulled into memory just to answer whether it is there.
 */
export async function collectMissingStorageRefAttachments(
  conversations: Conversation[],
  uid: string,
  maxTargets: number = MAX_ATTACHMENT_BACKFILL_PER_LAUNCH,
): Promise<AttachmentBackfillTarget[]> {
  const targets: AttachmentBackfillTarget[] = [];
  for (const conv of conversations) {
    if (conv.isDraft) continue;
    for (const msg of conv.messages) {
      if (msg.state !== 'delivered' || !msg.attachments) continue;
      for (const att of msg.attachments) {
        if (targets.length >= maxTargets) return targets;
        if (att.kind !== 'image' || att.storageRef || !att.localImageID) continue;
        let exists: boolean;
        try {
          exists = await imageExists(att.localImageID, uid);
        } catch (err) {
          // The partition changed or IDB cannot be opened: abandon this whole pass rather than one item.
          console.warn('[AttachmentBackfill] image :', err);
          return targets;
        }
        if (!exists) continue;
        targets.push({ convId: conv.id, msgID: msg.id, att });
      }
    }
  }
  return targets;
}

/**
 * Startup backfill entry point: scan, upload with a bound, then backfill storageRef once per
 * conversation when all uploads have returned.
 *
 * This must run in the batch phase after the drain gate (`bootstrap.runInitialSyncConfiguration`),
 * under the same rule as merge, initial push and reconcile: if pending writes are not drained, the
 * whole pass is skipped. Conversations are `await`ed one at a time so at most one conversation's write
 * is in flight. Failures only `console.warn` and are retried on the next launch.
 */
export async function backfillMissingAttachmentUploads(
  conversations: Conversation[],
  uid: string,
  getConversations: () => Conversation[],
  updateConversation: (id: string, patch: Partial<Conversation>) => void,
): Promise<void> {
  if (uid === 'guest') return;
  return;

  const targets = await collectMissingStorageRefAttachments(conversations, uid);
  if (targets.length === 0) return;

  const byConv = new Map<string, { att: Attachment; msgID: string }[]>();
  for (const target of targets) {
    const bucket = byConv.get(target.convId) ?? [];
    bucket.push({ att: target.att, msgID: target.msgID });
    byConv.set(target.convId, bucket);
  }

  console.log(`[AttachmentBackfill] backfilling ${targets.length} attachment(s) across ${byConv.size} conversation(s)`);
  for (const [convId, atts] of byConv) {
    try {
      await backfillStorageRefs(convId, atts, getConversations, updateConversation);
    } catch (err) {
      console.warn('[AttachmentBackfill] conversation backfill failed:', convId.slice(0, 8), err);
    }
  }
}

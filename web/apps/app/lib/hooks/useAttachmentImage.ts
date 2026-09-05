import { useState, useEffect } from 'react';
import type { Attachment } from '@oriveo/shared';
import { loadImageData } from '../infra/storage/image-store';
import { downloadAttachmentIfNeeded } from '../core/sync-port';
import { getActiveUID } from '../infra/storage/partition';

/**
 * Load an attachment image asynchronously, showing the thumbnail first.
 * Returns a URL usable as an <img src>: a thumbnail data URL or an Object URL for the full image.
 *
 * Load order:
 * 1. thumbnailBase64: show the thumbnail immediately.
 * 2. localImageID: load the full image from ImageStore as an Object URL.
 * 3. storageRef: download the full image from Cloud Storage, put it in ImageStore, return an Object URL.
 */
export function useAttachmentImage(att: Attachment): string | null {
  // Initial value order: thumbnailBase64 > base64Data > null.
  const initial = att.thumbnailBase64
    ? `data:image/jpeg;base64,${att.thumbnailBase64}`
    : att.base64Data
      ? (att.base64Data.startsWith('http') ? att.base64Data : `data:${att.mimeType};base64,${att.base64Data}`)
      : null;

  const [url, setUrl] = useState<string | null>(initial);

  useEffect(() => {
    let revoked: string | null = null;
    let cancelled = false;

    (async () => {
      // Prefer the local ImageStore.
      if (att.localImageID) {
        const blob = await loadImageData(att.localImageID);
        if (blob && !cancelled) {
          revoked = URL.createObjectURL(blob);
          setUrl(revoked);
          return;
        }
      }

      // Nothing local but a storageRef is present, so download from Cloud Storage.
      if (att.storageRef && att.kind === 'image') {
        const uid = await getActiveUID();
        if (uid === 'guest' || cancelled) return;
        const imageId = att.id; // the attachment id doubles as the ImageStore key
        const downloaded = await downloadAttachmentIfNeeded(uid, att.storageRef, imageId, att.mimeType);
        if (downloaded && !cancelled) {
          const blob = await loadImageData(downloaded);
          if (blob && !cancelled) {
            revoked = URL.createObjectURL(blob);
            setUrl(revoked);
          }
        }
      }
    })();

    return () => {
      cancelled = true;
      if (revoked) URL.revokeObjectURL(revoked);
    };
  }, [att.localImageID, att.storageRef, att.id, att.kind, att.mimeType]);

  return url;
}

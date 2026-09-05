/**
 *  / 
 *   MessageBubble  
 */
import type { Attachment } from '@oriveo/shared';
import { downloadFileBlob, downloadFileURL } from '../core/sync-port';

const DOWNLOAD_CLEANUP_DELAY_MS = 30_000;

function decodeBase64ToBlob(base64: string, mimeType: string): Blob {
  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  return new Blob([bytes], { type: mimeType });
}

function scheduleDownloadCleanup(
  elements: HTMLElement[],
  revoke?: () => void,
): void {
  window.setTimeout(() => {
    for (const element of elements) {
      element.remove();
    }
    revoke?.();
  }, DOWNLOAD_CLEANUP_DELAY_MS);
}

function buildRemoteDownloadURL(url: string, fileName: string): string {
  try {
    const parsed = new URL(url);
    parsed.searchParams.set(
      'response-content-disposition',
      `attachment; filename*=UTF-8''${encodeURIComponent(fileName)}`,
    );
    return parsed.toString();
  } catch {
    return url;
  }
}

function triggerBlobDownload(blob: Blob, fileName: string): void {
  const blobUrl = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = blobUrl;
  anchor.download = fileName;
  anchor.rel = 'noopener';
  anchor.style.display = 'none';
  document.body.appendChild(anchor);
  anchor.click();
  scheduleDownloadCleanup([anchor], () => URL.revokeObjectURL(blobUrl));
}

function triggerRemoteURLDownload(
  url: string,
  fileName: string,
): void {
  const anchor = document.createElement('a');
  anchor.href = buildRemoteDownloadURL(url, fileName);
  anchor.download = fileName;
  anchor.rel = 'noopener';
  anchor.style.display = 'none';
  document.body.appendChild(anchor);
  anchor.click();
  scheduleDownloadCleanup([anchor]);
}

async function fetchRemoteDownloadBlob(
  url: string,
  fileName: string,
): Promise<Blob | null> {
  try {
    const response = await fetch(buildRemoteDownloadURL(url, fileName));
    if (!response.ok) return null;
    return await response.blob();
  } catch {
    return null;
  }
}

export function buildLocalFileBlob(att: Attachment): Blob | null {
  if (att.downloadBase64Data) {
    try {
      return decodeBase64ToBlob(att.downloadBase64Data, att.mimeType || 'application/octet-stream');
    } catch {
      // Fall through to legacy payloads below.
    }
  }

  if (!att.base64Data) return null;

  const isPdf = att.mimeType === 'application/pdf'
    || att.fileName.toLowerCase().endsWith('.pdf');

  if (isPdf) {
    try {
      return decodeBase64ToBlob(att.base64Data, 'application/pdf');
    } catch {
      return new Blob([att.base64Data], { type: 'text/plain;charset=utf-8' });
    }
  }

  return new Blob([att.base64Data], { type: att.mimeType || 'text/plain;charset=utf-8' });
}

/**
 * Open a file attachment for download/preview from local bytes first, then a remote URL.
 */
export async function previewFileAttachment(
  att: Attachment,
  onDownloadStart: (id: string) => void,
  onDownloadEnd: () => void,
): Promise<void> {
  const localBlob = buildLocalFileBlob(att);
  if (localBlob) {
    triggerBlobDownload(localBlob, att.fileName);
    return;
  }

  if (att.storageRef) {
    onDownloadStart(att.id);
    try {
      const blob = await downloadFileBlob(att.storageRef);
      if (blob) {
        triggerBlobDownload(blob, att.fileName);
        return;
      }
    } catch {
      // Fall through to download URL fallback below.
    }

    try {
      const url = await downloadFileURL(att.storageRef);
      if (url) {
        const fetchedBlob = await fetchRemoteDownloadBlob(url, att.fileName);
        if (fetchedBlob) {
          triggerBlobDownload(fetchedBlob, att.fileName);
          return;
        }

        triggerRemoteURLDownload(url, att.fileName);
        return;
      }
    } finally {
      onDownloadEnd();
    }
  }
}

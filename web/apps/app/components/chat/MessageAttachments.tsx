'use client';

import { useTranslations } from 'next-intl';
import type { Attachment } from '@oriveo/shared';
import { FileIcon } from '@oriveo/ui';
import { AttachmentImage } from './AttachmentImage';
import styles from './MessageBubble.module.css';

export function UserImageAttachments({ attachments }: { attachments: Attachment[] }) {
  const images = attachments.filter((att) => att.kind === 'image');
  if (images.length === 0) return null;
  return (
    <div className={styles.userAttachments}>
      {images.map((att) => (
        <AttachmentImage key={att.id} attachment={att} className={styles.userAttachmentImage} asLink />
      ))}
    </div>
  );
}

export function UserFileChips({ attachments, downloadingFileId, onPreview }: {
  attachments: Attachment[]; downloadingFileId: string | null; onPreview: (att: Attachment) => void;
}) {
  const t = useTranslations('pages.chat');
  const files = attachments.filter((att) => att.kind === 'file');
  if (files.length === 0) return null;
  return (
    <div className={styles.bubbleFiles}>
      {files.map((att) => {
        const isUnavailable = !att.base64Data && !att.storageRef;
        const isDownloading = downloadingFileId === att.id;
        const title = isUnavailable
          ? t('attachmentOnlyOnOriginalDevice')
          : isDownloading
            ? t('attachmentDownloading')
            : att.fileName;
        return (
          <button key={att.id} type="button"
            className={`${styles.fileChip}${isUnavailable ? ` ${styles.fileChipRemoteOnly}` : ''}${isDownloading ? ` ${styles.fileChipLoading}` : ''}`}
            onClick={() => onPreview(att)} disabled={isUnavailable || isDownloading}
            title={title}>
            <FileIcon size={14} /><span>{att.fileName}</span>
          </button>
        );
      })}
    </div>
  );
}

export function GeneratedImages({ attachments }: { attachments: Attachment[] }) {
  const images = attachments.filter((att) => att.kind === 'image');
  if (images.length === 0) return null;
  const layout = images.length > 1 ? 'grid' : 'single';

  return (
    <div
      className={`${styles.generatedImages} ${layout === 'single' ? styles.generatedImagesSingle : styles.generatedImagesGrid}`}
      role="list"
      data-layout={layout}
    >
      {images.map((att) => (
        <figure key={att.id} className={styles.generatedImageCard} role="listitem">
          <AttachmentImage
            attachment={att}
            className={styles.generatedImage}
            linkClassName={styles.generatedImageLink}
            asLink
          />
        </figure>
      ))}
    </div>
  );
}

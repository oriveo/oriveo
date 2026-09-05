'use client';

import React from 'react';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import type { Attachment } from '@oriveo/shared';
import { FileIcon, CloseIcon } from '@oriveo/ui';
import { useAppStore } from '../../providers/StoreProvider';
import { selectActiveProvider } from '../../lib/core/store/selectors';
import styles from './AttachmentPreview.module.css';

interface AttachmentPreviewProps {
  attachments: Attachment[];
  onRemove: (id: string) => void;
}

export function AttachmentPreview({ attachments, onRemove }: AttachmentPreviewProps) {
  const tc = useTranslations('common');
  const tfe = useTranslations('pages.chat.fileExtraction');
  const router = useRouter();
  // The CTA only shows when the current provider is OpenAI and a key is configured, since
  // the knowledge base is OpenAI only, backed by the Vector Store and Files API.
  const activeProvider = useAppStore(selectActiveProvider);
  const canUseKnowledge = activeProvider?.kind === 'openAI' && !!activeProvider?.apiKey;
  if (attachments.length === 0) return null;

  return (
    <div className={styles.row}>
      {attachments.map((att) => {
        const lines = att.extractedTotalLines;
        const showInfo = att.kind === 'file' && typeof lines === 'number' && lines > 0;
        const infoLabel = showInfo
          ? `${tfe('extractedLines', { count: lines })}${att.extractedTruncated ? ' ⚠︎' : ''}`
          : null;
        const showCta = att.kind === 'file' && att.extractedTruncated === true && canUseKnowledge;
        return (
          <div key={att.id} className={styles.item}>
            {att.kind === 'image' && att.thumbnailBase64 ? (
              // Thumbnails are inline base64 previews generated on the client, so next/image provides no benefit here.
              // eslint-disable-next-line @next/next/no-img-element
              <img
                className={styles.thumbnail}
                src={`data:image/jpeg;base64,${att.thumbnailBase64}`}
                alt={att.fileName}
              />
            ) : (
              <div className={styles.fileIcon}>
                <FileIcon />
              </div>
            )}
            <span className={styles.fileName}>{att.fileName}</span>
            {infoLabel && <span className={styles.extractedInfo}>{infoLabel}</span>}
            {showCta && (
              <button
                type="button"
                className={styles.ctaKnowledge}
                onClick={() => router.push('/skills/edit')}
              >
                {tfe('truncatedCtaKnowledge')}
              </button>
            )}
            <button
              type="button"
              className={styles.removeBtn}
              onClick={() => onRemove(att.id)}
              aria-label={tc('remove')}
            >
              <CloseIcon size={12} />
            </button>
          </div>
        );
      })}
    </div>
  );
}

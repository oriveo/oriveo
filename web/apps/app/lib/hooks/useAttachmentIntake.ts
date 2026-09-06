import { useState, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import type { Attachment } from '@oriveo/shared';
import { loadAttachmentUtils } from '../utils/attachment-utils-lazy';
import { limitAttachmentCount, partitionFilesByAttachmentSize } from '../utils/attachment-size-policy';
import { DEFAULT_LIMITS } from '../core/attachments/file-text-extractor';
import { showToast } from '../../components/Toast';
import { FALLBACK_ATTACHMENT_BYTES } from '../utils/attachment-size-policy';

interface UseAttachmentIntakeParams {
  attachments: Attachment[];
  onAttachmentsChange?: (attachments: Attachment[]) => void;
  /** Whether images are supported, which decides if pasted images are accepted. */
  supportsImage: boolean;
  /** Normalized provider.kind, used for attachment_added reporting. */
  providerKind?: string;
}

/**
 * Attachment intake: file picking, pasted images and removal, with the capacity gate (reject when
 * exhausted, prompt to upgrade or show the hard-limit dialog when over) and conversion checks.
 * Returns showAttachmentSizeLimit so the caller can render the size limit dialog.
 */
export function useAttachmentIntake({
  attachments,
  onAttachmentsChange,
  supportsImage,
  providerKind,
}: UseAttachmentIntakeParams) {
  const [showAttachmentSizeLimit, setShowAttachmentSizeLimit] = useState(false);
  const tfe = useTranslations('pages.chat.fileExtraction');

  const handleAddFiles = useCallback(
    async (files: File[]) => {
      if (!onAttachmentsChange) return;
      const sized = partitionFilesByAttachmentSize(files, FALLBACK_ATTACHMENT_BYTES);
      if (sized.oversized.length > 0) {
        setShowAttachmentSizeLimit(true);
      }
      // Hard count limit: without a total cap, a few hundred images would push the message document past 1MiB.
      const counted = limitAttachmentCount(attachments.length, sized.accepted, DEFAULT_LIMITS.maxFiles);
      const accepted = counted.accepted;
      if (counted.rejectedCount > 0) {
        showToast(tfe('tooManyFiles', { maxFiles: DEFAULT_LIMITS.maxFiles }));
      }
      if (accepted.length === 0) {
        return;
      }

      const { validateAndConvertFiles } = await loadAttachmentUtils();
      const newAttachments = await validateAndConvertFiles(accepted, 'file', providerKind);
      if (newAttachments.length > 0) {
        onAttachmentsChange([...attachments, ...newAttachments]);
      }
    },
    [attachments, onAttachmentsChange, providerKind, tfe],
  );

  const handleFileInput = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const selectedFiles = e.target.files ? Array.from(e.target.files) : [];
      e.target.value = '';
      if (selectedFiles.length > 0) {
        handleAddFiles(selectedFiles);
      }
    },
    [handleAddFiles],
  );

  const handlePaste = useCallback(
    (e: React.ClipboardEvent) => {
      if (!onAttachmentsChange || !supportsImage) return;
      const files = Array.from(e.clipboardData.items)
        .filter((item) => item.type.startsWith('image/'))
        .map((item) => item.getAsFile())
        .filter((f): f is File => f !== null);
      if (files.length > 0) {
        handleAddFiles(files);
      }
    },
    [supportsImage, onAttachmentsChange, handleAddFiles],
  );

  const handleRemoveAttachment = useCallback(
    (id: string) => {
      onAttachmentsChange?.(attachments.filter((a) => a.id !== id));
    },
    [attachments, onAttachmentsChange],
  );

  return {
    showAttachmentSizeLimit,
    setShowAttachmentSizeLimit,
    handleAddFiles,
    handleFileInput,
    handlePaste,
    handleRemoveAttachment,
  };
}

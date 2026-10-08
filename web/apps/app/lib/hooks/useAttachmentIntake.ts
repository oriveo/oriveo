import { useState, useCallback, useRef } from 'react';
import { useTranslations } from 'next-intl';
import type { Attachment } from '@oriveo/shared';
import { appendAttachmentsWithinLimit, importAttachmentFiles } from '../core/attachments/attachment-import';

/**
 * The next state of the attachment tray: either the array itself or a function of the current
 * state. Importing and removing both use the latter; see attachment-import.
 */
export type AttachmentsChange = Attachment[] | ((current: Attachment[]) => Attachment[]);

interface UseAttachmentIntakeParams {
  attachments: Attachment[];
  onAttachmentsChange?: (next: AttachmentsChange) => void;
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

  // Importing is asynchronous: the `attachments` captured when the callback was created may be
  // stale by the time the files have been read, so the gate reads a ref.
  const attachmentsRef = useRef(attachments);
  attachmentsRef.current = attachments;

  const handleAddFiles = useCallback(
    async (files: File[]) => {
      if (!onAttachmentsChange) return;
      await importAttachmentFiles({
        files,
        source: 'file',
        providerKind,
        getAttachments: () => attachmentsRef.current,
        commit: (incoming, maxAttachments) =>
          onAttachmentsChange((current) => appendAttachmentsWithinLimit(current, incoming, maxAttachments)),
        onRejectedBySize: () => setShowAttachmentSizeLimit(true),
        translate: tfe,
      });
    },
    [onAttachmentsChange, providerKind, tfe],
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
      // Remove against the current state: while an import's write-back is in flight, filtering
      // the captured array would drop the attachments that were just merged in.
      onAttachmentsChange?.((current) => current.filter((a) => a.id !== id));
    },
    [onAttachmentsChange],
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

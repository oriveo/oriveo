import { useState, useCallback, useRef } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import type { AIModel, Attachment } from '@oriveo/shared';
import { appendAttachmentsWithinLimit, importAttachmentFiles } from '../core/attachments/attachment-import';
import {
  attachmentAcceptance,
  attachmentDisabledMessageKey,
  type AttachmentCapabilities,
} from '../core/chat/attachment-policy';
import { showToast } from '../../components/Toast';

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
  /** The currently selected model: import truncates and checks the total against its text limits; defaults apply when omitted. */
  currentModel?: AIModel | null;
  /**
   * Judges each attachment one by one (see useAttachmentRejectionGate); when given, both file picking and
   * pasting go through this gate, and a pasted image is handed to it even when images are not accepted so
   * it can reject the image and explain why.
   */
  canAcceptAttachment?: (attachment: Attachment) => boolean;
}

/**
 * Rejection gate for the attachment entry points: judges each attachment against the attachment
 * capabilities of the current model x provider; when an image / PDF / video is rejected, a light toast
 * states the reason for that media (the same reason within one rejected batch is shown only once).
 */
export function useAttachmentRejectionGate(capabilities: AttachmentCapabilities) {
  const t = useTranslations('capability.input');
  const pendingRef = useRef<Set<string> | null>(null);
  return useCallback((attachment: Attachment) => {
    const verdict = attachmentAcceptance(attachment, capabilities);
    if (verdict.accepted) return true;
    if (verdict.media !== 'text' && verdict.reason) {
      const message = t(attachmentDisabledMessageKey(verdict.reason, verdict.media));
      if (!pendingRef.current) {
        const batch = new Set<string>();
        pendingRef.current = batch;
        // Import runs the gate synchronously one by one, so by the next microtask this batch is fully judged.
        queueMicrotask(() => {
          pendingRef.current = null;
          showToast([...batch].join('\n'), 4000, undefined, 'warning');
        });
      }
      pendingRef.current.add(message);
    }
    return false;
  }, [capabilities, t]);
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
  currentModel,
  canAcceptAttachment,
}: UseAttachmentIntakeParams) {
  const [showAttachmentSizeLimit, setShowAttachmentSizeLimit] = useState(false);
  const tfe = useTranslations('pages.chat.fileExtraction');
  const locale = useLocale();

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
        model: currentModel,
        canAcceptAttachment,
        onRejectedBySize: () => setShowAttachmentSizeLimit(true),
        uiLanguage: locale,
        translate: tfe,
      });
    },
    [canAcceptAttachment, currentModel, locale, onAttachmentsChange, providerKind, tfe],
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
      // With a rejection gate, a pasted image is handed to it even when images are not accepted: it is rejected with a reason instead of being silently swallowed.
      if (!onAttachmentsChange || (!supportsImage && !canAcceptAttachment)) return;
      const files = Array.from(e.clipboardData.items)
        .filter((item) => item.type.startsWith('image/'))
        .map((item) => item.getAsFile())
        .filter((f): f is File => f !== null);
      if (files.length > 0) {
        handleAddFiles(files);
      }
    },
    [supportsImage, canAcceptAttachment, onAttachmentsChange, handleAddFiles],
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

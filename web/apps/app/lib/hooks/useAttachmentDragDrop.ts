import { useState, useCallback, useRef, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import type { Attachment } from '@oriveo/shared';
import { loadAttachmentUtils } from '../utils/attachment-utils-lazy';
import { limitAttachmentCount, partitionFilesByAttachmentSize } from '../utils/attachment-size-policy';
import { DEFAULT_LIMITS } from '../core/attachments/file-text-extractor';
import { showToast } from '../../components/Toast';
import type { AttachmentFilePolicy } from './useAttachmentIntake';
import { FALLBACK_ATTACHMENT_BYTES } from '../utils/attachment-size-policy';

/**
 * Hook handling drag-and-drop uploads and global image paste.
 * All the drag/drop/paste logic for ChatView lives here.
 */
export function useAttachmentDragDrop(
  onFilesAccepted: (files: Attachment[]) => void,
  onOversizedFiles?: (files: File[]) => void,
  options: {
    enabled?: boolean;
    canAcceptAttachment?: (attachment: Attachment) => boolean;
    /** The conversation's provider.kind, normalized to snake_case by telemetryProviderKind(). */
    providerKind?: string;
    existingAttachments?: Attachment[];
    attachmentFilePolicy?: AttachmentFilePolicy;
  } = {},
) {
  const [dragActive, setDragActive] = useState(false);
  const tfe = useTranslations('pages.chat.fileExtraction');
  const dragCountRef = useRef(0);
  const enabled = options.enabled ?? true;
  const canAcceptAttachment = options.canAcceptAttachment;
  const providerKind = options.providerKind;
  const existingAttachments = options.existingAttachments ?? [];
  const attachmentFilePolicy = options.attachmentFilePolicy;

  const handleDragEnter = useCallback((e: React.DragEvent) => {
    if (!enabled) return;
    e.preventDefault();
    dragCountRef.current++;
    if (dragCountRef.current > 0) setDragActive(true);
  }, [enabled]);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    if (!enabled) return;
    e.preventDefault();
  }, [enabled]);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    if (!enabled) return;
    e.preventDefault();
    dragCountRef.current--;
    if (dragCountRef.current <= 0) {
      dragCountRef.current = 0;
      setDragActive(false);
    }
  }, [enabled]);

  const handleDrop = useCallback(
    async (e: React.DragEvent) => {
      if (!enabled) return;
      e.preventDefault();
      dragCountRef.current = 0;
      setDragActive(false);

      let accepted: File[];
      if (attachmentFilePolicy) {
        const partition = attachmentFilePolicy.partitionFiles(Array.from(e.dataTransfer.files), existingAttachments);
        accepted = partition.accepted;
        if (partition.rejected.length > 0) {
          onOversizedFiles?.(partition.rejected);
        }
      } else {
        const partition = partitionFilesByAttachmentSize(Array.from(e.dataTransfer.files), FALLBACK_ATTACHMENT_BYTES);
        accepted = partition.accepted;
        if (partition.oversized.length > 0) {
          onOversizedFiles?.(partition.oversized);
        }
        // Hard count limit, the same gate as the InputComposer entry point; see the limitAttachmentCount comment.
        const counted = limitAttachmentCount(existingAttachments.length, accepted, DEFAULT_LIMITS.maxFiles);
        accepted = counted.accepted;
        if (counted.rejectedCount > 0) {
          showToast(tfe('tooManyFiles', { maxFiles: DEFAULT_LIMITS.maxFiles }));
        }
      }
      if (accepted.length === 0) {
        return;
      }

      const { validateAndConvertFiles } = await loadAttachmentUtils();
      const newAttachments = (await validateAndConvertFiles(accepted, 'drag_drop', providerKind))
        .filter((attachment) => canAcceptAttachment?.(attachment) ?? true);
      if (newAttachments.length > 0) {
        onFilesAccepted(newAttachments);
      }
    },
    [attachmentFilePolicy, canAcceptAttachment, enabled, existingAttachments, onFilesAccepted, onOversizedFiles, providerKind, tfe],
  );

  // Global paste (Cmd+V of an image outside the textarea).
  useEffect(() => {
    const handleGlobalPaste = (e: ClipboardEvent) => {
      if (!enabled) return;
      if (document.activeElement?.tagName === 'TEXTAREA') return;
      if (!e.clipboardData) return;

      const imageFiles = Array.from(e.clipboardData.items)
        .filter((item) => item.type.startsWith('image/'))
        .map((item) => item.getAsFile())
        .filter((f): f is File => f !== null);

      if (imageFiles.length > 0) {
        e.preventDefault();
        let accepted: File[];
        if (attachmentFilePolicy) {
          const partition = attachmentFilePolicy.partitionFiles(imageFiles, existingAttachments);
          accepted = partition.accepted;
          if (partition.rejected.length > 0) {
            onOversizedFiles?.(partition.rejected);
          }
        } else {
          const partition = partitionFilesByAttachmentSize(imageFiles, FALLBACK_ATTACHMENT_BYTES);
          accepted = partition.accepted;
          if (partition.oversized.length > 0) {
            onOversizedFiles?.(partition.oversized);
          }
          // Hard count limit, the same gate as the drag-and-drop and InputComposer entry points.
          const counted = limitAttachmentCount(existingAttachments.length, accepted, DEFAULT_LIMITS.maxFiles);
          accepted = counted.accepted;
          if (counted.rejectedCount > 0) {
            showToast(tfe('tooManyFiles', { maxFiles: DEFAULT_LIMITS.maxFiles }));
          }
        }
        if (accepted.length === 0) {
          return;
        }

        loadAttachmentUtils().then(({ validateAndConvertFiles }) => validateAndConvertFiles(accepted, 'paste', providerKind)).then((newAttachments) => {
          const filteredAttachments = newAttachments
            .filter((attachment) => canAcceptAttachment?.(attachment) ?? true);
          if (filteredAttachments.length > 0) {
            onFilesAccepted(filteredAttachments);
          }
        });
      }
    };

    document.addEventListener('paste', handleGlobalPaste);
    return () => document.removeEventListener('paste', handleGlobalPaste);
  }, [attachmentFilePolicy, canAcceptAttachment, enabled, existingAttachments, onFilesAccepted, onOversizedFiles, providerKind, tfe]);

  return {
    dragActive,
    dragHandlers: {
      onDragEnter: handleDragEnter,
      onDragOver: handleDragOver,
      onDragLeave: handleDragLeave,
      onDrop: handleDrop,
    },
  };
}

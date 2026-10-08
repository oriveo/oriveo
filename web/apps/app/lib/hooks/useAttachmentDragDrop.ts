import { useState, useCallback, useRef, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import type { Attachment } from '@oriveo/shared';
import { importAttachmentFiles } from '../core/attachments/attachment-import';

/**
 * Hook handling drag-and-drop uploads and global image paste.
 * All the drag/drop/paste logic for ChatView lives here.
 */
export function useAttachmentDragDrop(
  /**
   * Merges new attachments into the tray. The caller must use a functional update and cut to the
   * limit (`setAttachments((current) => appendAttachmentsWithinLimit(current, incoming, max))`);
   * the second argument is that limit.
   */
  onFilesAccepted: (files: Attachment[], maxAttachments: number) => void,
  onOversizedFiles?: (files: File[]) => void,
  options: {
    enabled?: boolean;
    canAcceptAttachment?: (attachment: Attachment) => boolean;
    /** The conversation's provider.kind, normalized to snake_case by telemetryProviderKind(). */
    providerKind?: string;
    existingAttachments?: Attachment[];
  } = {},
) {
  const [dragActive, setDragActive] = useState(false);
  const tfe = useTranslations('pages.chat.fileExtraction');
  const dragCountRef = useRef(0);
  const enabled = options.enabled ?? true;
  const canAcceptAttachment = options.canAcceptAttachment;
  const providerKind = options.providerKind;
  const existingAttachments = options.existingAttachments ?? [];
  // Importing is asynchronous: the gate reads a ref rather than the array captured when the
  // callback was created.
  const existingAttachmentsRef = useRef(existingAttachments);
  existingAttachmentsRef.current = existingAttachments;

  const importFiles = useCallback(
    (files: File[], source: 'drag_drop' | 'paste') => importAttachmentFiles({
      files,
      source,
      providerKind,
      getAttachments: () => existingAttachmentsRef.current,
      commit: onFilesAccepted,
      canAcceptAttachment,
      onRejectedBySize: (rejected) => onOversizedFiles?.(rejected),
      translate: tfe,
    }),
    [canAcceptAttachment, onFilesAccepted, onOversizedFiles, providerKind, tfe],
  );

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

      await importFiles(Array.from(e.dataTransfer.files), 'drag_drop');
    },
    [enabled, importFiles],
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
        void importFiles(imageFiles, 'paste');
      }
    };

    document.addEventListener('paste', handleGlobalPaste);
    return () => document.removeEventListener('paste', handleGlobalPaste);
  }, [enabled, importFiles]);

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

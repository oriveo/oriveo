'use client';

import { useState, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import type { Conversation, Folder } from '@oriveo/shared';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as folderOps from '../../lib/core/folder-ops';
import { CONVERSATION_DRAG_MIME } from '../../lib/constants/drag';
import { showToast } from '../Toast';

/**
 * Dragging a conversation onto a folder: a dragOver highlight, and a move on drop that skips
 * conversations already in the folder. Only drags carrying the conversation MIME type are
 * accepted, so dragging in external text or files neither highlights nor moves anything.
 */
export function useFolderDragTarget(conversations: Conversation[], folder: Folder) {
  const t = useTranslations('sidebar');
  const [dragOver, setDragOver] = useState(false);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    // getData is restricted during dragover, but types is readable, so use it to accept only in-app conversation drags.
    if (!e.dataTransfer.types.includes(CONVERSATION_DRAG_MIME)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    setDragOver(true);
  }, []);

  const handleDragLeave = useCallback(() => setDragOver(false), []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const convId = e.dataTransfer.getData(CONVERSATION_DRAG_MIME);
    if (!convId) return;
    // Skip conversations that are already in this folder
    if (conversations.some((c) => c.id === convId)) return;
    folderOps.moveConversationToFolder(getVanillaStore(), convId, folder.id);
    showToast(t('movedToFolder', { name: folder.name }));
  }, [conversations, folder.id, folder.name, t]);

  return { dragOver, handleDragOver, handleDragLeave, handleDrop };
}

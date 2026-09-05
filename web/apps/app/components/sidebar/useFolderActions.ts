'use client';

import { useState, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type { Folder } from '@oriveo/shared';
import { getVanillaStore } from '../../providers/StoreProvider';
import { useContextMenu, type ContextMenuItem } from '../ContextMenu';
import * as folderOps from '../../lib/core/folder-ops';
import { showToast } from '../Toast';

interface UseFolderActionsParams {
  folder: Folder;
  onStartRename: () => void;
}

/**
 * Folder actions: the context menu (rename, view, recolor, delete), the delete confirmation and
 * color picker state, and creating a conversation, opening details, confirming a delete and
 * choosing a color.
 */
export function useFolderActions({ folder, onStartRename }: UseFolderActionsParams) {
  const router = useRouter();
  const t = useTranslations('sidebar');
  const { menu, handleContextMenu, closeMenu } = useContextMenu();
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [showColorPicker, setShowColorPicker] = useState(false);

  const handleNewChat = useCallback(() => {
    const convId = folderOps.createConversationInFolder(getVanillaStore(), folder.id);
    if (!convId) return;
    router.push(`/chat/${convId}`);
  }, [folder.id, router]);

  // The folder detail route (/chat/folder/[id]) has no entry point: expanding a folder in place
  // from the sidebar covers the same need on the web, and a full-screen detail page would be
  // redundant with it while only being reachable through the pointer:fine context menu, so touch
  // users could never get there.
  // const handleOpenDetail = useCallback(() => {
  //   router.push(`/chat/folder/${folder.id}`);
  //   closeMenu();
  // }, [folder.id, router, closeMenu]);

  const handleConfirmDelete = useCallback(() => {
    folderOps.deleteFolder(getVanillaStore(), folder.id);
    showToast(t('folderDeleted'));
    setShowDeleteConfirm(false);
  }, [folder.id, t]);

  const handleChangeColor = useCallback(() => {
    setShowColorPicker(true);
    closeMenu();
  }, [closeMenu]);

  const handleSelectColor = useCallback((color: string) => {
    folderOps.updateFolderColor(getVanillaStore(), folder.id, color);
  }, [folder.id]);

  const contextMenuItems = useMemo<ContextMenuItem[]>(() => [
    { label: t('renameFolder'), onAction: () => { onStartRename(); closeMenu(); } },
    // { label: t('viewFolder'), onAction: handleOpenDetail }, //  
    { label: t('changeColor'), onAction: handleChangeColor },
    { label: t('deleteFolder'), danger: true, onAction: () => { setShowDeleteConfirm(true); closeMenu(); } },
  ], [t, onStartRename, handleChangeColor, closeMenu]);

  const onContextMenu = useCallback((e: React.MouseEvent) => {
    handleContextMenu(e, contextMenuItems);
  }, [handleContextMenu, contextMenuItems]);

  return {
    menu,
    closeMenu,
    onContextMenu,
    showDeleteConfirm,
    setShowDeleteConfirm,
    handleConfirmDelete,
    showColorPicker,
    setShowColorPicker,
    handleSelectColor,
    handleNewChat,
  };
}

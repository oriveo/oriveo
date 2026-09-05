'use client';

import { useState, useCallback, useMemo } from 'react';
import { useTranslations } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import { useContextMenu, type ContextMenuItem } from '../ContextMenu';
import { exportConversationMarkdown } from '../../lib/utils/conversation-item-meta';
import type { PinnedReorderMove } from '../../lib/utils/pinned-reorder';

interface UseConversationContextMenuParams {
  conversation: Conversation;
  isPinned?: boolean;
  onTogglePin?: (id: string) => void;
  onDelete: (id: string) => void;
  onStartRename: () => void;
  /** Position in the pinned list, meaningful only when isPinned, used to decide which keyboard reorder items are reachable. */
  pinnedIndex?: number;
  pinnedCount?: number;
  /** Keyboard equivalents for drag reordering: move to top, move up, move down. */
  onReorderPinned?: (id: string, move: PinnedReorderMove) => void;
}

/**
 * Context and overflow menu for a conversation row: builds the items (pin, reorder, move to folder,
 * rename, export as Markdown, delete) and holds the move-menu popover state.
 * The overflow button opens the menu at the button's own coordinates through openMenu.
 * Pinned rows also expose move to top, move up and move down as keyboard equivalents for drag
 * reordering, which is only available with a fine pointer.
 */
export function useConversationContextMenu({
  conversation,
  isPinned,
  onTogglePin,
  onDelete,
  onStartRename,
  pinnedIndex,
  pinnedCount,
  onReorderPinned,
}: UseConversationContextMenuParams) {
  const t = useTranslations('sidebar');
  const tCtx = useTranslations('contextMenu');
  const { menu, handleContextMenu, openMenu, closeMenu } = useContextMenu();
  const [showMoveMenu, setShowMoveMenu] = useState(false);
  const [moveMenuPos, setMoveMenuPos] = useState({ x: 0, y: 0 });

  const reorderItems = useMemo<ContextMenuItem[]>(() => {
    if (!isPinned || !onReorderPinned || pinnedIndex === undefined || (pinnedCount ?? 0) < 2) {
      return [];
    }
    const items: ContextMenuItem[] = [];
    if (pinnedIndex > 0) {
      items.push({ label: tCtx('moveToTop'), onAction: () => onReorderPinned(conversation.id, 'top') });
      items.push({ label: tCtx('moveUp'), onAction: () => onReorderPinned(conversation.id, 'up') });
    }
    if (pinnedIndex < (pinnedCount ?? 0) - 1) {
      items.push({ label: tCtx('moveDown'), onAction: () => onReorderPinned(conversation.id, 'down') });
    }
    return items;
  }, [isPinned, onReorderPinned, pinnedIndex, pinnedCount, tCtx, conversation.id]);

  const contextMenuItems = useMemo<ContextMenuItem[]>(
    () => [
      { label: isPinned ? tCtx('unpin') : tCtx('pin'), onAction: () => onTogglePin?.(conversation.id) },
      ...reorderItems,
      {
        label: tCtx('moveToFolder'),
        onAction: () => {
          if (menu) setMoveMenuPos(menu.position);
          closeMenu();
          setShowMoveMenu(true);
        },
      },
      { label: tCtx('rename'), onAction: onStartRename },
      { label: tCtx('exportMarkdown'), onAction: () => exportConversationMarkdown(conversation, t('untitled')) },
      { label: tCtx('delete'), danger: true, onAction: () => onDelete(conversation.id) },
    ],
    [tCtx, isPinned, onTogglePin, onStartRename, conversation, onDelete, t, menu, closeMenu, reorderItems],
  );

  const handleRightClick = useCallback(
    (e: React.MouseEvent) => {
      handleContextMenu(e, contextMenuItems);
    },
    [handleContextMenu, contextMenuItems],
  );

  const handleMoreClick = useCallback(
    (e: React.MouseEvent<HTMLButtonElement>) => {
      e.stopPropagation();
      const rect = e.currentTarget.getBoundingClientRect();
      openMenu({ x: rect.right, y: rect.top }, contextMenuItems);
    },
    [openMenu, contextMenuItems],
  );

  return {
    menu,
    closeMenu,
    showMoveMenu,
    moveMenuPos,
    setShowMoveMenu,
    handleRightClick,
    handleMoreClick,
  };
}

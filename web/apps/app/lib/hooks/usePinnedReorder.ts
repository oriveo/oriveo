import { useState, useCallback } from 'react';
import { CONVERSATION_DRAG_MIME } from '../constants/drag';
import {
  movePinnedToIndex,
  movePinnedByKeyboard,
  type PinnedReorderMove,
} from '../utils/pinned-reorder';

/**
 * Drag reordering for pinned conversations: a drag moves an entry from source to target inside
 * pinnedIds and writes the result back to conversationOrder.
 * reorderByKeyboard is the keyboard equivalent, backing the context menu actions "move to top",
 * "move up" and "move down".
 */
export function usePinnedReorder(
  pinnedIds: string[],
  setConversationOrder: (order: string[]) => void,
) {
  const [draggedId, setDraggedId] = useState<string | null>(null);

  const handleDragStart = useCallback((e: React.DragEvent, convId: string) => {
    setDraggedId(convId); e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData(CONVERSATION_DRAG_MIME, convId);
  }, []);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault(); e.dataTransfer.dropEffect = 'move';
  }, []);

  const handleDrop = useCallback((e: React.DragEvent, targetId: string) => {
    e.preventDefault();
    const sourceId = draggedId;
    setDraggedId(null);
    if (!sourceId || sourceId === targetId) return;
    const newOrder = movePinnedToIndex(pinnedIds, sourceId, pinnedIds.indexOf(targetId));
    if (newOrder) setConversationOrder(newOrder);
  }, [draggedId, pinnedIds, setConversationOrder]);

  const reorderByKeyboard = useCallback((convId: string, move: PinnedReorderMove) => {
    const newOrder = movePinnedByKeyboard(pinnedIds, convId, move);
    if (newOrder) setConversationOrder(newOrder);
  }, [pinnedIds, setConversationOrder]);

  return { draggedId, handleDragStart, handleDragOver, handleDrop, reorderByKeyboard };
}

'use client';

import { memo } from 'react';
import type { Conversation } from '@oriveo/shared';
import { ConversationItem } from './ConversationItem';
import { useAppStore } from '../../providers/StoreProvider';
import { selectStreamingConversationIdSet } from '../../lib/core/store/selectors';
import type { PinnedReorderMove } from '../../lib/utils/pinned-reorder';

interface ConversationGroupProps {
  conversations: Conversation[];
  activeId: string | null;
  editMode: boolean;
  selectedIds: Set<string>;
  isPinned: boolean;
  onSelect: (id: string) => void;
  onRename: (id: string, newTitle: string) => void;
  onDelete: (id: string) => void;
  onTogglePin: (id: string) => void;
  onToggleSelect: (id: string) => void;
  /** Only the pinned group needs this. */
  draggable?: boolean;
  variant?: 'sidebar' | 'mobileHome';
  onDragStart?: (e: React.DragEvent, id: string) => void;
  onDragOver?: (e: React.DragEvent) => void;
  onDrop?: (e: React.DragEvent, id: string) => void;
  draggedId?: string | null;
  /** Keyboard equivalent of drag reordering; passed only for the pinned group. */
  onReorderPinned?: (id: string, move: PinnedReorderMove) => void;
}

export const ConversationGroup = memo(function ConversationGroup({
  conversations,
  activeId,
  editMode,
  selectedIds,
  isPinned,
  onSelect,
  onRename,
  onDelete,
  onTogglePin,
  onToggleSelect,
  draggable,
  variant = 'sidebar',
  onDragStart,
  onDragOver,
  onDrop,
  draggedId,
  onReorderPinned,
}: ConversationGroupProps) {
  // Set selector: the underlying streamingConversationIds only changes identity on add or remove, so
  // the tokens arriving throughout a stream do not re-render the group or its items.
  // Using a Set also drops each item's membership check from .includes (O(S)) to .has (O(1)).
  const streamingIds = useAppStore(selectStreamingConversationIdSet);
  return (
    <>
      {conversations.map((conv, index) => (
        <ConversationItem
          key={conv.id}
          conversation={conv}
          active={conv.id === activeId}
          onSelect={onSelect}
          onRename={onRename}
          onDelete={onDelete}
          isPinned={isPinned}
          onTogglePin={onTogglePin}
          pinnedIndex={isPinned ? index : undefined}
          pinnedCount={isPinned ? conversations.length : undefined}
          onReorderPinned={isPinned ? onReorderPinned : undefined}
          draggable={draggable}
          onDragStart={onDragStart}
          onDragOver={draggable ? onDragOver : undefined}
          onDrop={onDrop}
          isDragging={draggedId === conv.id}
          editMode={editMode}
          selected={selectedIds.has(conv.id)}
          onToggleSelect={onToggleSelect}
          isStreaming={streamingIds.has(conv.id)}
          variant={variant}
        />
      ))}
    </>
  );
});

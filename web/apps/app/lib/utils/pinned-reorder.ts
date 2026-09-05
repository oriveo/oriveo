// Pure reordering logic for pinned conversations, shared by dragging (move to a target position)
// and the keyboard equivalents (move to top, up one, down one).
// Returns the new order array, or null when the move is invalid or changes nothing, which tells the
// caller to skip the write-back.

export type PinnedReorderMove = 'top' | 'up' | 'down';

/** Moves id to targetIndex within the pinned list and returns the new order; returns null when the index is out of range, the id is missing, or nothing changes. */
export function movePinnedToIndex(
  pinnedIds: string[],
  id: string,
  targetIndex: number,
): string[] | null {
  const from = pinnedIds.indexOf(id);
  if (from === -1 || targetIndex < 0 || targetIndex >= pinnedIds.length || from === targetIndex) {
    return null;
  }
  const next = [...pinnedIds];
  next.splice(from, 1);
  next.splice(targetIndex, 0, id);
  return next;
}

/** Keyboard equivalent of reordering: move to top, up one, or down one. Returns null at the boundaries. */
export function movePinnedByKeyboard(
  pinnedIds: string[],
  id: string,
  move: PinnedReorderMove,
): string[] | null {
  const from = pinnedIds.indexOf(id);
  if (from === -1) return null;
  const targetIndex = move === 'top' ? 0 : move === 'up' ? from - 1 : from + 1;
  return movePinnedToIndex(pinnedIds, id, targetIndex);
}

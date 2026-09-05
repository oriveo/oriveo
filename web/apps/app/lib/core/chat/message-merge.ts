/**
 * Incremental merge of message arrays by id, plus a stable sort by time.
 *
 * Root cause this fixes: operations-send used to rebuild the whole messages array from a
 * prevMessages snapshot captured at send time and write it back to the store, while
 * updateConversation replaces the entire array (see conversation-slice). Sending several messages
 * in quick succession made the later send overwrite the earlier one with its own stale snapshot,
 * so messages went missing or came out in the wrong order (all the user turns bunched together
 * with replies attached to the wrong ones).
 *
 * The fix: every write-back starts from the store's current messages and upserts incrementally by
 * msg.id (replace if present, insert otherwise), then applies a stable ascending sort by
 * createdAt.
 */
import type { ChatMessage } from '@oriveo/shared';
import { mergeMessageQuoteContext } from '@oriveo/shared';
import { normalizeUUID } from '../../utils/id-utils';

export function upsertMessages(base: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
  if (incoming.length === 0) return base;

  // Key through normalizeUUID so merge uniqueness does not rest on an implicit "every caller
  // already normalized" contract; case variants merge here instead of becoming duplicate entries
  // (same semantics as sameNormalizedID in sync-handlers).
  const byId = new Map(base.map((m) => [normalizeUUID(m.id), m]));
  for (const m of incoming) {
    const key = normalizeUUID(m.id);
    const existing = byId.get(key);
    byId.set(key, existing ? mergeMessageQuoteContext(existing, m) : m);
  }

  // Stable sort: different createdAt sorts ascending by time, equal (or both missing) returns 0 to
  // keep insertion order. This matches an ordered-by-createdAt read with no id tiebreak. Never
  // reorder by id within the same millisecond, or an assistant message (whose id may sort lower)
  // gets pushed ahead of the user message of the same turn. message-factory already spaces the
  // user and assistant createdAt of one turn 1ms apart, so normal data never collides.
  return Array.from(byId.values()).sort((a, b) => {
    const ta = a.createdAt ?? '';
    const tb = b.createdAt ?? '';
    if (ta === tb) return 0;
    return ta < tb ? -1 : 1;
  });
}

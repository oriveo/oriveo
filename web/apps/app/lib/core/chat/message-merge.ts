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

  // Stable sort: a missing createdAt sorts first and two missing ones keep insertion order; otherwise
  // ascending by numeric milliseconds (never by ISO string); within the same millisecond compare
  // roleRank first (user=0 < assistant=1 < other=2), and the same role returns 0 to keep insertion
  // order. Never reorder by id within the same millisecond, or an assistant message (whose id may
  // sort lower) gets pushed ahead of the user message of the same turn. Delivered state is not
  // compared here: while sending locally a generating assistant must stay after the user message
  // of its turn.
  return Array.from(byId.values()).sort((a, b) => compareMessageTime(a, b, false));
}

/** createdAt in milliseconds; empty, unparseable or <= 0 counts as missing (undefined, e.g. old backup imports). */
function messageCreatedAtMillis(message: Pick<ChatMessage, 'createdAt'>): number | undefined {
  if (!message.createdAt) return undefined;
  const millis = Date.parse(message.createdAt);
  return Number.isFinite(millis) && millis > 0 ? millis : undefined;
}

/**
 * Time order: missing first -> two missing are equal (a stable sort keeps insertion order; role and id
 * are not compared) -> numeric milliseconds -> roleRank -> with idTiebreak the normalized uppercase id,
 * otherwise equal.
 */
function compareMessageTime(a: ChatMessage, b: ChatMessage, idTiebreak: boolean): number {
  const ta = messageCreatedAtMillis(a);
  const tb = messageCreatedAtMillis(b);
  if (ta === undefined || tb === undefined) {
    if (ta === undefined && tb === undefined) return 0;
    return ta === undefined ? -1 : 1;
  }
  if (ta !== tb) return ta - tb;
  const rankDiff = roleRank(a.role) - roleRank(b.role);
  if (rankDiff !== 0 || !idTiebreak) return rankDiff;
  const ia = normalizeUUID(a.id);
  const ib = normalizeUUID(b.id);
  return ia < ib ? -1 : ia > ib ? 1 : 0;
}

/**
 * Message sort comparator: delivered first -> createdAt milliseconds (missing = empty, unparseable or
 * <= 0, sorts first; two missing are equal and keep insertion order) -> roleRank -> normalized
 * uppercase id. Needs a stable sort (Array.prototype.sort is stable). upsertMessages is the
 * exception, see the comment inside it.
 */
export function compareMessages(a: ChatMessage, b: ChatMessage): number {
  if (a.state === 'delivered' && b.state !== 'delivered') return -1;
  if (a.state !== 'delivered' && b.state === 'delivered') return 1;
  return compareMessageTime(a, b, true);
}

function roleRank(role: ChatMessage['role']): number {
  return role === 'user' ? 0 : role === 'assistant' ? 1 : 2;
}

/**
 * Display state of the external web search activity row (not persisted; one per conversation in-process).
 *
 * The status row only reads the streaming activity `external_search` (set by applySearchEvent's send, cleared by deliver); this adds its display context:
 * the service name and the search terms in the order they appear per call within this reply. A retry of the same call (same term sent consecutively) is not appended again.
 * Reset when a reply starts and cleared when it ends; the UI subscribes via subscribe / snapshot (useSyncExternalStore).
 */
import type { StreamActivityExternalSearch } from '@oriveo/core/providers/types';

export interface ExternalSearchActivityChip {
  query: string;
  /** This call is still searching (after send, before deliver). */
  searching: boolean;
}

export interface ExternalSearchActivityView {
  serviceName: string;
  chips: readonly ExternalSearchActivityChip[];
}

/** Next display state: detail = send effect (service name + term); null = deliver (this call ended). */
export function nextExternalSearchActivityView(
  previous: ExternalSearchActivityView | null,
  detail: StreamActivityExternalSearch | null,
): ExternalSearchActivityView | null {
  if (!detail) {
    if (!previous || previous.chips.every((chip) => !chip.searching)) return previous;
    return { ...previous, chips: previous.chips.map((chip) => (chip.searching ? { ...chip, searching: false } : chip)) };
  }
  const chips = previous?.chips ?? [];
  const last = chips[chips.length - 1];
  // Retry of the same call: still the same capsule spinning.
  if (last?.searching && last.query === detail.query) {
    return previous && previous.serviceName === detail.serviceName ? previous : { serviceName: detail.serviceName, chips };
  }
  return {
    serviceName: detail.serviceName,
    chips: [...chips.map((chip) => (chip.searching ? { ...chip, searching: false } : chip)), { query: detail.query, searching: true }],
  };
}

const views = new Map<string, ExternalSearchActivityView>();
const listeners = new Set<() => void>();

function emit(): void {
  for (const listener of listeners) listener();
}

export function subscribeExternalSearchActivity(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function externalSearchActivityView(conversationId: string | null | undefined): ExternalSearchActivityView | null {
  return conversationId ? views.get(conversationId) ?? null : null;
}

/** applySearchEvent's send (detail) / deliver (null). */
export function applyExternalSearchActivity(conversationId: string, detail: StreamActivityExternalSearch | null): void {
  const previous = views.get(conversationId) ?? null;
  const next = nextExternalSearchActivityView(previous, detail);
  if (next === previous) return;
  if (next) views.set(conversationId, next);
  else views.delete(conversationId);
  emit();
}

/** A reply starts / ends: clear the previous reply's capsule. */
export function clearExternalSearchActivity(conversationId: string): void {
  if (!views.delete(conversationId)) return;
  emit();
}

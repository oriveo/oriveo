import { QUOTE_CONTEXT_MAX_GRAPHEMES, isValidQuoteContext, quoteGraphemeCount, type QuoteContext } from '@oriveo/shared';
import type { ContextCheckpointRow } from '../../../infra/storage/context-checkpoint-store';
import { compactConversationNow } from '../context-pipeline/manual-compaction';
import type { CompactionResult } from '../context-pipeline/compaction-coordinator';
import { ContextCompactionStore } from './context-compaction-store';

/*
 * Compaction actions, called by the separator row details and the context panel; no UI and no copy.
 * All writes go through ContextCompactionStore, so subscribers refresh with them.
 */

/** Toast for a manual compaction result: a summary result shows none. */
export type CompactionToast = 'fallback' | 'noop';

function toastOf(result: CompactionResult): CompactionToast | null {
  // User cancelled: nothing is saved and nothing is shown.
  if (result.cancelled) return null;
  if (result.outcome === 'fallback') return 'fallback';
  if (result.outcome === 'noop') return 'noop';
  return null;
}

/** Clear compaction: deletes every checkpoint of the conversation and returns the deleted ids; the caller shows toast_cleared based on this. */
export function clearCompaction(conversationId: string): Promise<string[]> {
  return ContextCompactionStore.deleteAll(conversationId);
}

/** Manual compaction: returns the toast kind to show; null means no toast. */
export async function manualCompact(conversationId: string): Promise<CompactionToast | null> {
  return toastOf(await compactConversationNow(conversationId));
}

/** Recompact: deletes the active checkpoint R, then runs a manual compaction. */
export async function recompact(conversationId: string, checkpointId: string): Promise<CompactionToast | null> {
  await ContextCompactionStore.remove(conversationId, [checkpointId]);
  return manualCompact(conversationId);
}

/* ── Hint on the third compaction ─────────────────────────────── */

const HINT_CHECKPOINT_COUNT = 3;
/** Conversations already hinted during this page lifetime. */
const hintedConversations = new Set<string>();
const hintListeners = new Set<() => void>();
let pendingHint: string | null = null;

function emitHint(): void {
  for (const listener of [...hintListeners]) listener();
}

/** Called after the coordinator saves locally; count is the number of checkpoints in the conversation after saving. */
export function noteCompactionSaved(conversationId: string, count: number): void {
  if (count !== HINT_CHECKPOINT_COUNT || hintedConversations.has(conversationId)) return;
  hintedConversations.add(conversationId);
  pendingHint = conversationId;
  emitHint();
}

/** The conversation whose hint is pending; null when none. */
export function pendingCompactionHint(): string | null {
  return pendingHint;
}

/** "Got it" or a new chat was started: dismiss the hint. */
export function dismissCompactionHint(): void {
  if (pendingHint === null) return;
  pendingHint = null;
  emitHint();
}

export function subscribeCompactionHint(listener: () => void): () => void {
  hintListeners.add(listener);
  return () => {
    hintListeners.delete(listener);
  };
}

export function __resetCompactionHintForTest(): void {
  hintedConversations.clear();
  pendingHint = null;
}

/* ── Start a new chat with the summary ───────────────────────────── */

const PARAGRAPH_SEPARATOR = '\n\n';

function takeFirstGraphemes(value: string, limit: number): string {
  if (limit <= 0) return '';
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  const out: string[] = [];
  for (const part of segmenter.segment(value)) {
    if (out.length >= limit) break;
    out.push(part.segment);
  }
  return out.join('');
}

/**
 * Builds the pending quote from the active row R: uses the summary when non-empty (tail-truncated if too long);
 * otherwise one paragraph per verbatim user message in time order (when too long, the oldest are dropped first; if only the newest one is still too long, its tail is truncated). Returns null when unusable.
 */
export function buildSummaryQuote(
  row: ContextCheckpointRow,
  label: string,
  messages: readonly { id: string; text: string }[],
): QuoteContext | null {
  const budget = QUOTE_CONTEXT_MAX_GRAPHEMES - quoteGraphemeCount(label);
  let selectedText: string;
  let truncated = false;
  const summary = row.summary?.trim() ?? '';
  if (summary) {
    selectedText = summary;
    if (quoteGraphemeCount(selectedText) > budget) {
      selectedText = takeFirstGraphemes(selectedText, budget);
      truncated = true;
    }
  } else {
    const kept = new Set(row.userMessageIds);
    const paragraphs = messages.filter((m) => kept.has(m.id)).map((m) => m.text.trim()).filter((t) => t.length > 0);
    while (paragraphs.length > 1 && quoteGraphemeCount(paragraphs.join(PARAGRAPH_SEPARATOR)) > budget) {
      paragraphs.shift();
      truncated = true;
    }
    selectedText = paragraphs.join(PARAGRAPH_SEPARATOR);
    // Only the newest one is still too long: truncate its tail.
    if (quoteGraphemeCount(selectedText) > budget) {
      selectedText = takeFirstGraphemes(selectedText, budget);
      truncated = true;
    }
  }
  const quote: QuoteContext = {
    schemaVersion: 1,
    sourceMessageId: row.coversTo,
    sourceRole: 'assistant',
    contentKind: 'prose',
    leadingText: label,
    selectedText,
    trailingText: '',
    contextTruncated: truncated,
  };
  return isValidQuoteContext(quote) ? quote : null;
}

/**
 * The quote waiting to be attached to the composer of the new conversation; ChatView takes it once when the new conversation mounts.
 * A new conversation has no id before its first send, so null is the one-shot slot without an id.
 */
const pendingComposerQuotes = new Map<string | null, QuoteContext>();

export function setPendingComposerQuote(conversationId: string | null, quote: QuoteContext): void {
  pendingComposerQuotes.set(conversationId, quote);
}

export function takePendingComposerQuote(conversationId: string | null): QuoteContext | null {
  const quote = pendingComposerQuotes.get(conversationId) ?? null;
  pendingComposerQuotes.delete(conversationId);
  return quote;
}

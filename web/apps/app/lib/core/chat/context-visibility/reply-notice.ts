import type { StopReason } from '@oriveo/core/context/stop-reason';

/** Keys under pages.chat.replyNotice (stop-reason.v1 ui.notice, camelCased). */
export type ReplyNoticeKey = 'incompleteOutputLimit' | 'incompleteConnection' | 'filtered' | 'contextOverflow';

export interface ReplyNotice {
  key: ReplyNoticeKey;
  /** warning -> --o-warning-text; secondary -> --o-text-secondary (content_filter). */
  tone: 'warning' | 'secondary';
  showContinue: boolean;
}

export interface ReplyNoticeInput {
  role: string;
  stopReason: StopReason | null | undefined;
  isLastMessage: boolean;
  isStreaming: boolean;
  hasRecoveryCard: boolean;
  /** Any answer is being generated in this conversation. */
  isGenerating: boolean;
}

// Mirrors stop-reason.v1.json "ui"; other reasons show nothing.
const UI: Partial<Record<StopReason, { key: ReplyNoticeKey; continueAction: boolean }>> = {
  length: { key: 'incompleteOutputLimit', continueAction: true },
  incomplete: { key: 'incompleteConnection', continueAction: true },
  content_filter: { key: 'filtered', continueAction: false },
  context_window_exceeded: { key: 'contextOverflow', continueAction: false },
};

/** Footer notice for an incomplete / filtered assistant answer (contract card item 6). */
export function replyNoticeOf(input: ReplyNoticeInput): ReplyNotice | null {
  if (input.role !== 'assistant' || input.isStreaming || input.hasRecoveryCard || !input.stopReason) return null;
  const ui = UI[input.stopReason];
  if (!ui) return null;
  return {
    key: ui.key,
    tone: input.stopReason === 'content_filter' ? 'secondary' : 'warning',
    showContinue: ui.continueAction && input.isLastMessage && !input.isGenerating,
  };
}

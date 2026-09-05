/**
 * Chat operations aggregator.
 *
 * Each operation (send, retry, continue, edit, delete) lives in its own file; this module only holds
 * the type definitions and re-exports, so callers can do `import * as chatOps from './operations'`.
 *
 * Compatibility re-exports: several modules take helpers (error reporting, prompt injection, cost
 * aggregation) directly from the `'./operations'` path, and those re-exports are kept after the split
 * so call sites do not have to change.
 */
import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';

/* ── Types ────────────────────────────────────────────── */

export interface ChatOpCtx {
  store: StoreApi<AppStore>;
  appendChunk: (chunk: string) => void;
  te: (key: string) => string;
}

export interface SendHandle {
  convId: string;
  /** The assistant message id bound to this stream, used by the lifecycle flush and by the entry guard that persists partials. */
  msgId: string;
  abort: () => void;
  done: Promise<void>;
}

/* ── Operations ───────────────────────────────────────── */

export { sendMessage } from './operations-send';
export { retryMessage } from './operations-retry';
export { continueAnswering } from './operations-continue';
export { editAndResend } from './operations-edit';
export { deleteMessage } from './operations-delete';
export { stopStream } from './stop-stream';

/* ── Backwards-compatible helper re-exports ────────────── */
// Several call sites import these helpers through the `'./operations'` path, so the re-exports stay
// after the split into per-operation files.
export { shouldReportProviderError, createProviderSentryError } from './error-reporting';
export { resolvePromptUseMemory } from './prompt-injection';
export { recalculateConversationCost } from './usage-tracking';

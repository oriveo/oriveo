import type { StreamEvent } from '../providers/types';

/**
 * Envelope types for the chat streaming IPC. They live in @oriveo/core rather than ipc-contract
 * because they reference StreamEvent from core, and the two packages sit behind the same eslint
 * fence (only @oriveo/shared/pure-types is importable) so neither can import the other.
 * The main process wraps a StreamEvent into an envelope and sends it over a MessagePort; the
 * renderer unwraps it again.
 */

export interface ChatStreamStartResult {
  streamId: string;
  ok: true;
}

/**
 * Events sent from main to renderer over a MessagePort.
 * Small events carry the StreamEvent directly; a large image (a base64 data URL) is converted to an
 * ArrayBuffer and sent as a Transferable for zero-copy.
 */
export type ChatStreamEnvelope =
  | { streamId: string; event: StreamEvent }
  | { streamId: string; eventKind: 'image'; mime: string; data: ArrayBuffer };

/** Stream termination signal, emitted on natural end, cancellation and error alike, so the renderer can close its ReadableStream. */
export interface ChatStreamClosed {
  streamId: string;
  reason: 'done' | 'cancelled' | 'error';
}

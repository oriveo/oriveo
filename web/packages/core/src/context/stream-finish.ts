/** How a provider stream ended: protocol family, ending kind, and the raw terminal value seen. */

import { StopReasonResolver, type StopFamily, type StreamEnding } from './stop-reason';

export interface StreamFinish {
  family: StopFamily;
  ended: StreamEnding;
  /** Last terminal value seen (finish_reason / Responses status / stop_reason / finishReason); absent when none was seen. */
  finishRaw?: string;
}

/**
 * Tracks the termination signal of each protocol family within one stream. It recognizes the four direct
 * protocol families (openai_chat / openai_responses / anthropic / gemini), the native llama.cpp /completion
 * (llama_cpp), and the terminal frame written by the Gemini Interactions adapter (gemini_interactions);
 * the family is fixed by the first frame whose format can be recognized and does not change afterwards.
 * The Interactions adapter's body frames have the OpenAI chat shape, so a terminal frame carrying
 * interaction_status unconditionally switches the family to gemini_interactions.
 */
export class StreamFinishTracker {
  private family: StopFamily | null = null;
  private finishRaw: string | undefined;
  private sawMarker = false;

  /** Feed one parsed JSON frame; returns the StreamFinish (clean) if this frame is a terminal frame, otherwise null. */
  observe(eventType: string | null, chunk: Record<string, unknown>): StreamFinish | null {
    const interactionStatus = chunk[GEMINI_INTERACTION_STATUS_KEY];
    if (typeof interactionStatus === 'string' && interactionStatus) {
      this.family = 'gemini_interactions';
      this.finishRaw = interactionStatus;
      this.sawMarker = true;
      return this.current();
    }
    const family = this.family ?? detectFamily(eventType, chunk);
    if (!family) return null;
    this.family = family;
    switch (family) {
      case 'openai_chat': {
        if (eventType || !Array.isArray(chunk.choices)) return null;
        for (const choice of chunk.choices) {
          const reason = isRecord(choice) ? choice.finish_reason : undefined;
          if (typeof reason === 'string' && reason) {
            this.finishRaw = reason;
            this.sawMarker = true;
          }
        }
        return null;
      }
      case 'openai_responses': {
        const type = eventType ?? (typeof chunk.type === 'string' ? chunk.type : null);
        const status = responsesTerminalStatus(type, chunk);
        if (!status) return null;
        const response = isRecord(chunk.response) ? chunk.response : undefined;
        const details = response && isRecord(response.incomplete_details) ? response.incomplete_details : undefined;
        const reason = typeof details?.reason === 'string' ? details.reason : null;
        this.finishRaw = StopReasonResolver.responsesFinishRaw(status, reason);
        this.sawMarker = true;
        return this.current();
      }
      case 'anthropic': {
        if (chunk.type === 'message_delta' && isRecord(chunk.delta) && typeof chunk.delta.stop_reason === 'string') {
          this.finishRaw = chunk.delta.stop_reason;
        }
        if (chunk.type === 'message_stop') {
          this.sawMarker = true;
          return this.current();
        }
        return null;
      }
      case 'gemini': {
        if (!Array.isArray(chunk.candidates)) return null;
        for (const candidate of chunk.candidates) {
          const reason = isRecord(candidate) ? candidate.finishReason : undefined;
          if (typeof reason === 'string' && reason) {
            this.finishRaw = reason;
            this.sawMarker = true;
            return this.current();
          }
        }
        return null;
      }
      case 'llama_cpp': {
        if (chunk.stop !== true) return null;
        this.finishRaw = StopReasonResolver.llamaCppFinishRaw(chunk);
        this.sawMarker = true;
        return this.current();
      }
      default:
        return null;
    }
  }

  /** Conclusion when the stream ends; sawDoneToken counts as a terminal marker only for openai_chat. Returns undefined when no protocol family was recognized. */
  atEnd(sawDoneToken: boolean): StreamFinish | undefined {
    if (!this.family) return undefined;
    if (sawDoneToken && this.family === 'openai_chat') this.sawMarker = true;
    return this.current();
  }

  private current(): StreamFinish {
    const finish: StreamFinish = { family: this.family!, ended: this.sawMarker ? 'clean' : 'eof_without_marker' };
    if (this.finishRaw !== undefined) finish.finishRaw = this.finishRaw;
    return finish;
  }
}

/** Field on the Gemini Interactions adapter terminal frame: its value is the status of the final interaction. */
export const GEMINI_INTERACTION_STATUS_KEY = 'interaction_status';

const ANTHROPIC_TYPES = new Set([
  'message_start', 'content_block_start', 'content_block_delta', 'content_block_stop', 'message_delta', 'message_stop',
]);

function detectFamily(eventType: string | null, chunk: Record<string, unknown>): StopFamily | null {
  const type = typeof chunk.type === 'string' ? chunk.type : null;
  if ((eventType ?? type)?.startsWith('response.')) return 'openai_responses';
  if (type && ANTHROPIC_TYPES.has(type)) return 'anthropic';
  if (!eventType && Array.isArray(chunk.choices)) return 'openai_chat';
  if (Array.isArray(chunk.candidates)) return 'gemini';
  if (!eventType && typeof chunk.stop === 'boolean') return 'llama_cpp';
  return null;
}

function responsesTerminalStatus(type: string | null, chunk: Record<string, unknown>): string | null {
  const response = isRecord(chunk.response) ? chunk.response : undefined;
  const status = typeof response?.status === 'string' && response.status ? response.status : null;
  switch (type) {
    case 'response.completed':
      return status ?? 'completed';
    case 'response.incomplete':
      return status ?? 'incomplete';
    case 'response.failed':
      return status ?? 'failed';
    default:
      return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

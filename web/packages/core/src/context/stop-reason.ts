/** Persisted stop reasons and per-family terminal-signal mapping (shared contract stop-reason.v1.json). */

export const STOP_REASONS = [
  'stop',
  'length',
  'content_filter',
  'tool',
  'context_window_exceeded',
  'interrupted',
  'incomplete',
  'error',
  'unknown',
] as const;

export type StopReason = (typeof STOP_REASONS)[number];

export const StopReason = {
  /** null/undefined -> null; unrecognised strings -> unknown. */
  fromStored(raw?: string | null): StopReason | null {
    if (raw === null || raw === undefined) return null;
    return (STOP_REASONS as readonly string[]).includes(raw) ? (raw as StopReason) : 'unknown';
  },
};

export type StopFamily =
  | 'openai_chat'
  | 'openai_responses'
  | 'anthropic'
  | 'gemini'
  | 'gemini_interactions'
  | 'managed'
  | 'free'
  | 'llama_cpp';

export type StreamEnding = 'clean' | 'eof_without_marker' | 'error_frame' | 'transport_error' | 'user_cancelled';

const MAPPING: Record<StopFamily, Record<string, StopReason>> = {
  openai_chat: {
    stop: 'stop',
    length: 'length',
    content_filter: 'content_filter',
    tool_calls: 'tool',
    function_call: 'tool',
  },
  openai_responses: {
    completed: 'stop',
    'incomplete:max_output_tokens': 'length',
    'incomplete:content_filter': 'content_filter',
    failed: 'error',
  },
  anthropic: {
    end_turn: 'stop',
    stop_sequence: 'stop',
    max_tokens: 'length',
    tool_use: 'tool',
    pause_turn: 'incomplete',
    refusal: 'content_filter',
    model_context_window_exceeded: 'context_window_exceeded',
  },
  gemini: {
    STOP: 'stop',
    MAX_TOKENS: 'length',
    SAFETY: 'content_filter',
    RECITATION: 'content_filter',
    BLOCKLIST: 'content_filter',
    PROHIBITED_CONTENT: 'content_filter',
    SPII: 'content_filter',
    IMAGE_SAFETY: 'content_filter',
    IMAGE_PROHIBITED_CONTENT: 'content_filter',
    IMAGE_RECITATION: 'content_filter',
    LANGUAGE: 'content_filter',
    ESCALATION: 'content_filter',
    PUP_LIMITED_DISABLED: 'content_filter',
    CONTINUATION: 'length',
    MALFORMED_FUNCTION_CALL: 'error',
    MALFORMED_RESPONSE: 'error',
    MISSING_THOUGHT_SIGNATURE: 'error',
    UNEXPECTED_TOOL_CALL: 'error',
    TOO_MANY_TOOL_CALLS: 'error',
    OTHER: 'unknown',
    FINISH_REASON_UNSPECIFIED: 'unknown',
    IMAGE_OTHER: 'unknown',
    NO_IMAGE: 'unknown',
  },
  managed: {
    stop: 'stop',
    length: 'length',
    content_filter: 'content_filter',
    tool: 'tool',
    context_window_exceeded: 'context_window_exceeded',
    incomplete: 'incomplete',
    error: 'error',
    unknown: 'unknown',
  },
  free: {
    stop: 'stop',
    length: 'length',
    content_filter: 'content_filter',
    tool_calls: 'tool',
  },
  // Interactions API: finishRaw is the terminal interaction status; cancelled stays unmapped.
  gemini_interactions: {
    completed: 'stop',
    incomplete: 'length',
    requires_action: 'tool',
    failed: 'error',
  },
  // llama.cpp native /completion: finishRaw is stop_type (legacy stopped_* booleans folded in).
  llama_cpp: {
    eos: 'stop',
    word: 'stop',
    limit: 'length',
  },
};

const RESPONSES_INCOMPLETE_PREFIX = 'incomplete:';
const GEMINI_BLOCK_REASON_PREFIX = 'blockReason:';
const GEMINI_BLOCK_REASON_UNSPECIFIED = 'BLOCK_REASON_UNSPECIFIED';

export const StopReasonResolver = {
  resolve(
    family: StopFamily,
    ended: StreamEnding,
    finishRaw: string | null | undefined,
    hadContent: boolean,
  ): StopReason {
    switch (ended) {
      case 'user_cancelled':
        return 'interrupted';
      case 'transport_error':
      case 'error_frame':
        return hadContent ? 'incomplete' : 'error';
      case 'eof_without_marker':
        return 'incomplete';
      case 'clean':
        break;
    }
    if (finishRaw === null || finishRaw === undefined) return 'unknown';
    const mapped = Object.hasOwn(MAPPING[family], finishRaw) ? MAPPING[family][finishRaw] : undefined;
    if (mapped) return mapped;
    // status=incomplete without a reason, or an unmapped incomplete reason.
    if (family === 'openai_responses' && (finishRaw === 'incomplete' || finishRaw.startsWith(RESPONSES_INCOMPLETE_PREFIX))) {
      return 'incomplete';
    }
    // Prompt block (promptFeedback.blockReason, no candidate): resolved by rule, not by MAPPING.
    if (family === 'gemini' && finishRaw.startsWith(GEMINI_BLOCK_REASON_PREFIX)) {
      return finishRaw.slice(GEMINI_BLOCK_REASON_PREFIX.length) === GEMINI_BLOCK_REASON_UNSPECIFIED
        ? 'unknown'
        : 'content_filter';
    }
    return 'unknown';
  },

  /** Responses finishRaw: the status, or "incomplete:" + incomplete_details.reason. */
  responsesFinishRaw(status: string, incompleteReason?: string | null): string {
    if (status === 'incomplete' && incompleteReason) return RESPONSES_INCOMPLETE_PREFIX + incompleteReason;
    return status;
  },

  /** Gemini prompt-block finishRaw: "blockReason:" + promptFeedback.blockReason. */
  geminiBlockFinishRaw(blockReason: string): string {
    return GEMINI_BLOCK_REASON_PREFIX + blockReason;
  },

  /** llama.cpp finishRaw: stop_type, else folded from legacy stopped_eos / stopped_word / stopped_limit. */
  llamaCppFinishRaw(chunk: {
    stop_type?: unknown;
    stopped_eos?: unknown;
    stopped_word?: unknown;
    stopped_limit?: unknown;
  }): string {
    if (typeof chunk.stop_type === 'string' && chunk.stop_type) return chunk.stop_type;
    if (chunk.stopped_eos === true) return 'eos';
    if (chunk.stopped_word === true) return 'word';
    if (chunk.stopped_limit === true) return 'limit';
    return 'none';
  },
};

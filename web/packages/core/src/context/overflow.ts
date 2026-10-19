/** Context-overflow recognition for provider error responses (shared contract overflow-errors.v1.json). */

import type { StopReason } from './stop-reason';

export type OverflowFamily =
  | 'openai_chat'
  | 'openai_responses'
  | 'openai_compatible'
  | 'anthropic'
  | 'gemini'
  | 'managed'
  | 'free';

export type OverflowVia = 'code' | 'type+regex' | 'status+regex' | 'status413';

export interface OverflowResult {
  overflow: boolean;
  via: OverflowVia | null;
}

/** Pattern group name -> extra regex sources; callers pass none until a remote key exists (D-99). */
export type OverflowExtraPatterns = Record<string, string[]>;

const DEFAULT_PATTERNS: Readonly<Record<string, string>> = Object.freeze({
  openai_compatible:
    "(?i)(maximum context length|context length (is|of)|context window|exceeds? the (model'?s? )?(maximum )?context|prompt is too long|too many tokens in (the )?(prompt|input|messages)|exceeded model token limit|reduce the length of the (messages|prompt|input))",
  anthropic: '(?i)(prompt is too long|input length and `?max_tokens`? exceed context limit)',
  gemini:
    '(?i)(input token count.*exceeds the maximum number of tokens|exceeds the maximum number of tokens allowed)',
});

const NOT_OVERFLOW: OverflowResult = { overflow: false, via: null };

function patternGroup(family: OverflowFamily): string | null {
  switch (family) {
    case 'openai_chat':
    case 'openai_responses':
    case 'openai_compatible':
      return 'openai_compatible';
    case 'anthropic':
    case 'gemini':
      return family;
    case 'managed':
    case 'free':
      return null;
  }
}

function compile(source: string): RegExp | null {
  const stripped = source.startsWith('(?i)') ? source.slice(4) : source;
  try {
    return new RegExp(stripped, 'i');
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function parseBody(body: string): Record<string, unknown> | null {
  try {
    return asRecord(JSON.parse(body));
  } catch {
    return null;
  }
}

function hasOverflowCode(json: Record<string, unknown>): boolean {
  const error = asRecord(json.error);
  if (error?.code === 'context_length_exceeded') return true;
  if (json.code === 'CONTEXT_LENGTH_EXCEEDED') return true;
  if (json.code === 40022) return true;
  return asRecord(json.data)?.reason === 'free_context_length_exceeded';
}

function errorMessage(json: Record<string, unknown>): string | null {
  const error = asRecord(json.error);
  if (typeof error?.message === 'string') return error.message;
  return typeof json.message === 'string' ? json.message : null;
}

export const ContextOverflowClassifier = {
  /** Production default patterns; must equal the fixture `patterns` verbatim. */
  defaultPatterns: DEFAULT_PATTERNS,

  classify(
    family: OverflowFamily,
    status: number,
    body: string,
    extraPatterns: OverflowExtraPatterns = {},
  ): OverflowResult {
    if (status === 401 || status === 429 || status >= 500) return NOT_OVERFLOW;
    const json = parseBody(body);
    if (json && hasOverflowCode(json)) return { overflow: true, via: 'code' };
    if (status === 413) return { overflow: true, via: 'status413' };
    if (!json || status !== 400) return NOT_OVERFLOW;

    const group = patternGroup(family);
    if (!group) return NOT_OVERFLOW;
    if (family === 'anthropic' && asRecord(json.error)?.type !== 'invalid_request_error') return NOT_OVERFLOW;
    const message = errorMessage(json);
    if (message === null) return NOT_OVERFLOW;

    const sources = [DEFAULT_PATTERNS[group], ...(extraPatterns[group] ?? [])].filter(
      (s): s is string => typeof s === 'string',
    );
    const matched = sources.some((source) => compile(source)?.test(message) ?? false);
    if (!matched) return NOT_OVERFLOW;
    return { overflow: true, via: family === 'anthropic' ? 'type+regex' : 'status+regex' };
  },

  /** Only the Anthropic-stream stop reason context_window_exceeded counts as overflow. */
  isOverflow(stopReason: StopReason | null | undefined): boolean {
    return stopReason === 'context_window_exceeded';
  },
};

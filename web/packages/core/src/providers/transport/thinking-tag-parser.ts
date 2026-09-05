import type { StreamEvent } from '../types';

const OPEN_TAG = '<think>';
const CLOSE_TAG = '</think>';
const MAX_TAG_LENGTH = CLOSE_TAG.length;

export interface ThinkingTagParserState {
  mode: 'normal' | 'thinking';
  pending: string;
  fenceBackticks: number;
  inCodeFence: boolean;
}

export function createThinkingTagParserState(): ThinkingTagParserState {
  return {
    mode: 'normal',
    pending: '',
    fenceBackticks: 0,
    inCodeFence: false,
  };
}

export function parseThinkingTaggedDelta(
  input: string,
  state: ThinkingTagParserState,
  options: { final?: boolean } = {},
): StreamEvent[] {
  if (!input && !options.final) return [];

  const events: StreamEvent[] = [];
  const current = state.pending + input;
  state.pending = '';

  let index = 0;
  let out = '';

  const flush = () => {
    if (!out) return;
    events.push(
      state.mode === 'thinking'
        ? { type: 'reasoning', content: out }
        : { type: 'delta', content: out },
    );
    out = '';
  };

  while (index < current.length) {
    if (state.mode === 'normal') {
      updateFenceState(current[index] ?? '', state);
    }

    if (!state.inCodeFence && current.startsWith(OPEN_TAG, index)) {
      flush();
      state.mode = 'thinking';
      index += OPEN_TAG.length;
      continue;
    }

    if (!state.inCodeFence && current.startsWith(CLOSE_TAG, index)) {
      flush();
      state.mode = 'normal';
      index += CLOSE_TAG.length;
      continue;
    }

    if (!options.final && isPossibleTagPrefix(current.slice(index))) {
      break;
    }

    out += current[index] ?? '';
    index += 1;
  }

  state.pending = current.slice(index);
  if (options.final && state.pending) {
    out += state.pending;
    state.pending = '';
  }
  flush();

  return events;
}

function isPossibleTagPrefix(value: string): boolean {
  const capped = value.slice(0, MAX_TAG_LENGTH);
  return (OPEN_TAG.startsWith(capped) || CLOSE_TAG.startsWith(capped))
    && capped.length < MAX_TAG_LENGTH;
}

function updateFenceState(char: string, state: ThinkingTagParserState) {
  if (char === '`') {
    state.fenceBackticks += 1;
    if (state.fenceBackticks === 3) {
      state.inCodeFence = !state.inCodeFence;
      state.fenceBackticks = 0;
    }
    return;
  }
  state.fenceBackticks = 0;
}

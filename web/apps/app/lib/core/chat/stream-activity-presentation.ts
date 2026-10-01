/**
 * Decides what waiting feedback a generating message shows.
 *
 * While the typing indicator is on screen it carries the label; otherwise the activity line does.
 * At most one waiting label is ever visible at a time.
 */
import type { StreamActivity } from '@oriveo/core/providers/types';

/** The visible content has to stay unchanged for this long before it counts as a pause. */
export const STREAM_QUIET_THRESHOLD_MS = 1500;

export type StreamActivityPresentation =
  | { kind: 'hidden' }
  /** The typing indicator stays as it is and its label becomes the activity label. */
  | { kind: 'typingLabel'; activity: StreamActivity }
  /** The line under the body; `neutral` is the pause fallback with no specific activity observed. */
  | { kind: 'line'; label: StreamActivity | 'neutral' };

export interface StreamActivityPresentationInput {
  isGenerating: boolean;
  hasBodyText: boolean;
  typingIndicatorVisible: boolean;
  /** Activity observed on the wire; null when nothing was observed. Never inferred from the user's settings or the model name. */
  activity: StreamActivity | null;
  quiet: boolean;
}

export function resolveStreamActivityPresentation(
  input: StreamActivityPresentationInput,
): StreamActivityPresentation {
  if (!input.isGenerating) return { kind: 'hidden' };
  if (input.activity) {
    return input.typingIndicatorVisible
      ? { kind: 'typingLabel', activity: input.activity }
      : { kind: 'line', label: input.activity };
  }
  // A pause with no body text shows no line: the typing indicator or the reasoning block is already moving.
  if (input.quiet && input.hasBodyText) return { kind: 'line', label: 'neutral' };
  return { kind: 'hidden' };
}

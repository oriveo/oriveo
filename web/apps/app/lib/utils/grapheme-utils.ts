// Grapheme cluster counting and truncation built on Intl.Segmenter.
// Gives every client the same character counting rule (Unicode grapheme clusters).
//
// Intl.Segmenter is initialized lazily behind a feature detection: Firefox only shipped it in 125
// (2024-04) and Windows 7 is stuck on Firefox 115 ESR, so constructing one at module top level makes
// the whole lazy chunk throw a TypeError as soon as it is evaluated. Without support this falls back
// to code point counting and truncation via Array.from - ZWJ emoji sequences, flags and combining
// characters then count as several characters, which is an acceptable degradation. Browsers with
// Segmenter behave exactly as before. The same guard appears in packages/shared/src/quote-context.ts.

let cachedSegmenter: Intl.Segmenter | null | undefined;

function getSegmenter(): Intl.Segmenter | null {
  if (cachedSegmenter === undefined) {
    cachedSegmenter =
      typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
        ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
        : null;
  }
  return cachedSegmenter;
}

/** Count grapheme clusters; falls back to code point counting without Intl.Segmenter. */
export function graphemeCount(text: string): number {
  const segmenter = getSegmenter();
  if (!segmenter) {
    return Array.from(text).length;
  }
  let count = 0;
  for (const _ of segmenter.segment(text)) {
    count++;
  }
  return count;
}

/** Truncate on grapheme cluster boundaries; without Intl.Segmenter it falls back to code point truncation, which still never splits a surrogate pair. */
export function takeGraphemes(text: string, limit: number): string {
  const segmenter = getSegmenter();
  if (!segmenter) {
    return Array.from(text).slice(0, Math.max(0, limit)).join('');
  }
  const segments: string[] = [];
  let count = 0;
  for (const { segment } of segmenter.segment(text)) {
    if (count >= limit) break;
    segments.push(segment);
    count++;
  }
  return segments.join('');
}

/**
 * Maximum length of the chat input text, in UTF-16 code units, shared across clients.
 * Why: the Android input field re-lays out the whole text on every edit (the longest frame
 * for one keystroke was 40ms on 50,000 characters of non-repeating text, over 100ms on
 * 500,000). Web does not have that bottleneck, but drafts and messages move between
 * clients, so the limit has to be the same everywhere.
 */
export const CHAT_INPUT_MAX_LENGTH = 50_000;

/**
 * The last grapheme boundary in `text` that is at most `maxUnits` (UTF-16 code units) and
 * not below `floor`. Boundaries come from segmenting the whole `text`, so a combining mark
 * or ZWJ that follows the character right before `floor` is not left dangling.
 * Without Intl.Segmenter it only guarantees that a surrogate pair is not split.
 */
function graphemeBoundaryAtOrBefore(text: string, maxUnits: number, floor: number): number {
  if (maxUnits >= text.length) return text.length;
  if (maxUnits <= floor) return floor;
  const segmenter = getSegmenter();
  if (!segmenter) {
    const code = text.charCodeAt(maxUnits - 1);
    const splitsPair = code >= 0xd800 && code <= 0xdbff;
    return Math.max(floor, splitsPair ? maxUnits - 1 : maxUnits);
  }
  // Segment from the start rather than only after floor: a newly inserted combining mark,
  // skin-tone modifier, or second regional indicator must merge into the previous character,
  // which cannot be told from the inserted part alone. The maxUnits <= floor case (typing
  // past the limit) already returned above, so only a real truncation gets here. Take two
  // extra code units so the code point at maxUnits is complete: half a surrogate pair would
  // count as its own grapheme and split a thumbs-up from its skin tone.
  let boundary = floor;
  for (const { index } of segmenter.segment(text.slice(0, maxUnits + 2))) {
    if (index > maxUnits) break;
    if (index >= floor) boundary = index;
  }
  return boundary;
}

/** Takes a prefix within the UTF-16 code unit limit, backing the cut up to a grapheme boundary (the result may be slightly shorter than the limit). */
export function takeWithinUtf16Length(text: string, maxUnits: number): string {
  return text.slice(0, graphemeBoundaryAtOrBefore(text, Math.max(0, maxUnits), 0));
}

export interface InputLengthLimitResult {
  /** The text that should stay in the input */
  text: string;
  /** Caret position: right after the kept part of the insertion */
  caret: number;
  /** The part of the insertion that was actually kept */
  inserted: string;
  truncated: boolean;
}

/**
 * Length-limit rule for replacing `previous[start, end)` with `inserted`.
 * If the result is within the limit, or no longer than before, it is accepted as is;
 * otherwise only the tail of the inserted part is cut and the text around it is untouched.
 * When the existing text already exceeds the limit (an old draft or another programmatic
 * write), its current length is the bound: it can shrink but not grow, and an equal-length
 * replacement is still allowed.
 */
export function limitInsertion(
  previous: string,
  start: number,
  end: number,
  inserted: string,
  limit: number,
): InputLengthLimitResult {
  const head = previous.slice(0, start);
  const tail = previous.slice(end);
  const nextLength = head.length + inserted.length + tail.length;
  if (nextLength <= limit || nextLength <= previous.length) {
    return { text: head + inserted + tail, caret: start + inserted.length, inserted, truncated: false };
  }
  const room = Math.max(limit, previous.length) - head.length - tail.length;
  const headAndInserted = head + inserted;
  const keptEnd = graphemeBoundaryAtOrBefore(headAndInserted, start + room, start);
  const kept = headAndInserted.slice(start, keptEnd);
  return { text: head + kept + tail, caret: keptEnd, inserted: kept, truncated: true };
}

/**
 * For when only the text before and after an edit is available (input events, IME commits):
 * recovers the inserted part from the common prefix and suffix, then applies
 * `limitInsertion`. `caretAfter` is the caret position after the edit; when the same
 * character repeats, the common prefix and suffix cannot locate the insertion point, so a
 * known caret is taken as the end of the inserted part.
 */
export function applyInputLengthLimit(
  previous: string,
  next: string,
  limit: number,
  caretAfter?: number | null,
): InputLengthLimitResult {
  if (next.length <= limit || next.length <= previous.length) {
    return { text: next, caret: caretAfter ?? next.length, inserted: '', truncated: false };
  }
  const maxShared = Math.min(previous.length, next.length);
  let suffix = 0;
  if (
    typeof caretAfter === 'number'
    && caretAfter >= 0
    && caretAfter <= next.length
    && next.length - caretAfter <= previous.length
    && previous.endsWith(next.slice(caretAfter))
  ) {
    suffix = next.length - caretAfter;
  } else {
    while (
      suffix < maxShared
      && previous.charCodeAt(previous.length - 1 - suffix) === next.charCodeAt(next.length - 1 - suffix)
    ) suffix += 1;
  }
  let prefix = 0;
  const maxPrefix = maxShared - suffix;
  while (prefix < maxPrefix && previous.charCodeAt(prefix) === next.charCodeAt(prefix)) prefix += 1;
  return limitInsertion(
    previous,
    prefix,
    previous.length - suffix,
    next.slice(prefix, next.length - suffix),
    limit,
  );
}

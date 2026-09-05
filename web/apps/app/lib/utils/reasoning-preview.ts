/**
 * Plain-text pipeline for the single-line preview of a collapsed reasoning block.
 *
 * Two hard constraints:
 *
 * 1. Strip markdown markers. The collapsed state shows one plain line, so a bare `**` must never
 *    reach the reader. No styling is rendered here: the preview is a single secondary-colour line,
 *    and running full markdown rendering would be expensive and drag in heading sizes and other
 *    layout that a one-line preview has no use for.
 * 2. Stay bounded. Only the last PREVIEW_SCAN_WINDOW characters are scanned backwards, so the cost
 *    is independent of the total reasoning length. `lastIndexOf('\n')` is O(n) on a reasoning
 *    stream with sparse newlines, and the collapsed state recomputes on every chunk while the text
 *    can grow to tens of thousands of characters.
 *
 * The stripping rules are deliberately conservative: leaving a marker in is better than eating a
 * real character.
 * - `*` / `` ` `` / `~~` count as markers only when they touch non-whitespace text, so the
 *   multiplication sign in `2 * 3` and a standalone backtick survive.
 * - `_` is always kept: `snake_case` is far more common in reasoning text than `__emphasis__`.
 * - `[text](url)` keeps only `text`.
 * - Line-leading block markers (`#{1,6} ` / `> ` / `- ` / `1. `) are stripped only when the
 *   fragment really is at the start of a line.
 *
 * Deliberately not shared with `stripMarkdownForPreview()` in `markdown-preview.ts`: that one is
 * regex based and needs paired markers, so it cannot strip a streaming unclosed `**heading`; it
 * also strips `_`, deletes whole code fences and collapses whitespace to single spaces, none of
 * which suits a preview refreshed chunk by chunk.
 */

/**
 * Maximum characters in a preview line. 40 keeps it on one line even on narrow screens, so the
 * container needs no second truncation and the text does not jitter.
 */
const PREVIEW_MAX_CHARACTERS = 40;

/** Backward scan window: at most this many characters are read for the last line. */
const PREVIEW_SCAN_WINDOW = 160;

/** Source tail limit: the input is clipped to this many trailing characters, so the whitespace and marker scans stay in bounds. */
const PREVIEW_SOURCE_LIMIT = 1024;

const WHITESPACE_RE = /\s/;
/** `\p{Nd}` rather than `\d`, so the whole Unicode digit range counts. */
const DIGIT_RE = /\p{Nd}/u;
/** A line made only of these characters carries no preview value: markdown skeleton, rules, whitespace. */
const MARKER_ONLY_RE = /[*`~#>\-+_|=\s]/;

function isWhitespace(ch: string): boolean {
  return WHITESPACE_RE.test(ch);
}

function isDigit(ch: string): boolean {
  return DIGIT_RE.test(ch);
}

/**
 * Take the last line of a reasoning text, strip markdown markers and truncate it to a preview line.
 *
 * An empty result means there is nothing displayable in this frame, and the caller (the collapsed
 * branch of `ReasoningBlock`) keeps the previous frame: either the reasoning has no readable body
 * yet, or the whole line is markdown skeleton (`**` / `###` / `|---|`).
 */
export function reasoningTail(text: string): string {
  if (!text) return '';
  const source = text.length > PREVIEW_SOURCE_LIMIT ? text.slice(-PREVIEW_SOURCE_LIMIT) : text;

  // 1. Skip trailing whitespace and newlines inside the fixed tail window (streaming chunks often end with \n)
  let end = source.length;
  while (end > 0 && isWhitespace(source[end - 1])) end--;
  if (end === 0) return '';

  // 2. Collect the last line backwards, at most PREVIEW_SCAN_WINDOW characters
  let start = end;
  let scanned = 0;
  let reachedLineStart = false;
  while (start > 0) {
    if (source[start - 1] === '\n') {
      reachedLineStart = true;
      break;
    }
    if (scanned >= PREVIEW_SCAN_WINDOW) break;
    start--;
    scanned++;
  }
  if (start === 0 && source.length === text.length) reachedLineStart = true;

  // 3. Strip markers (bounded input)
  const stripped = strippingMarkers(source, start, end, reachedLineStart);

  // 4. A line left with nothing but markers means there is nothing displayable in this frame, so
  //    return an empty string. Typically the model emits `**` / `###` / `|---|` right after a
  //    newline and only sends the body in the next chunk. At that point the strippingMarkers rule
  //    of "only counts when it touches non-whitespace" fails on both sides (line start on the
  //    left, line end on the right) and the markers would be left in place, which is exactly the
  //    symptom this is meant to avoid.
  if (isMarkerOnlyLine(stripped)) return '';

  // 5. Truncate: a leading ellipsis marks that there is more before it, both when the content is too long and when step 2 hit the window limit
  if (stripped.length > PREVIEW_MAX_CHARACTERS) {
    return '…' + stripped.slice(-PREVIEW_MAX_CHARACTERS);
  }
  return reachedLineStart ? stripped : '…' + stripped;
}

function isMarkerOnlyLine(line: string): boolean {
  for (let i = 0; i < line.length; i++) {
    if (!MARKER_ONLY_RE.test(line[i])) return false;
  }
  return true;
}

/** Strip markdown markers inside `[start, end)`. The caller already bounds the length, so a character-by-character scan is fine. */
function strippingMarkers(source: string, start: number, end: number, isLineStart: boolean): string {
  let index = isLineStart ? start + blockMarkerPrefixLength(source, start, end) : start;
  let output = '';

  while (index < end) {
    const character = source[index];

    if (character === '*' || character === '`' || character === '~') {
      let run = 1;
      while (index + run < end && source[index + run] === character) run++;
      // A single `~` is an ordinary tilde; only `~~` is a strikethrough marker
      const isEscaped = index > start && source[index - 1] === '\\';
      const isEmphasisMarker = character !== '~' || run >= 2;
      const attachedLeft = index > start && !isWhitespace(source[index - 1]);
      const attachedRight = index + run < end && !isWhitespace(source[index + run]);
      const isNumericOperator =
        run === 1 &&
        index > start &&
        isDigit(source[index - 1]) &&
        index + run < end &&
        isDigit(source[index + run]);
      // A single asterisk stuck to the end of a word (`char*`) stays literal; a double asterisk still supports a streaming unclosed `**bold`.
      const isInlineMarker =
        character === '*' && run === 1
          ? (!attachedLeft && attachedRight) || (attachedLeft && attachedRight && !isNumericOperator)
          : attachedLeft || attachedRight;
      if (!isEscaped && isEmphasisMarker && isInlineMarker) {
        index += run;
        continue;
      }
      output += character.repeat(run);
      index += run;
      continue;
    }

    if (character === '[') {
      const link = linkSpan(source, index, end);
      if (link) {
        output += source.slice(link.textStart, link.textEnd);
        index = link.spanEnd;
        continue;
      }
    }

    output += character;
    index++;
  }

  return output;
}

/** Length of a line-leading block marker including the whitespace after it; 0 when nothing matches. */
function blockMarkerPrefixLength(source: string, start: number, end: number): number {
  const skippingWhitespace = (from: number): number => {
    let index = from;
    while (index < end && isWhitespace(source[index]) && source[index] !== '\n') index++;
    return index - start;
  };

  // heading: #{1,6} + whitespace
  let hashes = 0;
  while (start + hashes < end && hashes < 6 && source[start + hashes] === '#') hashes++;
  if (hashes >= 1 && start + hashes < end && isWhitespace(source[start + hashes])) {
    return skippingWhitespace(start + hashes);
  }

  // quote: > + whitespace
  if (source[start] === '>' && start + 1 < end && isWhitespace(source[start + 1])) {
    return skippingWhitespace(start + 1);
  }

  // Unordered list: -/*/+ followed by whitespace (rules such as `---` have no whitespace and never match)
  const first = source[start];
  if (
    (first === '-' || first === '*' || first === '+') &&
    start + 1 < end &&
    isWhitespace(source[start + 1])
  ) {
    return skippingWhitespace(start + 2);
  }

  // Ordered list: digits + . + whitespace
  let digits = 0;
  while (start + digits < end && isDigit(source[start + digits])) digits++;
  if (
    digits > 0 &&
    start + digits + 1 < end &&
    source[start + digits] === '.' &&
    isWhitespace(source[start + digits + 1])
  ) {
    return skippingWhitespace(start + digits + 2);
  }

  return 0;
}

interface LinkSpan {
  textStart: number;
  textEnd: number;
  spanEnd: number;
}

/** Span of a `[text](url)` link; null when it is not a valid link, in which case `[` stays literal. */
function linkSpan(source: string, openBracket: number, end: number): LinkSpan | null {
  let index = openBracket + 1;
  while (index < end && source[index] !== ']') {
    if (source[index] === '\n') return null;
    index++;
  }
  if (index >= end) return null;
  const textStart = openBracket + 1;
  const textEnd = index;
  if (index + 1 >= end || source[index + 1] !== '(') return null;
  let closing = index + 2;
  while (closing < end && source[closing] !== ')') {
    if (source[closing] === '\n') return null;
    closing++;
  }
  if (closing >= end) return null;
  return { textStart, textEnd, spanEnd: closing + 1 };
}

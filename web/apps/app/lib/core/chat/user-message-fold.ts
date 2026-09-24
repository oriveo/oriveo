/**
 * Folding of very long user messages: the bubble renders only a prefix and the full text opens in
 * UserMessageFullTextDialog.
 *
 * Why it has to fold: the browser also shapes text paragraph by paragraph, at a cost linear in the
 * number of characters, so a 200,000-character Arabic message is laid out again in full every time
 * the conversation opens or the window is resized. The only way to make one bubble cost the same
 * regardless of message length is to not render the whole text.
 *
 * The rule and its parameters are shared with the native clients; change them together.
 */

/** Messages longer than this fold (UTF-16 code units, i.e. JS string length). */
export const USER_MESSAGE_FOLD_THRESHOLD = 6_000;
/** Prefix length cap: enough to fill the folded viewport (about 80 Latin letters x 14 lines in the widest bubble) with room to spare. */
export const USER_MESSAGE_PREVIEW_LENGTH = 2_000;
/** Most line breaks the prefix may carry: a message of short lines need not lay out thousands of them to fill the viewport. */
export const USER_MESSAGE_PREVIEW_LINE_CAP = 60;
/** Soft cap per chunk in the full-text dialog; with content-visibility only visible chunks are laid out. */
export const USER_MESSAGE_READING_CHUNK_LENGTH = 2_048;

/** Same set of line breaks as Swift's `Character.isNewline`. */
const LINE_BREAK = /[\n\r\u000B\u000C\u0085\u2028\u2029]/;
const SENTENCE_ENDS = new Set(['.', '!', '?', '。', '！', '？', '؟', '۔', '।', '॥']);
/** Grapheme segmentation only sees a window near the boundary; the slack lets the grapheme that crosses the limit be recognized whole. */
const WINDOW_SLACK = 64;

export function shouldFoldUserMessage(text: string): boolean {
  return text.length > USER_MESSAGE_FOLD_THRESHOLD;
}

let cachedSegmenter: Intl.Segmenter | null | undefined;

function graphemeSegmenter(): Intl.Segmenter | null {
  if (cachedSegmenter === undefined) {
    cachedSegmenter = typeof Intl !== 'undefined' && 'Segmenter' in Intl
      ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
      : null;
  }
  return cachedSegmenter;
}

/** The last grapheme boundary within [start, limit]. Without Intl.Segmenter it at least keeps surrogate pairs whole. */
function graphemeBoundaryAtOrBefore(text: string, start: number, limit: number): number {
  const segmenter = graphemeSegmenter();
  if (!segmenter) {
    const code = text.charCodeAt(limit - 1);
    return limit > start && code >= 0xd800 && code <= 0xdbff ? limit - 1 : limit;
  }
  let boundary = start;
  for (const { index, segment } of segmenter.segment(text.slice(start, Math.min(text.length, limit + WINDOW_SLACK)))) {
    const end = start + index + segment.length;
    if (end > limit) break;
    boundary = end;
  }
  return boundary;
}

/** Cuts the prefix on a grapheme boundary, never splitting surrogate pairs, combining marks or emoji sequences; at most 60 line breaks. */
export function userMessagePreview(text: string): string {
  let limit = Math.min(text.length, USER_MESSAGE_PREVIEW_LENGTH);
  let newlines = 0;
  for (let i = 0; i < limit; i += 1) {
    // \r\n is a single grapheme and counts as one line break, as the native clients count by grapheme.
    if (text[i] === '\n' && i > 0 && text[i - 1] === '\r') continue;
    if (LINE_BREAK.test(text[i])) {
      newlines += 1;
      if (newlines > USER_MESSAGE_PREVIEW_LINE_CAP) {
        limit = i;
        break;
      }
    }
  }
  return text.slice(0, graphemeBoundaryAtOrBefore(text, 0, limit));
}

/** Finds a break in (start, limit]: after sentence-ending punctuation (and the whitespace after it) first, then after whitespace, else on a grapheme boundary. */
function readingBreak(text: string, start: number, limit: number): number {
  const floor = start + USER_MESSAGE_READING_CHUNK_LENGTH / 2;
  for (let i = limit - 1; i >= floor; i -= 1) {
    if (SENTENCE_ENDS.has(text[i])) {
      let end = i + 1;
      while (end < limit && /\s/.test(text[end])) end += 1;
      return end;
    }
  }
  for (let i = limit - 1; i >= floor; i -= 1) {
    if (/\s/.test(text[i])) return i + 1;
  }
  const boundary = graphemeBoundaryAtOrBefore(text, start, limit);
  return boundary > start ? boundary : limit;
}

/**
 * Reading chunks for the full-text dialog: split on line breaks first, then break overlong
 * paragraphs at the nearest point within the cap. Chunks display as paragraphs, the same trade-off
 * the native clients make.
 */
export function userMessageReadingChunks(text: string): string[] {
  const chunks: string[] = [];
  let paragraphStart = 0;
  while (paragraphStart <= text.length) {
    const newline = text.indexOf('\n', paragraphStart);
    const paragraphEnd = newline < 0 ? text.length : newline;
    let start = paragraphStart;
    while (paragraphEnd - start > USER_MESSAGE_READING_CHUNK_LENGTH) {
      const cut = readingBreak(text, start, start + USER_MESSAGE_READING_CHUNK_LENGTH);
      chunks.push(text.slice(start, cut));
      start = cut;
    }
    chunks.push(text.slice(start, paragraphEnd));
    if (newline < 0) break;
    paragraphStart = newline + 1;
  }
  return chunks;
}

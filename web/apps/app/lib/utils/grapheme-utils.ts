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

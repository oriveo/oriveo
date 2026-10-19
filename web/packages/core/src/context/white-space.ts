/**
 * Trim shared by the context pipeline (contract: Unicode White_Space, same set on every client).
 * String.prototype.trim differs: it strips U+FEFF and keeps U+0085.
 */

/** Unicode White_Space code points, in the contract fixture's notation (`whitespace` in directive-detector.v2.json). */
export const WHITE_SPACE: readonly string[] = [
  'U+0009..U+000D',
  'U+0020',
  'U+0085',
  'U+00A0',
  'U+1680',
  'U+2000..U+200A',
  'U+2028',
  'U+2029',
  'U+202F',
  'U+205F',
  'U+3000',
];

function classEntry(entry: string): string {
  return entry
    .split('..')
    .map((codePoint) => `\\u${codePoint.slice('U+'.length)}`)
    .join('-');
}

const WHITE_SPACE_CLASS = WHITE_SPACE.map(classEntry).join('');
const LEADING = new RegExp(`^[${WHITE_SPACE_CLASS}]+`);
const TRAILING = new RegExp(`[${WHITE_SPACE_CLASS}]+$`);

/** Strips leading and trailing Unicode White_Space; U+FEFF and U+001C–U+001F are kept. */
export function trimWhiteSpace(text: string): string {
  return text.replace(LEADING, '').replace(TRAILING, '');
}

import { describe, expect, it } from 'vitest';
import {
  CHAT_INPUT_MAX_LENGTH,
  applyInputLengthLimit,
  limitInsertion,
  takeWithinUtf16Length,
} from './grapheme-utils';

const LIMIT = CHAT_INPUT_MAX_LENGTH;
const FAMILY = '👨‍👩‍👧';

describe('chat input length limit rule', () => {
  it('pins the shared limit', () => {
    expect(LIMIT).toBe(50_000);
  });

  it('limit_pasteWithinLimit_passesThrough', () => {
    const pasted = 'b'.repeat(LIMIT - 5);
    const result = limitInsertion('hello', 5, 5, pasted, LIMIT);
    expect(result.truncated).toBe(false);
    expect(result.text).toBe(`hello${pasted}`);
    expect(result.text.length).toBe(LIMIT);
    expect(result.caret).toBe(LIMIT);

    const viaDiff = applyInputLengthLimit('hello', `hello${pasted}`, LIMIT);
    expect(viaDiff).toMatchObject({ truncated: false, text: `hello${pasted}` });
  });

  it('limit_pasteOverflow_keepsPrefixAndToastsOnce', () => {
    // 60,000 "a" characters pasted into an empty field give 50,000.
    const result = limitInsertion('', 0, 0, 'a'.repeat(60_000), LIMIT);
    expect(result.truncated).toBe(true);
    expect(result.text).toBe('a'.repeat(LIMIT));
    expect(result.caret).toBe(LIMIT);

    const viaDiff = applyInputLengthLimit('', 'a'.repeat(60_000), LIMIT);
    expect(viaDiff.truncated).toBe(true);
    expect(viaDiff.text.length).toBe(LIMIT);
  });

  it('limit_pasteInMiddle_keepsSurroundingTextAndCaret', () => {
    const head = 'H'.repeat(20_000);
    const tail = 'T'.repeat(20_000);
    const pasted = 'p'.repeat(30_000);
    const result = limitInsertion(head + tail, head.length, head.length, pasted, LIMIT);
    expect(result.truncated).toBe(true);
    expect(result.text).toBe(head + 'p'.repeat(10_000) + tail);
    expect(result.caret).toBe(30_000);

    const viaDiff = applyInputLengthLimit(head + tail, head + pasted + tail, LIMIT);
    expect(viaDiff.text).toBe(head + 'p'.repeat(10_000) + tail);
    expect(viaDiff.caret).toBe(30_000);
  });

  it('locates the insertion by caret when the text is one repeated character', () => {
    const previous = 'a'.repeat(LIMIT - 2);
    const next = 'a'.repeat(LIMIT + 3);
    // Inserting 5 "a" characters at position 100: the common prefix and suffix cannot locate the insertion point, so the caret (105) decides.
    const result = applyInputLengthLimit(previous, next, LIMIT, 105);
    expect(result.text).toBe('a'.repeat(LIMIT));
    expect(result.caret).toBe(102);
  });

  it('limit_replaceSelection_countsRemovedRange', () => {
    const previous = 'a'.repeat(LIMIT);
    // Replacing a 100-character selection with 100 characters: the length is unchanged, so it is allowed.
    const same = limitInsertion(previous, 10, 110, 'b'.repeat(100), LIMIT);
    expect(same.truncated).toBe(false);
    expect(same.text.length).toBe(LIMIT);
    // Replacing 100 selected characters with 250: only 100 fit.
    const longer = limitInsertion(previous, 10, 110, 'b'.repeat(250), LIMIT);
    expect(longer.truncated).toBe(true);
    expect(longer.text).toBe('a'.repeat(10) + 'b'.repeat(100) + 'a'.repeat(LIMIT - 110));
    expect(longer.caret).toBe(110);

    const viaDiff = applyInputLengthLimit(
      previous,
      'a'.repeat(10) + 'b'.repeat(250) + 'a'.repeat(LIMIT - 110),
      LIMIT,
    );
    expect(viaDiff.text).toBe(longer.text);
    expect(viaDiff.caret).toBe(110);
  });

  it('limit_cutPoint_neverSplitsSurrogateOrGraphemeCluster', () => {
    // 49,999 "a" characters plus a family emoji: the grapheme that crosses the limit is dropped whole, leaving 49,999.
    const base = 'a'.repeat(LIMIT - 1);
    const pasted = limitInsertion('', 0, 0, base + FAMILY, LIMIT);
    expect(pasted.truncated).toBe(true);
    expect(pasted.text).toBe(base);
    expect(pasted.text.length).toBe(LIMIT - 1);

    const typed = applyInputLengthLimit(base, base + FAMILY, LIMIT);
    expect(typed.text).toBe(base);

    // Surrogate pair: when the limit falls in the middle of the emoji it is dropped whole, leaving no lone high surrogate.
    const pair = limitInsertion('', 0, 0, 'a'.repeat(LIMIT - 1) + '😀', LIMIT);
    expect(pair.text).toBe(base);
    // Combining character: e + U+0301 is not split.
    const combining = limitInsertion('', 0, 0, 'a'.repeat(LIMIT - 1) + 'é', LIMIT);
    expect(combining.text).toBe(base);
    // A skin-tone modifier is an Extend that starts a surrogate pair: a cut right before it must not separate the thumbs-up from its skin tone.
    const skinTone = limitInsertion('', 0, 0, 'a'.repeat(LIMIT - 2) + '👍🏽', LIMIT);
    expect(skinTone.text).toBe('a'.repeat(LIMIT - 2));

    expect(takeWithinUtf16Length(`ab${FAMILY}c`, 5)).toBe('ab');
    expect(takeWithinUtf16Length(`ab${FAMILY}c`, 2 + FAMILY.length)).toBe(`ab${FAMILY}`);
    expect(takeWithinUtf16Length('abc', 10)).toBe('abc');
    expect(takeWithinUtf16Length('abc', 0)).toBe('');
  });

  it('limit_deleteAtOrAboveLimit_alwaysAllowed', () => {
    const atLimit = 'a'.repeat(LIMIT);
    expect(applyInputLengthLimit(atLimit, atLimit.slice(1), LIMIT))
      .toMatchObject({ truncated: false, text: atLimit.slice(1) });
    const above = 'a'.repeat(LIMIT + 500);
    expect(applyInputLengthLimit(above, above.slice(0, -1), LIMIT))
      .toMatchObject({ truncated: false, text: above.slice(0, -1) });
    expect(limitInsertion(above, 0, 300, '', LIMIT))
      .toMatchObject({ truncated: false, text: above.slice(300) });
  });

  it('limit_legacyOverlongDraft_restoredIntact_onlyShrinkAllowed', () => {
    const legacy = 'L'.repeat(60_000);
    // Growing: the whole inserted part is dropped and the existing text keeps every character.
    const grown = applyInputLengthLimit(legacy, `${legacy}x`, LIMIT);
    expect(grown).toMatchObject({ truncated: true, text: legacy, caret: 60_000 });
    // An equal-length replacement is allowed; a longer one is kept only up to the original length.
    expect(limitInsertion(legacy, 0, 10, 'x'.repeat(10), LIMIT).truncated).toBe(false);
    const replaced = limitInsertion(legacy, 0, 10, 'x'.repeat(40), LIMIT);
    expect(replaced.truncated).toBe(true);
    expect(replaced.text).toBe('x'.repeat(10) + 'L'.repeat(59_990));
    // Shrinking is always allowed.
    expect(applyInputLengthLimit(legacy, legacy.slice(0, 55_000), LIMIT))
      .toMatchObject({ truncated: false, text: legacy.slice(0, 55_000) });
  });
});

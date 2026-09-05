import { describe, it, expect } from 'vitest';
import { reasoningTail } from './reasoning-preview';

/**
 * Behavior lock for the single-line preview shown on a collapsed reasoning block.
 *
 * Two reasons it exists:
 * - reported from the app: the reasoning preview line showed raw `**` markers, so the preview has
 *   to strip markdown; the old implementation only trimmed, took the last line and cut it to 40
 *   characters.
 * - preview generation must be bounded: it is recomputed for every chunk while collapsed, and the
 *   old `lastIndexOf('\n')` is O(n) on a reasoning stream with sparse newlines.
 */
describe('reasoningTail', () => {
  describe('markdown marker stripping', () => {
    it('bold markers do not reach the screen', () => {
      expect(reasoningTail('I need to **double check** this step')).toBe('I need to double check this step');
    });

    it('an unclosed bold marker does not reach the screen either (the typical streaming tail)', () => {
      // Mid-stream: the opening `**` has arrived but the closing one has not. A stripper that requires pairs would leave it on screen.
      expect(reasoningTail('next, analyze the **key constraints')).toBe('next, analyze the key constraints');
    });

    it('inline code, strikethrough and italic markers are stripped too', () => {
      expect(reasoningTail('after calling `flush()` here')).toBe('after calling flush() here');
      expect(reasoningTail('this plan ~~will not work~~ needs a redo')).toBe('this plan will not work needs a redo');
      expect(reasoningTail('*note*, then the boundary case')).toBe('note, then the boundary case');
    });

    it('links keep only their readable text', () => {
      expect(reasoningTail('see [the docs](https://example.com/a) for details')).toBe('see the docs for details');
    });

    it('leading block-level markers are stripped', () => {
      expect(reasoningTail('## step two: verify the assumption')).toBe('step two: verify the assumption');
      expect(reasoningTail('> mind the precondition here')).toBe('mind the precondition here');
      expect(reasoningTail('- handle the edge case first')).toBe('handle the edge case first');
      expect(reasoningTail('3. then merge the results')).toBe('then merge the results');
    });
  });

  describe('conservative stripping: leave alone what should be left alone', () => {
    it('multiplication signs, snake_case, tildes and escapes are not removed', () => {
      // `*` with whitespace on both sides is not an emphasis marker
      expect(reasoningTail('complexity is n * log n')).toBe('complexity is n * log n');
      // `_` is always kept: snake_case is far more common in reasoning text than __emphasis__
      expect(reasoningTail('the field name is last_sse_sequence')).toBe('the field name is last_sse_sequence');
      // A single `~` is a tilde, not strikethrough
      expect(reasoningTail('about ~100ms')).toBe('about ~100ms');
      expect(reasoningTail('2*3')).toBe('2*3');
      expect(reasoningTail('char*')).toBe('char*');
      expect(reasoningTail('escaped \\* is kept')).toBe('escaped \\* is kept');
      expect(reasoningTail('>file')).toBe('>file');
    });
  });

  describe('line selection and truncation semantics', () => {
    it('all-whitespace or empty text returns an empty string', () => {
      expect(reasoningTail('')).toBe('');
      expect(reasoningTail('\n\n  ')).toBe('');
      expect(reasoningTail('\n\n   \n')).toBe('');
    });

    it('only the last line is taken', () => {
      expect(reasoningTail('line one\nline two\nline three')).toBe('line three');
    });

    it('trailing newlines and whitespace do not affect line selection (streaming chunks often end with \\n)', () => {
      expect(reasoningTail('line one\nline two\n\n  ')).toBe('line two');
    });

    it('an over-long line is truncated to its tail and prefixed with an ellipsis', () => {
      const result = reasoningTail('a'.repeat(50));
      expect(result).toBe('…' + 'a'.repeat(40));
      expect(result.length).toBe(41);
    });

    it('a line exactly at the limit gets no ellipsis', () => {
      const exact = 'b'.repeat(40);
      expect(reasoningTail(exact)).toBe(exact);
    });
  });

  describe('a frame that holds only marker skeleton', () => {
    /**
     * The model can emit a block-level or emphasis marker right after a newline and only send the
     * body in the next chunk. The marker then owns the line, and the "only counts as a marker when
     * it touches non-whitespace" rule fails on both sides, so without a special case `**` / `###`
     * would be displayed verbatim - exactly the symptom being fixed. Returning an empty string lets
     * the caller keep the previous frame.
     */
    it('a line holding only markdown skeleton returns an empty string, so bare markers never reach the screen', () => {
      expect(reasoningTail('analysis:\n**')).toBe('');
      expect(reasoningTail('analysis:\n###')).toBe('');
      expect(reasoningTail('analysis:\n```')).toBe('');
      expect(reasoningTail('table head\n|---|---|')).toBe('');
      expect(reasoningTail('summary\n---')).toBe('');
    });

    it('a marker already followed by body text still renders and is not caught by the marker-only rule', () => {
      expect(reasoningTail('analysis:\n**key')).toBe('key');
      expect(reasoningTail('analysis:\n### step three')).toBe('step three');
    });
  });

  describe('boundedness (performance invariant)', () => {
    /**
     * Preview cost must be independent of the total reasoning length. The check: put the same line
     * at the tail of hundreds of thousands of characters of reasoning and require the result to match taking that line
     * on its own. Together with the "scan backwards at most one window" implementation, that locks
     * out a regression into a full-text scan.
     */
    it('the preview reads only the tail window, independent of how much precedes it', () => {
      const tail = 'the final line **conclusion** is here';
      const expected = 'the final line conclusion is here';

      expect(reasoningTail(`start\n${tail}`)).toBe(expected);
      expect(reasoningTail('past reasoning text.'.repeat(20_000) + '\n' + tail)).toBe(expected);
    });

    it('very long reasoning with no newline: the window truncation still yields an ellipsis', () => {
      const preview = reasoningTail('no newline reasoning'.repeat(5_000));
      expect(preview.startsWith('…')).toBe(true);
      expect(preview.slice(1).length).toBeLessThanOrEqual(40);
    });

    it('very long trailing whitespace also only scans the fixed tail window', () => {
      expect(reasoningTail('readable content' + ' '.repeat(100_000))).toBe('');
    });
  });
});

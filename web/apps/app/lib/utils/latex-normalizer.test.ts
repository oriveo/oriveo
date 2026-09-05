import { describe, it, expect } from 'vitest';
import { normalizeLatexDelimiters, splitClosedAndOpenLatex } from './latex-normalizer';

describe('normalizeLatexDelimiters', () => {
  it('converts inline \\(...\\) to $...$', () => {
    expect(normalizeLatexDelimiters('  \\(x + y\\)  ')).toBe('  $x + y$  ');
  });

  it('converts block \\[...\\] to $$...$$', () => {
    expect(normalizeLatexDelimiters('\\[x^2 + 1\\]')).toBe('$$x^2 + 1$$');
  });

  it('allows block \\[...\\] to span lines', () => {
    const input = ' \n\\[\nx^2 +\ny^2\n\\]\n ';
    const out = normalizeLatexDelimiters(input);
    expect(out).toBe(' \n$$\nx^2 +\ny^2\n$$\n ');
  });

  it('does not convert inline \\(...\\) that spans lines', () => {
    const input = '  \\(x +\ny\\)  ';
    const out = normalizeLatexDelimiters(input);
    expect(out).toBe(input);
  });

  it('leaves existing $...$ untouched', () => {
    const input = '  $5   $x + y$';
    expect(normalizeLatexDelimiters(input)).toBe(input);
  });

  it('leaves existing $$...$$ untouched', () => {
    const input = '$$x^2$$';
    expect(normalizeLatexDelimiters(input)).toBe(input);
  });

  it('does not convert \\(...\\) inside inline code', () => {
    const input = ' `\\(x + y\\)`  ';
    const out = normalizeLatexDelimiters(input);
    expect(out).toBe(' `\\(x + y\\)`  ');
  });

  it('does not convert LaTeX inside a fenced code block', () => {
    const input = '```js\nfoo[i\\]\nbar = \\(1\\)\n```\n  \\(x\\)';
    const out = normalizeLatexDelimiters(input);
    // Inside the code block the text is preserved; outside it is converted.
    expect(out).toBe('```js\nfoo[i\\]\nbar = \\(1\\)\n```\n  $x$');
  });

  it('handles several formulas mixed together', () => {
    const input = '  1 \\(a\\)   2 \\[b\\]   3 \\(c\\)';
    expect(normalizeLatexDelimiters(input)).toBe('  1 $a$   2 $$b$$   3 $c$');
  });

  it('handles inline and block formulas in the same paragraph', () => {
    const input = '  \\(\\alpha + \\beta\\)   \\[\\sum_{i=0}^n i\\]';
    expect(normalizeLatexDelimiters(input)).toBe(
      '  $\\alpha + \\beta$   $$\\sum_{i=0}^n i$$',
    );
  });

  it('short-circuits on plain text with no LaTeX', () => {
    const input = ' ';
    expect(normalizeLatexDelimiters(input)).toBe(input);
  });

  it('leaves several delimiter styles alone inside a code block', () => {
    const input = '```\n\\[a\\]\n\\(b\\)\n$c$\n```';
    expect(normalizeLatexDelimiters(input)).toBe(input);
  });

  it('protects inline code delimited by double backticks', () => {
    const input = '``\\(x\\)``   \\(y\\)';
    expect(normalizeLatexDelimiters(input)).toBe('``\\(x\\)``   $y$');
  });

  it('handles a block formula containing special characters', () => {
    const input = '\\[\\frac{a}{b} = \\sqrt{c}\\]';
    expect(normalizeLatexDelimiters(input)).toBe('$$\\frac{a}{b} = \\sqrt{c}$$');
  });

  it('handles the empty string', () => {
    expect(normalizeLatexDelimiters('')).toBe('');
  });

  it('protects a ~~~ fenced code block too', () => {
    const input = '~~~\n\\(x\\)\n~~~';
    expect(normalizeLatexDelimiters(input)).toBe(input);
  });
});

describe('splitClosedAndOpenLatex', () => {
  it('leaves an empty tail when every formula is closed', () => {
    const r = splitClosedAndOpenLatex('  \\(x\\)  ');
    expect(r.tail).toBe('');
    expect(r.closed).toBe('  \\(x\\)  ');
  });

  it('splits an unclosed \\( into the tail', () => {
    const r = splitClosedAndOpenLatex('  \\(x + y');
    expect(r.closed).toBe('  ');
    expect(r.tail).toBe('\\(x + y');
  });

  it('splits an unclosed \\[ into the tail, across lines', () => {
    const r = splitClosedAndOpenLatex(' \n\\[\nx^2 +');
    expect(r.closed).toBe(' \n');
    expect(r.tail).toBe('\\[\nx^2 +');
  });

  it('splits an unclosed $$ into the tail', () => {
    const r = splitClosedAndOpenLatex('  $$x^2');
    expect(r.closed).toBe('  ');
    expect(r.tail).toBe('$$x^2');
  });

  it('splits an unclosed single $ into the tail', () => {
    const r = splitClosedAndOpenLatex('  $x +');
    expect(r.closed).toBe('  ');
    expect(r.tail).toBe('$x +');
  });

  it('ignores an unclosed \\( inside a code block when splitting', () => {
    const r = splitClosedAndOpenLatex('```\n\\(unclosed\n```\n ');
    expect(r.tail).toBe('');
    expect(r.closed).toBe('```\n\\(unclosed\n```\n ');
  });

  it('does not split on an unclosed \\( inside inline code', () => {
    const r = splitClosedAndOpenLatex('`\\(x`');
    expect(r.tail).toBe('');
  });

  it('handles several closed formulas followed by an unclosed one', () => {
    const r = splitClosedAndOpenLatex('a \\(1\\) b \\[2\\] c \\(3');
    expect(r.closed).toBe('a \\(1\\) b \\[2\\] c ');
    expect(r.tail).toBe('\\(3');
  });

  it('treats a single $ spanning a newline as not a formula', () => {
    const r = splitClosedAndOpenLatex('  $5\n ');
    // A $ that crosses a line break is treated as closed at the newline.
    expect(r.tail).toBe('');
  });
});

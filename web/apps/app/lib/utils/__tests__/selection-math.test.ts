import { describe, expect, it } from 'vitest';
import { selectionTextWithMathSource } from '../selection-math';

/** Build the minimal DOM that KaTeX emits: .katex-mathml holding the annotation source plus .katex-html holding the visible text. */
function katexSpan(tex: string, visible: string): string {
  return (
    '<span class="katex">' +
    '<span class="katex-mathml"><math><semantics><mrow></mrow>' +
    `<annotation encoding="application/x-tex">${tex}</annotation>` +
    '</semantics></math></span>' +
    `<span class="katex-html" aria-hidden="true">${visible}</span>` +
    '</span>'
  );
}

function selectAll(html: string): Selection {
  document.body.innerHTML = html;
  const selection = window.getSelection()!;
  selection.removeAllRanges();
  const range = document.createRange();
  range.selectNodeContents(document.body);
  selection.addRange(range);
  return selection;
}

describe('selectionTextWithMathSource', () => {
  it('restores inline math to $tex$ without duplicated mathml text', () => {
    const selection = selectAll(`<p>the equation ${katexSpan('E=mc^2', 'E=mc2')} holds</p>`);
    const text = selectionTextWithMathSource(selection);
    expect(text).toContain('$E=mc^2$');
    // The MathML source and the visible text do not both appear
    expect(text.match(/E=mc/g)?.length).toBe(1);
  });

  it('restores display math to $$tex$$ on its own line', () => {
    const selection = selectAll(
      `<p>before</p><span class="katex-display">${katexSpan('a+b=c', 'a+b=c')}</span><p>after</p>`,
    );
    const text = selectionTextWithMathSource(selection);
    expect(text).toContain('$$a+b=c$$');
    expect(text).toContain('before');
    expect(text).toContain('after');
  });

  it('falls back to visible text when annotation is missing', () => {
    const selection = selectAll(
      '<p><span class="katex"><span class="katex-html">x^2</span></span></p>',
    );
    const text = selectionTextWithMathSource(selection);
    expect(text.trim()).toBe('x^2');
  });

  it('keeps plain paragraphs separated by newlines', () => {
    const selection = selectAll('<p>first paragraph</p><p>second paragraph</p>');
    const text = selectionTextWithMathSource(selection);
    expect(text).toContain('first paragraph\n');
    expect(text).toContain('second paragraph');
  });

  it('separates table cells with tabs', () => {
    const selection = selectAll('<table><tbody><tr><td>left</td><td>right</td></tr></tbody></table>');
    const text = selectionTextWithMathSource(selection);
    expect(text).toContain('left\tright');
  });
});

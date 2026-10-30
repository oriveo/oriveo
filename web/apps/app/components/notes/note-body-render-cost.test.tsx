import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/react';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { MarkdownRenderer, ProgressiveMarkdownRenderer, PROGRESSIVE_SECTION_CHARS } from '../chat/MarkdownRenderer';
import { splitMarkdownSections } from '../../lib/markdown/split-markdown-sections';

// Fixture with the same scale and structure as a long real-world note
function onlineFixture(lines: number): string {
  const out: string[] = [];
  let n = 1;
  while (out.length < lines) {
    out.push(
      `## Section ${n}: rendering cost breakdown`, '',
      `This is the body of section ${n}, simulating the paragraph density and mixed content of a long real note, with **bold** and plain text.`, '',
      '- Point one', '- Point two', '- Point three', '',
      '1. First step `measure()`', '2. Second step `layout()`', '3. Third step `draw()`', '',
      '| Metric | Before | After |', '| --- | --- | --- |', '| a | 1 | 2 |', '| b | 3 | 4 |', '| c | 5 | 6 |', '',
      '```kotlin', 'val a = 1', 'val b = 2', 'val c = a + b', 'println(c)', '```', '',
      'Inline math $T_{frame} = 1000 / 120$', '',
      '$$', 'E = mc^2', '$$', '',
      `> Quote ${n}`, '',
    );
    n += 1;
  }
  return out.slice(0, lines).join('\n');
}

function sectionFixture(sections: number): string {
  let s = '';
  for (let i = 0; i < sections; i += 1) {
    s += `## Heading ${i}\n\nParagraph marker${i} with **bold** and \`code\`.\n\n\`\`\`kotlin\nval x = ${i}\n\`\`\`\n\n| a | b |\n|---|---|\n| ${i} | ${i + 1} |\n\n`;
  }
  return s;
}

function firstFrameMs(node: () => React.ReactElement): number {
  const runs: number[] = [];
  for (let r = 0; r < 5; r += 1) {
    const t0 = performance.now();
    act(() => { render(node()); });
    runs.push(performance.now() - t0);
    cleanup();
  }
  runs.sort((a, b) => a - b);
  return runs[2];
}

async function renderFully(content: string): Promise<HTMLElement> {
  const { container } = render(<ProgressiveMarkdownRenderer content={content} />);
  const root = container.firstElementChild as HTMLElement;
  // setState inside idle callbacks only commits outside act, so poll with waitFor
  await waitFor(() => expect(root.dataset.sectionsMounted).toBe(root.dataset.sections), { timeout: 60_000 });
  return root;
}

function fullHtml(content: string): string {
  const { container } = render(<MarkdownRenderer content={content} />);
  const html = container.firstElementChild!.innerHTML;
  cleanup();
  return html;
}

beforeAll(async () => {
  // Let rehype-katex finish loading dynamically so comparisons run in the steady state with math ready
  render(<MarkdownRenderer content={'$x$'} />);
  await act(async () => { await new Promise((r) => setTimeout(r, 300)); });
  cleanup();
});

afterEach(() => cleanup());

describe('splitMarkdownSections', () => {
  it('short markdown stays a single section', () => {
    const md = sectionFixture(3);
    expect(splitMarkdownSections(md, PROGRESSIVE_SECTION_CHARS)).toEqual([md]);
  });

  it('only cuts at top-level block starts and loses no text', () => {
    const md = onlineFixture(3200);
    const parts = splitMarkdownSections(md, PROGRESSIVE_SECTION_CHARS);
    expect(parts.length).toBeGreaterThan(5);
    for (const part of parts.slice(1)) {
      expect(part[0]).not.toMatch(/[\s>\-*+]/);
    }
    expect(parts.join('\n\n').replace(/\n+/g, '\n')).toBe(md.replace(/\n+/g, '\n'));
  });

  it('never cuts inside fences, $$ blocks, comments or before list items', () => {
    const filler = 'x'.repeat(50);
    const md = [filler, '', '```', filler, '', 'inside fence', '```', '', '$$', filler, '', 'inside math', '$$', '',
      '<!--', '', 'inside comment', '-->', '', '- a', '', '- b', '', 'after'].join('\n');
    const parts = splitMarkdownSections(md, 1);
    expect(parts.some((p) => p.startsWith('inside'))).toBe(false);
    expect(parts.some((p) => p.startsWith('- b'))).toBe(false);
    expect(parts[parts.length - 1]).toBe('after');
  });

  it('keeps document-scoped references and footnotes unsplit', () => {
    const body = sectionFixture(300);
    expect(splitMarkdownSections(`${body}[ref]: https://example.com\n`, PROGRESSIVE_SECTION_CHARS)).toHaveLength(1);
    expect(splitMarkdownSections(`${body}note[^1]\n\n[^1]: x\n`, PROGRESSIVE_SECTION_CHARS)).toHaveLength(1);
  });
});

describe('ProgressiveMarkdownRenderer', () => {
  it('fully mounted DOM is identical to whole-document rendering', async () => {
    for (const md of [onlineFixture(3200), sectionFixture(300)]) {
      const expected = fullHtml(md);
      const root = await renderFully(md);
      expect(Number(root.dataset.sections)).toBeGreaterThan(1);
      expect(root.innerHTML).toBe(expected);
      cleanup();
    }
  }, 120_000);

  it('short notes render whole on the first frame, same as before', () => {
    const md = sectionFixture(3);
    const expected = fullHtml(md);
    const { container } = render(<ProgressiveMarkdownRenderer content={md} />);
    const root = container.firstElementChild as HTMLElement;
    expect(root.dataset.sections).toBe('1');
    expect(root.innerHTML).toBe(expected);
  });

  it('select-all / copy / find shortcuts and selection start mount the whole body synchronously', () => {
    const md = sectionFixture(300);
    const expected = fullHtml(md);
    for (const trigger of [
      () => fireEvent.keyDown(document, { key: 'a', ctrlKey: true }),
      () => fireEvent.keyDown(document, { key: 'c', metaKey: true }),
      (root: HTMLElement) => fireEvent(root, new Event('selectstart', { bubbles: true })),
    ]) {
      const { container } = render(<ProgressiveMarkdownRenderer content={md} />);
      const root = container.firstElementChild as HTMLElement;
      expect(root.dataset.sectionsMounted).toBe('1');
      trigger(root);
      expect(root.dataset.sectionsMounted).toBe(root.dataset.sections);
      expect(root.innerHTML).toBe(expected);
      cleanup();
    }
  }, 120_000);

  it('saving an edit re-renders the new body without dropping mounted sections', async () => {
    const md = sectionFixture(300);
    const root = await renderFully(md);
    const edited = md.replace('Paragraph marker150 ', 'Edited marker150 ');
    cleanup();
    const { container, rerender } = render(<ProgressiveMarkdownRenderer content={md} />);
    fireEvent.keyDown(document, { key: 'a', ctrlKey: true });
    rerender(<ProgressiveMarkdownRenderer content={edited} />);
    const after = container.firstElementChild as HTMLElement;
    expect(root).toBeTruthy();
    expect(after.dataset.sectionsMounted).toBe(after.dataset.sections);
    expect(after.innerHTML).toBe(fullHtml(edited));
  }, 120_000);

  it('first-frame cost does not grow with note length', () => {
    const s300 = sectionFixture(300);
    const s1500 = sectionFixture(1500);
    const online = onlineFixture(3200);
    const r = {
      whole: {
        online3200: firstFrameMs(() => <MarkdownRenderer content={online} />),
        s300: firstFrameMs(() => <MarkdownRenderer content={s300} />),
        s1500: firstFrameMs(() => <MarkdownRenderer content={s1500} />),
      },
      progressive: {
        online3200: firstFrameMs(() => <ProgressiveMarkdownRenderer content={online} />),
        s300: firstFrameMs(() => <ProgressiveMarkdownRenderer content={s300} />),
        s1500: firstFrameMs(() => <ProgressiveMarkdownRenderer content={s1500} />),
      },
    };
    console.log('NOTE_BODY_FIRST_FRAME_MS', JSON.stringify(r));
    expect(r.progressive.s1500).toBeLessThanOrEqual(r.progressive.s300 * 1.3);
    expect(r.progressive.online3200).toBeLessThan(r.whole.online3200 / 4);
  }, 300_000);
});

import { describe, it, expect } from 'vitest';
import { stripMarkdownForPreview, stripMarkdownForClipboard } from '../markdown-preview';

describe('stripMarkdownForPreview', () => {
  it('keeps plain text unchanged', () => {
    expect(stripMarkdownForPreview('Hello world')).toBe('Hello world');
  });

  it('removes common markdown markers', () => {
    const text = [
      '# Title',
      '> Quote',
      '- List item',
      'To give you a clear, **actionable** plan, start with this [link](https://example.com).',
    ].join('\n');

    expect(stripMarkdownForPreview(text)).toBe('Title Quote List item To give you a clear, actionable plan, start with this link.');
  });

  it('removes code blocks but keeps inline code content', () => {
    const text = 'First run `pnpm test`, then:\n```bash\npnpm lint\n```';
    expect(stripMarkdownForPreview(text)).toBe('First run pnpm test, then:');
  });

  it('removes invisible placeholder characters and collapses whitespace', () => {
    const text = 'Hello￼  \n\nworld�';
    expect(stripMarkdownForPreview(text)).toBe('Hello world');
  });

  it('table: drops the separator row, trims edge pipes, collapses inner pipes into spaces', () => {
    const text = '| Chinese | English |\n|------|------|\n| hello | hola |';
    expect(stripMarkdownForPreview(text)).toBe('Chinese English hello hola');
  });

  it('table separator row (including alignment colons) is dropped entirely', () => {
    const text = '| a | b |\n| :--- | ---: |\n| 1 | 2 |';
    expect(stripMarkdownForPreview(text)).toBe('a b 1 2');
  });

  it('falls back to stripping an unclosed fence (caller already sliced the text)', () => {
    const text = 'Bubble sort:\n```c\n#include <stdio.h>\nvoid bubbleSort(int arr[], int n) {';
    expect(stripMarkdownForPreview(text)).toBe('Bubble sort:');
  });
});

describe('stripMarkdownForClipboard', () => {
  it('keeps paragraph breaks (repeated newlines)', () => {
    const text = 'First paragraph.\n\nSecond paragraph.';
    expect(stripMarkdownForClipboard(text)).toBe('First paragraph.\n\nSecond paragraph.');
  });

  it('keeps single line breaks', () => {
    const text = 'line one\nline two';
    expect(stripMarkdownForClipboard(text)).toBe('line one\nline two');
  });

  it('strips inline emphasis markers but keeps the content', () => {
    expect(stripMarkdownForClipboard('hello **world** and *italic*.')).toBe('hello world and italic.');
  });

  it('keeps the readable link text and drops the URL', () => {
    expect(stripMarkdownForClipboard('see [docs](https://example.com) here')).toBe('see docs here');
  });

  it('fenced code block keeps the code body and drops the fence and language tag', () => {
    const text = 'Intro:\n```bash\nnpm test\n```\nOutro';
    expect(stripMarkdownForClipboard(text)).toBe('Intro:\nnpm test\nOutro');
  });

  it('unclosed fence (sliced text) drops the opening marker and keeps the rest of the code', () => {
    const text = 'Intro\n```c\n#include <stdio.h>\nint main() {';
    expect(stripMarkdownForClipboard(text)).toBe('Intro\n#include <stdio.h>\nint main() {');
  });

  it('inline code keeps its content', () => {
    expect(stripMarkdownForClipboard('run `pnpm test` now')).toBe('run pnpm test now');
  });

  it('header / quote / list markers are stripped but the content is untouched', () => {
    const text = '# Title\n\n> quote\n\n- item one\n- item two\n\n1. step one\n2. step two';
    expect(stripMarkdownForClipboard(text)).toBe('Title\n\nquote\n\nitem one\nitem two\n\nstep one\nstep two');
  });

  it('collapses repeated spaces on a line without touching newlines', () => {
    expect(stripMarkdownForClipboard('a   b\n\nc')).toBe('a b\n\nc');
  });

  it('strips invisible placeholder characters', () => {
    expect(stripMarkdownForClipboard('Hello￼ world�')).toBe('Hello world');
  });
});

describe('stripMarkdownForPreview math delimiters', () => {
  it('strips $..$ and $$..$$ delimiters but keeps latex content', () => {
    const result = stripMarkdownForPreview('Conclusion: $E=mc^2$ and\n$$a+b=c$$');
    expect(result).not.toContain('$');
    expect(result).toContain('E=mc^2');
    expect(result).toContain('a+b=c');
  });

  it('keeps a lone currency dollar untouched', () => {
    expect(stripMarkdownForPreview('Price $5 only')).toContain('$5');
  });
});

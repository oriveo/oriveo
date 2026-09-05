import { describe, it, expect } from 'vitest';
import { ReasoningBlockSplitter } from './reasoning-stream-blocks';

/**
 * Behavior lock for splitting an expanded thinking stream into stable blocks.
 *
 * Why it exists: react-markdown reparses everything on every render with no caching, and thinking text
 * can run to tens of thousands of characters. Splitting sealed paragraphs into immutable blocks lets each
 * one be memoized and parsed exactly once, making the total cost O(total input).
 * Two invariants: **a block never changes once emitted** (otherwise memoization breaks and the layout
 * reflows), and **a block boundary never cuts into a code fence** (otherwise a code block is split in
 * half and has to be reassembled once it closes).
 */
describe('ReasoningBlockSplitter', () => {
  /** Feed in fixed-size chunks to simulate real chunk arrival */
  function feed(text: string, chunkSize: number) {
    const splitter = new ReasoningBlockSplitter();
    let last = { blocks: [] as string[], tail: '' };
    for (let i = 0; i < text.length; i += chunkSize) {
      last = splitter.advance(text.slice(0, i + chunkSize));
    }
    return { ...last, blocks: [...last.blocks] };
  }

  it('seals a block at a blank line and leaves the final segment in the tail', () => {
    const { blocks, tail } = feed('first\n\nsecond\n\nunfinished', 3);
    expect(blocks).toEqual(['first\n\n', 'second\n\n']);
    expect(tail).toBe('unfinished');
  });

  it('does not change a block once it has been emitted, which memoization depends on', () => {
    const splitter = new ReasoningBlockSplitter();
    splitter.advance('first\n\n');
    const firstSnapshot = splitter.advance('first\n\nseco')?.blocks[0];
    splitter.advance('first\n\nsecond\n\nthird');
    const stillSame = splitter.advance('first\n\nsecond\n\nthird more')?.blocks[0];
    expect(stillSame).toBe(firstSnapshot);
  });

  it('does not split on blank lines inside a code fence', () => {
    const text = 'intro\n\n```js\nconst a = 1;\n\nconst b = 2;\n```\n\noutro\n\n';
    const { blocks } = feed(text, 5);
    // The fence has to survive as one block and must not be split by the blank line inside it
    const fenceBlock = blocks.find((b) => b.includes('```'));
    expect(fenceBlock).toBeDefined();
    expect((fenceBlock!.match(/```/g) ?? []).length).toBe(2);
    expect(fenceBlock).toContain('const a = 1;');
    expect(fenceBlock).toContain('const b = 2;');
  });

  it('never seals an unclosed fence and keeps it in the tail until it closes', () => {
    const { blocks, tail } = feed('preface\n\n```js\nlet x = 1;\n\nlet y = 2;\n', 4);
    expect(blocks).toEqual(['preface\n\n']);
    expect(tail).toContain('```js');
    expect(tail).toContain('let y = 2;');
  });

  it('produces the same split regardless of chunk granularity', () => {
    const text = 'alpha\n\nbeta\n\n```py\nx=1\n\ny=2\n```\n\ngamma\n\ntailend';
    const baseline = feed(text, 1);
    for (const size of [2, 3, 7, 16, 64]) {
      const got = feed(text, size);
      expect(got.blocks).toEqual(baseline.blocks);
      expect(got.tail).toBe(baseline.tail);
    }
  });

  it('emits no empty blocks for consecutive blank lines, avoiding a swarm of empty components', () => {
    const { blocks } = feed('alpha\n\n\n\nbeta\n\n', 3);
    expect(blocks.every((b) => b.trim() !== '')).toBe(true);
  });

  it('rebuilds from scratch when the input is not an extension of the previous one (message switch or replay)', () => {
    const splitter = new ReasoningBlockSplitter();
    splitter.advance('old one\n\nold two\n\n');
    const { blocks, tail } = splitter.advance('brand new\n\nnew tail');
    expect(blocks).toEqual(['brand new\n\n']);
    expect(tail).toBe('new tail');
  });

  it('starts from zero after reset', () => {
    const splitter = new ReasoningBlockSplitter();
    splitter.advance('body\n\nmore');
    splitter.reset();
    const { blocks, tail } = splitter.advance('fresh\n\ntip');
    expect(blocks).toEqual(['fresh\n\n']);
    expect(tail).toBe('tip');
  });

  /**
   * Performance invariant: the tail is bounded. The tail is the only part reparsed each frame, so if it
   * grew with the total length, per-frame parse cost would rise with the thinking text and the total would
   * be back to O(n^2).
   */
  it('keeps the tail from growing with the total length of the thinking text', () => {
    const splitter = new ReasoningBlockSplitter();
    let text = '';
    let peakTail = 0;
    for (let i = 0; i < 2_000; i += 1) {
      text += `paragraph ${i} of reasoning, with **emphasis** and \`code\`.\n\n`;
      peakTail = Math.max(peakTail, splitter.advance(text).tail.length);
    }
    expect(peakTail).toBeLessThan(200);
  });

  /** The scan must be incremental: feeding the same text again must not emit the blocks twice. */
  it('is idempotent across repeated advance calls, which keeps it safe under StrictMode', () => {
    const splitter = new ReasoningBlockSplitter();
    const text = 'alpha\n\nbeta\n\ngamma';
    const first = splitter.advance(text);
    const second = splitter.advance(text);
    expect(second.blocks).toEqual(first.blocks);
    expect(second.tail).toBe(first.tail);
    expect(second.blocks.length).toBe(2);
  });
});

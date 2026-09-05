/**
 * Unit tests for the token estimation formula.
 *
 * estimatedTokens = Math.ceil(graphemeCount * 0.35)
 * The formula is inlined in MemoryPage.tsx; this file verifies it on its own.
 */
import { describe, it, expect } from 'vitest';
import { graphemeCount } from '../grapheme-utils';

// Same formula as in MemoryPage.tsx.
function estimateTokens(text: string): number {
  return Math.ceil(graphemeCount(text) * 0.35);
}

describe('Token estimation formula', () => {
  it('empty string -> ceil(0 * 0.35) = 0', () => {
    expect(estimateTokens('')).toBe(0);
  });

  it('1 character -> ceil(1 * 0.35) = 1', () => {
    expect(estimateTokens('a')).toBe(1);
  });

  it('3 characters -> ceil(3 * 0.35) = ceil(1.05) = 2', () => {
    expect(estimateTokens('abc')).toBe(2);
  });

  it('2000 characters -> ceil(2000 * 0.35) = 700', () => {
    const text = 'a'.repeat(2000);
    expect(estimateTokens(text)).toBe(700);
  });

  it('matches Math.ceil(graphemeCount * 0.35)', () => {
    const testCases = ['', 'a', 'hello', '👨‍👩‍👧‍👦', '🇨🇳test', 'x'.repeat(100)];
    for (const text of testCases) {
      const count = graphemeCount(text);
      expect(estimateTokens(text)).toBe(Math.ceil(count * 0.35));
    }
  });

  it('counts emoji by grapheme rather than by code unit', () => {
    // A family emoji is 1 grapheme, not its .length of 11.
    const emoji = '👨‍👩‍👧‍👦';
    expect(estimateTokens(emoji)).toBe(Math.ceil(1 * 0.35)); // = 1
    //   string.length  
    expect(estimateTokens(emoji)).not.toBe(Math.ceil(emoji.length * 0.35));
  });
});

/**
 * Unit tests for grapheme-utils.
 *
 * Covers grapheme cluster counting and truncation built on Intl.Segmenter, focusing on Unicode
 * edge cases such as emoji, combining marks and flags, plus the fallback path for browsers with
 * no Intl.Segmenter (Firefox before 125).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { graphemeCount, takeGraphemes } from '../grapheme-utils';

describe('graphemeCount', () => {
  it('counts ASCII strings by character', () => {
    expect(graphemeCount('hello')).toBe(5);
    expect(graphemeCount('abc123')).toBe(6);
  });

  it('returns 0 for an empty string', () => {
    expect(graphemeCount('')).toBe(0);
  });

  it('counts a family emoji (ZWJ sequence) as one grapheme', () => {
    // 👨‍👩‍👧‍👦 = U+1F468 U+200D U+1F469 U+200D U+1F467 U+200D U+1F466
    expect(graphemeCount('👨‍👩‍👧‍👦')).toBe(1);
  });

  it('counts a flag emoji (regional indicator) as one grapheme', () => {
    // 🇨🇳 = U+1F1E8 U+1F1F3
    expect(graphemeCount('🇨🇳')).toBe(1);
  });

  it('counts a combining mark as one grapheme', () => {
    // é = e + U+0301 (combining acute accent)
    const eCombined = 'e\u0301';
    expect(graphemeCount(eCombined)).toBe(1);
  });

  it('counts mixed content correctly', () => {
    // "Hi👨‍👩‍👧‍👦!" = H + i + 👨‍👩‍👧‍👦 + ! = 4
    expect(graphemeCount('Hi👨‍👩‍👧‍👦!')).toBe(4);
  });

  it('counts each of several emoji as one', () => {
    expect(graphemeCount('🇨🇳🇯🇵🇺🇸')).toBe(3);
  });
});

describe('takeGraphemes', () => {
  it('truncation does not break ASCII characters', () => {
    expect(takeGraphemes('hello world', 5)).toBe('hello');
  });

  it('returns the whole string when limit exceeds its length', () => {
    expect(takeGraphemes('short', 100)).toBe('short');
  });

  it('returns an empty string when limit is 0', () => {
    expect(takeGraphemes('hello', 0)).toBe('');
  });

  it('truncating on an emoji boundary does not break a ZWJ sequence', () => {
    // A family emoji is one grapheme, so limit=1 returns the whole emoji
    const family = '👨‍👩‍👧‍👦';
    expect(takeGraphemes(`${family}abc`, 1)).toBe(family);
  });

  it('truncating on a flag emoji boundary does not break the regional indicator pair', () => {
    expect(takeGraphemes('🇨🇳abc', 1)).toBe('🇨🇳');
  });

  it('truncates mixed content on grapheme boundaries', () => {
    // "Hi👨‍👩‍👧‍👦!" → limit=3 → "Hi👨‍👩‍👧‍👦"
    expect(takeGraphemes('Hi👨‍👩‍👧‍👦!', 3)).toBe('Hi👨‍👩‍👧‍👦');
  });

  it('returns an empty string for an empty string', () => {
    expect(takeGraphemes('', 5)).toBe('');
  });
});

describe('fallback path when Intl.Segmenter is unavailable (Firefox before 125)', () => {
  // Delegate through the prototype to keep the rest of Intl, shadowing only Segmenter as undefined to emulate an old browser
  const intlWithoutSegmenter = Object.create(Intl, {
    Segmenter: { value: undefined },
  }) as typeof Intl;

  beforeEach(() => {
    vi.resetModules();
    vi.stubGlobal('Intl', intlWithoutSegmenter);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  function importFresh() {
    return import('../grapheme-utils');
  }

  it('evaluating the module top level does not throw: a top-level new Intl.Segmenter blows up as soon as the chunk is evaluated', async () => {
    await expect(importFresh()).resolves.toBeDefined();
  });

  it('graphemeCount falls back to counting code points', async () => {
    const { graphemeCount: count } = await importFresh();
    expect(count('hello')).toBe(5);
    expect(count('')).toBe(0);
    // Fallback semantics: a ZWJ family emoji is 4 emoji code points plus 3 ZWJ = 7
    expect(count('👨‍👩‍👧‍👦')).toBe(7);
    // A flag is 2 regional indicator code points
    expect(count('🇨🇳')).toBe(2);
    // e plus a combining accent is 2 code points
    const eCombined = 'e' + String.fromCharCode(0x0301);
    expect(count(eCombined)).toBe(2);
  });

  it('takeGraphemes falls back to code point truncation without splitting a surrogate pair', async () => {
    const { takeGraphemes: take } = await importFresh();
    expect(take('hello world', 5)).toBe('hello');
    expect(take('hello', 0)).toBe('');
    expect(take('short', 100)).toBe('short');
    // A grinning face is a single code point (a surrogate pair), and Array.from does not cut it in half
    expect(take('😀abc', 1)).toBe('😀');
    expect(take('😀abc', 2)).toBe('😀a');
  });

  it('a negative limit returns an empty string, matching the Segmenter path', async () => {
    const { takeGraphemes: take } = await importFresh();
    expect(take('hello', -1)).toBe('');
  });
});

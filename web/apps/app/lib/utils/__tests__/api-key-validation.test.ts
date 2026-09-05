import { describe, it, expect } from 'vitest';
import { isPrintableAsciiKey } from '../api-key-validation';

describe('isPrintableAsciiKey', () => {
  it('accepts a common OpenAI-style key', () => {
    expect(isPrintableAsciiKey('sk-1234567890ABCDEFabcdef')).toBe(true);
  });

  it('accepts an Anthropic-style key containing hyphens', () => {
    expect(isPrintableAsciiKey('sk-ant-api03-AaBbCc1234')).toBe(true);
  });

  it('accepts a Gemini-style key with the AIza prefix', () => {
    expect(isPrintableAsciiKey('AIzaSy0123-_AAAA1234')).toBe(true);
  });

  it('rejects an empty string', () => {
    expect(isPrintableAsciiKey('')).toBe(false);
  });

  it('rejects a key containing CJK characters', () => {
    expect(isPrintableAsciiKey('sk-\u4e2d\u6587key')).toBe(false);
  });

  it('rejects a key containing an ideographic (full-width) space', () => {
    expect(isPrintableAsciiKey('sk-test\u3000abc')).toBe(false);
  });

  it('rejects a key containing a zero-width space', () => {
    expect(isPrintableAsciiKey('sk-test\u200babc')).toBe(false);
  });

  it('rejects a key containing a BOM', () => {
    expect(isPrintableAsciiKey('﻿sk-test')).toBe(false);
  });

  it('rejects control characters such as newlines and tabs', () => {
    expect(isPrintableAsciiKey('sk-test\nabc')).toBe(false);
    expect(isPrintableAsciiKey('sk-test\tabc')).toBe(false);
  });

  it('rejects a key made only of invisible characters', () => {
    expect(isPrintableAsciiKey('\u200b\u200b')).toBe(false);
  });

  it('accepts an inner ASCII space, although callers should already have trimmed the key', () => {
    // A space inside a key is within the printable ASCII range; in practice callers trim first.
    expect(isPrintableAsciiKey('sk a')).toBe(true);
  });
});

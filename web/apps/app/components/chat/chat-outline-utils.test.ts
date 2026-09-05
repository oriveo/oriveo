import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';
import {
  clampPreview,
  derivePreview,
  deriveOutlineTicks,
  outlineVisibleRange,
  previewCharLimit,
  resolveOutlineActiveIndex,
  tooltipMaxWidth,
} from './chat-outline-utils';

function userMsg(id: string, text: string, attachments?: ChatMessage['attachments']): ChatMessage {
  return { id, role: 'user', text, attachments } as ChatMessage;
}

function assistantMsg(id: string, text: string): ChatMessage {
  return { id, role: 'assistant', text } as ChatMessage;
}

describe('derivePreview', () => {
  it('takes first line, collapses whitespace, trims', () => {
    expect(derivePreview(userMsg('1', '  hello   world  \nsecond line'), '(att)')).toBe('hello world');
  });

  it('collapses internal tabs/newlines on the first line only', () => {
    expect(derivePreview(userMsg('1', 'a\t\tb'), '(att)')).toBe('a b');
  });

  it('falls back to attachment label when text is empty', () => {
    expect(derivePreview(userMsg('1', '   '), '(att)')).toBe('(att)');
    expect(derivePreview(userMsg('1', ''), '(att)')).toBe('(att)');
  });

  it('uses attachment label for attachment-only messages', () => {
    expect(derivePreview(userMsg('1', '', [{ id: 'a' } as never]), '(att)')).toBe('(att)');
  });
});

describe('deriveOutlineTicks', () => {
  it('keeps only user messages in order with stable ids', () => {
    const ticks = deriveOutlineTicks(
      [userMsg('u1', 'first'), assistantMsg('a1', 'answer'), userMsg('u2', 'second')],
      '(att)',
    );
    expect(ticks).toEqual([
      { id: 'u1', preview: 'first' },
      { id: 'u2', preview: 'second' },
    ]);
  });

  it('returns empty array when there are no user messages', () => {
    expect(deriveOutlineTicks([assistantMsg('a1', 'x')], '(att)')).toEqual([]);
  });
});

describe('clampPreview', () => {
  it('returns input unchanged when within limit', () => {
    expect(clampPreview('short', 10)).toBe('short');
  });

  it('truncates and appends ellipsis beyond limit', () => {
    expect(clampPreview('abcdefghij', 4)).toBe('abcd…');
  });

  it('counts CJK characters the same as ASCII', () => {
    expect(clampPreview('\u4f60\u597d\u4e16\u754c\u4f60\u597d', 4)).toBe('\u4f60\u597d\u4e16\u754c…');
  });
});

describe('previewCharLimit', () => {
  it('uses breakpoints 48 / 32 / 24', () => {
    expect(previewCharLimit(1280)).toBe(48);
    expect(previewCharLimit(900)).toBe(32);
    expect(previewCharLimit(500)).toBe(24);
  });
});

describe('tooltipMaxWidth', () => {
  it('clamps small screens to viewport width minus gutters', () => {
    expect(tooltipMaxWidth(1280)).toBe(320);
    expect(tooltipMaxWidth(900)).toBe(240);
    expect(tooltipMaxWidth(360)).toBe(220);
    expect(tooltipMaxWidth(200)).toBe(152);
  });
});

describe('outlineVisibleRange', () => {
  it('shows all when within capacity', () => {
    expect(outlineVisibleRange(10, 3, 54)).toEqual({ start: 0, end: 10 });
    expect(outlineVisibleRange(54, 0, 54)).toEqual({ start: 0, end: 54 });
  });

  it('tail-aligned pages: window is stable anywhere within the same page', () => {
    expect(outlineVisibleRange(100, 99, 54)).toEqual({ start: 46, end: 100 });
    expect(outlineVisibleRange(100, 46, 54)).toEqual({ start: 46, end: 100 });
    expect(outlineVisibleRange(100, 45, 54)).toEqual({ start: 0, end: 46 });
    expect(outlineVisibleRange(100, 5, 54)).toEqual({ start: 0, end: 46 });
  });

  it('tail page is always full; partial page only at the earliest history top', () => {
    // Regression for three orphaned dots: 57 turns must still fill the window with 54 at the tail of a conversation
    expect(outlineVisibleRange(57, 56, 54)).toEqual({ start: 3, end: 57 });
    expect(outlineVisibleRange(57, 2, 54)).toEqual({ start: 0, end: 3 });
    expect(outlineVisibleRange(108, 107, 54)).toEqual({ start: 54, end: 108 });
    expect(outlineVisibleRange(108, 53, 54)).toEqual({ start: 0, end: 54 });
  });

  it('falls back to tail page when no current or out of bounds', () => {
    expect(outlineVisibleRange(100, -1, 54)).toEqual({ start: 46, end: 100 });
    expect(outlineVisibleRange(100, 200, 54)).toEqual({ start: 46, end: 100 });
  });

  it('defensive: non-positive capacity shows all, empty list yields empty range', () => {
    expect(outlineVisibleRange(10, 3, 0)).toEqual({ start: 0, end: 10 });
    expect(outlineVisibleRange(0, -1, 54)).toEqual({ start: 0, end: 0 });
  });
});

describe('resolveOutlineActiveIndex', () => {
  it('pins the last tick at the real bottom even when the focus line still points earlier', () => {
    expect(resolveOutlineActiveIndex(6, 4, false, true)).toBe(5);
  });

  it('pins the first tick only at the real top', () => {
    expect(resolveOutlineActiveIndex(6, 1, true, false)).toBe(0);
  });

  it('prefers the latest turn when a short conversation fits entirely in the viewport', () => {
    expect(resolveOutlineActiveIndex(4, 1, true, true)).toBe(3);
  });

  it('uses and clamps the focus candidate in the middle', () => {
    expect(resolveOutlineActiveIndex(6, 3, false, false)).toBe(3);
    expect(resolveOutlineActiveIndex(6, 99, false, false)).toBe(5);
    expect(resolveOutlineActiveIndex(0, 0, true, true)).toBe(-1);
  });
});

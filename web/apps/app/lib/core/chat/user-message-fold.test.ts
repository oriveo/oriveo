import { describe, expect, it } from 'vitest';
import {
  USER_MESSAGE_FOLD_THRESHOLD,
  USER_MESSAGE_PREVIEW_LENGTH,
  USER_MESSAGE_PREVIEW_LINE_CAP,
  USER_MESSAGE_READING_CHUNK_LENGTH,
  shouldFoldUserMessage,
  userMessagePreview,
  userMessageReadingChunks,
} from './user-message-fold';

// Mirrors the fold tests of the native clients.
const arabic = (length: number) => {
  const sentence = 'هذا نص عربي طويل جدا بدون أي سطر جديد. ';
  let out = '';
  while (out.length < length) out += sentence;
  return out;
};

describe('user message fold', () => {
  it('folds only past the UTF-16 threshold', () => {
    const atThreshold = 'a'.repeat(USER_MESSAGE_FOLD_THRESHOLD);
    expect(shouldFoldUserMessage(atThreshold)).toBe(false);
    expect(shouldFoldUserMessage(`${atThreshold}a`)).toBe(true);
    expect(shouldFoldUserMessage('😀'.repeat(3_000))).toBe(false);
    expect(shouldFoldUserMessage('😀'.repeat(3_001))).toBe(true);
  });

  it('keeps a bounded prefix of the original', () => {
    const text = arabic(200_000);
    const preview = userMessagePreview(text);
    expect(text.startsWith(preview)).toBe(true);
    expect(preview.length).toBeLessThanOrEqual(USER_MESSAGE_PREVIEW_LENGTH);
    expect(preview.length).toBeGreaterThan(USER_MESSAGE_PREVIEW_LENGTH - 30);
  });

  it('never splits an emoji sequence or a base letter from its marks', () => {
    const family = '👩‍👩‍👧‍👦';
    const text = `${'a'.repeat(USER_MESSAGE_PREVIEW_LENGTH - 1)}${family}${'b'.repeat(8_000)}`;
    expect(userMessagePreview(text)).toBe('a'.repeat(USER_MESSAGE_PREVIEW_LENGTH - 1));
    // ب + kasra + shadda is one grapheme.
    expect(userMessagePreview('بِّ'.repeat(3_000)).length % 3).toBe(0);
  });

  it('keeps at most 60 line breaks and counts CRLF once', () => {
    const lf = userMessagePreview('line\n'.repeat(5_000));
    expect(lf.split('\n').length - 1).toBe(USER_MESSAGE_PREVIEW_LINE_CAP);
    const crlf = userMessagePreview('line\r\n'.repeat(5_000));
    expect(crlf.split('\r\n').length - 1).toBe(USER_MESSAGE_PREVIEW_LINE_CAP);
  });

  it('splits the full text into bounded reading chunks without losing characters', () => {
    const text = `${arabic(200_000)}\n\nsecond paragraph\n${'한'.repeat(5_000)}`;
    const chunks = userMessageReadingChunks(text);
    expect(chunks.join('')).toBe(text.replaceAll('\n', ''));
    expect(chunks.every((chunk) => chunk.length <= USER_MESSAGE_READING_CHUNK_LENGTH)).toBe(true);
    expect(chunks.length).toBeGreaterThanOrEqual(100);
    expect(chunks[0].endsWith('. ')).toBe(true);

    const emoji = '👍🏽'.repeat(3_000);
    const emojiChunks = userMessageReadingChunks(emoji);
    expect(emojiChunks.join('')).toBe(emoji);
    expect(emojiChunks.every((chunk) => chunk.length % 4 === 0)).toBe(true);
  });
});

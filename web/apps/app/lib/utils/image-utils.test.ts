import { describe, it, expect } from 'vitest';
import { detectImageMime } from './image-utils';

const b64 = (head: number[] | string) => {
  const bytes = typeof head === 'string' ? Array.from(head, (c) => c.charCodeAt(0)) : head;
  return btoa(String.fromCharCode(...bytes, ...new Array(16).fill(0)));
};

describe('detectImageMime', () => {
  it('recognises the four formats providers accept', () => {
    expect(detectImageMime(b64([0xff, 0xd8, 0xff, 0xe0]))).toBe('image/jpeg');
    expect(detectImageMime(b64([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))).toBe('image/png');
    expect(detectImageMime(b64('GIF89a'))).toBe('image/gif');
    expect(detectImageMime(b64('RIFF\0\0\0\0WEBPVP8 '))).toBe('image/webp');
  });

  it('returns null for unknown or truncated input so callers keep the declared mime', () => {
    expect(detectImageMime(b64('RIFF\0\0\0\0WAVEfmt '))).toBeNull();
    expect(detectImageMime(b64('\0\0\0\x18ftypheic'))).toBeNull();
    expect(detectImageMime('aGk=')).toBeNull();
    expect(detectImageMime('')).toBeNull();
  });

  it('sniffs line-wrapped base64', () => {
    const raw = b64([0xff, 0xd8, 0xff]);
    expect(detectImageMime(`${raw.slice(0, 6)}\r\n${raw.slice(6)}`)).toBe('image/jpeg');
  });
});

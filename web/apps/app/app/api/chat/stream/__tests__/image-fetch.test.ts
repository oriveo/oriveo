import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { safeFetchImage, safeImageToDataURL, isAllowedImageUrl, IMAGE_FETCH_LIMITS } from '../image-fetch';

describe('isAllowedImageUrl', () => {
  it('allows https://', () => {
    expect(isAllowedImageUrl('https://example.com/img.png')).toBe(true);
  });

  it('rejects http://, which could be redirected into a private network by a man in the middle', () => {
    expect(isAllowedImageUrl('http://example.com/img.png')).toBe(false);
  });

  it('rejects file://, which would allow reading local files', () => {
    expect(isAllowedImageUrl('file:///etc/passwd')).toBe(false);
  });

  it('rejects ftp://, data:// and javascript:', () => {
    expect(isAllowedImageUrl('ftp://example.com/img.png')).toBe(false);
    expect(isAllowedImageUrl('data:image/png;base64,abc')).toBe(false);
    expect(isAllowedImageUrl('javascript:alert(1)')).toBe(false);
  });

  it('rejects an invalid URL', () => {
    expect(isAllowedImageUrl('not a url')).toBe(false);
    expect(isAllowedImageUrl('')).toBe(false);
  });
});

describe('safeFetchImage', () => {
  let originalFetch: typeof fetch;

  beforeEach(() => {
    originalFetch = global.fetch;
  });

  afterEach(() => {
    global.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  it('rejects an http URL outright, without issuing a request', async () => {
    const fetchSpy = vi.fn();
    global.fetch = fetchSpy;
    const result = await safeFetchImage('http://example.com/img.png');
    expect(result).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('returns the buffer and content-type on a successful response', async () => {
    const bytes = new Uint8Array([1, 2, 3, 4]);
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: new Headers({ 'Content-Type': 'image/jpeg' }),
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(bytes);
          controller.close();
        },
      }),
    });

    const result = await safeFetchImage('https://example.com/img.jpg');
    expect(result).not.toBeNull();
    expect(result?.contentType).toBe('image/jpeg');
    expect(new Uint8Array(result!.buffer)).toEqual(bytes);
  });

  it('rejects an oversized Content-Length without reading the body', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: new Headers({
        'Content-Type': 'image/png',
        'Content-Length': String(IMAGE_FETCH_LIMITS.MAX_BYTES + 1),
      }),
      body: new ReadableStream(),
    });

    const result = await safeFetchImage('https://example.com/huge.png');
    expect(result).toBeNull();
  });

  it('aborts when the limit is exceeded partway through the stream', async () => {
    // Simulate a single chunk larger than MAX_BYTES
    const huge = new Uint8Array(IMAGE_FETCH_LIMITS.MAX_BYTES + 100);
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: new Headers({ 'Content-Type': 'image/png' }),
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(huge);
          controller.close();
        },
      }),
    });

    const result = await safeFetchImage('https://example.com/huge.png');
    expect(result).toBeNull();
  });

  it('returns null for a non-2xx response', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: false,
      headers: new Headers(),
      body: null,
    });
    expect(await safeFetchImage('https://example.com/notfound.png')).toBeNull();
  });

  it('returns null when fetch throws', async () => {
    global.fetch = vi.fn().mockRejectedValue(new Error('network error'));
    expect(await safeFetchImage('https://example.com/img.png')).toBeNull();
  });

  it('returns null when the body is missing', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: new Headers(),
      body: null,
    });
    expect(await safeFetchImage('https://example.com/img.png')).toBeNull();
  });
});

describe('safeImageToDataURL', () => {
  let originalFetch: typeof fetch;

  beforeEach(() => {
    originalFetch = global.fetch;
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  it('converts a successful response into a data URL', async () => {
    const bytes = new Uint8Array([1, 2, 3]);
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: new Headers({ 'Content-Type': 'image/png' }),
      body: new ReadableStream({
        start(c) {
          c.enqueue(bytes);
          c.close();
        },
      }),
    });

    const result = await safeImageToDataURL('https://example.com/img.png');
    expect(result).toBe('data:image/png;base64,AQID');
  });

  it('returns null when http is rejected', async () => {
    const result = await safeImageToDataURL('http://example.com/img.png');
    expect(result).toBeNull();
  });
});

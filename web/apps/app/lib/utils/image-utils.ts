/**
 * Image processing helpers.
 * - loadImageElement: base64 -> HTMLImageElement
 * - compressImage: image compression
 * - createImageThumbnail: thumbnail generation
 * - readFileAsBase64: File -> base64
 * - base64ToBlob: base64 -> Blob, chunked so the main thread is not frozen; also used by file
 *   attachment upload
 */

/** Load base64 image data into an HTMLImageElement. */
export function loadImageElement(base64Data: string, mimeType: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('Failed to load image'));
    img.src = `data:${mimeType};base64,${base64Data}`;
  });
}

/**
 * Longest edge 1536px, JPEG quality 0.7.
 *
 * Failure always returns `null`; the input is never handed back unchanged. Both this and
 * createImageThumbnail share `loadImageElement`, so when the browser cannot decode an image they
 * fail together. Echoing the input back would make the "compressed result" and the "thumbnail"
 * both equal to the original base64, so a 100MB PNG would be written into a message attachment's
 * thumbnailBase64 as a single 133MB string. A remote client SDK accepts that write into its
 * mutation queue first and the 1MiB per-document limit is only checked at the server commit, so
 * the whole batch of messages is rejected permanently and lost. Callers must decide their own
 * fallback.
 */
export async function compressImage(base64Data: string, mimeType: string): Promise<{ data: string; mime: string } | null> {
  try {
    const img = await loadImageElement(base64Data, mimeType);
    const maxDim = 1536;
    const scale = Math.min(maxDim / Math.max(img.width, img.height), 1.0);
    const w = Math.round(img.width * scale);
    const h = Math.round(img.height * scale);

    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, w, h);

    const data = canvas.toDataURL('image/jpeg', 0.7).split(',')[1] ?? '';
    return data ? { data, mime: 'image/jpeg' } : null;
  } catch {
    return null;
  }
}

/** Longest edge 120px, JPEG quality 0.5. Returns `null` on failure; see compressImage for why. */
export async function createImageThumbnail(base64Data: string, mimeType: string): Promise<string | null> {
  try {
    const img = await loadImageElement(base64Data, mimeType);
    const canvas = document.createElement('canvas');
    const maxSize = 120;
    const ratio = Math.min(maxSize / Math.max(img.width, img.height), 1);
    canvas.width = Math.round(img.width * ratio);
    canvas.height = Math.round(img.height * ratio);

    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

    const thumbnail = canvas.toDataURL('image/jpeg', 0.5).split(',')[1] ?? '';
    return thumbnail || null;
  } catch {
    return null;
  }
}

/** File -> base64 string. */
export function readFileAsBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result as string;
      // Strip the data URI prefix and keep only the base64 payload.
      const base64 = result.split(',')[1] ?? result;
      resolve(base64);
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

/**
 * base64 chunk size in characters. Must be a multiple of 4: base64 encodes 3 bytes per 4
 * characters, and cutting anywhere else decodes every following byte incorrectly.
 */
const BASE64_CHUNK_CHARS = 1_048_576;

/** Yield one macrotask; a microtask would not give the browser a chance to paint. */
function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, 0); });
}

/**
 * base64 -> Blob, decoded in chunks that yield the main thread in between.
 *
 * `Uint8Array.from(atob(all), (c) => c.charCodeAt(0))` has two problems:
 *  1. the mapFn of `Uint8Array.from` is a function call per byte; a 5MB input measured 150ms as
 *     one synchronous block (chunked with preallocated writes it is 5ms total and 0.8ms for the
 *     longest block, byte-for-byte identical output). It scales linearly, so at the 100MB
 *     attachment limit it freezes the whole tab for seconds.
 *  2. decoding the whole string with atob first materializes a binary string of the same length,
 *     adding one more copy of the file at peak.
 *
 * Deliberately not `fetch('data:...')`: that path is governed by the CSP `connect-src` directive,
 * and under a `connect-src 'self'` baseline data: URIs are not allowlisted and the fetch fails
 * silently. Chunked decoding works everywhere and produces identical bytes.
 *
 * Shared by image attachments (`attachment-utils`) and file attachment upload
 * (`core/sync-port`).
 */
export async function base64ToBlob(base64: string, mimeType: string): Promise<Blob> {
  // Explicit ArrayBuffer type argument: since TS 5.9 lib.dom narrows BlobPart to
  // ArrayBufferView<ArrayBuffer>, and a bare Uint8Array[] (= Uint8Array<ArrayBufferLike>) does not
  // compile against it.
  const parts: Array<Uint8Array<ArrayBuffer>> = [];
  for (let offset = 0; offset < base64.length; offset += BASE64_CHUNK_CHARS) {
    const binary = atob(base64.slice(offset, offset + BASE64_CHUNK_CHARS));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    parts.push(bytes);
    if (offset + BASE64_CHUNK_CHARS < base64.length) await yieldToEventLoop();
  }
  // Blob  
  return new Blob(parts, { type: mimeType });
}

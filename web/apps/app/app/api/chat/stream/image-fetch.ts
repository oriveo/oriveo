/**
 * Hardening for image URL fetches: an allowlist plus size and timeout limits, to prevent SSRF.
 *
 * In BYOK mode the server-side route can be talked into fetching an arbitrary URL, for
 * example when an upstream provider returns image_url=http://internal-host/admin, so a
 * bare fetch would be an SSRF.
 *
 * - https:// only; http://, data:, file://, ftp:// and the rest are rejected
 * - size <= 10MB (a legitimately generated image is almost always under 5MB, so a much
 *   larger one is most likely a malicious payload)
 * - timeout <= 10s
 * - fails safe by returning null, leaving the caller to degrade
 */

const ALLOWED_PROTOCOL = 'https:';
const MAX_BYTES = 10 * 1024 * 1024; // 10MB
const FETCH_TIMEOUT_MS = 10_000;

export interface SafeImageFetchResult {
  buffer: ArrayBuffer;
  contentType: string;
}

export function isAllowedImageUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === ALLOWED_PROTOCOL;
  } catch {
    return false;
  }
}

export async function safeFetchImage(url: string): Promise<SafeImageFetchResult | null> {
  if (!isAllowedImageUrl(url)) return null;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) return null;

    // Reject on the declared size first, so an oversized image costs nothing to refuse.
    const contentLength = response.headers.get('Content-Length');
    if (contentLength) {
      const declared = Number.parseInt(contentLength, 10);
      if (Number.isFinite(declared) && declared > MAX_BYTES) return null;
    }

    // No Content-Length, or a lying one: count the bytes and abort as soon as the cap is passed.
    const reader = response.body?.getReader();
    if (!reader) return null;
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        total += value.byteLength;
        if (total > MAX_BYTES) {
          controller.abort();
          return null;
        }
        chunks.push(value);
      }
    }

    const buffer = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      buffer.set(chunk, offset);
      offset += chunk.byteLength;
    }

    return {
      buffer: buffer.buffer,
      contentType: response.headers.get('Content-Type') || 'image/png',
    };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function safeImageToDataURL(url: string): Promise<string | null> {
  const result = await safeFetchImage(url);
  if (!result) return null;
  const base64 = Buffer.from(result.buffer).toString('base64');
  return `data:${result.contentType};base64,${base64}`;
}

export const IMAGE_FETCH_LIMITS = {
  ALLOWED_PROTOCOL,
  MAX_BYTES,
  FETCH_TIMEOUT_MS,
} as const;

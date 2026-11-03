/**
 * Studio URL image fetcher: downloads a URL image right away with a byte limit
 * and one timeout covering the whole read (headers and body), then decodes the
 * pixel size from the bytes. Content-Type is not trusted or checked.
 * Runs in both Node and the browser (no Buffer).
 * Private-address blocking is out of scope here.
 * Fixture: image_response_samples.v1 fetchPolicy / fetchCases.
 */
import { decodeImageInfo, type ImageMaterializeOutcome } from './image-response';

export const STUDIO_IMAGE_FETCH_POLICY = {
  maxBytes: 30 * 1024 * 1024,
  timeoutSeconds: 60,
  schemes: ['http', 'https'] as readonly string[],
  checkContentType: false,
  redirects: 'platform default',
} as const;

export interface StudioImageFetchOptions {
  /** Injected transport; defaults to the global fetch. */
  fetch?: typeof fetch;
  maxBytes?: number;
  timeoutMs?: number;
}

class TimedOut extends Error {}

/** Rejects as soon as the signal aborts, even when the transport ignores the signal. */
function untilAborted<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(new TimedOut());
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(new TimedOut());
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener('abort', onAbort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener('abort', onAbort);
        reject(error);
      },
    );
  });
}

function allowedScheme(url: string): boolean {
  try {
    const protocol = new URL(url).protocol.replace(/:$/, '');
    return STUDIO_IMAGE_FETCH_POLICY.schemes.includes(protocol);
  } catch {
    return false;
  }
}

const DECODE_FAILED: ImageMaterializeOutcome = { ok: false, failure: 'decode_failed' };

export async function fetchStudioImage(
  url: string,
  options: StudioImageFetchOptions = {},
): Promise<ImageMaterializeOutcome> {
  if (!allowedScheme(url)) return DECODE_FAILED;
  const fetchImpl = options.fetch ?? globalThis.fetch;
  const maxBytes = options.maxBytes ?? STUDIO_IMAGE_FETCH_POLICY.maxBytes;
  const signal = AbortSignal.timeout(options.timeoutMs ?? STUDIO_IMAGE_FETCH_POLICY.timeoutSeconds * 1000);

  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  try {
    const response = await untilAborted(fetchImpl(url, { signal }), signal);
    if (!response.ok) {
      void response.body?.cancel().catch(() => undefined);
      return { ok: false, failure: 'network' };
    }

    const contentLength = response.headers.get('Content-Length');
    if (contentLength) {
      const declared = Number.parseInt(contentLength, 10);
      if (Number.isFinite(declared) && declared > maxBytes) {
        void response.body?.cancel().catch(() => undefined);
        return DECODE_FAILED;
      }
    }

    reader = response.body?.getReader();
    if (!reader) return DECODE_FAILED;
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await untilAborted(reader.read(), signal);
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) return DECODE_FAILED;
      chunks.push(value);
    }
    reader = undefined;

    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const info = decodeImageInfo(bytes);
    return info ? { ok: true, bytes, ...info } : DECODE_FAILED;
  } catch (error) {
    return error instanceof TimedOut || signal.aborted
      ? { ok: false, failure: 'timeout' }
      : { ok: false, failure: 'network' };
  } finally {
    void reader?.cancel().catch(() => undefined);
  }
}

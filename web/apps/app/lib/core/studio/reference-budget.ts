/**
 * BYOK reference image budget: per-route request / per-image limits, encoded
 * byte accounting and the backwards shrink walk that fits references under
 * the provider limits before sending. Mirrors the shared fixture
 * byok_reference_budget.v1.json.
 */

export type ReferenceRoute =
  | 'openai_images'
  | 'xai_images'
  | 'openrouter_images'
  | 'chat_modalities'
  | 'gemini_generate_content'
  | 'dashscope_multimodal'
  | 'minimax_image_generation';

export interface ReferenceRouteLimits {
  maxRequestBytes: number | null;
  maxImageBytes: number | null;
}

export type ReferenceBudgetStatus = 'fits' | 'too_large';

export interface ReferenceBudgetSpec {
  overheadBytes: number;
  routes: Record<ReferenceRoute, ReferenceRouteLimits | null>;
  shrink: { maxLongEdge: number; jpegQuality: number; mime: 'image/jpeg' };
  tooLargeErrorKind: 'invalid_param';
  statuses: readonly ReferenceBudgetStatus[];
}

export const REFERENCE_BUDGET_SPEC: ReferenceBudgetSpec = {
  overheadBytes: 65536,
  routes: {
    openai_images: { maxRequestBytes: 50000000, maxImageBytes: 20971520 },
    xai_images: { maxRequestBytes: 50000000, maxImageBytes: 20971520 },
    openrouter_images: { maxRequestBytes: 50000000, maxImageBytes: null },
    chat_modalities: { maxRequestBytes: 50000000, maxImageBytes: null },
    gemini_generate_content: { maxRequestBytes: 20000000, maxImageBytes: null },
    dashscope_multimodal: { maxRequestBytes: 16777216, maxImageBytes: 10000000 },
    minimax_image_generation: null,
  },
  shrink: { maxLongEdge: 2048, jpegQuality: 0.9, mime: 'image/jpeg' },
  tooLargeErrorKind: 'invalid_param',
  statuses: ['fits', 'too_large'],
};

/** Description of one reference image as the budget sees it. */
export interface ReferenceImageInfo {
  slot: number;
  role: string;
  mime: string;
  byteCount: number;
}

export interface ReferenceBudgetInput<T> {
  route: ReferenceRoute;
  editTransport: string | null;
  prompt: string;
  images: readonly T[];
  describe: (image: T) => ReferenceImageInfo;
  /** Returns the shrunk image, or null when it cannot be decoded. */
  shrink: (image: T) => Promise<T | null>;
}

export interface ReferenceBudgetResult<T> {
  status: ReferenceBudgetStatus;
  errorKind: 'invalid_param' | null;
  requestBytes: number;
  /** Final images in send order. */
  images: T[];
}

/** Limits for a route, or null when the route has no table entry. */
export function referenceRouteLimits(route: ReferenceRoute): ReferenceRouteLimits | null {
  return REFERENCE_BUDGET_SPEC.routes[route] ?? null;
}

/**
 * Bytes one image contributes to the encoded request body: multipart sends
 * raw bytes, Gemini inline data is bare base64, every other route embeds a
 * `data:<mime>;base64,` URI.
 */
export function referenceEncodedBytes(
  route: ReferenceRoute,
  editTransport: string | null,
  mime: string,
  byteCount: number,
): number {
  if (editTransport === 'multipart') return byteCount;
  const base64 = 4 * Math.ceil(byteCount / 3);
  if (route === 'gemini_generate_content') return base64;
  return `data:${mime};base64,`.length + base64;
}

/**
 * Fits references under the route limits. Send order is the base image
 * first, then the rest by ascending slot; the walk goes backwards from the
 * last image, shrinking only when the request or that image is over its
 * limit, and keeps a shrunk image only when it encodes strictly smaller.
 */
export async function fitReferenceBudget<T>(
  input: ReferenceBudgetInput<T>,
): Promise<ReferenceBudgetResult<T>> {
  const { route, editTransport, prompt, describe, shrink } = input;
  const limits = referenceRouteLimits(route);
  const fixedBytes = REFERENCE_BUDGET_SPEC.overheadBytes + new TextEncoder().encode(prompt).length;

  const isBase = (image: T) => (describe(image).role === 'base' ? 1 : 0);
  const images = [...input.images].sort(
    (a, b) => isBase(b) - isBase(a) || describe(a).slot - describe(b).slot,
  );
  const encoded = (image: T) => {
    const info = describe(image);
    return referenceEncodedBytes(route, editTransport, info.mime, info.byteCount);
  };
  const requestBytes = () => images.reduce((sum, image) => sum + encoded(image), fixedBytes);

  if (limits === null) {
    return { status: 'fits', errorKind: null, requestBytes: requestBytes(), images };
  }

  const requestOk = (bytes: number) =>
    limits.maxRequestBytes === null || bytes <= limits.maxRequestBytes;
  const imageOk = (bytes: number) => limits.maxImageBytes === null || bytes <= limits.maxImageBytes;
  const allOk = () => requestOk(requestBytes()) && images.every((image) => imageOk(encoded(image)));

  for (let index = images.length - 1; index >= 0; index -= 1) {
    if (allOk()) break;
    const current = images[index]!;
    const currentBytes = encoded(current);
    if (requestOk(requestBytes()) && imageOk(currentBytes)) continue;
    const shrunk = await shrink(current);
    if (shrunk !== null && encoded(shrunk) < currentBytes) images[index] = shrunk;
  }

  const fits = allOk();
  return {
    status: fits ? 'fits' : 'too_large',
    errorKind: fits ? null : REFERENCE_BUDGET_SPEC.tooLargeErrorKind,
    requestBytes: requestBytes(),
    images,
  };
}

/**
 * Browser BYOK round executor: fits references under the route budget,
 * uploads one multipart request to /api/studio/generate, reads the SSE
 * `result` frame and returns the decoded image bytes. Saving the images is
 * the caller's job.
 */
import { SSEFrameDecoder, type SSEFrame } from '@oriveo/core/providers/sse-parser';
import { IMAGE_ERROR_POLICIES, type ImageErrorKind } from './image-error';
import type { ImageParamAdjustment } from './image-param-normalization';
import type { ImageProfile } from './image-profile';
import type { ImageRequestAdvanced } from './image-request-builder';
import {
  STUDIO_PROMPT_COMPOSE_SPEC,
  composeStudioPrompt,
  type StudioPromptAdjustment,
  type StudioPromptComposeInput,
} from './prompt-compose';
import { fitReferenceBudget } from './reference-budget';
import { shrinkReferenceImage } from './reference-shrink';

export interface StudioByokImage {
  slot: number;
  role: string;
  mime: string;
  data: Uint8Array;
}

export interface StudioByokRoundInput {
  providerKind: string;
  apiKey: string;
  baseURL: string;
  modelId: string;
  profile: ImageProfile;
  operation: 'generate' | 'edit';
  prompt: Omit<StudioPromptComposeInput, 'maxPromptChars'>;
  params: { aspect?: string | null; resolution?: string | null; quality?: string | null; n?: number | null };
  advanced?: ImageRequestAdvanced | null;
  images: StudioByokImage[];
}

export type StudioReferenceShrinkFn = (
  bytes: Uint8Array,
  mime: string,
) => Promise<{ data: Uint8Array; mime: string } | null>;

export interface StudioByokRoundDeps {
  fetch?: typeof fetch;
  signal: AbortSignal;
  /** Defaults to shrinkReferenceImage. */
  shrink?: StudioReferenceShrinkFn;
}

export type StudioGenerateStatus = 'completed' | 'partial' | 'failed' | 'cancelled';

export interface StudioGenerateImage<D> {
  data: D;
  mime: string;
  width: number;
  height: number;
  revisedPrompt: string | null;
}

export interface StudioGenerateResultOf<D> {
  status: StudioGenerateStatus;
  errorKind: ImageErrorKind | null;
  message: string | null;
  mayBeBilled: boolean;
  retried: boolean;
  nRequested: number;
  delivered: number;
  composedPrompt: string | null;
  adjustments: { prompt: StudioPromptAdjustment[]; params: ImageParamAdjustment[] };
  usage: { inputTokens: number; outputTokens: number; totalTokens: number } | null;
  images: StudioGenerateImage<D>[];
}

/** Round result with decoded image bytes. */
export type StudioGenerateResult = StudioGenerateResultOf<Uint8Array>;

/** Wire shape of the `result` frame: image data is base64. */
export type StudioGenerateWireResult = StudioGenerateResultOf<string>;

export const STUDIO_GENERATE_PATH = '/api/studio/generate';

function isErrorKind(value: unknown): value is ImageErrorKind {
  return typeof value === 'string' && Object.hasOwn(IMAGE_ERROR_POLICIES, value);
}

function localResult(
  input: StudioByokRoundInput,
  status: 'failed' | 'cancelled',
  errorKind: ImageErrorKind | null,
  message: string | null,
  mayBeBilled: boolean,
): StudioGenerateResult {
  return {
    status,
    errorKind,
    message,
    mayBeBilled,
    retried: false,
    nRequested: input.params.n ?? 1,
    delivered: 0,
    composedPrompt: null,
    adjustments: { prompt: [], params: [] },
    usage: null,
    images: [],
  };
}

/** Compose limit when the profile declares no maxPromptChars; matches the server executor. */
export const STUDIO_DEFAULT_MAX_PROMPT_CHARS = 32000;

/** Prompt used only for budget byte accounting; falls back to the user text. */
function budgetPrompt(input: StudioByokRoundInput): string {
  const composed = composeStudioPrompt(STUDIO_PROMPT_COMPOSE_SPEC, {
    ...input.prompt,
    maxPromptChars: input.profile.maxPromptChars ?? STUDIO_DEFAULT_MAX_PROMPT_CHARS,
  });
  return composed.composed ?? input.prompt.userPrompt;
}

function statusErrorKind(status: number): ImageErrorKind {
  if (status === 429) return 'rate_limited';
  if (status === 400 || status === 413) return 'invalid_param';
  return 'upstream_error';
}

async function failedResponse(input: StudioByokRoundInput, response: Response): Promise<StudioGenerateResult> {
  let errorKind = statusErrorKind(response.status);
  let message: string | null = null;
  try {
    const body: unknown = JSON.parse(await response.text());
    if (body !== null && typeof body === 'object') {
      const record = body as Record<string, unknown>;
      if (isErrorKind(record.errorKind)) {
        errorKind = record.errorKind;
        message = typeof record.message === 'string' ? record.message : null;
      }
    }
  } catch {
    // Unparsable body: keep the status mapping.
  }
  return localResult(input, 'failed', errorKind, message, false);
}

function decodeBase64(data: string): Uint8Array {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function isAbort(error: unknown, signal: AbortSignal): boolean {
  // DOMException is not an Error subclass in every runtime, so match by name.
  const name = error !== null && typeof error === 'object' ? (error as { name?: unknown }).name : undefined;
  return signal.aborted || name === 'AbortError';
}

/** Reads the SSE body until the `result` frame; null when the stream ends without one. */
async function readResultFrame(body: ReadableStream<Uint8Array>): Promise<string | null> {
  const reader = body.getReader();
  const decoder = new SSEFrameDecoder();
  const pick = (frames: SSEFrame[]) => frames.find((frame) => frame.event === 'result')?.data ?? null;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      const data = done ? pick(decoder.finish()) : pick(decoder.push(value));
      if (data !== null || done) return data;
    }
  } finally {
    reader.cancel().catch(() => {});
  }
}

export async function runStudioByokRound(
  input: StudioByokRoundInput,
  deps: StudioByokRoundDeps,
): Promise<StudioGenerateResult> {
  const { signal } = deps;
  const fetchFn = deps.fetch ?? fetch;
  const shrink = deps.shrink ?? shrinkReferenceImage;

  const fit = await fitReferenceBudget<StudioByokImage>({
    route: input.profile.route,
    editTransport: input.operation === 'edit' ? (input.profile.editTransport ?? null) : null,
    prompt: budgetPrompt(input),
    images: input.images,
    describe: (image) => ({ slot: image.slot, role: image.role, mime: image.mime, byteCount: image.data.length }),
    shrink: async (image) => {
      const shrunk = await shrink(image.data, image.mime);
      return shrunk === null ? null : { ...image, data: shrunk.data, mime: shrunk.mime };
    },
  });
  if (fit.status === 'too_large') {
    return localResult(input, 'failed', 'invalid_param', 'references_too_large', false);
  }
  // Cancelled before the upload: nothing reached the provider, so it cannot be billed.
  if (signal.aborted) return localResult(input, 'cancelled', null, null, false);

  const form = new FormData();
  form.append(
    'request',
    JSON.stringify({
      providerKind: input.providerKind,
      apiKey: input.apiKey,
      baseURL: input.baseURL,
      modelId: input.modelId,
      profile: input.profile,
      operation: input.operation,
      prompt: input.prompt,
      params: input.params,
      advanced: input.advanced ?? null,
      images: fit.images.map(({ slot, role, mime }) => ({ slot, role, mime })),
    }),
  );
  for (const image of fit.images) {
    form.append(`image_${image.slot}`, new Blob([image.data as BlobPart], { type: image.mime }));
  }

  let wire: StudioGenerateWireResult;
  try {
    const response = await fetchFn(STUDIO_GENERATE_PATH, { method: 'POST', body: form, signal });
    if (!response.ok) return await failedResponse(input, response);
    const data = response.body === null ? null : await readResultFrame(response.body);
    if (signal.aborted) return localResult(input, 'cancelled', null, null, true);
    if (data === null) return localResult(input, 'failed', 'network', null, true);
    wire = JSON.parse(data) as StudioGenerateWireResult;
  } catch (error) {
    if (isAbort(error, signal)) return localResult(input, 'cancelled', null, null, true);
    return localResult(input, 'failed', 'network', null, true);
  }

  try {
    return { ...wire, images: wire.images.map((image) => ({ ...image, data: decodeBase64(image.data) })) };
  } catch {
    return localResult(input, 'failed', 'network', null, true);
  }
}

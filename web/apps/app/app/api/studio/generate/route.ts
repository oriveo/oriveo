/**
 * POST /api/studio/generate: server-side BYOK image generation.
 * Pre-stream errors (rate limit, multipart, request JSON, missing reference files)
 * answer JSON { errorKind, message }; otherwise a text/event-stream carries a
 * `: ping` comment every 15 seconds and one final `event: result` frame with the
 * StudioGenerateResult. A browser disconnect or a stream cancel aborts the run and no result is sent;
 * an unexpected executor failure still sends a failed result.
 */
import { assertUrlNotSsrf } from '../../_shared/ssrf-guard';
import { buildRateLimitHeaders, checkRateLimit, getClientIp } from '../../chat/stream/rate-limit';
import type { ImageParamRequest } from '../../../../lib/core/studio/image-param-normalization';
import type { ImageRequestAdvanced } from '../../../../lib/core/studio/image-request-builder';
import type { StudioPromptReference, StudioReferenceRole } from '../../../../lib/core/studio/prompt-compose';
import {
  runStudioGenerate,
  type StudioGenerateDeps,
  type StudioGenerateImageInput,
  type StudioGenerateInput,
  type StudioGenerateResult,
} from './executor';
import { createStudioImageFetcher } from './image-fetcher';

export const runtime = 'nodejs';

const PING_INTERVAL_MS = 15000;
const REFERENCE_ROLES: readonly StudioReferenceRole[] = ['base', 'subject', 'style', 'composition', 'person', 'element'];

type PreStreamErrorKind = 'rate_limited' | 'invalid_param';

function errorResponse(
  status: number,
  errorKind: PreStreamErrorKind,
  message: string,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify({ errorKind, message }), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

type JsonObject = Record<string, unknown>;

const isObject = (value: unknown): value is JsonObject =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const isString = (value: unknown): value is string => typeof value === 'string';
const isNumber = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);
const isBoolean = (value: unknown): value is boolean => typeof value === 'boolean';
const optional = <T>(value: unknown, check: (v: unknown) => v is T): boolean =>
  value === undefined || value === null || check(value);

interface DeclaredImage {
  readonly slot: number;
  readonly role: string;
  readonly mime: string;
}

type ParsedRequest = { input: Omit<StudioGenerateInput, 'images'>; images: DeclaredImage[] } | { error: string };

function parsePrompt(raw: unknown): StudioGenerateInput['prompt'] | null {
  if (!isObject(raw) || !isString(raw.userPrompt) || !Array.isArray(raw.references)) return null;
  const references: StudioPromptReference[] = [];
  for (const ref of raw.references) {
    if (!isObject(ref) || !isNumber(ref.n) || !REFERENCE_ROLES.includes(ref.role as StudioReferenceRole)) return null;
    references.push({ n: ref.n, role: ref.role as StudioReferenceRole });
  }
  if (!optional(raw.styleFragment, isString)) return null;
  const effects = raw.effectFragments;
  if (effects !== undefined && !(Array.isArray(effects) && effects.every(isString))) return null;
  return {
    userPrompt: raw.userPrompt,
    references,
    styleFragment: (raw.styleFragment as string | null | undefined) ?? null,
    ...(effects !== undefined ? { effectFragments: effects as string[] } : {}),
  };
}

function parseParams(raw: unknown): ImageParamRequest | null {
  if (!isObject(raw)) return null;
  const { aspect, resolution, quality, n } = raw;
  if (!optional(aspect, isString) || !optional(resolution, isString) || !optional(quality, isString)) return null;
  if (!optional(n, isNumber)) return null;
  return raw as ImageParamRequest;
}

function parseAdvanced(raw: unknown): ImageRequestAdvanced | null | undefined {
  if (raw === undefined || raw === null) return null;
  if (!isObject(raw)) return undefined;
  const { negativePrompt, seed, transparentBackground, outputFormat } = raw;
  if (!optional(negativePrompt, isString) || !optional(seed, isNumber)) return undefined;
  if (!optional(transparentBackground, isBoolean) || !optional(outputFormat, isString)) return undefined;
  return raw as ImageRequestAdvanced;
}

function parseImages(raw: unknown): DeclaredImage[] | null {
  if (!Array.isArray(raw)) return null;
  const images: DeclaredImage[] = [];
  for (const image of raw) {
    if (!isObject(image) || !Number.isInteger(image.slot) || !isString(image.role) || !isString(image.mime)) return null;
    images.push({ slot: image.slot as number, role: image.role, mime: image.mime });
  }
  return images;
}

function parseRequest(raw: unknown): ParsedRequest {
  if (!isObject(raw)) return { error: 'invalid_field:request' };
  for (const name of ['providerKind', 'apiKey', 'baseURL', 'modelId', 'operation'] as const) {
    if (!isString(raw[name])) return { error: `invalid_field:${name}` };
  }
  if (!isObject(raw.profile)) return { error: 'invalid_field:profile' };
  const prompt = parsePrompt(raw.prompt);
  if (!prompt) return { error: 'invalid_field:prompt' };
  const params = parseParams(raw.params);
  if (!params) return { error: 'invalid_field:params' };
  const advanced = parseAdvanced(raw.advanced);
  if (advanced === undefined) return { error: 'invalid_field:advanced' };
  const images = parseImages(raw.images);
  if (!images) return { error: 'invalid_field:images' };
  return {
    input: {
      providerKind: raw.providerKind as string,
      apiKey: raw.apiKey as string,
      baseURL: raw.baseURL as string,
      modelId: raw.modelId as string,
      profile: raw.profile,
      operation: raw.operation as string,
      prompt,
      params,
      advanced,
    },
    images,
  };
}

/**
 * Result for an unexpected executor failure: whether a request already went out
 * is unknown, so it is reported as possibly billed.
 */
function internalErrorResult(input: StudioGenerateInput): StudioGenerateResult {
  return {
    status: 'failed',
    errorKind: 'upstream_error',
    message: 'internal_error',
    mayBeBilled: true,
    retried: false,
    nRequested: input.params.n ?? 1,
    delivered: 0,
    composedPrompt: null,
    adjustments: { prompt: [], params: [] },
    usage: null,
    images: [],
  };
}

function realDeps(signal: AbortSignal): StudioGenerateDeps {
  return {
    fetch: ((input: RequestInfo | URL, init?: RequestInit) =>
      fetch(input, { ...init, redirect: 'manual' })) as typeof fetch,
    assertUrl: async (url) => {
      await assertUrlNotSsrf(url);
    },
    fetchImage: createStudioImageFetcher(),
    signal,
  };
}

export async function POST(request: Request): Promise<Response> {
  const outcome = checkRateLimit(getClientIp(request.headers));
  const rateLimitHeaders = buildRateLimitHeaders(outcome);
  if (!outcome.allowed) {
    return errorResponse(429, 'rate_limited', 'Rate limit exceeded', {
      ...rateLimitHeaders,
      'Retry-After': String(Math.max(1, Math.ceil((outcome.resetAt - Date.now()) / 1000))),
    });
  }
  const invalid = (message: string) => errorResponse(400, 'invalid_param', message, rateLimitHeaders);

  let formData: FormData;
  try {
    formData = await request.formData();
  } catch {
    return invalid('invalid_form_data');
  }
  const rawRequest = formData.get('request');
  if (!isString(rawRequest)) return invalid('missing_request');
  let json: unknown;
  try {
    json = JSON.parse(rawRequest);
  } catch {
    return invalid('invalid_request_json');
  }
  const parsed = parseRequest(json);
  if ('error' in parsed) return invalid(parsed.error);

  const images: StudioGenerateImageInput[] = [];
  for (const image of parsed.images) {
    const file = formData.get(`image_${image.slot}`);
    if (!(file instanceof File)) return invalid(`missing_image:${image.slot}`);
    images.push({ ...image, data: new Uint8Array(await file.arrayBuffer()) });
  }
  const input: StudioGenerateInput = { ...parsed.input, images };

  // The run stops on a browser disconnect or a stream cancel, whichever comes first.
  const client = request.signal;
  const run = new AbortController();
  const signal = run.signal;
  const abortRun = () => run.abort();
  const encoder = new TextEncoder();
  let finish = () => {};
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let closed = false;
      let timer: ReturnType<typeof setInterval> | undefined;
      finish = () => {
        if (closed) return;
        closed = true;
        clearInterval(timer);
        client.removeEventListener('abort', abortRun);
        signal.removeEventListener('abort', finish);
        try {
          controller.close();
        } catch {
          // Already closed or cancelled by the consumer.
        }
      };
      if (client.aborted) {
        run.abort();
        finish();
        return;
      }
      client.addEventListener('abort', abortRun, { once: true });
      signal.addEventListener('abort', finish, { once: true });
      timer = setInterval(() => {
        if (!closed) controller.enqueue(encoder.encode(': ping\n\n'));
      }, PING_INTERVAL_MS);
      const writeResult = (result: StudioGenerateResult) => {
        if (!closed && !signal.aborted) {
          controller.enqueue(encoder.encode(`event: result\ndata: ${JSON.stringify(result)}\n\n`));
        }
        finish();
      };
      runStudioGenerate(input, realDeps(signal)).then(writeResult, () => writeResult(internalErrorResult(input)));
    },
    cancel() {
      run.abort();
      finish();
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'X-Accel-Buffering': 'no',
      ...rateLimitHeaders,
    },
  });
}

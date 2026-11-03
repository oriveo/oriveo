/**
 * Server-side BYOK image generation executor behind POST /api/studio/generate:
 * compose -> normalize -> reference budget -> build -> SSRF ->
 * concurrent batch sends (per-attempt timeout, one pre-connect retry) ->
 * classify / materialize -> aggregate. Every side effect is
 * injected through deps so the route stays a thin stream wrapper.
 */
import {
  byokAggregate,
  byokEffectiveTimeoutSeconds,
  byokRetryDecision,
  byokTransportPhase,
  type ByokBatchResult,
} from '../../../../lib/core/studio/byok-tasks';
import { classifyImageResult, type ImageErrorKind } from '../../../../lib/core/studio/image-error';
import {
  normalizeImageParams,
  type ImageParamAdjustment,
  type ImageParamRequest,
} from '../../../../lib/core/studio/image-param-normalization';
import { checkImageProfile } from '../../../../lib/core/studio/image-profile';
import {
  buildImageRequest,
  encodeBase64,
  type ImageRequest,
  type ImageRequestAdvanced,
} from '../../../../lib/core/studio/image-request-builder';
import {
  assembleImageOutcomes,
  materializeImage,
  parseImageResponse,
  type ImageMaterializeOutcome,
  type ImageUsage,
} from '../../../../lib/core/studio/image-response';
import {
  composeStudioPrompt,
  STUDIO_PROMPT_COMPOSE_SPEC,
  type StudioPromptAdjustment,
  type StudioPromptComposeInput,
} from '../../../../lib/core/studio/prompt-compose';
import { fitReferenceBudget, type ReferenceRoute } from '../../../../lib/core/studio/reference-budget';

/** Prompt cap when the profile declares no maxPromptChars. */
export const STUDIO_DEFAULT_MAX_PROMPT_CHARS = 32000;
/** Upstream error messages keep this many leading characters of the reply text. */
const MESSAGE_LIMIT = 1000;
/** Wire keys that carry the per-call image count; rewritten to each batch's size. */
const N_WIRE_KEYS = ['n', 'parameters.n'] as const;
/** Upstream reply cap per requested image, plus a fixed allowance for the envelope. */
const RESPONSE_BYTES_PER_IMAGE = 41943040;
const RESPONSE_BYTES_OVERHEAD = 1048576;

export interface StudioGenerateImageInput {
  readonly slot: number;
  readonly role: string;
  readonly mime: string;
  readonly data: Uint8Array;
}

export interface StudioGenerateInput {
  readonly providerKind: string;
  readonly apiKey: string;
  readonly baseURL: string;
  readonly modelId: string;
  /** Unvalidated profile JSON; checked with checkImageProfile before use. */
  readonly profile: unknown;
  readonly operation: string;
  readonly prompt: Omit<StudioPromptComposeInput, 'maxPromptChars'>;
  readonly params: ImageParamRequest;
  readonly advanced?: ImageRequestAdvanced | null;
  readonly images: readonly StudioGenerateImageInput[];
}

export type StudioGenerateStatus = 'completed' | 'partial' | 'failed' | 'cancelled';

export interface StudioGenerateImage {
  /** Base64 of the image bytes. */
  readonly data: string;
  readonly mime: string;
  readonly width: number;
  readonly height: number;
  readonly revisedPrompt: string | null;
}

export interface StudioGenerateResult {
  status: StudioGenerateStatus;
  errorKind: ImageErrorKind | null;
  message: string | null;
  mayBeBilled: boolean;
  retried: boolean;
  nRequested: number;
  delivered: number;
  composedPrompt: string | null;
  adjustments: { prompt: StudioPromptAdjustment[]; params: ImageParamAdjustment[] };
  usage: ImageUsage | null;
  images: StudioGenerateImage[];
}

export interface StudioGenerateDeps {
  readonly fetch: typeof fetch;
  /** Rejects when the URL is blocked by the SSRF guard. */
  readonly assertUrl: (url: string) => Promise<void>;
  readonly fetchImage: (url: string, signal: AbortSignal) => Promise<ImageMaterializeOutcome>;
  readonly signal: AbortSignal;
}

/** Request body for the platform fetch: multipart becomes FormData (the platform sets the boundary). */
function toFetchInit(request: ImageRequest, signal: AbortSignal): RequestInit {
  const headers: Record<string, string> = { ...request.headers };
  if (request.body.kind === 'json') {
    return { method: request.method, headers, body: JSON.stringify(request.body.json), signal };
  }
  for (const name of Object.keys(headers)) {
    if (name.toLowerCase() === 'content-type') delete headers[name];
  }
  const form = new FormData();
  for (const [name, value] of request.body.fields) form.append(name, value);
  for (const file of request.body.files) {
    form.append(file.name, new Blob([file.data as BlobPart], { type: file.mime }), file.filename);
  }
  return { method: request.method, headers, body: form, signal };
}

/**
 * Reads the reply body as UTF-8 text, cancelling the reader as soon as it passes
 * `limit` bytes; null means the reply was too large.
 */
async function readBodyLimited(response: Response, limit: number): Promise<string | null> {
  if (response.body === null) return '';
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let total = 0;
  let text = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return text + decoder.decode();
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    text += decoder.decode(value, { stream: true });
  }
}

function parseBody(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export async function runStudioGenerate(
  input: StudioGenerateInput,
  deps: StudioGenerateDeps,
): Promise<StudioGenerateResult> {
  const result: StudioGenerateResult = {
    status: 'failed',
    errorKind: null,
    message: null,
    mayBeBilled: false,
    retried: false,
    nRequested: 0,
    delivered: 0,
    composedPrompt: null,
    adjustments: { prompt: [], params: [] },
    usage: null,
    images: [],
  };
  const reject = (errorKind: ImageErrorKind, message: string): StudioGenerateResult => ({
    ...result,
    status: 'failed',
    errorKind,
    message,
  });

  // Validation: profile, operation, prompt, params.
  const { profile } = checkImageProfile(input.profile);
  if (!profile || !(profile.operations as readonly string[]).includes(input.operation)) {
    return reject('invalid_param', 'invalid_profile');
  }
  const composed = composeStudioPrompt(STUDIO_PROMPT_COMPOSE_SPEC, {
    ...input.prompt,
    maxPromptChars: profile.maxPromptChars ?? STUDIO_DEFAULT_MAX_PROMPT_CHARS,
  });
  result.adjustments.prompt = composed.adjustments;
  if (composed.composed === null) return reject('invalid_param', composed.error ?? 'prompt_too_long');
  const prompt = composed.composed;
  result.composedPrompt = prompt;

  const normalized = normalizeImageParams(profile, input.params);
  if ('error' in normalized) return reject('invalid_param', normalized.error);
  result.adjustments.params = [...normalized.adjustments];
  const batches = normalized.batches;
  const nRequested = batches.reduce((sum, size) => sum + size, 0);
  result.nRequested = nRequested;

  // Budget: shrinking is not available server-side, so an oversized reference is final.
  const budget = await fitReferenceBudget({
    route: profile.route as ReferenceRoute,
    editTransport: profile.editTransport ?? null,
    prompt,
    images: input.images,
    describe: (image) => ({ slot: image.slot, role: image.role, mime: image.mime, byteCount: image.data.length }),
    shrink: async () => null,
  });
  if (budget.status === 'too_large') return reject('invalid_param', 'references_too_large');

  // One request per batch: the wire n key (if any) carries that batch's size.
  const requests: ImageRequest[] = [];
  for (const size of batches) {
    const wire: Record<string, string | number> = { ...normalized.wire };
    for (const key of N_WIRE_KEYS) if (key in wire) wire[key] = size;
    const request = buildImageRequest(profile, {
      operation: input.operation,
      modelId: input.modelId,
      prompt,
      wire,
      images: budget.images,
      advanced: input.advanced ?? null,
      baseUrl: input.baseURL,
      apiKey: input.apiKey,
    });
    if ('error' in request) return reject('invalid_param', request.error);
    requests.push(request);
  }

  // SSRF. Every batch targets the same URL.
  try {
    await deps.assertUrl(requests[0]!.url);
  } catch {
    return reject('invalid_param', 'base_url_blocked');
  }

  if (deps.signal.aborted) return { ...result, status: 'cancelled' };

  // Send every batch concurrently; each attempt has its own timeout on top of the client signal.
  const timeoutMs = byokEffectiveTimeoutSeconds(profile.timeoutSeconds) * 1000;
  const round = { sent: false, billed: false, retried: false, cancelled: false };
  const outcomes = await Promise.all(
    requests.map((request, index) => sendBatch(request, batches[index]!, timeoutMs, round, deps)),
  );

  result.retried = round.retried;
  result.usage = sumUsage(outcomes.map((outcome) => outcome.usage));
  const cancelled = deps.signal.aborted || round.cancelled;
  const aggregate = byokAggregate(
    nRequested,
    batches,
    outcomes.map((outcome) => outcome.result),
    cancelled,
  );
  if (aggregate.status === 'cancelled') {
    // A request that may have reached the upstream can still be billed after the client left.
    return {
      ...result,
      status: 'cancelled',
      errorKind: null,
      mayBeBilled: round.billed || round.sent,
      images: [],
      delivered: 0,
    };
  }
  return {
    ...result,
    status: aggregate.status,
    errorKind: aggregate.errorKind,
    // The message belongs to the batch byokAggregate took errorKind from (lowest index with one).
    message:
      aggregate.status === 'completed'
        ? null
        : (outcomes.find((outcome) => outcome.result.errorKind != null)?.message ?? null),
    mayBeBilled: round.billed,
    delivered: aggregate.delivered,
    images: outcomes.flatMap((outcome) => outcome.images),
  };
}

interface RoundState {
  /** A request may have reached the upstream (anything but a pre-connect failure). */
  sent: boolean;
  billed: boolean;
  retried: boolean;
  cancelled: boolean;
}

interface BatchOutcome {
  result: ByokBatchResult;
  images: StudioGenerateImage[];
  usage: ImageUsage | null;
  message: string | null;
}

async function sendBatch(
  request: ImageRequest,
  batchSize: number,
  timeoutMs: number,
  round: RoundState,
  deps: StudioGenerateDeps,
): Promise<BatchOutcome> {
  const empty = (errorKind: ImageErrorKind | null, message: string | null = null): BatchOutcome => ({
    result: { images: 0, errorKind },
    images: [],
    usage: null,
    message,
  });
  for (let attempt = 0; ; attempt += 1) {
    if (deps.signal.aborted) return empty(null);
    const signal = AbortSignal.any([deps.signal, AbortSignal.timeout(timeoutMs)]);
    let response: Response;
    try {
      response = await deps.fetch(request.url, toFetchInit(request, signal));
    } catch (error) {
      const phase = byokTransportPhase(error);
      const decision = byokRetryDecision(phase, attempt);
      if (phase !== 'pre_connect') round.sent = true;
      if (decision.retried) round.retried = true;
      if (decision.mayBeBilled) round.billed = true;
      if (phase === 'cancelled') round.cancelled = true;
      if (decision.retry && !deps.signal.aborted) continue;
      return empty(decision.errorKind);
    }
    round.sent = true;
    if (attempt > 0) round.retried = true;
    if (response.status >= 200 && response.status < 300) round.billed = true;

    let text: string | null;
    try {
      text = await readBodyLimited(response, batchSize * RESPONSE_BYTES_PER_IMAGE + RESPONSE_BYTES_OVERHEAD);
    } catch (error) {
      // The reply already started, so a body failure is never retried.
      const phase = byokTransportPhase(error);
      const decision = byokRetryDecision(phase === 'pre_connect' ? 'after_send' : phase, attempt);
      if (decision.mayBeBilled) round.billed = true;
      if (phase === 'cancelled') round.cancelled = true;
      return empty(decision.errorKind);
    }
    if (text === null) {
      // The upstream already produced output, so the oversized reply may be billed.
      round.billed = true;
      return empty('upstream_error', 'response_too_large');
    }
    const body = parseBody(text);
    const kind = classifyImageResult({ http: response.status, body, nRequested: batchSize });
    if (kind !== 'ok' && kind !== 'partial') return empty(kind, text.slice(0, MESSAGE_LIMIT));

    const parsed = parseImageResponse(body);
    const materialized: ImageMaterializeOutcome[] = [];
    for (const image of parsed.images) {
      try {
        // Image downloads are outside the per-attempt timeout (they carry their own); only cancellation applies.
        materialized.push(await materializeImage(image, (url) => deps.fetchImage(url, deps.signal)));
      } catch (error) {
        if (byokTransportPhase(error) === 'cancelled') round.cancelled = true;
        materialized.push({ ok: false, failure: 'network' });
      }
    }
    const assembled = assembleImageOutcomes(
      batchSize,
      materialized.map((outcome) => (outcome.ok ? 'ok' : outcome.failure)),
    );
    const images: StudioGenerateImage[] = [];
    materialized.forEach((outcome, index) => {
      if (!outcome.ok || images.length >= batchSize) return;
      images.push({
        data: encodeBase64(outcome.bytes),
        mime: outcome.mime,
        width: outcome.width,
        height: outcome.height,
        revisedPrompt: parsed.images[index]?.revisedPrompt ?? null,
      });
    });
    const errorKind: ImageErrorKind | null =
      assembled.result === 'ok' ? null : assembled.result === 'partial' ? 'partial' : (assembled.result ?? 'decode_failed');
    return { result: { images: assembled.delivered, errorKind }, images, usage: parsed.usage, message: null };
  }
}

/** Sums each usage field across batches; a field no batch reports stays null, and all-null is null. */
function sumUsage(usages: readonly (ImageUsage | null)[]): ImageUsage | null {
  const field = (pick: (usage: ImageUsage) => number | null): number | null => {
    let total: number | null = null;
    for (const usage of usages) {
      const value = usage ? pick(usage) : null;
      if (value !== null) total = (total ?? 0) + value;
    }
    return total;
  };
  const usage: ImageUsage = {
    inputTokens: field((u) => u.inputTokens),
    outputTokens: field((u) => u.outputTokens),
    totalTokens: field((u) => u.totalTokens),
  };
  return usage.inputTokens === null && usage.outputTokens === null && usage.totalTokens === null ? null : usage;
}

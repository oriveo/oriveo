/**
 * Image response normalization shared by every Studio route: parse any provider
 * JSON body into image candidates, decode the pixel size from image headers, turn
 * a candidate into bytes, and decide the delivery verdict for a call.
 * Runs in both Node and the browser (atob + Uint8Array, no Buffer).
 * Fixture: image_response_samples.v1.
 */

export type ImageKind = 'b64' | 'url' | 'data_url';
export type ImageFetchFailure = 'network' | 'timeout' | 'decode_failed';
export type ImageOutcomeKind = 'ok' | ImageFetchFailure;

export interface ParsedImage {
  kind: ImageKind;
  /** Declared mime (lowercased data URL prefix or provider field); null = sniff from bytes. */
  mime: string | null;
  /** Raw base64 string, the URL, or the full data URL. */
  value: string;
  revisedPrompt: string | null;
}

export interface ImageUsage {
  inputTokens: number | null;
  outputTokens: number | null;
  totalTokens: number | null;
}

export interface ImageSize {
  width: number;
  height: number;
}

export interface ParsedImageResponse {
  shapes: string[];
  deduped: string[];
  images: ParsedImage[];
  usage: ImageUsage | null;
  /** Informational only; the real size always comes from decodeImageInfo. */
  declaredSize: ImageSize | null;
}

export interface ImageInfo extends ImageSize {
  mime: string;
}

export type ImageMaterializeOutcome =
  | ({ ok: true; bytes: Uint8Array } & ImageInfo)
  | { ok: false; failure: ImageFetchFailure };

export type ImageFetcher = (url: string) => Promise<ImageMaterializeOutcome>;

export interface AssembledImageOutcome {
  /** null = no image at all; the error classifier decides the result. */
  result: 'ok' | 'partial' | ImageFetchFailure | null;
  delivered: number;
  failures: ImageFetchFailure[];
}

// ---------- parse ----------

type JsonObject = Record<string, unknown>;

const MARKDOWN_DATA_URL = /!\[[^\]]*\]\((data:(image\/[a-z0-9.+-]+);base64,[^)]+)\)/gi;
// Mime only from a `data:image/<x>;base64,` prefix; anything else (non-image, no ;base64) is null.
const DATA_URL_MIME = /^data:(image\/[a-z0-9.+-]+);base64,/i;

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function isDataUrl(value: string): boolean {
  return value.slice(0, 5).toLowerCase() === 'data:';
}

function dataUrlMime(value: string): string | null {
  const m = DATA_URL_MIME.exec(value);
  return m ? m[1].toLowerCase() : null;
}

/** URL-valued field: data: prefix (any case) means an inline data URL. */
function urlImage(value: string, declaredMime: string | null, revisedPrompt: string | null = null): ParsedImage {
  return isDataUrl(value)
    ? { kind: 'data_url', mime: dataUrlMime(value), value, revisedPrompt }
    : { kind: 'url', mime: declaredMime, value, revisedPrompt };
}

function firstInt(candidates: unknown[]): number | null {
  const ints = candidates.filter((v): v is number => Number.isInteger(v));
  return ints.find((v) => v > 0) ?? ints[0] ?? null;
}

function positiveInt(value: unknown): number | null {
  return Number.isInteger(value) && (value as number) > 0 ? (value as number) : null;
}

function parseUsage(body: JsonObject): ImageUsage | null {
  const usage = isObject(body.usage) ? body.usage : {};
  const meta = isObject(body.usageMetadata) ? body.usageMetadata : {};
  const parsed: ImageUsage = {
    inputTokens: firstInt([usage.input_tokens, usage.prompt_tokens, meta.promptTokenCount]),
    outputTokens: firstInt([usage.output_tokens, usage.completion_tokens, meta.candidatesTokenCount]),
    totalTokens: firstInt([usage.total_tokens, meta.totalTokenCount]),
  };
  return parsed.inputTokens === null && parsed.outputTokens === null && parsed.totalTokens === null
    ? null
    : parsed;
}

function parseDeclaredSize(body: JsonObject): ImageSize | null {
  const size = str(body.size);
  const m = size ? /^(\d+)x(\d+)$/.exec(size) : null;
  if (m) {
    const width = Number(m[1]);
    const height = Number(m[2]);
    if (width > 0 && height > 0) return { width, height };
  }
  if (isObject(body.usage)) {
    const width = positiveInt(body.usage.width);
    const height = positiveInt(body.usage.height);
    if (width !== null && height !== null) return { width, height };
  }
  return null;
}

export function parseImageResponse(body: unknown): ParsedImageResponse {
  const shapes: string[] = [];
  const deduped: string[] = [];
  const images: ParsedImage[] = [];
  if (!isObject(body)) return { shapes, deduped, images, usage: null, declaredSize: null };

  const add = (shape: string, image: ParsedImage) => {
    images.push(image);
    if (!shapes.includes(shape)) shapes.push(shape);
  };

  // data[]: within one item b64_json wins over url (same picture).
  const data = Array.isArray(body.data) ? body.data : null;
  for (const item of data ?? []) {
    if (!isObject(item)) continue;
    const revisedPrompt = str(item.revised_prompt);
    const b64 = str(item.b64_json);
    const url = str(item.url);
    if (b64 !== null) {
      const mime = str(item.mime_type) ?? str(item.media_type);
      add('data[].b64_json', { kind: 'b64', mime, value: b64, revisedPrompt });
    } else if (url !== null) {
      // URL items (http or data URL) never take mime_type / media_type.
      add('data[].url', urlImage(url, null, revisedPrompt));
    }
  }

  // images[].url duplicates data[] when both are present (SiliconFlow): keep data[] only.
  if (Array.isArray(body.images)) {
    if (data && data.length > 0) deduped.push('images[].url');
    else {
      for (const item of body.images) {
        const url = isObject(item) ? str(item.url) : null;
        if (url !== null) add('images[].url', urlImage(url, null));
      }
    }
  }

  if (isObject(body.data)) {
    for (const item of asArray(body.data.image_base64)) {
      if (typeof item === 'string') add('data.image_base64[]', { kind: 'b64', mime: null, value: item, revisedPrompt: null });
    }
  }

  for (const choice of asArray(body.choices)) {
    const message = isObject(choice) && isObject(choice.message) ? choice.message : null;
    if (!message) continue;
    for (const item of asArray(message.images)) {
      const imageUrl = isObject(item) && isObject(item.image_url) ? str(item.image_url.url) : null;
      if (imageUrl !== null) add('message.images[]', urlImage(imageUrl, null));
    }
    if (typeof message.content === 'string') {
      for (const m of message.content.matchAll(MARKDOWN_DATA_URL)) {
        add('markdown data URL', { kind: 'data_url', mime: m[2].toLowerCase(), value: m[1], revisedPrompt: null });
      }
    }
  }

  for (const candidate of asArray(body.candidates)) {
    const content = isObject(candidate) && isObject(candidate.content) ? candidate.content : null;
    for (const part of asArray(content?.parts)) {
      if (!isObject(part)) continue;
      const inline = isObject(part.inlineData) ? part.inlineData : isObject(part.inline_data) ? part.inline_data : null;
      const value = inline ? str(inline.data) : null;
      if (inline && value !== null) {
        add('inlineData', { kind: 'b64', mime: str(inline.mimeType) ?? str(inline.mime_type), value, revisedPrompt: null });
      }
    }
  }

  const output = isObject(body.output) ? body.output : null;
  for (const choice of asArray(output?.choices)) {
    const message = isObject(choice) && isObject(choice.message) ? choice.message : null;
    for (const part of asArray(message?.content)) {
      const image = isObject(part) ? str(part.image) : null;
      if (image !== null) add('output.choices[].message.content[].image', urlImage(image, null));
    }
  }

  return { shapes, deduped, images, usage: parseUsage(body), declaredSize: parseDeclaredSize(body) };
}

// ---------- header decode ----------

function u16be(b: Uint8Array, i: number): number {
  return (b[i] << 8) | b[i + 1];
}

function u32be(b: Uint8Array, i: number): number {
  return ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
}

function ascii(b: Uint8Array, i: number, text: string): boolean {
  if (i + text.length > b.length) return false;
  for (let k = 0; k < text.length; k++) if (b[i + k] !== text.charCodeAt(k)) return false;
  return true;
}

function sized(mime: string, width: number, height: number): ImageInfo | null {
  return width > 0 && height > 0 ? { mime, width, height } : null;
}

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const PNG_MAX_DIMENSION = 0x7fffffff;

function decodePng(b: Uint8Array): ImageInfo | null {
  if (b.length < 24 || !PNG_SIGNATURE.every((v, i) => b[i] === v) || !ascii(b, 12, 'IHDR')) return null;
  const width = u32be(b, 16);
  const height = u32be(b, 20);
  // PNG dimensions are limited to 1..2^31-1.
  if (width > PNG_MAX_DIMENSION || height > PNG_MAX_DIMENSION) return null;
  return sized('image/png', width, height);
}

function decodeJpeg(b: Uint8Array): ImageInfo | null {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
  let i = 2;
  while (i + 1 < b.length) {
    if (b[i] !== 0xff) return null;
    let marker = b[i + 1];
    while (marker === 0xff && i + 2 < b.length) {
      i++;
      marker = b[i + 1];
    }
    // Standalone markers carry no length.
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) return null;
    if (i + 4 > b.length) return null;
    const length = u16be(b, i + 2);
    if (length < 2) return null;
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      // SOF needs length(2) + precision(1) + height(2) + width(2); shorter is invalid, no further scan.
      if (length < 7 || i + 9 > b.length) return null;
      return sized('image/jpeg', u16be(b, i + 7), u16be(b, i + 5));
    }
    i += 2 + length;
  }
  return null;
}

function decodeWebp(b: Uint8Array): ImageInfo | null {
  if (b.length < 20 || !ascii(b, 0, 'RIFF') || !ascii(b, 8, 'WEBP')) return null;
  if (ascii(b, 12, 'VP8 ')) {
    if (b.length < 30 || b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return null;
    return sized('image/webp', (b[26] | (b[27] << 8)) & 0x3fff, (b[28] | (b[29] << 8)) & 0x3fff);
  }
  if (ascii(b, 12, 'VP8L')) {
    if (b.length < 25 || b[20] !== 0x2f) return null;
    const bits = (b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24)) >>> 0;
    return sized('image/webp', (bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
  }
  if (ascii(b, 12, 'VP8X')) {
    if (b.length < 30) return null;
    return sized(
      'image/webp',
      1 + (b[24] | (b[25] << 8) | (b[26] << 16)),
      1 + (b[27] | (b[28] << 8) | (b[29] << 16)),
    );
  }
  return null;
}

/** Stored pixel size from the image header (EXIF orientation ignored); png / jpeg / webp only. */
export function decodeImageInfo(bytes: Uint8Array): ImageInfo | null {
  return decodePng(bytes) ?? decodeJpeg(bytes) ?? decodeWebp(bytes);
}

// ---------- materialize ----------

function base64Bytes(b64: string): Uint8Array | null {
  try {
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function inlinePayload(image: ParsedImage): string | null {
  if (image.kind === 'b64') return image.value;
  const comma = image.value.indexOf(',');
  if (comma < 0 || !/;base64$/i.test(image.value.slice(0, comma))) return null;
  return image.value.slice(comma + 1);
}

/** Inline images decode locally; URL images go through the fetcher. */
export async function materializeImage(
  image: ParsedImage,
  fetcher: ImageFetcher,
): Promise<ImageMaterializeOutcome> {
  if (image.kind === 'url') return fetcher(image.value);
  const payload = inlinePayload(image);
  const bytes = payload === null ? null : base64Bytes(payload);
  const info = bytes ? decodeImageInfo(bytes) : null;
  if (!bytes || !info) return { ok: false, failure: 'decode_failed' };
  return { ok: true, bytes, ...info };
}

// ---------- assemble ----------

export function assembleImageOutcomes(
  nRequested: number,
  outcomes: readonly ImageOutcomeKind[],
): AssembledImageOutcome {
  const failures = outcomes.filter((o): o is ImageFetchFailure => o !== 'ok');
  const delivered = outcomes.length - failures.length;
  let result: AssembledImageOutcome['result'];
  if (outcomes.length === 0) result = null;
  else if (delivered === 0) result = failures[0];
  else result = delivered >= nRequested ? 'ok' : 'partial';
  return { result, delivered, failures };
}

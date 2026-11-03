/**
 * BYOK image request builder (shared fixture request_shape_contract.v2.json
 * imageRequests). Pure function over a profile that passed checkImageProfile,
 * the normalized wire and the user's input; returns one HTTP request
 * description. JSON bodies are plain objects; multipart bodies are ordered
 * fields and files left unencoded (no boundary) for the transport layer.
 * Only openai_images / xai_images / openrouter_images / minimax_image_generation /
 * gemini_generate_content / chat_modalities / dashscope_multimodal are built here;
 * other routes are invalid_profile. Every JSON route writes its fixed fields first,
 * then the wire and advanced keys; any collision is invalid_profile, never an overwrite.
 */

import { IMAGE_ROUTE_RULES, type ImageProfile } from './image-profile';

export type ImageRequestError = 'invalid_request' | 'invalid_profile';

export type ImageRequestMime = 'image/png' | 'image/jpeg' | 'image/webp';

export interface ImageRequestImage {
  readonly slot: number;
  readonly role: string;
  readonly mime: string;
  readonly data: Uint8Array;
}

export interface ImageRequestAdvanced {
  readonly negativePrompt?: string | null;
  readonly seed?: number | null;
  readonly transparentBackground?: boolean | null;
  readonly outputFormat?: string | null;
}

export interface ImageRequestInput {
  readonly operation: string;
  readonly modelId: string;
  readonly prompt: string;
  /** normalizeImageParams(...).wire: body keys, dotted for nested objects. */
  readonly wire: Readonly<Record<string, string | number>>;
  readonly images: readonly ImageRequestImage[];
  readonly advanced?: ImageRequestAdvanced | null;
  readonly baseUrl: string;
  readonly apiKey: string;
}

export interface ImageRequestFile {
  readonly name: string;
  readonly filename: string;
  readonly mime: ImageRequestMime;
  readonly data: Uint8Array;
}

export type ImageRequestBody =
  | { readonly kind: 'json'; readonly json: Record<string, unknown> }
  | {
      readonly kind: 'multipart';
      readonly fields: readonly (readonly [string, string])[];
      readonly files: readonly ImageRequestFile[];
    };

export interface ImageRequest {
  readonly method: 'POST';
  readonly url: string;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: ImageRequestBody;
}

export type ImageRequestBuild = ImageRequest | { readonly error: ImageRequestError };

type BuilderRoute =
  | 'openai_images'
  | 'xai_images'
  | 'openrouter_images'
  | 'minimax_image_generation'
  | 'gemini_generate_content'
  | 'chat_modalities'
  | 'dashscope_multimodal';
type BuilderTransport =
  | 'multipart'
  | 'json_image'
  | 'json_image_url'
  | 'json_image_object'
  | 'input_references'
  | 'inline';
type AdvancedField = keyof ImageRequestAdvanced;
type WireValue = string | number;

const BUILDER_ROUTES: readonly string[] = [
  'openai_images',
  'xai_images',
  'openrouter_images',
  'minimax_image_generation',
  'gemini_generate_content',
  'chat_modalities',
  'dashscope_multimodal',
];

/** Most images a transport carries, before the profile's maxReferenceImages. */
const TRANSPORT_IMAGE_LIMIT: Readonly<Record<BuilderTransport, number>> = {
  multipart: Number.POSITIVE_INFINITY,
  json_image: 1,
  json_image_url: 1,
  json_image_object: 5,
  input_references: Number.POSITIVE_INFINITY,
  inline: Number.POSITIVE_INFINITY,
};

const MIME_EXTENSIONS: Readonly<Record<ImageRequestMime, string>> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
};

const OUTPUT_FORMATS: readonly string[] = ['png', 'jpeg', 'webp'];
const SEED_MAX = 2147483647;

/** Body keys of the advanced fields per route; a missing key is never sent. */
const ADVANCED_KEYS: Readonly<Record<BuilderRoute, Partial<Record<AdvancedField, string>>>> = {
  openai_images: {
    negativePrompt: 'negative_prompt',
    seed: 'seed',
    transparentBackground: 'background',
    outputFormat: 'output_format',
  },
  xai_images: {},
  openrouter_images: {
    seed: 'seed',
    transparentBackground: 'background',
    outputFormat: 'output_format',
  },
  minimax_image_generation: {
    seed: 'seed',
  },
  gemini_generate_content: {
    seed: 'generationConfig.seed',
  },
  chat_modalities: {
    seed: 'seed',
  },
  dashscope_multimodal: {
    negativePrompt: 'parameters.negative_prompt',
    seed: 'parameters.seed',
  },
};

/** Leading resource prefix a pasted Gemini model name may carry; stripped once. */
const GEMINI_MODEL_PREFIX = 'models/';

/** RFC 3986 unreserved characters; every other UTF-8 byte of a path segment is percent-encoded. */
const UNRESERVED_BYTE = /^[A-Za-z0-9\-._~]$/;

/** Bytes per String.fromCharCode call; keeps the argument list well under engine limits. */
const BASE64_CHUNK = 0x8000;

/**
 * Whole-string base URL shape (no platform URL parser): http(s), a bracketed IP
 * literal or a host without userinfo, optional port, optional path; no query or fragment.
 */
const BASE_URL_PATTERN = /^[Hh][Tt][Tt][Pp][Ss]?:\/\/(\[[0-9A-Fa-f:.]+\]|[^/?# \t\n\x0B\f\r:@[\]]+)(:[0-9]{1,5})?(\/[^?# \t\n\x0B\f\r]*)?$/;

/** ASCII whitespace only (space, tab, LF, VT, FF, CR); U+00A0, U+FEFF and friends are not whitespace. */
const ASCII_EDGE_WHITESPACE = /^[ \t\n\x0B\f\r]+|[ \t\n\x0B\f\r]+$/g;

const INVALID_REQUEST = { error: 'invalid_request' } as const;
const INVALID_PROFILE = { error: 'invalid_profile' } as const;

function isBuilderRoute(route: string): route is BuilderRoute {
  return BUILDER_ROUTES.includes(route);
}

function isBuilderTransport(transport: string): transport is BuilderTransport {
  return Object.prototype.hasOwnProperty.call(TRANSPORT_IMAGE_LIMIT, transport);
}

function isSupportedMime(mime: string): mime is ImageRequestMime {
  return Object.prototype.hasOwnProperty.call(MIME_EXTENSIONS, mime);
}

function trimAsciiWhitespace(value: string): string {
  return value.replace(ASCII_EDGE_WHITESPACE, '');
}

/**
 * Standard base64 with padding via btoa; no Node Buffer so it runs in browsers.
 * Bytes become a binary string in 32 KB chunks instead of one character at a time.
 */
export function encodeBase64(bytes: Uint8Array): string {
  const chunks: string[] = [];
  for (let i = 0; i < bytes.length; i += BASE64_CHUNK) {
    chunks.push(String.fromCharCode(...bytes.subarray(i, i + BASE64_CHUNK)));
  }
  return btoa(chunks.join(''));
}

/** Percent-encodes each UTF-8 byte outside the unreserved set, with upper-case hex. */
function encodePathSegment(segment: string): string {
  let encoded = '';
  for (const byte of new TextEncoder().encode(segment)) {
    const char = String.fromCharCode(byte);
    encoded += byte < 0x80 && UNRESERVED_BYTE.test(char)
      ? char
      : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return encoded;
}

function dataUri(image: ImageRequestImage): string {
  return `data:${image.mime};base64,${encodeBase64(image.data)}`;
}

/** Expects an already trimmed base URL: the string checked is the string joined. */
function isValidBaseUrl(baseUrl: string): boolean {
  return BASE_URL_PATTERN.test(baseUrl);
}

function imagesAreValid(images: readonly ImageRequestImage[]): boolean {
  const slots = new Set<number>();
  let bases = 0;
  for (const image of images) {
    if (!Number.isInteger(image.slot) || image.slot <= 0 || slots.has(image.slot)) return false;
    slots.add(image.slot);
    if (image.role === 'base') bases += 1;
    if (!isSupportedMime(image.mime)) return false;
    // No instanceof: byte arrays from another realm (worker, iframe, jsdom) are still valid.
    if (!image.data || image.data.byteLength === 0) return false;
  }
  return bases <= 1;
}

function advancedIsValid(advanced: ImageRequestAdvanced): boolean {
  const { seed, outputFormat } = advanced;
  if (seed !== undefined && seed !== null) {
    if (!Number.isInteger(seed) || seed < 0 || seed > SEED_MAX) return false;
  }
  if (outputFormat !== undefined && outputFormat !== null && !OUTPUT_FORMATS.includes(outputFormat)) {
    return false;
  }
  return true;
}

/** Base first, then the rest by ascending slot. */
function orderImages(images: readonly ImageRequestImage[]): ImageRequestImage[] {
  return [...images].sort((a, b) => {
    const aBase = a.role === 'base' ? 0 : 1;
    const bBase = b.role === 'base' ? 0 : 1;
    return aBase !== bBase ? aBase - bBase : a.slot - b.slot;
  });
}

/** Advanced body entries in a fixed order: negative prompt, seed, background, output format. */
function advancedEntries(
  profile: ImageProfile,
  route: BuilderRoute,
  advanced: ImageRequestAdvanced,
): [string, WireValue][] {
  const keys = ADVANCED_KEYS[route];
  const params = profile.params ?? {};
  const keyFor = (field: AdvancedField): string | null =>
    params[field] === true ? (keys[field] ?? null) : null;
  const entries: [string, WireValue][] = [];

  const negativeKey = keyFor('negativePrompt');
  const negativePrompt = advanced.negativePrompt;
  if (negativeKey && typeof negativePrompt === 'string' && trimAsciiWhitespace(negativePrompt) !== '') {
    entries.push([negativeKey, negativePrompt]);
  }
  const seedKey = keyFor('seed');
  if (seedKey && typeof advanced.seed === 'number') entries.push([seedKey, advanced.seed]);
  const backgroundKey = keyFor('transparentBackground');
  const transparent = backgroundKey !== null && advanced.transparentBackground === true;
  if (backgroundKey && transparent) entries.push([backgroundKey, 'transparent']);
  const formatKey = keyFor('outputFormat');
  if (formatKey) {
    if (transparent) entries.push([formatKey, 'png']);
    else if (typeof advanced.outputFormat === 'string') entries.push([formatKey, advanced.outputFormat]);
  }
  return entries;
}

/**
 * Sets a dotted wire key on a plain object. Only own keys count: inherited names such as
 * "constructor" are free to write, and an existing own key at the leaf or a non-object
 * (array included) on the way is a collision. Any "__proto__" segment is rejected.
 * Returns false on collision or rejection.
 */
function setDotted(target: Record<string, unknown>, dottedKey: string, value: WireValue): boolean {
  const segments = dottedKey.split('.');
  if (segments.includes('__proto__')) return false;
  let current = target;
  for (let i = 0; i < segments.length - 1; i += 1) {
    const segment = segments[i]!;
    const next = Object.hasOwn(current, segment) ? current[segment] : undefined;
    if (next === undefined) {
      const created: Record<string, unknown> = {};
      current[segment] = created;
      current = created;
    } else if (next !== null && typeof next === 'object' && !Array.isArray(next)) {
      current = next as Record<string, unknown>;
    } else {
      return false;
    }
  }
  const last = segments[segments.length - 1]!;
  if (Object.hasOwn(current, last)) return false;
  current[last] = value;
  return true;
}

function compareKeys(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Every fixed body field of a JSON route: request fields, image fields and the response format. */
function fixedJsonFields(
  profile: ImageProfile,
  route: BuilderRoute,
  transport: BuilderTransport | null,
  modelId: string,
  prompt: string,
  ordered: readonly ImageRequestImage[],
): Record<string, unknown> {
  if (route === 'dashscope_multimodal') {
    // Images in request order, then exactly one text item; generate carries only the text.
    const content: Record<string, unknown>[] = [
      ...ordered.map((image) => ({ image: dataUri(image) })),
      { text: prompt },
    ];
    // Only a literal boolean promptExtend is sent, false included; watermark is never sent.
    const promptExtend = (profile.params ?? {}).promptExtend;
    const parameters: Record<string, unknown> =
      typeof promptExtend === 'boolean' ? { prompt_extend: promptExtend } : {};
    return {
      model: modelId,
      input: { messages: [{ role: 'user', content }] },
      parameters,
    };
  }
  if (route === 'gemini_generate_content') {
    const parts: Record<string, unknown>[] = [{ text: prompt }];
    for (const image of ordered) {
      parts.push({ inline_data: { mime_type: image.mime, data: encodeBase64(image.data) } });
    }
    return {
      contents: [{ role: 'user', parts }],
      generationConfig: { responseModalities: ['TEXT', 'IMAGE'] },
    };
  }
  if (route === 'chat_modalities') {
    const content: unknown =
      ordered.length === 0
        ? prompt
        : [
            { type: 'text', text: prompt },
            ...ordered.map((image) => ({ type: 'image_url', image_url: { url: dataUri(image) } })),
          ];
    return {
      model: modelId,
      messages: [{ role: 'user', content }],
      modalities: ['image', 'text'],
      stream: false,
    };
  }

  const json: Record<string, unknown> = { model: modelId, prompt };
  if (transport === 'json_image') {
    json.image = dataUri(ordered[0]!);
  } else if (transport === 'json_image_url') {
    json.image_url = dataUri(ordered[0]!);
  } else if (transport === 'json_image_object') {
    if (ordered.length === 1) json.image = { url: dataUri(ordered[0]!) };
    else json.images = ordered.map((image) => ({ url: dataUri(image) }));
  } else if (transport === 'input_references') {
    json.input_references = ordered.map((image) => ({ type: 'image_url', image_url: { url: dataUri(image) } }));
  }
  if (route === 'xai_images') json.response_format = 'b64_json';
  else if (route === 'minimax_image_generation') json.response_format = 'base64';
  return json;
}

export function buildImageRequest(profile: ImageProfile, input: ImageRequestInput): ImageRequestBuild {
  const route = profile.route;
  if (!isBuilderRoute(route)) return INVALID_PROFILE;

  const operation = input.operation;
  if (operation !== 'generate' && operation !== 'edit') return INVALID_REQUEST;
  if (!profile.operations.includes(operation)) return INVALID_REQUEST;

  let transport: BuilderTransport | null = null;
  if (operation === 'edit') {
    const declared = profile.editTransport;
    if (
      declared === undefined ||
      !IMAGE_ROUTE_RULES[route].allowedEditTransports.includes(declared) ||
      !isBuilderTransport(declared)
    ) {
      return INVALID_PROFILE;
    }
    transport = declared;
  }

  // The model id goes out trimmed; the prompt goes out verbatim.
  const modelId = trimAsciiWhitespace(input.modelId);
  // Gemini carries the model only in the path, without one pasted "models/" prefix.
  const modelSegment =
    route === 'gemini_generate_content' && modelId.startsWith(GEMINI_MODEL_PREFIX)
      ? modelId.slice(GEMINI_MODEL_PREFIX.length)
      : modelId;
  if (modelSegment === '' || trimAsciiWhitespace(input.prompt) === '') return INVALID_REQUEST;
  const images = input.images;
  if (operation === 'generate' && images.length > 0) return INVALID_REQUEST;
  if (operation === 'edit' && images.length === 0) return INVALID_REQUEST;
  if (!imagesAreValid(images)) return INVALID_REQUEST;
  if (transport) {
    const declaredMax = profile.maxReferenceImages;
    const profileMax =
      typeof declaredMax === 'number' && Number.isInteger(declaredMax) && declaredMax > 0 ? declaredMax : 1;
    if (images.length > Math.min(profileMax, TRANSPORT_IMAGE_LIMIT[transport])) return INVALID_REQUEST;
  }
  const advanced = input.advanced ?? {};
  if (!advancedIsValid(advanced)) return INVALID_REQUEST;
  const baseUrl = trimAsciiWhitespace(input.baseUrl);
  if (!isValidBaseUrl(baseUrl)) return INVALID_REQUEST;

  const path =
    route === 'gemini_generate_content'
      ? `/models/${encodePathSegment(modelSegment)}:generateContent`
      : route === 'chat_modalities'
        ? '/chat/completions'
        : route === 'dashscope_multimodal'
          ? '/services/aigc/multimodal-generation/generation'
          : route === 'openrouter_images'
      ? '/images'
      : route === 'minimax_image_generation'
        ? '/image_generation'
        : transport === 'multipart' || transport === 'json_image_object'
          ? '/images/edits'
          : '/images/generations';
  const url = `${baseUrl.replace(/\/+$/, '')}${path}`;
  const headers: Record<string, string> = {
    'Content-Type': transport === 'multipart' ? 'multipart/form-data' : 'application/json',
  };
  const apiKey = trimAsciiWhitespace(input.apiKey);
  // A blank key sends no auth header at all; Gemini keys never go in Authorization or the query.
  if (apiKey !== '') {
    if (route === 'gemini_generate_content') headers['x-goog-api-key'] = apiKey;
    else headers.Authorization = `Bearer ${apiKey}`;
  }

  const ordered = orderImages(images);
  const extras = advancedEntries(profile, route, advanced);

  if (transport === 'multipart') {
    const wireFields = Object.entries(input.wire)
      .sort(([a], [b]) => compareKeys(a, b))
      .map(([key, value]): readonly [string, string] => [key, String(value)]);
    const fields: (readonly [string, string])[] = [
      ['model', modelId],
      ['prompt', input.prompt],
      ...wireFields,
      ...extras.map(([key, value]): readonly [string, string] => [key, String(value)]),
    ];
    // A wire or advanced key that repeats model, prompt or another field is a profile defect.
    if (new Set(fields.map(([name]) => name)).size !== fields.length) return INVALID_PROFILE;
    const files: ImageRequestFile[] = ordered.map((image, index) => {
      const mime = image.mime as ImageRequestMime;
      return { name: 'image[]', filename: `image-${index + 1}.${MIME_EXTENSIONS[mime]}`, mime, data: image.data };
    });
    return { method: 'POST', url, headers, body: { kind: 'multipart', fields, files } };
  }

  // Fixed fields first, so a wire or advanced key that repeats one is caught instead of overwriting it.
  const json = fixedJsonFields(profile, route, transport, modelId, input.prompt, ordered);
  for (const [key, value] of Object.entries(input.wire)) {
    if (!setDotted(json, key, value)) return INVALID_PROFILE;
  }
  for (const [key, value] of extras) {
    if (!setDotted(json, key, value)) return INVALID_PROFILE;
  }
  return { method: 'POST', url, headers, body: { kind: 'json', json } };
}

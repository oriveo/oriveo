/**
 * Image parameter normalization (shared fixture image_param_normalization.v1.json).
 * Pure function over a profile that passed checkImageProfile and the raw user
 * request: picks the aspect ratio / resolution tier / quality tier the profile
 * supports, builds the wire body keys (dotted for nested objects), splits n into
 * batches, and reports every replaced user choice as an adjustment.
 */

import {
  IMAGE_QUALITY_TIERS,
  IMAGE_RESOLUTION_TIERS,
  type ImageProfile,
  type ImageQualityTier,
  type ImageResolutionTier,
  type ImageRoute,
} from './image-profile';

/** Raw user request; null / missing / empty string (and n = 0) mean unset. */
export interface ImageParamRequest {
  readonly aspect?: string | null;
  readonly resolution?: string | null;
  readonly quality?: string | null;
  readonly n?: number | null;
}

export type ImageParamAdjustment =
  | { readonly field: 'aspect'; readonly from: string; readonly to: string }
  | { readonly field: 'resolution'; readonly from: ImageResolutionTier; readonly to: ImageResolutionTier }
  | { readonly field: 'size'; readonly from: string; readonly to: string }
  | { readonly field: 'quality'; readonly from: ImageQualityTier; readonly to: null }
  | { readonly field: 'n'; readonly from: number; readonly to: readonly number[] };

export interface ImageParamNormalized {
  readonly aspect: string;
  readonly resolution: ImageResolutionTier;
  readonly quality: ImageQualityTier | null;
  /** Wire body keys, dotted for nested objects. */
  readonly wire: Readonly<Record<string, string | number>>;
  readonly batches: readonly number[];
  readonly adjustments: readonly ImageParamAdjustment[];
}

export type ImageParamError = 'invalid_request' | 'invalid_profile';

export type ImageParamNormalization = ImageParamNormalized | { readonly error: ImageParamError };

export const IMAGE_PARAM_DEFAULT_ASPECT = '1:1';
const DEFAULT_RESOLUTION: ImageResolutionTier = '1K';
const DEFAULT_QUALITY: ImageQualityTier = 'standard';
const ASPECT_TIE_TOLERANCE = 1e-12;

/** Wire key of n per route; absent = the route has no n body key. */
const N_WIRE_KEY: Readonly<Partial<Record<ImageRoute, string>>> = {
  openai_images: 'n',
  xai_images: 'n',
  openrouter_images: 'n',
  dashscope_multimodal: 'parameters.n',
  minimax_image_generation: 'n',
};

/** Wire key of quality per route; absent = the route has no quality body key. */
const QUALITY_WIRE_KEY: Readonly<Partial<Record<ImageRoute, string>>> = {
  openai_images: 'quality',
  openrouter_images: 'quality',
};

interface Aspect {
  readonly text: string;
  readonly width: number;
  readonly height: number;
}

/** Each side 1..9999 without a leading zero. */
const ASPECT_PATTERN = /^([1-9][0-9]{0,3}):([1-9][0-9]{0,3})$/;

/** Parses W:H with each side 1..9999 (no leading zero); anything else is null. */
function parseAspect(text: unknown): Aspect | null {
  if (typeof text !== 'string') return null;
  const match = ASPECT_PATTERN.exec(text);
  if (!match) return null;
  const width = Number(match[1]);
  const height = Number(match[2]);
  return { text, width, height };
}

function isOneOf<T extends string>(values: readonly T[], value: string): value is T {
  return (values as readonly string[]).includes(value);
}

/** null / missing / empty string = unset. */
function setString(value: unknown): unknown {
  return value === null || value === undefined || value === '' ? undefined : value;
}

function isPositiveInteger(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) > 0;
}

/** Tiers with a positive-integer long edge (and, where the wire needs it, a resolutionValues string). */
function availableTiers(profile: ImageProfile): ImageResolutionTier[] {
  const needsValue = profile.sizeParam === 'aspect_resolution'
    || profile.sizeParam === 'gemini_image_config';
  return IMAGE_RESOLUTION_TIERS.filter((tier) => {
    if (!isPositiveInteger(profile.resolutions[tier])) return false;
    if (!needsValue) return true;
    const value = profile.resolutionValues?.[tier];
    return typeof value === 'string' && value !== '';
  });
}

function nearestAspect(target: Aspect, candidates: readonly Aspect[]): Aspect {
  const targetLog = Math.log(target.width / target.height);
  let best = candidates[0];
  let bestDistance = Math.abs(Math.log(best.width / best.height) - targetLog);
  for (const candidate of candidates.slice(1)) {
    const distance = Math.abs(Math.log(candidate.width / candidate.height) - targetLog);
    if (distance < bestDistance - ASPECT_TIE_TOLERANCE) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return best;
}

function pickTier(requested: ImageResolutionTier, available: readonly ImageResolutionTier[]): ImageResolutionTier {
  if (available.includes(requested)) return requested;
  const rank = IMAGE_RESOLUTION_TIERS.indexOf(requested);
  const lower = available.filter((tier) => IMAGE_RESOLUTION_TIERS.indexOf(tier) <= rank);
  return lower.length > 0 ? lower[lower.length - 1] : available[0];
}

interface PixelSize {
  readonly width: number;
  readonly height: number;
}

/** Long edge from the tier, short edge from the ratio, clamped by sizeConstraints. */
function pixelSize(profile: ImageProfile, aspect: Aspect, longEdge: number): {
  readonly initial: PixelSize;
  readonly final: PixelSize;
} {
  const constraints = profile.sizeConstraints ?? {};
  const positive = (value: unknown): number | undefined => (isPositiveInteger(value) ? value : undefined);
  const multipleOf = positive(constraints.multipleOf) ?? 1;
  const maxLongEdge = positive(constraints.maxLongEdge);
  const maxPixels = positive(constraints.maxPixels);
  const minPixels = positive(constraints.minPixels);
  // Every step leaves each edge at least one multipleOf (no zero edge, no division by zero).
  const atLeastOne = (edge: number): number => Math.max(multipleOf, edge);
  const roundTo = (edge: number): number => atLeastOne(Math.round(edge / multipleOf) * multipleOf);

  const landscape = aspect.width >= aspect.height;
  const shortEdge = landscape
    ? (longEdge * aspect.height) / aspect.width
    : (longEdge * aspect.width) / aspect.height;
  const initial: PixelSize = landscape
    ? { width: roundTo(longEdge), height: roundTo(shortEdge) }
    : { width: roundTo(shortEdge), height: roundTo(longEdge) };

  let { width, height } = initial;
  if (maxLongEdge !== undefined) {
    const currentLong = Math.max(width, height);
    if (currentLong > maxLongEdge) {
      const clamp = (edge: number): number =>
        atLeastOne(Math.floor((edge * maxLongEdge) / currentLong / multipleOf) * multipleOf);
      width = clamp(width);
      height = clamp(height);
    }
  }
  if (maxPixels !== undefined && width * height > maxPixels) {
    const scale = Math.sqrt(maxPixels / (width * height));
    width = atLeastOne(Math.floor((width * scale) / multipleOf) * multipleOf);
    height = atLeastOne(Math.floor((height * scale) / multipleOf) * multipleOf);
  }
  if (minPixels !== undefined && width * height < minPixels) {
    const scale = Math.sqrt(minPixels / (width * height));
    width = Math.ceil((width * scale) / multipleOf) * multipleOf;
    height = Math.ceil((height * scale) / multipleOf) * multipleOf;
  }
  return { initial, final: { width, height } };
}

function formatSize(size: PixelSize, separator: string): string {
  return `${size.width}${separator}${size.height}`;
}

function splitBatches(n: number, maxPerCall: number): number[] {
  const batches: number[] = [];
  for (let remaining = n; remaining > 0; remaining -= maxPerCall) {
    batches.push(Math.min(remaining, maxPerCall));
  }
  return batches;
}

/**
 * Normalizes a raw request against a checked profile. A profile without usable
 * aspect ratios, batch size or resolution tier is invalid_profile (checked
 * first); a set request value outside its closed set is invalid_request.
 */
export function normalizeImageParams(
  profile: ImageProfile,
  request: ImageParamRequest,
  defaultAspect: string = IMAGE_PARAM_DEFAULT_ASPECT,
): ImageParamNormalization {
  // Profile first (the Server rejects a bad profile before it sees the request).
  const candidates = profile.aspectRatios.map(parseAspect);
  if (candidates.length === 0 || candidates.some((candidate) => candidate === null)) {
    return { error: 'invalid_profile' };
  }
  const aspects = candidates as Aspect[];
  if (!(profile.maxNPerCall >= 1)) return { error: 'invalid_profile' };
  const tiers = availableTiers(profile);
  if (tiers.length === 0) return { error: 'invalid_profile' };
  // Then the request.
  const rawAspect = setString(request.aspect);
  const rawResolution = setString(request.resolution);
  const rawQuality = setString(request.quality);
  const rawN = request.n === null || request.n === undefined || request.n === 0 ? undefined : request.n;

  const requestedAspect = rawAspect === undefined ? undefined : parseAspect(rawAspect);
  if (requestedAspect === null) return { error: 'invalid_request' };
  if (
    rawResolution !== undefined
    && !(typeof rawResolution === 'string' && isOneOf(IMAGE_RESOLUTION_TIERS, rawResolution))
  ) {
    return { error: 'invalid_request' };
  }
  if (
    rawQuality !== undefined
    && !(typeof rawQuality === 'string' && isOneOf(IMAGE_QUALITY_TIERS, rawQuality))
  ) {
    return { error: 'invalid_request' };
  }
  if (rawN !== undefined && !isPositiveInteger(rawN)) return { error: 'invalid_request' };

  const fallbackAspect = parseAspect(defaultAspect) ?? parseAspect(IMAGE_PARAM_DEFAULT_ASPECT)!;

  const adjustments: ImageParamAdjustment[] = [];
  const wire: Record<string, string | number> = {};

  // Aspect.
  const wantedAspect = requestedAspect ?? fallbackAspect;
  const aspect = aspects.find((candidate) => candidate.text === wantedAspect.text)
    ?? nearestAspect(wantedAspect, aspects);
  if (requestedAspect && aspect.text !== requestedAspect.text) {
    adjustments.push({ field: 'aspect', from: requestedAspect.text, to: aspect.text });
  }

  // Resolution.
  const requestedTier = rawResolution as ImageResolutionTier | undefined;
  const tier = pickTier(requestedTier ?? DEFAULT_RESOLUTION, tiers);
  if (requestedTier !== undefined && tier !== requestedTier) {
    adjustments.push({ field: 'resolution', from: requestedTier, to: tier });
  }

  // Size keys.
  const resolutionValue = profile.resolutionValues?.[tier] ?? '';
  switch (profile.sizeParam) {
    case 'wxh':
    case 'dashscope_wxh': {
      const { initial, final } = pixelSize(profile, aspect, profile.resolutions[tier] as number);
      const dashscope = profile.sizeParam === 'dashscope_wxh';
      wire[dashscope ? 'parameters.size' : 'size'] = formatSize(final, dashscope ? '*' : 'x');
      if (initial.width !== final.width || initial.height !== final.height) {
        adjustments.push({ field: 'size', from: formatSize(initial, 'x'), to: formatSize(final, 'x') });
      }
      break;
    }
    case 'aspect_resolution':
      wire.aspect_ratio = aspect.text;
      wire.resolution = resolutionValue;
      break;
    case 'gemini_image_config':
      wire['generationConfig.imageConfig.aspectRatio'] = aspect.text;
      wire['generationConfig.imageConfig.imageSize'] = resolutionValue;
      break;
    case 'chat_image_config':
      wire['image_config.aspect_ratio'] = aspect.text;
      break;
    case 'aspect_only':
      wire.aspect_ratio = aspect.text;
      break;
  }

  // Quality.
  const requestedQuality = rawQuality as ImageQualityTier | undefined;
  const qualityTier = requestedQuality ?? DEFAULT_QUALITY;
  const qualityKey = QUALITY_WIRE_KEY[profile.route];
  let quality: ImageQualityTier | null = null;
  if (profile.qualityMap && qualityKey) {
    const mapped = profile.qualityMap[qualityTier];
    if (typeof mapped === 'string' && mapped !== '') {
      wire[qualityKey] = mapped;
      quality = qualityTier;
    } else if (requestedQuality !== undefined) {
      adjustments.push({ field: 'quality', from: requestedQuality, to: null });
    }
  }

  // n.
  const n = rawN ?? 1;
  const nKey = N_WIRE_KEY[profile.route];
  let batches: number[];
  if (profile.nParam === false || !nKey) {
    batches = Array.from({ length: n }, () => 1);
  } else {
    batches = splitBatches(n, profile.maxNPerCall);
    wire[nKey] = batches[0];
  }
  if (batches.length > 1) adjustments.push({ field: 'n', from: n, to: batches });

  return { aspect: aspect.text, resolution: tier, quality, wire, batches, adjustments };
}

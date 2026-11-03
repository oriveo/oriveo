/**
 * ImageProfile v2 resolution and studio visibility (shared fixtures
 * image_profile.v2.json + image_profile_resolution.v1.json). Pure functions over
 * the metadata slice in wire shape: profiles.image plus providers.<kind>.models /
 * providers.<kind>.imageModels (wire model id -> entry carrying imageProfile /
 * imageProfileOverride). The Server is the only authority; nothing here guesses
 * capability from a model id or provider kind. Any unknown enum value or a
 * transport the route does not allow makes the profile unusable (fail closed,
 * never fall back to chat).
 */

import type { MetadataResponse } from '../metadata/metadata-client';

/** Closed enums, hard-coded and compared with image_profile.v2.json by the contract test. */
export const IMAGE_OPERATIONS = ['generate', 'edit'] as const;
export const IMAGE_ROUTES = [
  'openai_images',
  'xai_images',
  'gemini_generate_content',
  'chat_modalities',
  'openrouter_images',
  'dashscope_multimodal',
  'minimax_image_generation',
] as const;
export const IMAGE_EDIT_TRANSPORTS = [
  'multipart',
  'json_image',
  'json_image_url',
  'json_image_object',
  'input_references',
  'inline',
] as const;
export const IMAGE_SIZE_PARAMS = [
  'wxh',
  'aspect_resolution',
  'gemini_image_config',
  'dashscope_wxh',
  'chat_image_config',
  'aspect_only',
] as const;
export const IMAGE_QUALITY_TIERS = ['draft', 'standard', 'fine'] as const;
export const IMAGE_RESOLUTION_TIERS = ['1K', '2K', '4K'] as const;
export const IMAGE_PROFILE_SOURCES = [
  'official_api',
  'verified_allowlist',
  'models_dev',
  'openrouter',
  'relay_probe',
  'user_declared',
  'managed_catalog',
] as const;
export const IMAGE_PRICING_UNITS = ['per_image'] as const;

/** image_profile.v2 fields.required: missing or null after the override merge = unusable. */
export const IMAGE_PROFILE_REQUIRED_FIELDS = [
  'imageOutput',
  'operations',
  'route',
  'aspectRatios',
  'sizeParam',
  'resolutions',
  'maxNPerCall',
  'timeoutSeconds',
  'source',
] as const;

/** Closed set of reasons a model has no usable ImageProfile. */
export const IMAGE_PROFILE_REASONS = [
  'missing_required_field',
  'no_image_profile',
  'dangling_profile',
  'model_not_in_catalog',
  'unknown_route',
  'unknown_edit_transport',
  'unknown_size_param',
  'unknown_operation',
  'size_param_not_allowed',
  'edit_transport_not_allowed',
  'edit_transport_without_edit',
  'unknown_source',
  'not_image_output',
  'relay_unmatched',
  'probe_pending_confirmation',
] as const;

/** profileRef reported when a connection-level (user declared / probed) profile applies. */
export const USER_DECLARED_PROFILE_REF = 'user_declared';

export type ImageOperation = (typeof IMAGE_OPERATIONS)[number];
export type ImageRoute = (typeof IMAGE_ROUTES)[number];
export type ImageEditTransport = (typeof IMAGE_EDIT_TRANSPORTS)[number];
export type ImageSizeParam = (typeof IMAGE_SIZE_PARAMS)[number];
export type ImageQualityTier = (typeof IMAGE_QUALITY_TIERS)[number];
export type ImageResolutionTier = (typeof IMAGE_RESOLUTION_TIERS)[number];
export type ImageProfileSource = (typeof IMAGE_PROFILE_SOURCES)[number];
export type ImagePricingUnit = (typeof IMAGE_PRICING_UNITS)[number];
export type ImageProfileReason = (typeof IMAGE_PROFILE_REASONS)[number];

export interface ImageRouteRule {
  readonly allowedEditTransports: readonly ImageEditTransport[];
  readonly allowedSizeParams: readonly ImageSizeParam[];
}

/** image_profile.v2 routes[route] allow tables. */
export const IMAGE_ROUTE_RULES: Readonly<Record<ImageRoute, ImageRouteRule>> = {
  openai_images: {
    allowedEditTransports: ['multipart', 'json_image', 'json_image_url'],
    allowedSizeParams: ['wxh'],
  },
  xai_images: {
    allowedEditTransports: ['json_image_object'],
    allowedSizeParams: ['aspect_resolution'],
  },
  gemini_generate_content: {
    allowedEditTransports: ['inline'],
    allowedSizeParams: ['gemini_image_config'],
  },
  chat_modalities: {
    allowedEditTransports: ['inline'],
    allowedSizeParams: ['chat_image_config'],
  },
  openrouter_images: {
    allowedEditTransports: ['input_references'],
    allowedSizeParams: ['wxh'],
  },
  dashscope_multimodal: {
    allowedEditTransports: ['inline'],
    allowedSizeParams: ['dashscope_wxh'],
  },
  minimax_image_generation: {
    allowedEditTransports: [],
    allowedSizeParams: ['aspect_only'],
  },
};

/**
 * A profile that passed checkImageProfile. Required fields are present (null =
 * missing) with the right JSON type, closed enums / allow tables hold, optional
 * fields that are null or of the wrong JSON type are dropped; unknown fields are
 * passed through untouched.
 */
/** Numeric pixel sub-fields of sizeConstraints that are kept only as positive integers. */
export const IMAGE_SIZE_CONSTRAINT_NUMERIC_FIELDS = [
  'multipleOf',
  'minPixels',
  'maxPixels',
  'maxLongEdge',
] as const;

/**
 * sizeConstraints after narrowing: each numeric sub-field is a positive integer
 * or absent; other sub-fields (e.g. ratioRange) are passed through untouched.
 */
export interface ImageSizeConstraints {
  readonly multipleOf?: number;
  readonly minPixels?: number;
  readonly maxPixels?: number;
  readonly maxLongEdge?: number;
  readonly [field: string]: unknown;
}

export interface ImageProfile {
  readonly imageOutput: true;
  readonly operations: readonly ImageOperation[];
  readonly route: ImageRoute;
  readonly editTransport?: ImageEditTransport;
  readonly maxReferenceImages?: number;
  readonly aspectRatios: readonly string[];
  readonly sizeParam: ImageSizeParam;
  readonly resolutions: Readonly<Partial<Record<ImageResolutionTier, number>>>;
  readonly maxNPerCall: number;
  readonly timeoutSeconds: number;
  readonly source: ImageProfileSource;
  readonly sizeConstraints?: ImageSizeConstraints;
  readonly qualityMap?: Readonly<Partial<Record<ImageQualityTier, string>>>;
  readonly params?: Readonly<Record<string, boolean | null>>;
  readonly nParam?: boolean;
  readonly nativeMultiTurn?: boolean;
  readonly typicalSeconds?: readonly number[];
  readonly pricing?: Readonly<Record<string, unknown>>;
  readonly maxPromptChars?: number;
  readonly verifiedAt?: string;
  readonly resolutionValues?: Readonly<Partial<Record<ImageResolutionTier, string>>>;
}

/** One provider in wire shape; entries are unvalidated JSON. */
export interface ImageProviderSlice {
  readonly models?: Readonly<Record<string, unknown>> | null;
  readonly imageModels?: Readonly<Record<string, unknown>> | null;
}

/** The metadata slice in wire shape; every value is unvalidated JSON. */
export interface ImageMetadataSlice {
  readonly profiles?: { readonly image?: Readonly<Record<string, unknown>> | null } | null;
  readonly providers?: Readonly<Record<string, ImageProviderSlice | null | undefined>> | null;
}

/** Official model the Server alias table maps a relay model id onto. */
export interface ImageOfficialMatch {
  readonly providerKind: string;
  readonly modelId: string;
}

/** Relay connection context for one model. */
export interface ImageRelayContext {
  /** null / missing = the alias table has no match. */
  readonly officialMatch?: ImageOfficialMatch | null;
  /** Present = a paid probe is waiting for the user to confirm. */
  readonly probe?: unknown;
  /** Connection-level profile (user declared or confirmed probe); wins over everything. */
  readonly userDeclared?: unknown;
}

export interface ImageProfileResolution {
  readonly profile: ImageProfile | null;
  /** profiles.image key, USER_DECLARED_PROFILE_REF, or null when unusable. */
  readonly profileRef: string | null;
  readonly reason: ImageProfileReason | null;
  /** The imageProfileOverride shallow-merged over the table entry, if any. */
  readonly appliedOverride: Readonly<Record<string, unknown>> | null;
}

export interface ImageProfileCheck {
  readonly profile: ImageProfile | null;
  readonly reason: ImageProfileReason | null;
}

export interface StudioVisibilityContext {
  readonly connectionUsable: boolean;
  readonly hasBase: boolean;
  readonly referenceCount: number;
}

type JsonRecord = Readonly<Record<string, unknown>>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function ownValue(record: unknown, key: string): unknown {
  if (!isRecord(record) || !Object.prototype.hasOwnProperty.call(record, key)) return undefined;
  return record[key];
}

function isOneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === 'string' && (values as readonly string[]).includes(value);
}

function failedCheck(reason: ImageProfileReason): ImageProfileCheck {
  return { profile: null, reason };
}

function failedResolution(reason: ImageProfileReason): ImageProfileResolution {
  return { profile: null, profileRef: null, reason, appliedOverride: null };
}

type JsonTypeCheck = (value: unknown) => boolean;

const isNumber: JsonTypeCheck = (value) => typeof value === 'number';
/** JSON integer; 2.0 decodes to 2 and counts as an integer. */
const isInteger: JsonTypeCheck = (value) => Number.isInteger(value);
const isBoolean: JsonTypeCheck = (value) => typeof value === 'boolean';
const isString: JsonTypeCheck = (value) => typeof value === 'string';
const isArrayOf = (element: JsonTypeCheck): JsonTypeCheck =>
  (value) => Array.isArray(value) && value.every(element);
const isRecordOf = (element: JsonTypeCheck): JsonTypeCheck =>
  (value) => isRecord(value) && Object.values(value).every(element);

/** sizeParam values whose wire mapping needs a conditionally required field. */
const SIZE_PARAMS_REQUIRING_SIZE_CONSTRAINTS: readonly string[] = ['wxh', 'dashscope_wxh'];
const SIZE_PARAMS_REQUIRING_RESOLUTION_VALUES: readonly string[] = [
  'aspect_resolution',
  'gemini_image_config',
];

/**
 * Optional ImageProfile fields and their JSON types (element types included). A
 * value of the wrong type (or null, or with one wrong element) is treated as
 * absent and the whole field is dropped from the narrowed profile; the profile
 * itself stays usable. editTransport is validated by the rule order, so
 * only its null form is dropped here.
 */
const OPTIONAL_FIELD_TYPES: Readonly<Record<string, JsonTypeCheck>> = {
  editTransport: isString,
  maxReferenceImages: isInteger,
  sizeConstraints: isRecord,
  qualityMap: isRecord,
  params: isRecord,
  nParam: isBoolean,
  nativeMultiTurn: isBoolean,
  typicalSeconds: isArrayOf(isNumber),
  pricing: isRecord,
  maxPromptChars: isInteger,
  verifiedAt: isString,
  resolutionValues: isRecord,
};

/** Keeps only the entries whose value is a non-empty string (a bad entry disables only its tier). */
function narrowStringEntries(record: JsonRecord): Record<string, string> {
  const kept: Record<string, string> = {};
  for (const [key, value] of Object.entries(record)) {
    if (typeof value === 'string' && value !== '') kept[key] = value;
  }
  return kept;
}

/** Drops numeric sizeConstraints sub-fields that are not positive integers. */
function narrowSizeConstraints(record: JsonRecord): ImageSizeConstraints {
  const kept: Record<string, unknown> = { ...record };
  for (const field of IMAGE_SIZE_CONSTRAINT_NUMERIC_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(kept, field)) continue;
    const value = kept[field];
    if (!(Number.isInteger(value) && (value as number) > 0)) delete kept[field];
  }
  return kept;
}

/**
 * Copies a validated profile, dropping optional fields that are null or of the
 * wrong JSON type; qualityMap / resolutionValues are narrowed per entry and
 * sizeConstraints per sub-field so the ImageProfile type holds at runtime.
 */
function narrowImageProfile(raw: JsonRecord): ImageProfile {
  const narrowed: Record<string, unknown> = { ...raw };
  for (const [field, hasType] of Object.entries(OPTIONAL_FIELD_TYPES)) {
    if (Object.prototype.hasOwnProperty.call(narrowed, field) && !hasType(narrowed[field])) {
      delete narrowed[field];
    }
  }
  for (const field of ['qualityMap', 'resolutionValues'] as const) {
    const value = narrowed[field];
    if (isRecord(value)) narrowed[field] = narrowStringEntries(value);
  }
  if (isRecord(narrowed.sizeConstraints)) {
    narrowed.sizeConstraints = narrowSizeConstraints(narrowed.sizeConstraints);
  }
  return narrowed as unknown as ImageProfile;
}

/** Validates an unvalidated (already merged) profile in the image_profile.v2 rule order. */
export function checkImageProfile(raw: unknown): ImageProfileCheck {
  if (!isRecord(raw)) return failedCheck('missing_required_field');
  for (const field of IMAGE_PROFILE_REQUIRED_FIELDS) {
    if (ownValue(raw, field) == null) return failedCheck('missing_required_field');
  }
  // These required fields have no reason of their own: a wrong JSON type (element
  // types included) counts as missing.
  if (
    !isArrayOf(isString)(raw.aspectRatios)
    || !isRecordOf(isInteger)(raw.resolutions)
    || !isInteger(raw.maxNPerCall)
    || !isInteger(raw.timeoutSeconds)
  ) {
    return failedCheck('missing_required_field');
  }
  // image_profile.v2 conditional requirements: the wire size mapping depends on them.
  if (
    (SIZE_PARAMS_REQUIRING_SIZE_CONSTRAINTS.includes(raw.sizeParam as string)
      && !isRecord(raw.sizeConstraints))
    || (SIZE_PARAMS_REQUIRING_RESOLUTION_VALUES.includes(raw.sizeParam as string)
      && !isRecord(raw.resolutionValues))
  ) {
    return failedCheck('missing_required_field');
  }
  if (raw.imageOutput !== true) return failedCheck('not_image_output');
  const route = raw.route;
  if (!isOneOf(IMAGE_ROUTES, route)) return failedCheck('unknown_route');
  const sizeParam = raw.sizeParam;
  if (!isOneOf(IMAGE_SIZE_PARAMS, sizeParam)) return failedCheck('unknown_size_param');
  const operations = raw.operations;
  if (
    !Array.isArray(operations)
    || operations.length === 0
    || !operations.every((operation) => isOneOf(IMAGE_OPERATIONS, operation))
  ) {
    return failedCheck('unknown_operation');
  }
  const rule = IMAGE_ROUTE_RULES[route];
  if (!rule.allowedSizeParams.includes(sizeParam)) return failedCheck('size_param_not_allowed');
  const editTransport = ownValue(raw, 'editTransport');
  if (operations.includes('edit')) {
    if (!isOneOf(IMAGE_EDIT_TRANSPORTS, editTransport)) return failedCheck('unknown_edit_transport');
    if (!rule.allowedEditTransports.includes(editTransport)) {
      return failedCheck('edit_transport_not_allowed');
    }
  } else if (editTransport != null) {
    return failedCheck('edit_transport_without_edit');
  }
  if (!isOneOf(IMAGE_PROFILE_SOURCES, raw.source)) return failedCheck('unknown_source');
  return { profile: narrowImageProfile(raw), reason: null };
}

/**
 * Looks a wire model id up under one provider kind; models wins over imageModels.
 * A null models entry is the same as an absent one, so imageModels is consulted.
 */
function resolveFromCatalog(
  slice: ImageMetadataSlice,
  providerKind: string,
  modelId: string,
): ImageProfileResolution {
  const provider = ownValue(slice.providers, providerKind);
  const fromModels = ownValue(isRecord(provider) ? provider.models : undefined, modelId);
  const entry = fromModels != null
    ? fromModels
    : ownValue(isRecord(provider) ? provider.imageModels : undefined, modelId);
  if (entry == null) return failedResolution('model_not_in_catalog');

  const profileRef = ownValue(entry, 'imageProfile');
  if (typeof profileRef !== 'string' || profileRef === '') {
    return failedResolution('no_image_profile');
  }
  const tableEntry = ownValue(isRecord(slice.profiles) ? slice.profiles.image : undefined, profileRef);
  // A table entry that is not a JSON object cannot be a profile: same as a missing ref.
  if (!isRecord(tableEntry)) return failedResolution('dangling_profile');

  // A non-object override is ignored, never merged.
  const rawOverride = ownValue(entry, 'imageProfileOverride');
  const override = isRecord(rawOverride) ? rawOverride : null;
  const merged = override ? { ...tableEntry, ...override } : tableEntry;
  const checked = checkImageProfile(merged);
  if (!checked.profile) return failedResolution(checked.reason ?? 'missing_required_field');
  return { profile: checked.profile, profileRef, reason: null, appliedOverride: override };
}

function readOfficialMatch(value: unknown): ImageOfficialMatch | null {
  if (!isRecord(value)) return null;
  const { providerKind, modelId } = value;
  if (typeof providerKind !== 'string' || typeof modelId !== 'string') return null;
  return { providerKind, modelId };
}

/**
 * Resolves which ImageProfile applies to one model. Without a relay context the
 * model is looked up under providerKind. With one: a user declared / probed
 * profile is the only thing validated; otherwise the Server officialMatch is
 * looked up, and an unmatched relay model waits for a probe or stays unmatched.
 */
export function resolveImageProfile(
  slice: ImageMetadataSlice,
  providerKind: string | null | undefined,
  modelId: string,
  relay?: ImageRelayContext | null,
): ImageProfileResolution {
  if (relay) {
    if (relay.userDeclared != null) {
      const checked = checkImageProfile(relay.userDeclared);
      if (!checked.profile) return failedResolution(checked.reason ?? 'missing_required_field');
      return {
        profile: checked.profile,
        profileRef: USER_DECLARED_PROFILE_REF,
        reason: null,
        appliedOverride: null,
      };
    }
    const match = readOfficialMatch(relay.officialMatch);
    if (!match) {
      // An empty string probe is the same as an absent one.
      const hasProbe = relay.probe != null && relay.probe !== '';
      return failedResolution(hasProbe ? 'probe_pending_confirmation' : 'relay_unmatched');
    }
    return resolveFromCatalog(slice, match.providerKind, match.modelId);
  }
  if (typeof providerKind !== 'string') return failedResolution('model_not_in_catalog');
  return resolveFromCatalog(slice, providerKind, modelId);
}

/**
 * Whether a resolved model is listed in the studio model list. Image count is
 * base (0/1) + references: with none the model must generate; otherwise it must
 * edit and accept that many images (maxReferenceImages, default 1).
 */
export function visibleInStudio(
  profile: ImageProfile | null,
  context: StudioVisibilityContext,
): boolean {
  if (!profile || profile.imageOutput !== true || !context.connectionUsable) return false;
  const imageCount = (context.hasBase ? 1 : 0) + context.referenceCount;
  if (imageCount === 0) return profile.operations.includes('generate');
  return profile.operations.includes('edit') && imageCount <= (profile.maxReferenceImages ?? 1);
}

/**
 * Builds the wire-shape ImageProfile slice from a decoded metadata response
 * (lean, full, or split assembled through assembleLeanFromSplit): profiles.image
 * plus each provider's models / imageModels, passed through unvalidated so that
 * resolveImageProfile applies the only validation.
 */
export function imageMetadataSliceFromMetadata(metadata: MetadataResponse): ImageMetadataSlice {
  const image = ownValue(metadata.profiles, 'image');
  const providers: Record<string, ImageProviderSlice> = {};
  if (isRecord(metadata.providers)) {
    for (const [providerKind, provider] of Object.entries(metadata.providers)) {
      if (!isRecord(provider)) continue;
      const models = ownValue(provider, 'models');
      const imageModels = ownValue(provider, 'imageModels');
      providers[providerKind] = {
        ...(isRecord(models) ? { models } : {}),
        ...(isRecord(imageModels) ? { imageModels } : {}),
      };
    }
  }
  return {
    profiles: isRecord(image) ? { image } : null,
    providers,
  };
}

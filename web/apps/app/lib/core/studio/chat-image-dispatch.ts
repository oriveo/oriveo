/**
 * Chat image dispatch: decides whether a chat image send moves to the studio
 * pipeline and maps studio error kinds onto chat error kinds.
 * Fixture: chat_image_dispatch.v1.
 */
import type { ImageErrorKind } from './image-error';
import type { ImageOperation, ImageProfile, ImageRoute } from './image-profile';

/** Routes whose chat image sends run on the studio executor (spec.studioRoutes). */
export const STUDIO_ROUTES: readonly ImageRoute[] = [
  'openai_images',
  'xai_images',
  'openrouter_images',
  'minimax_image_generation',
  'dashscope_multimodal',
];

/** Provider kinds that always keep the legacy chat image path (spec.legacyProviderKinds). */
export const LEGACY_PROVIDER_KINDS: readonly string[] = ['relay'];

/** Fixed parameters of a chat image send (spec.chatParams). */
export const CHAT_IMAGE_PARAMS = {
  aspect: '1:1',
  resolution: '1K',
  quality: 'standard',
  n: 1,
} as const;

/** Every studio error kind that ends a chat send as a failure ('partial' completes). */
export type ChatImageFailureKind = Exclude<ImageErrorKind, 'partial'>;

/** Chat failure categories of spec.errorMap; each end maps them onto its own chat error type. */
export type ChatImageErrorCategory =
  | 'upstream_400'
  | 'invalid_key'
  | 'quota_exceeded'
  | 'rate_limited'
  | 'model_unavailable'
  | 'upstream_502'
  | 'upstream_507'
  | 'network'
  | 'empty_response';

/** Studio error kind -> chat failure category (spec.errorMap). */
export const CHAT_IMAGE_ERROR_MAP: Readonly<Record<ChatImageFailureKind, ChatImageErrorCategory>> = {
  refused: 'upstream_400',
  auth: 'invalid_key',
  insufficient_balance: 'quota_exceeded',
  rate_limited: 'rate_limited',
  invalid_param: 'upstream_400',
  model_unavailable: 'model_unavailable',
  upstream_error: 'upstream_502',
  timeout: 'network',
  network: 'network',
  decode_failed: 'empty_response',
  storage_full: 'upstream_507',
};

/** Chat failure category -> Web chat error kind (see chat-stream-utils mapErrorKindKey). */
const CATEGORY_CHAT_KINDS: Readonly<Record<ChatImageErrorCategory, string>> = {
  upstream_400: 'badRequest',
  invalid_key: 'invalidKey',
  quota_exceeded: 'quotaExceeded',
  rate_limited: 'rateLimited',
  model_unavailable: 'unavailable',
  upstream_502: 'upstream',
  upstream_507: 'upstream',
  network: 'network',
  empty_response: 'emptyResponse',
};

export interface ChatImageAttachment {
  readonly id: string;
  readonly mime: string;
  /** true = the attachment's bytes are available locally. */
  readonly hasBytes: boolean;
}

export interface ChatImageDispatchInput {
  readonly providerKind: string;
  /** The legacy chat gate already decided this send generates an image. */
  readonly legacyImageDispatch: boolean;
  readonly profile: ImageProfile | null;
  /** Image attachments of this user message, in message order. */
  readonly attachments: readonly ChatImageAttachment[];
}

export interface ChatImageDispatchImage {
  readonly attachmentId: string;
  readonly slot: number;
  readonly role: 'base' | 'element';
}

export type ChatImageDispatch =
  | { readonly path: 'legacy' }
  | {
      readonly path: 'studio';
      readonly operation: ImageOperation;
      readonly images: readonly ChatImageDispatchImage[];
    };

const LEGACY: ChatImageDispatch = { path: 'legacy' };

export function decideChatImageDispatch(input: ChatImageDispatchInput): ChatImageDispatch {
  const { profile } = input;
  if (!input.legacyImageDispatch) return LEGACY;
  if (LEGACY_PROVIDER_KINDS.includes(input.providerKind)) return LEGACY;
  if (!profile || !STUDIO_ROUTES.includes(profile.route)) return LEGACY;

  if (!profile.operations.includes('edit')) {
    return { path: 'studio', operation: 'generate', images: [] };
  }
  // Missing or non-positive maxReferenceImages caps at one image, same as the reference
  // implementation and the other ends.
  const max = profile.maxReferenceImages;
  const limit = typeof max === 'number' && Number.isInteger(max) && max > 0 ? max : 1;
  const images = input.attachments
    .filter((attachment) => attachment.hasBytes)
    .slice(0, limit)
    .map((attachment, index): ChatImageDispatchImage => ({
      attachmentId: attachment.id,
      slot: index + 1,
      role: index === 0 ? 'base' : 'element',
    }));
  if (images.length === 0) return { path: 'studio', operation: 'generate', images: [] };
  return { path: 'studio', operation: 'edit', images };
}

export function chatImageErrorCategory(kind: ChatImageFailureKind): ChatImageErrorCategory {
  return CHAT_IMAGE_ERROR_MAP[kind];
}

/** Web chat error kind for a failed studio result; message is the result message. */
export function chatImageErrorKind(kind: ChatImageFailureKind, message: string | null): string {
  if (kind === 'refused' && message === 'moderation_blocked') return 'moderation';
  if (kind === 'upstream_error' && message === 'moderation_unavailable') return 'moderation';
  return CATEGORY_CHAT_KINDS[chatImageErrorCategory(kind)];
}

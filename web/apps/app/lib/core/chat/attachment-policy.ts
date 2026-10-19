import type { AIModel, Attachment, Provider } from '@oriveo/shared';
import {
  type ProviderAttachmentSupport,
  getProviderAttachmentSupport,
  getRelayRuntimeConfig,
} from '../metadata/metadata-client';
import { resolveRelayAttachmentSupport } from '../providers/relay-runtime-support';
import { providerFormOf } from '../capability/truth/provider-form';
import { relayCapabilityEvidenceIdentity, resolveModelCapabilityEvidence } from './capability-evidence';
import { relayFirstSendTransport } from '../providers/relay-first-send-transport';
import { isRelayNegativeCached } from './relay-negative-cache';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from './stream-options';
import { attachmentAcceptExtensions } from '../attachments/attachment-file-types';
import {
  TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER,
  attachmentTransportProfile,
  fallbackTextAttachmentTransport,
  relayAttachmentTransport,
  type AttachmentTransport,
} from '@oriveo/core/providers/attachment-transport';

export interface AttachmentCapabilities {
  supportsImage: boolean;
  supportsVideo: boolean;
  supportsFile: boolean;
  supportsAttachment: boolean;
}

/**
 * Computes the attachment capabilities of a model and provider combination.
 * Matches the per-field checks InputComposer and ChatView used to do, one for one.
 */
export function resolveAttachmentCapabilities(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
  providerAttachmentSupport: ProviderAttachmentSupport | null | undefined,
): AttachmentCapabilities {
  const attachmentIntentOptions = provider && model
    ? buildProviderStreamOptions(
        provider,
        buildStreamOptionsFromIntent(model, 'automatic', false),
        model,
      )
    : undefined;
  const modelSupportsImage = Boolean(provider && model
    && modelImageEntryVisible(provider, model, attachmentIntentOptions));
  const modelSupportsVideo = model?.capabilities?.includes('video') ?? false;
  const providerImage = providerAttachmentSupport?.image ?? false;
  const providerVideo = providerAttachmentSupport?.video ?? false;
  const providerNativeFile = providerAttachmentSupport?.nativeFile ?? false;
  const providerTextInline = providerAttachmentSupport?.textFileInline ?? false;

  const supportsImage = modelSupportsImage && providerImage;
  const supportsVideo = modelSupportsVideo && providerVideo;
  // Does not rely on model.capabilities.includes('file'): once the BYOK client extracts
  // locally, every provider with textFileInline=true accepts text attachments.
  const supportsFile = providerTextInline || providerNativeFile;
  const supportsAttachment = supportsImage || supportsVideo || supportsFile;

  return { supportsImage, supportsVideo, supportsFile, supportsAttachment };
}

/**
 * The model-side image entry. Relay: an unknown image capability is still shown, hidden only by negative
 * evidence (an override or an engine declaring false) or an unexpired image negative cache for the key; only an
 * override of true beats the negative cache; a missing connection identity still fails closed.
 * Every other form requires supported. Whether the protocol envelope accepts images is ANDed in by the caller.
 */
function modelImageEntryVisible(
  provider: Provider,
  model: AIModel,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): boolean {
  if (providerFormOf(provider) !== 'relay') {
    return resolveModelCapabilityEvidence({ key: 'vision_input', provider, model, streamOptions }).support === 'supported';
  }
  const relayIdentity = relayCapabilityEvidenceIdentity(provider, model, streamOptions);
  if (!relayIdentity) return false;
  // Only an override of true beats the image negative cache; other positive evidence (inherited / declared) stays hidden while the cache is live.
  if (model.relayCapabilityOverrides?.image?.value === true) return true;
  const support = resolveModelCapabilityEvidence({
    key: 'vision_input', provider, model, streamOptions, relayIdentity,
  }).support;
  if (support === 'unsupported') return false;
  return !isRelayNegativeCached({
    connectionId: provider.id,
    modelId: model.id,
    // The same protocol as the send-side write key (the first-send protocol).
    transport: relayFirstSendTransport(provider, model),
    kind: 'image',
  });
}

/** The placeholder for this route when the image gate strips an image: the route's declared placeholder if it has one, otherwise the generic text-only route placeholder. */
function imageGatePlaceholder(
  provider: Provider,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): string {
  const transport: AttachmentTransport = provider.kind === 'relay'
    ? relayAttachmentTransport(streamOptions?.relayTransport)
    : fallbackTextAttachmentTransport(provider.kind);
  return attachmentTransportProfile(transport).imagePlaceholderText ?? TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER;
}

/**
 * Strips images from history before sending, by the model's image rule: the same criterion as the image entry
 * (Relay sends unknown-image models as is and strips only on negative evidence or an image negative cache;
 * every other form requires supported). Shared by the four send paths (normal / continue / MCP / library);
 * `streamOptions` is the one built with this turn's attachment rule.
 * Each stripped image is replaced by a placeholder line at the end of the text, so a user turn carrying only images does not become empty.
 */
export function withoutUnreceivableImages<T extends { text: string; attachments?: Attachment[] }>(
  messages: T[],
  provider: Provider,
  model: AIModel,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): T[] {
  if (modelImageEntryVisible(provider, model, streamOptions)) return messages;
  const placeholder = imageGatePlaceholder(provider, streamOptions);
  return messages.map((message) => {
    const images = message.attachments?.filter((attachment) => attachment.kind === 'image').length ?? 0;
    if (images === 0) return message;
    const kept = message.attachments?.filter((attachment) => attachment.kind !== 'image') ?? [];
    const lines = Array.from({ length: images }, () => placeholder);
    return {
      ...message,
      text: (message.text.length > 0 ? [message.text, ...lines] : lines).join('\n'),
      attachments: kept.length > 0 ? kept : undefined,
    };
  });
}

/**
 * Whether a single dropped or pasted attachment is acceptable for the current model and provider.
 * Keeps ChatView's rule: images check the image capability, everything else, video and files included, checks the file capability.
 */
export function canAcceptDroppedAttachment(
  attachment: Attachment,
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
  providerAttachmentSupport: ProviderAttachmentSupport | null | undefined,
): boolean {
  const { supportsImage, supportsFile } = resolveAttachmentCapabilities(
    provider,
    model,
    providerAttachmentSupport,
  );
  return attachment.kind === 'image' ? supportsImage : supportsFile;
}

/**
 * Builds the accept attribute of the file input, matching InputComposer's rule exactly, including that PDF is only allowed with nativeFile.
 */
export function buildAcceptAttribute(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
  providerAttachmentSupport: ProviderAttachmentSupport | null | undefined,
): string {
  const { supportsImage, supportsFile } = resolveAttachmentCapabilities(
    provider,
    model,
    providerAttachmentSupport,
  );
  const providerNativeFile = providerAttachmentSupport?.nativeFile ?? false;
  // nativeFile means native PDF upload is supported (OpenAI, Anthropic, Gemini and other direct connections); textFileInline covers text formats only.
  // The extensions come from the extractor's own type list (attachment extraction spec section 2); no second copy is kept.
  const fileExts = attachmentAcceptExtensions({ includePdf: providerNativeFile });
  return supportsImage && supportsFile
    ? `image/*,${fileExts}`
    : supportsImage
      ? 'image/*'
      : fileExts;
}

/** What the current connection supports for each attachment type (the same resolution ChatView computes for the input box). */
export function resolveProviderAttachmentSupport(
  provider: Provider,
  model: AIModel | null | undefined,
): ProviderAttachmentSupport | null {
  if (provider.kind === 'relay') return resolveRelayAttachmentSupport(provider, getRelayRuntimeConfig(), model);
  return getProviderAttachmentSupport(provider.kind);
}

/**
 * Filters this turn's user-message attachments by the current model's capabilities, using the same rule
 * the input box applies when it accepts attachments (`resolveAttachmentCapabilities`: images, videos and
 * files are each judged by their own capability).
 *
 * Attachments of a plain send already passed this gate when they entered the input box. A retry or an
 * edited resend carries the original message's attachments, and the model back then may have been a
 * different one, so they go through the current model once more before sending. Only the outbound content
 * changes; the attachments in the message record stay as they are, and earlier history messages are untouched.
 */
export function filterCurrentTurnAttachments<T extends { id: string; attachments?: Attachment[] }>(
  messages: T[],
  currentTurnId: string,
  provider: Provider,
  model: AIModel,
  /** Resolved from the current connection by default; tests can pass it directly. */
  providerAttachmentSupport?: ProviderAttachmentSupport | null,
): T[] {
  const turn = messages.find((message) => message.id === currentTurnId);
  if (!turn?.attachments?.length) return messages;
  const support = providerAttachmentSupport === undefined
    ? resolveProviderAttachmentSupport(provider, model)
    : providerAttachmentSupport;
  // A support table that has not loaded yet means "unknown", not "unsupported": leave the attachments alone and let the other gates at send time decide.
  if (!support) return messages;
  const capabilities = resolveAttachmentCapabilities(provider, model, support);
  const kept = turn.attachments.filter((attachment) => attachment.kind === 'image'
    ? capabilities.supportsImage
    : attachment.kind === 'video' ? capabilities.supportsVideo : capabilities.supportsFile);
  if (kept.length === turn.attachments.length) return messages;
  return messages.map((message) => message === turn
    ? { ...message, attachments: kept.length > 0 ? kept : undefined }
    : message);
}

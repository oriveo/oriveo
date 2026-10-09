import type { AIModel, Attachment, Provider } from '@oriveo/shared';
import {
  type ProviderAttachmentSupport,
  getProviderAttachmentSupport,
  getRelayRuntimeConfig,
} from '../metadata/metadata-client';
import { resolveRelayAttachmentSupport } from '../providers/relay-runtime-support';
import { resolveModelCapabilityEvidence } from './capability-evidence';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from './stream-options';

// Text attachment extensions: providers with textFileInline=true receive these after local extraction.
const TEXT_FILE_EXTS =
  '.txt,.csv,.md,.json,.xml,.html,.css,.js,.ts,.jsx,.tsx,.py,.rb,.go,.rs,.java,.kt,.swift,.c,.cpp,.h,.hpp,.sh,.yaml,.yml,.toml,.ini,.env,.log,.sql,.graphql,.proto';
const OFFICE_FILE_EXTS = '.docx,.xlsx,.pptx,.odt,.ods,.odp,.rtf';

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
  const modelSupportsImage = Boolean(provider && model &&
    resolveModelCapabilityEvidence({
      key: 'vision_input', provider, model, streamOptions: attachmentIntentOptions,
    }).support === 'supported');
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
  const fileExts = providerNativeFile
    ? `.pdf,${TEXT_FILE_EXTS},${OFFICE_FILE_EXTS}`
    : `${TEXT_FILE_EXTS},${OFFICE_FILE_EXTS}`;
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
  if (provider.kind === 'relay') return resolveRelayAttachmentSupport(provider, getRelayRuntimeConfig());
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

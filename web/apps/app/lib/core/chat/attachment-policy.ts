import type { AIModel, Attachment, Provider } from '@oriveo/shared';
import type { ProviderAttachmentSupport } from '../metadata/metadata-client';
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

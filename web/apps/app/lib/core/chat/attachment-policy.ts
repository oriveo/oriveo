import type { AIModel, Attachment, Provider } from '@oriveo/shared';
import type { OmittedImagePlaceholders } from '../../utils/chat-stream-utils';
import {
  type ProviderAttachmentSupport,
  getProviderAttachmentSupport,
  getRelayRuntimeConfig,
} from '../metadata/metadata-client';
import { resolveRelayAttachmentSupport } from '../providers/relay-runtime-support';
import { providerFormOf } from '../capability/truth/provider-form';
import { resolveInputCapabilityProjections } from '../capability/truth/input-truth-adapter';
import type { ModelOptionsVisionFacts } from './model-options-panel-model';
import type {
  InputCapabilityDisabledReason,
  InputCapabilityProjection,
} from '@oriveo/core/providers/capability-evidence-facade';
import { effectiveCapabilityTransport } from './capability-evidence';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from './stream-options';
import { attachmentAcceptExtensions } from '../attachments/attachment-file-types';
import {
  TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER,
  TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER,
  attachmentTransportProfile,
  dispatchedAttachmentTransport,
  fallbackTextAttachmentTransport,
  relayAttachmentTransport,
  type AttachmentTransport,
  type OutboundWire,
} from '@oriveo/core/providers/attachment-transport';

export interface AttachmentCapabilities {
  supportsImage: boolean;
  supportsVideo: boolean;
  /** Either text-type files (extracted by the client and inlined) or native files can be accepted. */
  supportsFile: boolean;
  /** Native files (PDF): read from the file_input projection; text-type attachments are not affected by it. */
  supportsNativeFile: boolean;
  supportsAttachment: boolean;
  /** Why each media entry is closed; null when the entry is open, or for subscriptions (legacy rule). */
  disabledReasons: Record<AttachmentMedia, InputCapabilityDisabledReason | null>;
  /** The projection of each media; null for subscriptions / a missing provider. The first-attachment hint reads its hint. */
  projections: Record<AttachmentMedia, InputCapabilityProjection | null>;
}

export type AttachmentMedia = 'image' | 'file' | 'video';

/** Reason -> localization key segment (`capability.input.disabled.<segment>.<media>`). */
const DISABLED_REASON_MESSAGE_SEGMENT: Readonly<Record<InputCapabilityDisabledReason, string>> = {
  'disabled.model_absent': 'modelAbsent',
  'disabled.wire_not_implemented': 'wireNotImplemented',
  'disabled.kill_switch': 'killSwitch',
  'disabled.rejected_recently': 'rejectedRecently',
  'disabled.user_removed': 'userRemoved',
};

/** Localization key for why an entry is disabled (relative to the `capability.input` namespace). */
export function attachmentDisabledMessageKey(reason: InputCapabilityDisabledReason, media: AttachmentMedia): string {
  return `disabled.${DISABLED_REASON_MESSAGE_SEGMENT[reason]}.${media}`;
}

/**
 * The reason key written on the button when the whole attachment entry is closed (relative to
 * `capability.input`): the first media with a reason, in the order image -> file -> video; null when the
 * entry is open or there is no projection reason.
 */
export function attachmentEntryDisabledMessageKey(capabilities: AttachmentCapabilities): string | null {
  if (capabilities.supportsAttachment) return null;
  for (const media of ['image', 'file', 'video'] as const) {
    const reason = capabilities.disabledReasons[media];
    if (reason) return attachmentDisabledMessageKey(reason, media);
  }
  return null;
}

/** Groups an attachment by media: image and video are one class each; PDF is a native file; every other file is text-type (extracted by the client). */
export function attachmentMediaOf(attachment: Pick<Attachment, 'kind' | 'fileName' | 'mimeType'>): AttachmentMedia | 'text' {
  if (attachment.kind === 'image') return 'image';
  if (attachment.kind === 'video') return 'video';
  return isNativeFileAttachment(attachment) ? 'file' : 'text';
}

function isNativeFileAttachment(attachment: Pick<Attachment, 'fileName' | 'mimeType'>): boolean {
  return attachment.mimeType === 'application/pdf' || /\.pdf$/i.test(attachment.fileName ?? '');
}

/** Whether a single attachment can be accepted; when not, gives the reason of its media (null when there is no projection reason). */
export function attachmentAcceptance(
  attachment: Pick<Attachment, 'kind' | 'fileName' | 'mimeType'>,
  capabilities: AttachmentCapabilities,
): { accepted: true; media: AttachmentMedia | 'text' } | { accepted: false; media: AttachmentMedia | 'text'; reason: InputCapabilityDisabledReason | null } {
  const media = attachmentMediaOf(attachment);
  const accepted = media === 'image'
    ? capabilities.supportsImage
    : media === 'video'
      ? capabilities.supportsVideo
      : media === 'file'
        ? capabilities.supportsNativeFile
        : capabilities.supportsFile;
  if (accepted) return { accepted, media };
  return { accepted, media, reason: media === 'text' ? null : capabilities.disabledReasons[media] };
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
  const projections = provider && model
    ? resolveInputCapabilityProjections(provider, model, attachmentIntentOptions, {
        // A missing support table / missing entry is not a rejection (null); video does not read the envelope.
        relayEnvelopeImage: providerAttachmentSupport?.image ?? null,
        relayEnvelopeNativeFile: providerAttachmentSupport?.nativeFile ?? null,
      })
    : null;
  const providerTextInline = providerAttachmentSupport?.textFileInline ?? false;

  // Every form (subscriptions included) goes by the projection only (auto / unknown both open the entry); with no provider / model everything is closed.
  const supportsImage = projections?.vision_input.editable ?? false;
  const supportsVideo = projections?.video_input.editable ?? false;
  const supportsNativeFile = projections?.file_input.editable ?? false;
  // Does not rely on model.capabilities.includes('file'): once the BYOK client extracts
  // locally, every provider with textFileInline=true accepts text attachments; file_input only governs native files.
  const supportsFile = providerTextInline || supportsNativeFile;
  const supportsAttachment = supportsImage || supportsVideo || supportsFile;

  // With no provider / model the entry reports that the model lacks the capability.
  const reasonOf = (projection: InputCapabilityProjection | undefined, open: boolean): InputCapabilityDisabledReason | null => {
    if (open) return null;
    if (!provider || !model) return 'disabled.model_absent';
    return projection?.disabledReason ?? null;
  };

  return {
    supportsImage,
    supportsVideo,
    supportsFile,
    supportsNativeFile,
    supportsAttachment,
    disabledReasons: {
      image: reasonOf(projections?.vision_input, supportsImage),
      file: reasonOf(projections?.file_input, supportsNativeFile),
      video: reasonOf(projections?.video_input, supportsVideo),
    },
    projections: {
      image: projections?.vision_input ?? null,
      file: projections?.file_input ?? null,
      video: projections?.video_input ?? null,
    },
  };
}

/**
 * Facts for the vision card (model options panel, model library rows), read from the vision projection:
 * entry visible = editable; no positive evidence = the projection is not visible (unknown, the
 * first-attachment hint tier).
 */
export function visionCardFacts(
  provider: Provider,
  model: AIModel,
  providerAttachmentSupport: ProviderAttachmentSupport | null | undefined,
): ModelOptionsVisionFacts {
  const capabilities = resolveAttachmentCapabilities(provider, model, providerAttachmentSupport);
  const projection = capabilities.projections.image;
  return {
    entryVisible: capabilities.supportsImage,
    isRelayForm: providerFormOf(provider) === 'relay',
    noPositiveEvidence: projection ? !projection.visible : false,
    ...(projection
      ? { projection: { visible: projection.visible, editable: projection.editable, disabledReason: projection.disabledReason } }
      : {}),
  };
}

/** Normalized line (`effectiveCapabilityTransport`) -> outbound wire; unrecognized lines have none. */
const OUTBOUND_WIRE_BY_TRANSPORT: Readonly<Record<string, OutboundWire>> = {
  openai_chat: 'openai_chat',
  openai_responses: 'openai_responses',
  anthropic_messages: 'anthropic_messages',
  gemini_generate_content: 'gemini_generate',
  gemini_interactions: 'gemini_interactions',
};

/** The placeholder for this line when the image gate strips an image: the placeholder declared by the line actually used for outbound, otherwise the generic text-only line placeholder. */
function imageGatePlaceholder(
  provider: Provider,
  model: AIModel,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): string {
  return attachmentTransportProfile(imageGateTransport(provider, model, streamOptions)).imagePlaceholderText
    ?? TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER;
}

/** The placeholder for this line when the video gate strips a video: the video placeholder declared by the line, otherwise the generic text-only line video placeholder. */
function videoGatePlaceholder(
  provider: Provider,
  model: AIModel,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): string {
  return attachmentTransportProfile(imageGateTransport(provider, model, streamOptions)).videoPlaceholderText
    ?? TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER;
}

function imageGateTransport(
  provider: Provider,
  model: AIModel,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): AttachmentTransport {
  if (providerFormOf(provider) === 'relay') return relayAttachmentTransport(streamOptions?.relayTransport);
  const wire = OUTBOUND_WIRE_BY_TRANSPORT[effectiveCapabilityTransport(provider, model, undefined, streamOptions)];
  return (wire && dispatchedAttachmentTransport(provider.kind, wire)) ?? fallbackTextAttachmentTransport(provider.kind);
}

/**
 * Strips images from history before sending, by the model's image rule: official and Relay connections read
 * the outbound of the input capability projection (auto / unknown send the real image as is, a placeholder is
 * written only when the projection says it cannot be sent; subscriptions also read the projection, and the
 * placeholder is chosen by line). Shared by the four send paths (normal / continue / MCP / library);
 * `streamOptions` is the one built with this turn's attachment rule.
 * Each stripped image is replaced by a placeholder line after a blank line at the end of the text ('\n\n', the
 * same as the video placeholder and the other platforms), so a user turn carrying only images does not become
 * empty (normalization, budgeting and cleanup all still see this turn);
 * the lines are also carried on `omittedImagePlaceholders`, from which `buildChatHistory` moves them after all
 * parts of that turn (text, file blocks), matching the "text -> file blocks -> placeholders" order of the
 * attachment delivery golden.
 */
export function withoutUnreceivableImages<T extends { text: string; attachments?: Attachment[] }>(
  messages: T[],
  provider: Provider,
  model: AIModel,
  streamOptions: ReturnType<typeof buildProviderStreamOptions> | undefined,
): T[] {
  const receivable = resolveInputCapabilityProjections(provider, model, streamOptions).vision_input.outbound === 'native_part';
  if (receivable) return messages;
  const placeholder = imageGatePlaceholder(provider, model, streamOptions);
  return messages.map((message) => {
    const images = message.attachments?.filter((attachment) => attachment.kind === 'image').length ?? 0;
    if (images === 0) return message;
    const kept = message.attachments?.filter((attachment) => attachment.kind !== 'image') ?? [];
    const lines = Array.from({ length: images }, () => placeholder);
    const carried: T & OmittedImagePlaceholders = {
      ...message,
      text: (message.text.length > 0 ? [message.text, ...lines] : lines).join('\n\n'),
      attachments: kept.length > 0 ? kept : undefined,
      omittedImagePlaceholders: lines,
    };
    return carried;
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
  return attachmentAcceptance(
    attachment,
    resolveAttachmentCapabilities(provider, model, providerAttachmentSupport),
  ).accepted;
}

/**
 * Builds the accept attribute of the file input, matching InputComposer's rule exactly, including that PDF is only allowed with nativeFile.
 */
export function buildAcceptAttribute(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
  providerAttachmentSupport: ProviderAttachmentSupport | null | undefined,
): string {
  const { supportsImage, supportsFile, supportsNativeFile } = resolveAttachmentCapabilities(
    provider,
    model,
    providerAttachmentSupport,
  );
  // Native files (PDF) read the editable flag of the file_input projection; textFileInline covers text formats only.
  // The extensions come from the extractor's own type list (attachment extraction spec section 2); no second copy is kept.
  const fileExts = attachmentAcceptExtensions({ includePdf: supportsNativeFile });
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
 * When the video projection is not native_part, a placeholder is written as at the image gate: one line per
 * video, appended to the end of the text and carried on `omittedImagePlaceholders`, never silently dropped.
 */
export function filterCurrentTurnAttachments<T extends { id: string; attachments?: Attachment[] }>(
  messages: T[],
  currentTurnId: string,
  provider: Provider,
  model: AIModel,
  /** Resolved from the current connection by default; tests can pass it directly. */
  providerAttachmentSupport?: ProviderAttachmentSupport | null,
  /** The stream options built with this turn's attachment rule: the video gate picks the line placeholder by it (a Relay line looks at relayTransport). */
  streamOptions?: ReturnType<typeof buildProviderStreamOptions>,
): T[] {
  const turn = messages.find((message) => message.id === currentTurnId);
  if (!turn?.attachments?.length) return messages;
  const support = providerAttachmentSupport === undefined
    ? resolveProviderAttachmentSupport(provider, model)
    : providerAttachmentSupport;
  // A support table that has not loaded yet means "unknown", not "unsupported": leave the attachments alone and let the other gates at send time decide.
  if (!support) return messages;
  const capabilities = resolveAttachmentCapabilities(provider, model, support);
  // Video outbound reads the outbound of the video_input projection (all forms, subscriptions included).
  // The file retention criterion is unchanged (kept if the connection takes text injection or native files); whether a native
  // block or text injection is sent is decided by the file_input projection when the outbound is built
  // (buildChatHistory -> resolveFileAttachmentDelivery): a projection other than native_part means text injection.
  const outboundVideo = capabilities.projections.video?.outbound === 'native_part';
  const outboundFile = support.textFileInline || support.nativeFile;
  const kept = turn.attachments.filter((attachment) => attachment.kind === 'image'
    ? capabilities.supportsImage
    : attachment.kind === 'video' ? outboundVideo : outboundFile);
  if (kept.length === turn.attachments.length) return messages;
  const videos = outboundVideo ? 0 : turn.attachments.filter((attachment) => attachment.kind === 'video').length;
  return messages.map((message) => {
    if (message !== turn) return message;
    const trimmed = { ...message, attachments: kept.length > 0 ? kept : undefined };
    if (videos === 0) return trimmed;
    const placeholder = videoGatePlaceholder(provider, model, streamOptions);
    const lines = Array.from({ length: videos }, () => placeholder);
    const own = message as T & { text?: string } & OmittedImagePlaceholders;
    const text = typeof own.text === 'string' ? own.text : '';
    const carried: T & OmittedImagePlaceholders = {
      ...trimmed,
      // Same as the other platforms: a blank line between the text and each placeholder line (shared fixture videoPlaceholderCases.separator).
      text: (text.length > 0 ? [text, ...lines] : lines).join('\n\n'),
      omittedImagePlaceholders: [...(own.omittedImagePlaceholders ?? []), ...lines],
    };
    return carried;
  });
}

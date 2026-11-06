/**
 * Chat image runner: runs one chat image send that decideChatImageDispatch puts on
 * the studio pipeline through runStudioByokRound, stores every delivered image with
 * a thumbnail and hands back chat image attachments or a chat error kind. Returns
 * null when the send stays on the legacy path. Not gated by the studio build switch.
 */
import type { Attachment } from '@oriveo/shared';
import { getImageMetadataSlice } from '../metadata/metadata-client';
import { generateThumbnail, loadImageData, saveImage } from '../../infra/storage/image-store';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { createCanonicalUUID } from '../../utils/id-utils';
import { runStudioByokRound, type StudioByokImage, type StudioGenerateResult } from './byok-client';
import { persistStudioRoundImages } from './byok-persist';
import { CHAT_IMAGE_PARAMS, chatImageErrorKind, chatStudioBaseUrl, decideChatImageDispatch } from './chat-image-dispatch';
import { resolveImageProfile, type ImageMetadataSlice } from './image-profile';

export interface ChatImageStudioInput {
  providerKind: string;
  model: string;
  apiKey: string;
  baseURL: string;
  /** The exact prompt the legacy path sends (style prefix + last user text). */
  prompt: string;
  /** Attachments of this user message, in message order. */
  attachments: readonly Attachment[];
  signal: AbortSignal;
}

export interface ChatImageStudioDeps {
  /** Client fetch for /api/studio/generate; defaults to the global fetch. */
  fetch?: typeof fetch;
  /** ImageProfile metadata slice; defaults to the in-memory metadata snapshot. */
  metadata?: ImageMetadataSlice | null;
  /** Thumbnail generator; defaults to generateThumbnail. */
  thumbnail?: (image: Blob) => Promise<Blob>;
  /** Image store partition; defaults to the active partition at call time. */
  partitionUID?: string;
}

export type ChatImageStudioResult =
  /** usage is the studio result's usage as is, for the legacy cost fields. */
  | { attachments: Attachment[]; usage: StudioGenerateResult['usage'] }
  | { errorKind: string; message: string | null }
  | { cancelled: true };

/** Same file name the legacy chat image path gives generated images. */
const GENERATED_FILE_NAME = 'generated.png';

interface LocalImageBytes {
  data: Uint8Array;
  mime: string;
}

function decodeBase64(data: string): Uint8Array {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function encodeBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** Bytes of one user image attachment available on this device; null when there are none. */
async function localImageBytes(attachment: Attachment, partitionUID: string): Promise<LocalImageBytes | null> {
  try {
    if (attachment.localImageID) {
      const blob = await loadImageData(attachment.localImageID, partitionUID);
      if (!blob) return null;
      const data = new Uint8Array(await blob.arrayBuffer());
      return data.length > 0 ? { data, mime: attachment.mimeType || blob.type } : null;
    }
    const b64 = attachment.base64Data;
    if (!b64 || b64.startsWith('http')) return null;
    const data = decodeBase64(b64);
    return data.length > 0 ? { data, mime: attachment.mimeType } : null;
  } catch {
    return null;
  }
}

export async function runChatImageStudio(
  input: ChatImageStudioInput,
  deps: ChatImageStudioDeps = {},
): Promise<ChatImageStudioResult | null> {
  // Bind the partition when the send starts: a sign-out mid-run must not write into another partition.
  const partitionUID = deps.partitionUID ?? getActiveUIDSync();
  const slice = deps.metadata !== undefined ? deps.metadata : getImageMetadataSlice();
  if (!slice) return null;
  const { profile } = resolveImageProfile(slice, input.providerKind, input.model);

  // Only an edit-capable profile reads attachment bytes; generate-only ignores attachments.
  const bytes = new Map<string, LocalImageBytes>();
  const imageAttachments = input.attachments.filter((attachment) => attachment.kind === 'image');
  if (profile?.operations.includes('edit')) {
    for (const attachment of imageAttachments) {
      const local = await localImageBytes(attachment, partitionUID);
      if (local) bytes.set(attachment.id, local);
    }
  }

  const dispatch = decideChatImageDispatch({
    providerKind: input.providerKind,
    legacyImageDispatch: true,
    profile,
    attachments: imageAttachments.map((attachment) => ({
      id: attachment.id,
      mime: bytes.get(attachment.id)?.mime ?? attachment.mimeType,
      hasBytes: bytes.has(attachment.id),
    })),
  });
  if (dispatch.path === 'legacy' || !profile) return null;
  // The studio request needs a concrete base URL; one that cannot be derived keeps the legacy path.
  const baseURL = chatStudioBaseUrl(profile.route, input.baseURL);
  if (baseURL === null) return null;

  const images: StudioByokImage[] = dispatch.images.map((image) => {
    const local = bytes.get(image.attachmentId)!;
    return { slot: image.slot, role: image.role, mime: local.mime, data: local.data };
  });

  const { signal } = input;
  const round = await runStudioByokRound(
    {
      providerKind: input.providerKind,
      apiKey: input.apiKey,
      baseURL,
      modelId: input.model,
      profile,
      operation: dispatch.operation,
      // The legacy prompt goes in as the user text with no reference sentences, so the wire prompt stays the same.
      prompt: { userPrompt: input.prompt, references: [] },
      params: { ...CHAT_IMAGE_PARAMS },
      advanced: null,
      images,
    },
    { fetch: deps.fetch, signal },
  );

  const makeThumbnail = deps.thumbnail ?? ((image: Blob) => generateThumbnail(image));
  const thumbnails = new Map<string, string>();
  const persisted = await persistStudioRoundImages(round, {
    partitionUID,
    signal,
    // Thumbnails are required on chat image attachments, so they are written with the image.
    persist: async (data, mime) => {
      const blob = new Blob([data as Uint8Array<ArrayBuffer>], { type: mime });
      const thumbnail = await makeThumbnail(blob);
      const id = createCanonicalUUID();
      await saveImage(id, blob, thumbnail, mime, partitionUID);
      thumbnails.set(id, encodeBase64(new Uint8Array(await thumbnail.arrayBuffer())));
      return id;
    },
  });

  switch (persisted.status) {
    case 'completed':
    case 'partial':
      return {
        attachments: persisted.images.map((image) => ({
          id: createCanonicalUUID(),
          kind: 'image',
          fileName: GENERATED_FILE_NAME,
          mimeType: image.mime,
          localImageID: image.assetId,
          thumbnailBase64: thumbnails.get(image.assetId),
        })),
        usage: persisted.usage,
      };
    case 'cancelled':
      // Cancelled like the legacy path: no attachments.
      return { cancelled: true };
    case 'failed':
      return {
        errorKind: chatImageErrorKind(persisted.errorKind === 'partial' || persisted.errorKind === null
          ? 'upstream_error'
          : persisted.errorKind, persisted.message),
        message: persisted.message,
      };
  }
}

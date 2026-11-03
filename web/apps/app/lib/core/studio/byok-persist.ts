/**
 * Persist one BYOK studio round: write every delivered image's bytes into the
 * image store and hand back the same round with asset ids instead of bytes.
 * The round is all-or-nothing: a cancel or a failed write deletes what was
 * already written. Thumbnails are not generated here.
 */
import { deleteImage, saveImage } from '../../infra/storage/image-store';
import type { ImageErrorKind } from './image-error';

export type StudioRoundStatus = 'completed' | 'partial' | 'failed' | 'cancelled';

export interface StudioRoundImageBytes {
  data: Uint8Array;
  mime: string;
  width: number | null;
  height: number | null;
  revisedPrompt: string | null;
}

export interface StudioRoundImageAsset {
  assetId: string;
  mime: string;
  width: number | null;
  height: number | null;
  revisedPrompt: string | null;
}

/** Fields every round carries; the rest of the result shape passes through untouched. */
export interface StudioRoundBase<I> {
  status: StudioRoundStatus;
  errorKind: ImageErrorKind | null;
  message: string | null;
  images: readonly I[];
}

export type PersistedStudioRound<R extends StudioRoundBase<StudioRoundImageBytes>> =
  Omit<R, 'status' | 'errorKind' | 'message' | 'images'> & {
    status: StudioRoundStatus;
    errorKind: ImageErrorKind | null;
    message: string | null;
    images: StudioRoundImageAsset[];
  };

export interface PersistStudioRoundOptions {
  partitionUID?: string;
  signal: AbortSignal;
  /** Writes one image and returns its asset id; defaults to the image store. */
  persist?: (bytes: Uint8Array, mime: string) => Promise<string>;
}

export async function persistStudioRoundImages<R extends StudioRoundBase<StudioRoundImageBytes>>(
  result: R,
  options: PersistStudioRoundOptions,
): Promise<PersistedStudioRound<R>> {
  const { partitionUID, signal } = options;
  // Only rounds that delivered images are written; anything else passes through.
  if (result.status !== 'completed' && result.status !== 'partial') {
    return { ...result, images: [] };
  }

  const persist = options.persist ?? (async (bytes: Uint8Array, mime: string) => {
    const id = crypto.randomUUID();
    await saveImage(id, new Blob([bytes as Uint8Array<ArrayBuffer>], { type: mime }), null, mime, partitionUID);
    return id;
  });

  const saved: StudioRoundImageAsset[] = [];
  try {
    for (const item of result.images) {
      if (signal.aborted) break;
      const assetId = await persist(item.data, item.mime);
      saved.push({
        assetId,
        mime: item.mime,
        width: item.width,
        height: item.height,
        revisedPrompt: item.revisedPrompt,
      });
    }
  } catch {
    await rollback(saved, partitionUID);
    if (signal.aborted) return { ...result, status: 'cancelled', errorKind: null, message: null, images: [] };
    return { ...result, status: 'failed', errorKind: 'storage_full', images: [] };
  }

  if (signal.aborted) {
    await rollback(saved, partitionUID);
    return { ...result, status: 'cancelled', errorKind: null, message: null, images: [] };
  }
  return { ...result, images: saved };
}

/** Best-effort delete of everything this round wrote; one failed delete does not stop the rest. */
async function rollback(saved: readonly StudioRoundImageAsset[], partitionUID: string | undefined) {
  await Promise.all(saved.map((item) => deleteImage(item.assetId, partitionUID).catch(() => 0)));
}

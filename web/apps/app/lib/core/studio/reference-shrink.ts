/**
 * Browser reference image shrinker for the BYOK budget: applies EXIF
 * orientation, scales the long edge down to the spec limit (never up),
 * flattens alpha onto white and re-encodes as JPEG without metadata.
 */
import { REFERENCE_BUDGET_SPEC } from './reference-budget';

/** Returns the re-encoded JPEG, or null when decoding or encoding fails. */
export async function shrinkReferenceImage(
  bytes: Uint8Array,
  mime: string,
): Promise<{ data: Uint8Array; mime: 'image/jpeg' } | null> {
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(new Blob([bytes as BlobPart], { type: mime }), {
      imageOrientation: 'from-image',
    });
  } catch {
    return null;
  }

  const { maxLongEdge, jpegQuality, mime: outMime } = REFERENCE_BUDGET_SPEC.shrink;
  const scale = Math.min(maxLongEdge / Math.max(bitmap.width, bitmap.height), 1);
  const w = Math.round(bitmap.width * scale);
  const h = Math.round(bitmap.height * scale);

  // Any failure after decoding (no OffscreenCanvas on older Safari, no 2d
  // context, encoder or byte read errors) yields null so the budget keeps
  // the original image.
  try {
    const canvas = new OffscreenCanvas(w, h);
    const ctx = canvas.getContext('2d');
    if (ctx === null) return null;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(bitmap, 0, 0, w, h);
    const blob = await canvas.convertToBlob({ type: outMime, quality: jpegQuality });
    return { data: new Uint8Array(await blob.arrayBuffer()), mime: outMime };
  } catch {
    return null;
  } finally {
    bitmap.close();
  }
}

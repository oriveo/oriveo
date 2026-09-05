'use client';

import { useState, useRef, useCallback, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import { Dialog } from '@oriveo/ui';
import { saveImage } from '../../lib/infra/storage/image-store';
import styles from './AvatarCropDialog.module.css';

interface AvatarCropDialogProps {
  open: boolean;
  onClose: () => void;
  onSaved: (localImageID: string) => void | Promise<void>;
}

const CIRCLE_SIZE = 280;
const OUTPUT_SIZE = 512;
const THUMB_SIZE = 120;
const MIN_SCALE = 1.0;
const MAX_SCALE = 5.0;

export function AvatarCropDialog({ open, onClose, onSaved }: AvatarCropDialogProps) {
  const t = useTranslations('avatarCrop');
  const tc = useTranslations('common');
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const cropContainerRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const objectURLRef = useRef<string | null>(null);

  // Crop state: the offset is in pixels of the image coordinate system.
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [scale, setScale] = useState(1.0);
  const [hasImage, setHasImage] = useState(false);
  const [saving, setSaving] = useState(false);

  // Drag state lives in a ref to avoid re-renders.
  const dragRef = useRef<{ dragging: boolean; lastX: number; lastY: number }>({
    dragging: false, lastX: 0, lastY: 0,
  });

  // Reset state when the dialog opens and release the object URL when it closes.
  useEffect(() => {
    if (open) {
      imageRef.current = null;
      setOffset({ x: 0, y: 0 });
      setScale(1.0);
      setHasImage(false);
      setSaving(false);
    } else if (objectURLRef.current) {
      URL.revokeObjectURL(objectURLRef.current);
      objectURLRef.current = null;
    }
  }, [open]);

  /** Clamp the offset so the image never leaves the circular area. */
  const clampOffset = useCallback((ox: number, oy: number, s: number, img: HTMLImageElement) => {
    // Rendered size of the image on the canvas.
    const fitScale = CIRCLE_SIZE / Math.min(img.naturalWidth, img.naturalHeight);
    const renderW = img.naturalWidth * fitScale * s;
    const renderH = img.naturalHeight * fitScale * s;

    // Largest allowed offset: the image edge must not pass the center of the circle.
    const maxX = Math.max((renderW - CIRCLE_SIZE) / 2, 0);
    const maxY = Math.max((renderH - CIRCLE_SIZE) / 2, 0);

    return {
      x: Math.max(-maxX, Math.min(maxX, ox)),
      y: Math.max(-maxY, Math.min(maxY, oy)),
    };
  }, []);

  /** Draw the preview canvas. */
  const draw = useCallback((img: HTMLImageElement, ox: number, oy: number, s: number) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    canvas.width = CIRCLE_SIZE * dpr;
    canvas.height = CIRCLE_SIZE * dpr;
    ctx.scale(dpr, dpr);

    ctx.clearRect(0, 0, CIRCLE_SIZE, CIRCLE_SIZE);

    // Fit the image's short edge to the canvas, then multiply by the user's zoom.
    const fitScale = CIRCLE_SIZE / Math.min(img.naturalWidth, img.naturalHeight);
    const renderW = img.naturalWidth * fitScale * s;
    const renderH = img.naturalHeight * fitScale * s;

    const drawX = (CIRCLE_SIZE - renderW) / 2 + ox;
    const drawY = (CIRCLE_SIZE - renderH) / 2 + oy;

    // Draw the image only inside the circle (the circular crop itself is done with a CSS clip-path).
    ctx.drawImage(img, drawX, drawY, renderW, renderH);
  }, []);

  /** Handle file selection. */
  const handleFileChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    // Release the previous object URL to avoid a memory leak.
    if (objectURLRef.current) {
      URL.revokeObjectURL(objectURLRef.current);
    }

    const img = new Image();
    const url = URL.createObjectURL(file);
    objectURLRef.current = url;
    img.onload = () => {
      imageRef.current = img;
      setScale(1.0);
      setOffset({ x: 0, y: 0 });
      setHasImage(true);
      draw(img, 0, 0, 1.0);
    };
    img.src = url;

    // Reset the input so selecting the same file again still fires a change.
    e.target.value = '';
  }, [draw]);

  // Redraw whenever offset or scale changes, once an image is loaded.
  useEffect(() => {
    if (imageRef.current) {
      draw(imageRef.current, offset.x, offset.y, scale);
    }
  }, [offset, scale, draw]);

  /* -- Drag handling (mouse and touch) -- */

  const handlePointerDown = useCallback((e: React.PointerEvent) => {
    dragRef.current = { dragging: true, lastX: e.clientX, lastY: e.clientY };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }, []);

  const handlePointerMove = useCallback((e: React.PointerEvent) => {
    if (!dragRef.current.dragging || !imageRef.current) return;

    const dx = e.clientX - dragRef.current.lastX;
    const dy = e.clientY - dragRef.current.lastY;
    dragRef.current.lastX = e.clientX;
    dragRef.current.lastY = e.clientY;

    setOffset((prev) => clampOffset(prev.x + dx, prev.y + dy, scale, imageRef.current!));
  }, [scale, clampOffset]);

  const handlePointerUp = useCallback(() => {
    dragRef.current.dragging = false;
  }, []);

  /** Wheel zoom, kept in a ref callback to avoid a stale closure. */
  const wheelHandler = useRef((_e: WheelEvent) => {});
  wheelHandler.current = (e: WheelEvent) => {
    e.preventDefault();
    if (!imageRef.current) return;

    setScale((prev) => {
      const next = Math.max(MIN_SCALE, Math.min(MAX_SCALE, prev - e.deltaY * 0.002));
      setOffset((prevOff) => clampOffset(prevOff.x, prevOff.y, next, imageRef.current!));
      return next;
    });
  };

  // Register a non-passive wheel listener, otherwise preventDefault has no effect in Chrome.
  useEffect(() => {
    const el = cropContainerRef.current;
    if (!el || !hasImage) return;

    const handler = (e: WheelEvent) => wheelHandler.current(e);
    el.addEventListener('wheel', handler, { passive: false });
    return () => el.removeEventListener('wheel', handler);
  }, [hasImage]);

  /** Crop and save. */
  const cropAndSave = useCallback(async () => {
    const img = imageRef.current;
    if (!img) return;
    setSaving(true);

    try {
      // Position of the crop area in the image's original pixel coordinates.
      const fitScale = CIRCLE_SIZE / Math.min(img.naturalWidth, img.naturalHeight);
      const renderScale = fitScale * scale;

      // Where the image starts being drawn on the canvas.
      const imgDrawX = (CIRCLE_SIZE - img.naturalWidth * renderScale) / 2 + offset.x;
      const imgDrawY = (CIRCLE_SIZE - img.naturalHeight * renderScale) / 2 + offset.y;

      // Source image coordinates corresponding to the top-left corner (0,0) of the canvas circle.
      const srcX = -imgDrawX / renderScale;
      const srcY = -imgDrawY / renderScale;
      const srcSize = CIRCLE_SIZE / renderScale;

      // Full-size output.
      const fullCanvas = document.createElement('canvas');
      fullCanvas.width = OUTPUT_SIZE;
      fullCanvas.height = OUTPUT_SIZE;
      const fullCtx = fullCanvas.getContext('2d')!;
      fullCtx.drawImage(img, srcX, srcY, srcSize, srcSize, 0, 0, OUTPUT_SIZE, OUTPUT_SIZE);

      // Thumbnail.
      const thumbCanvas = document.createElement('canvas');
      thumbCanvas.width = THUMB_SIZE;
      thumbCanvas.height = THUMB_SIZE;
      const thumbCtx = thumbCanvas.getContext('2d')!;
      thumbCtx.drawImage(img, srcX, srcY, srcSize, srcSize, 0, 0, THUMB_SIZE, THUMB_SIZE);

      const [fullBlob, thumbBlob] = await Promise.all([
        new Promise<Blob>((resolve, reject) => {
          fullCanvas.toBlob(
            (blob) => (blob ? resolve(blob) : reject(new Error('canvas toBlob failed'))),
            'image/jpeg', 0.8,
          );
        }),
        new Promise<Blob>((resolve, reject) => {
          thumbCanvas.toBlob(
            (blob) => (blob ? resolve(blob) : reject(new Error('canvas toBlob failed'))),
            'image/jpeg', 0.8,
          );
        }),
      ]);

      const id = `user-avatar-${crypto.randomUUID()}`;
      await saveImage(id, fullBlob, thumbBlob, 'image/jpeg');
      onSaved(id);
    } catch {
      // A failed crop is swallowed; the user can simply try again.
    } finally {
      setSaving(false);
    }
  }, [scale, offset, onSaved]);

  return (
    <Dialog open={open} onClose={onClose}>
      <h2 className={styles.title}>{t('title')}</h2>

      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        hidden
        onChange={handleFileChange}
      />

      {!hasImage ? (
        <button
          type="button"
          className={styles.fileButton}
          onClick={() => fileInputRef.current?.click()}
        >
          {t('chooseImage')}
        </button>
      ) : (
        <>
          <div
            ref={cropContainerRef}
            className={styles.cropContainer}
            onPointerDown={handlePointerDown}
            onPointerMove={handlePointerMove}
            onPointerUp={handlePointerUp}
          >
            <canvas ref={canvasRef} className={styles.canvas} />
          </div>

          <p className={styles.hint}>{t('scrollToZoom')}</p>

          <button
            type="button"
            className={styles.fileButton}
            onClick={() => fileInputRef.current?.click()}
          >
            {t('chooseAnotherImage')}
          </button>
        </>
      )}

      <div className={styles.controls}>
        <button type="button" className={styles.cancelButton} onClick={onClose}>
          {tc('cancel')}
        </button>
        <button
          type="button"
          className={styles.saveButton}
          disabled={!hasImage || saving}
          onClick={cropAndSave}
        >
          {saving ? t('saving') : tc('save')}
        </button>
      </div>
    </Dialog>
  );
}

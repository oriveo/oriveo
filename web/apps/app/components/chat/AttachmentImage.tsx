'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useTranslations } from 'next-intl';
import { Download, X } from 'lucide-react';
import type { Attachment } from '@oriveo/shared';
import { useAttachmentImage } from '../../lib/hooks/useAttachmentImage';
import { loadImageData } from '../../lib/infra/storage/image-store';
import { downloadAttachmentIfNeeded } from '../../lib/core/sync-port';
import { getActiveUID } from '../../lib/infra/storage/partition';
import styles from './AttachmentImage.module.css';

interface AttachmentImageProps {
  attachment: Attachment;
  className?: string;
  linkClassName?: string;
  /** Open the full-size preview modal on this page when clicked */
  asLink?: boolean;
}

export function AttachmentImage({ attachment, className, linkClassName, asLink }: AttachmentImageProps) {
  const src = useAttachmentImage(attachment);
  const t = useTranslations('imagePreview');
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [isLoadingOriginal, setIsLoadingOriginal] = useState(false);
  const [hasOriginalPreview, setHasOriginalPreview] = useState(false);
  // Tracks whether the current previewUrl was created with createObjectURL and needs revoking
  const ownsBlobUrlRef = useRef(false);
  const previewRequestIdRef = useRef(0);

  const setOwnedPreviewUrl = useCallback((url: string) => {
    setPreviewUrl((current) => {
      if (ownsBlobUrlRef.current && current && current !== url) {
        URL.revokeObjectURL(current);
      }
      ownsBlobUrlRef.current = true;
      return url;
    });
  }, []);

  const loadOriginalPreview = useCallback(async () => {
    const imageKey = attachment.localImageID ?? attachment.id;
    const existingBlob = await loadImageData(imageKey);
    if (existingBlob) return URL.createObjectURL(existingBlob);

    if (!attachment.storageRef || attachment.kind !== 'image') return null;
    const uid = await getActiveUID();
    if (uid === 'guest') return null;

    const downloaded = await downloadAttachmentIfNeeded(uid, attachment.storageRef, attachment.id, attachment.mimeType);
    if (!downloaded) return null;

    const downloadedBlob = await loadImageData(downloaded);
    return downloadedBlob ? URL.createObjectURL(downloadedBlob) : null;
  }, [attachment.id, attachment.kind, attachment.localImageID, attachment.mimeType, attachment.storageRef]);

  const closePreview = useCallback(() => {
    if (ownsBlobUrlRef.current && previewUrl) {
      URL.revokeObjectURL(previewUrl);
    }
    ownsBlobUrlRef.current = false;
    previewRequestIdRef.current += 1;
    setPreviewUrl(null);
    setIsLoadingOriginal(false);
    setHasOriginalPreview(false);
  }, [previewUrl]);

  const handleClick = useCallback(async () => {
    const requestId = previewRequestIdRef.current + 1;
    previewRequestIdRef.current = requestId;
    setHasOriginalPreview(false);

    let fallbackUrl: string | null = null;
    if (src) {
      try {
        const resp = await fetch(src);
        const fallbackBlob = await resp.blob();
        fallbackUrl = URL.createObjectURL(fallbackBlob);
        setOwnedPreviewUrl(fallbackUrl);
      } catch {
        fallbackUrl = src;
        ownsBlobUrlRef.current = false;
        setPreviewUrl(src);
      }
    }

    setIsLoadingOriginal(true);
    try {
      const originalUrl = await loadOriginalPreview();
      if (previewRequestIdRef.current !== requestId) {
        if (originalUrl) URL.revokeObjectURL(originalUrl);
        return;
      }
      if (originalUrl) {
        setOwnedPreviewUrl(originalUrl);
        setHasOriginalPreview(true);
      } else if (!fallbackUrl) {
        setPreviewUrl(null);
      }
    } finally {
      if (previewRequestIdRef.current === requestId) {
        setIsLoadingOriginal(false);
      }
    }
  }, [loadOriginalPreview, setOwnedPreviewUrl, src]);

  // Close on Esc and lock body scrolling
  useEffect(() => {
    if (!previewUrl) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closePreview();
    };
    document.addEventListener('keydown', onKey);
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = previousOverflow;
    };
  }, [previewUrl, closePreview]);

  // Revoke the blob URL on unmount
  useEffect(() => {
    return () => {
      if (ownsBlobUrlRef.current && previewUrl) {
        URL.revokeObjectURL(previewUrl);
      }
    };
  }, [previewUrl]);

  if (!src) return null;

  const img = (
    // Local attachment previews are blob/data URLs from ImageStore and are not suitable for next/image optimization.
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt={attachment.fileName}
      className={className}
      loading="lazy"
    />
  );

  if (!asLink) return img;

  const trigger = (
    <button
      type="button"
      onClick={handleClick}
      className={linkClassName}
      style={linkClassName ? undefined : { cursor: 'pointer', border: 'none', padding: 0, background: 'none', display: 'block', lineHeight: 0 }}
    >
      {img}
    </button>
  );

  // Do not render the portal where there is no document (SSR or tests)
  const canPortal = typeof document !== 'undefined';

  return (
    <>
      {trigger}
      {canPortal && previewUrl
        ? createPortal(
            <div
              className={styles.previewOverlay}
              role="dialog"
              aria-modal="true"
              onClick={closePreview}
            >
              <div className={styles.previewToolbar}>
                {hasOriginalPreview ? (
                  <a
                    href={previewUrl}
                    download={attachment.fileName}
                    className={styles.previewToolButton}
                    aria-label={t('download')}
                    title={t('download')}
                    onClick={(e) => e.stopPropagation()}
                  >
                    <Download size={18} aria-hidden="true" />
                  </a>
                ) : null}
                <button
                  type="button"
                  className={styles.previewToolButton}
                  aria-label={t('close')}
                  title={t('close')}
                  onClick={(e) => {
                    e.stopPropagation();
                    closePreview();
                  }}
                >
                  <X size={18} aria-hidden="true" />
                </button>
              </div>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={previewUrl}
                alt={attachment.fileName}
                className={styles.previewImage}
                onClick={(e) => e.stopPropagation()}
              />
              {isLoadingOriginal ? (
                <div className={styles.previewLoading} role="status" onClick={(e) => e.stopPropagation()}>
                  <span className={styles.previewSpinner} aria-hidden="true" />
                  <span>{t('loadingOriginal')}</span>
                </div>
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}

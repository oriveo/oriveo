'use client';

import { useState, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import { IMAGE_SIZES, IMAGE_QUALITIES, IMAGE_STYLES } from '../../lib/core/providers/image-service';
import styles from './ImageGeneration.module.css';

interface ImageGenerationProps {
  size: string;
  quality: string;
  style: string;
  onSizeChange: (size: string) => void;
  onQualityChange: (quality: string) => void;
  onStyleChange: (style: string) => void;
}

export function ImageGeneration({
  size,
  quality,
  style,
  onSizeChange,
  onQualityChange,
  onStyleChange,
}: ImageGenerationProps) {
  const t = useTranslations('imageGen');
  const [expanded, setExpanded] = useState(false);

  const toggleExpanded = useCallback(() => {
    setExpanded((v) => !v);
  }, []);

  return (
    <div className={styles.wrap}>
      <button type="button" className={styles.toggle} onClick={toggleExpanded}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
          <circle cx="8.5" cy="8.5" r="1.5" />
          <polyline points="21 15 16 10 5 21" />
        </svg>
        <span>{t('mode')}</span>
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ transform: expanded ? 'rotate(180deg)' : undefined }}>
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </button>

      {expanded && (
        <div className={styles.options}>
          <div className={styles.optionGroup}>
            <label className={styles.label}>{t('size')}</label>
            <div className={styles.chips}>
              {IMAGE_SIZES.map((s) => (
                <button
                  key={s.value}
                  type="button"
                  className={styles.chip}
                  data-active={s.value === size}
                  onClick={() => onSizeChange(s.value)}
                >
                  {t(s.labelKey)}
                </button>
              ))}
            </div>
          </div>

          <div className={styles.optionGroup}>
            <label className={styles.label}>{t('quality')}</label>
            <div className={styles.chips}>
              {IMAGE_QUALITIES.map((q) => (
                <button
                  key={q.value}
                  type="button"
                  className={styles.chip}
                  data-active={q.value === quality}
                  onClick={() => onQualityChange(q.value)}
                >
                  {t(q.labelKey)}
                </button>
              ))}
            </div>
          </div>

          <div className={styles.optionGroup}>
            <label className={styles.label}>{t('style')}</label>
            <div className={styles.chips}>
              {IMAGE_STYLES.map((st) => (
                <button
                  key={st.value}
                  type="button"
                  className={styles.chip}
                  data-active={st.value === style}
                  onClick={() => onStyleChange(st.value)}
                >
                  {t(st.labelKey)}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

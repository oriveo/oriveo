'use client';

import { useRef, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import { FOLDER_COLOR_ORDER, getFolderColorPair } from '@oriveo/shared';

interface FolderColorPickerProps {
  currentColor?: string;
  onSelect: (color: string) => void;
  onClose: () => void;
}

/**
 * Folder colour picker - a 5x2 grid of colour dots in a popover.
 */
export function FolderColorPicker({ currentColor, onSelect, onClose }: FolderColorPickerProps) {
  const ref = useRef<HTMLDivElement>(null);
  const t = useTranslations('sidebar');

  // Close on an outside click or Escape
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('mousedown', handleClick);
    document.addEventListener('keydown', handleKey);
    return () => {
      document.removeEventListener('mousedown', handleClick);
      document.removeEventListener('keydown', handleKey);
    };
  }, [onClose]);

  return (
    <div
      ref={ref}
      style={{
        position: 'absolute', top: '100%', left: 0, zIndex: 9999,
        background: 'var(--o-surface-raised)', border: '1px solid var(--o-border)',
        borderRadius: 'var(--o-radius-lg)', padding: 12,
        boxShadow: 'var(--o-elevation-modal)',
        animation: 'dialogIn 150ms ease-out',
      }}
    >
      <style>{`@keyframes dialogIn { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: translateY(0); } }`}</style>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--o-text-secondary)', marginBottom: 8 }}>
        {t('changeColor')}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
        {FOLDER_COLOR_ORDER.map((tag) => {
          const [main, dark] = getFolderColorPair(tag);
          const isSelected = tag === (currentColor || 'blue');
          return (
            <button
              key={tag}
              type="button"
              onClick={() => { onSelect(tag); onClose(); }}
              aria-label={tag}
              style={{
                width: 32, height: 32, borderRadius: '50%', border: 'none', cursor: 'pointer',
                background: `linear-gradient(135deg, ${main}, ${dark})`,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                boxShadow: `0 2px 4px ${main}40`,
                outline: isSelected ? '2px solid var(--o-text)' : 'none',
                outlineOffset: 2,
              }}
            >
              {isSelected && (
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
                  <polyline points="20 6 9 17 4 12" />
                </svg>
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}

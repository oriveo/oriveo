'use client';

import { FOLDER_COLOR_ORDER, getFolderColorPair } from '@oriveo/shared';
import styles from './Notes.module.css';

interface FolderColorGridProps {
  value: string;
  onChange: (tag: string) => void;
}

/**
 * Six-column dot grid of note folder colours, shared by the create and recolour flows.
 */
export function FolderColorGrid({ value, onChange }: FolderColorGridProps) {
  return (
    <div className={styles.colorGrid}>
      {FOLDER_COLOR_ORDER.map((tag) => {
        const [main, dark] = getFolderColorPair(tag);
        return (
          <button
            key={tag}
            type="button"
            aria-label={tag}
            className={styles.colorSwatch}
            data-selected={tag === value ? 'true' : undefined}
            style={{ background: `linear-gradient(135deg, ${main}, ${dark})` }}
            onClick={() => onChange(tag)}
          />
        );
      })}
    </div>
  );
}

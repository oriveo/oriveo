'use client';

import styles from './ChatAmbientAurora.module.css';

interface ChatAmbientAuroraProps {
  /** Full intensity for the empty state; dimmed once there are messages so it stays in the background. */
  prominent: boolean;
}

/**
 * Persistent "aurora glow plus halftone dots" backdrop for the chat page.
 *
 * Design intent: the glow rises from the input area at the bottom with an echo at the top, and
 * the halftone dots cluster at the top and bottom edges leaving the middle open for the greeting
 * and cards, so content appears to float on a pool of still light. The whole layer breathes with
 * a slow scale (pure CSS transform, GPU composited, no per-frame repaint). Light and dark each
 * get their own treatment:
 * - dark: purple and magenta neon glow with bright lavender dust
 * - light: very pale lavender plus a cool periwinkle haze and low-saturation purple dots, present
 *   without competing with the content
 *
 * `prominent` controls the intensity of the whole layer (full in the empty state, dimmed to 0.42
 * once there are messages). The layer sits at z-index:-1 between the solid .view background and
 * the content, with `pointer-events: none`.
 */
export function ChatAmbientAurora({ prominent }: ChatAmbientAuroraProps) {
  return (
    <div
      className={styles.aurora}
      data-prominent={prominent ? 'true' : 'false'}
      aria-hidden="true"
    >
      <div className={styles.breathe}>
        <span className={styles.glow} />
        <span className={styles.halftone} />
      </div>
    </div>
  );
}

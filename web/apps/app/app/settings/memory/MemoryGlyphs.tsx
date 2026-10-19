import type { MemoryItem } from '@oriveo/core/context/memory-items';
import type { MemoryCategory } from './MemoryItemEditor';
import styles from './MemoryPage.module.css';

/* ───────── Group glyphs (line symbols, tinted by the group hue; never on a backplate) ───────── */

type GlyphProps = { size?: number };

function svgProps(size: number) {
  return {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 2,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    'aria-hidden': true,
    focusable: false,
  };
}

/** One line symbol per category: person / sliders / loop arrow / layers. */
export function MemoryCategoryGlyph({ category, size = 17 }: GlyphProps & { category: MemoryCategory }) {
  switch (category) {
    case 'about':
      return (
        <svg {...svgProps(size)}>
          <circle cx="12" cy="8.5" r="3.5" />
          <path d="M5 20c1.4-3.6 4-5.5 7-5.5s5.6 1.9 7 5.5" />
        </svg>
      );
    case 'preferences':
      return (
        <svg {...svgProps(size)}>
          <path d="M4 8h16M4 16h16" />
          <circle cx="9" cy="8" r="2.4" fill="currentColor" />
          <circle cx="15" cy="16" r="2.4" fill="currentColor" />
        </svg>
      );
    case 'instructions':
      return (
        <svg {...svgProps(size)}>
          <path d="M17 4l3 3-3 3" />
          <path d="M20 7H9a5 5 0 000 10h2" />
          <path d="M14 17h6" />
        </svg>
      );
    case 'projects':
    default:
      return (
        <svg {...svgProps(size)}>
          <path d="M12 3l9 4.5-9 4.5-9-4.5z" />
          <path d="M3 12l9 4.5 9-4.5M3 16.5L12 21l9-4.5" />
        </svg>
      );
  }
}

/** Events & decisions: a vertical line through a diamond. */
export function MemoryEpisodicGlyph({ size = 17 }: GlyphProps) {
  return (
    <svg {...svgProps(size)}>
      <path d="M12 2v4M12 18v4" />
      <path d="M12 7l5 5-5 5-5-5z" />
    </svg>
  );
}

/** Filled diamond (decision) / ring (event), the episodic timeline markers. */
export function MemoryEpisodicKindGlyph({ kind, size = 15 }: GlyphProps & { kind: 'decision' | 'event' }) {
  if (kind === 'event') {
    return (
      <svg {...svgProps(size)} strokeWidth={2.6}>
        <circle cx="12" cy="12" r="7.5" />
      </svg>
    );
  }
  return (
    <svg {...svgProps(size)} stroke="none">
      <path d="M12 3l9 9-9 9-9-9z" fill="currentColor" />
    </svg>
  );
}

/** Conflicts: a fork. */
export function MemoryConflictGlyph({ size = 17 }: GlyphProps) {
  return (
    <svg {...svgProps(size)}>
      <circle cx="6" cy="5" r="2" />
      <circle cx="6" cy="19" r="2" />
      <circle cx="18" cy="12" r="2" />
      <path d="M6 7v10M6 12h4a4 4 0 004-4V7M14 12h2" />
    </svg>
  );
}

/** Suggestions inbox: a tray. */
export function MemoryInboxGlyph({ size = 20 }: GlyphProps) {
  return (
    <svg {...svgProps(size)} strokeWidth={1.8}>
      <path d="M4 13l2.5-7h11L20 13v5a1 1 0 01-1 1H5a1 1 0 01-1-1v-5z" />
      <path d="M4 13h4.5l1 2h5l1-2H20" />
    </svg>
  );
}

/** Draft from recent chats: a filled double sparkle. */
export function MemorySparkleGlyph({ size = 17 }: GlyphProps) {
  return (
    <svg {...svgProps(size)} stroke="none" fill="currentColor">
      <path d="M12 2l2.2 6.3L20.5 10.5l-6.3 2.2L12 19l-2.2-6.3L3.5 10.5l6.3-2.2z" />
      <path d="M19 15l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z" />
    </svg>
  );
}

export function MemoryScopeGlyph({ type }: { type: MemoryItem['scope']['type'] }) {
  if (type === 'folder') {
    return (
      <svg {...svgProps(12)}>
        <path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z" />
      </svg>
    );
  }
  if (type === 'conversation') {
    return (
      <svg {...svgProps(12)}>
        <path d="M4 5h16v11H9l-5 4z" />
      </svg>
    );
  }
  return (
    <svg {...svgProps(12)}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.5 2.6 2.5 14.4 0 17M12 3.5c-2.5 2.6-2.5 14.4 0 17" />
    </svg>
  );
}

const CATEGORY_HUE_CLASS: Record<MemoryCategory, string> = {
  about: styles.hueAbout,
  preferences: styles.huePreferences,
  instructions: styles.hueInstructions,
  projects: styles.hueProjects,
};

/** CSS class that sets `--memory-hue` for a category (graphics only, never text). */
export function categoryHueClass(category: MemoryCategory): string {
  return CATEGORY_HUE_CLASS[category];
}

/** Conflict footer "Keep both": two parallel bars. */
export function MemoryKeepBothGlyph({ size = 15 }: GlyphProps) {
  return (
    <svg {...svgProps(size)}>
      <path d="M7 6v12M17 6v12" />
    </svg>
  );
}

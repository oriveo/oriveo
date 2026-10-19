'use client';

import { useId, useState, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Check } from 'lucide-react';
import { Dialog } from '@oriveo/ui';
import { MemoryItems, type MemoryItem, type MemoryKind } from '@oriveo/core/context/memory-items';
import styles from './MemoryPage.module.css';
import { MemoryCategoryGlyph, MemoryEpisodicKindGlyph, categoryHueClass } from './MemoryGlyphs';

/** The four user-facing categories; each maps to one or more stored kinds. */
export type MemoryCategory = 'about' | 'preferences' | 'instructions' | 'projects';

export const MEMORY_CATEGORIES: readonly MemoryCategory[] = ['about', 'preferences', 'instructions', 'projects'];

export const MEMORY_CONTENT_MAX = MemoryItems.constants.contentMaxCodePoints;

const CATEGORY_TITLE_KEY: Record<MemoryCategory, string> = {
  about: 'groupAbout',
  preferences: 'groupPreferences',
  instructions: 'groupInstructions',
  projects: 'groupProjects',
};

export function categoryTitleKey(category: MemoryCategory): string {
  return CATEGORY_TITLE_KEY[category];
}

/** Category a kind is listed under; `event` is never listed. */
export function categoryOfKind(kind: MemoryKind): MemoryCategory | null {
  switch (kind) {
    case 'identity':
    case 'fact':
      return 'about';
    case 'preference':
      return 'preferences';
    case 'instruction':
    case 'constraint':
      return 'instructions';
    case 'project':
    case 'goal':
    case 'decision':
      return 'projects';
    default:
      return null;
  }
}

/** Kind written when the user picks a category. */
export function kindForCategory(category: MemoryCategory): MemoryKind {
  switch (category) {
    case 'about':
      return 'identity';
    case 'preferences':
      return 'preference';
    case 'instructions':
      return 'instruction';
    case 'projects':
    default:
      return 'project';
  }
}

/** Length in Unicode code points (the contract limit unit). */
export function codePointCount(text: string): number {
  return Array.from(text).length;
}

/** L3 (episodic) kinds offered by the editor. */
export type EpisodicKind = 'decision' | 'event';

export const EPISODIC_KINDS: readonly EpisodicKind[] = ['decision', 'event'];

const EPISODIC_KIND_TITLE_KEY: Record<EpisodicKind, string> = {
  decision: 'kindDecision',
  event: 'kindEvent',
};

/** Today's local calendar date as YYYY-MM-DD. */
export function todayDate(now: Date = new Date()): string {
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${now.getFullYear()}-${month}-${day}`;
}

/** Stored date (YYYY-MM-DD, UTC part of occurredAt, else createdAt) of an item; null when neither is set. */
export function episodicDateOf(item: Pick<MemoryItem, 'occurredAt' | 'createdAt'>): string | null {
  const time = item.occurredAt ?? item.createdAt;
  return time ? time.slice(0, 10) : null;
}

/** Calendar date (YYYY-MM-DD) → occurredAt at 00:00:00Z of that day. */
export function occurredAtForDate(date: string): string {
  return `${date}T00:00:00Z`;
}

export interface MemoryEditorSession {
  /** Item being edited; null for a new item. */
  itemId: string | null;
  /** Defaults to semantic (the four categories). */
  layer?: 'semantic' | 'episodic';
  category: MemoryCategory;
  /** Kind for an episodic item; defaults to decision. */
  episodicKind?: EpisodicKind;
  /** Event date (YYYY-MM-DD) for an episodic item; defaults to today. */
  date?: string;
  content: string;
}

/** What the editor picked for an episodic item. */
export interface MemoryEpisodicChoice {
  kind: EpisodicKind;
  date: string;
}

interface MemoryItemEditorProps {
  session: MemoryEditorSession;
  saving: boolean;
  onCancel: () => void;
  /** `episodic` is set only when editing an episodic item. */
  onSave: (category: MemoryCategory, content: string, episodic?: MemoryEpisodicChoice) => void;
}

/** Ring circumference for r = 7.5 (the counter progress ring). */
const COUNTER_RING_LENGTH = 2 * Math.PI * 7.5;

function OptionTile({
  selected,
  hueClass,
  glyph,
  label,
  onSelect,
}: {
  selected: boolean;
  hueClass: string;
  glyph: ReactNode;
  label: string;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      className={`${styles.categoryOption} ${hueClass} ${selected ? styles.categoryOptionSelected : ''}`}
      onClick={onSelect}
    >
      <span className={styles.categoryOptionGlyph} aria-hidden>
        {glyph}
      </span>
      <span>{label}</span>
      {selected && (
        <span className={styles.categoryOptionCheck} aria-hidden>
          <Check size={10} strokeWidth={3.4} />
        </span>
      )}
    </button>
  );
}

export function MemoryItemEditor({ session, saving, onCancel, onSave }: MemoryItemEditorProps) {
  const t = useTranslations('pages.memory');
  const tCommon = useTranslations('common');
  const dateLabelId = useId();
  const [category, setCategory] = useState<MemoryCategory>(session.category);
  const [episodicKind, setEpisodicKind] = useState<EpisodicKind>(session.episodicKind ?? 'decision');
  const [date, setDate] = useState(() => session.date ?? todayDate());
  const [content, setContent] = useState(session.content);
  const episodic = session.layer === 'episodic';

  const count = codePointCount(content);
  const tooLong = count > MEMORY_CONTENT_MAX;
  const canSave = !saving && !tooLong && content.trim().length > 0 && (!episodic || date.length > 0);
  const title = session.itemId ? t('editorTitleEdit') : t('editorTitleNew');
  const progress = Math.min(count / MEMORY_CONTENT_MAX, 1) * COUNTER_RING_LENGTH;
  const day = /^\d{4}-\d{2}-(\d{2})$/.exec(date)?.[1];

  return (
    <Dialog open onClose={onCancel} size="lg">
      <h2 className={`${styles.dialogTitle} ${styles.itemEditorTitle}`}>{title}</h2>
      <div className={styles.itemEditor}>
        {episodic ? (
          <>
          <span className={styles.itemEditorLabel} id="memory-editor-kind">
            {t('editorCategory')}
          </span>
          <div className={styles.episodicPicker}>
            <div className={styles.episodicKindPicker} role="radiogroup" aria-labelledby="memory-editor-kind">
              {EPISODIC_KINDS.map((option) => (
                <OptionTile
                  key={option}
                  selected={episodicKind === option}
                  hueClass={styles.hueEpisodic}
                  glyph={<MemoryEpisodicKindGlyph kind={option} />}
                  label={t(EPISODIC_KIND_TITLE_KEY[option])}
                  onSelect={() => setEpisodicKind(option)}
                />
              ))}
            </div>
            <div className={`${styles.categoryOption} ${styles.dateTile}`}>
              <span className={styles.dateTileCalendar} aria-hidden>
                <span className={styles.dateTileCalendarStrip} />
                <span className={styles.dateTileCalendarDay}>{day ? String(Number(day)) : ''}</span>
              </span>
              <span className={styles.dateTileText}>
                <span className={styles.dateTileLabel} id={dateLabelId}>{t('itemDate')}</span>
                <span className={styles.dateTileValue} aria-hidden>{date}</span>
              </span>
              <input
                type="date"
                className={styles.itemEditorDate}
                aria-labelledby={dateLabelId}
                value={date}
                onChange={(e) => setDate(e.target.value)}
                onClick={(e) => {
                  // Open the native picker from anywhere on the tile (not only its icon).
                  try {
                    e.currentTarget.showPicker?.();
                  } catch {
                    // showPicker can refuse (no user activation); the input still edits by keyboard.
                  }
                }}
              />
            </div>
          </div>
          </>
        ) : (
          <>
            <span className={styles.itemEditorLabel} id="memory-editor-category">
              {t('editorCategory')}
            </span>
            <div className={styles.categoryPicker} role="radiogroup" aria-labelledby="memory-editor-category">
              {MEMORY_CATEGORIES.map((option) => (
                <OptionTile
                  key={option}
                  selected={category === option}
                  hueClass={categoryHueClass(option)}
                  glyph={<MemoryCategoryGlyph category={option} />}
                  label={t(categoryTitleKey(option))}
                  onSelect={() => setCategory(option)}
                />
              ))}
            </div>
          </>
        )}
        <textarea
          className={styles.itemEditorTextarea}
          aria-label={title}
          value={content}
          placeholder={t('exampleHint')}
          onChange={(e) => setContent(e.target.value)}
          autoFocus
        />
        <div className={styles.itemEditorFooter}>
          <span className={`${styles.itemEditorCount} ${tooLong ? styles.itemEditorCounterOver : ''}`}>
            <svg width="15" height="15" viewBox="0 0 20 20" aria-hidden focusable={false}>
              <circle cx="10" cy="10" r="7.5" fill="none" className={styles.counterRingTrack} strokeWidth="2.2" />
              <circle
                cx="10"
                cy="10"
                r="7.5"
                fill="none"
                className={styles.counterRingValue}
                strokeWidth="2.2"
                strokeLinecap="round"
                strokeDasharray={`${progress} ${COUNTER_RING_LENGTH}`}
                transform="rotate(-90 10 10)"
              />
            </svg>
            <span className={styles.itemEditorCounter}>{`${count} / ${MEMORY_CONTENT_MAX}`}</span>
          </span>
          {tooLong && (
            <span className={styles.itemEditorTooLong} role="alert">
              {t('editorTooLong')}
            </span>
          )}
          <span className={styles.itemEditorFooterSpacer} />
          <button type="button" className={styles.btnSecondary} onClick={onCancel}>
            {tCommon('cancel')}
          </button>
          <button
            type="button"
            className={styles.btnPrimary}
            disabled={!canSave}
            onClick={() => onSave(category, content.trim(), episodic ? { kind: episodicKind, date } : undefined)}
          >
            {t('save')}
          </button>
        </div>
      </div>
    </Dialog>
  );
}

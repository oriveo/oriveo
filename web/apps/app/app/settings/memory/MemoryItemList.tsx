'use client';

import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronRight, CirclePause, CirclePlay, MoreHorizontal, Pencil, Pin, PinOff, Plus, Smartphone, Sparkles, Trash2 } from 'lucide-react';
import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';
import type { MemoryRecallResolution } from '@oriveo/core/context/memory-recall';
import {
  MEMORY_CATEGORIES,
  categoryOfKind,
  categoryTitleKey,
  episodicDateOf,
  type MemoryCategory,
} from './MemoryItemEditor';
import styles from './MemoryPage.module.css';
import {
  MemoryCategoryGlyph,
  MemoryConflictGlyph,
  MemoryEpisodicGlyph,
  MemoryEpisodicKindGlyph,
  MemoryKeepBothGlyph,
  MemoryScopeGlyph,
  MemorySparkleGlyph,
  categoryHueClass,
} from './MemoryGlyphs';

export interface MemoryL3ConflictPair {
  newer: MemoryItem;
  older: MemoryItem;
}

export interface MemoryItemGroups {
  /** Conflicted items paired by conflictGroupId, in list order. */
  conflicts: MemoryItem[][];
  /** Conflicted episodic pairs (same conflictGroupId), newer first. */
  episodicConflicts: MemoryL3ConflictPair[];
  /** Non-empty categories in display order. */
  groups: Array<{ category: MemoryCategory; items: MemoryItem[] }>;
  /** Active / paused episodic items, newest first. */
  episodic: MemoryItem[];
}

/** Rows the events group shows before "Show all". */
export const EPISODIC_COLLAPSED_LIMIT = 20;

const HIDDEN_STATUSES = new Set(['deleted', 'superseded', 'expired']);

function isEpisodic(item: MemoryItem): boolean {
  return item.layer === 'episodic';
}

/**
 * Items the page shows: no tombstones, no superseded / expired items (never injected);
 * semantic items only when they map to a category, episodic items when active, paused or conflicted.
 */
export function visibleMemoryItems(items: readonly MemoryItem[]): MemoryItem[] {
  return items.filter((m) => {
    if (HIDDEN_STATUSES.has(m.status)) return false;
    return isEpisodic(m) || categoryOfKind(m.kind) !== null;
  });
}

/** Event time of an episodic item: occurredAt, else createdAt. */
function episodicTime(item: MemoryItem): string {
  return item.occurredAt ?? item.createdAt ?? '';
}

/** Newer first: later event time, then larger id. */
function compareEpisodicNewestFirst(a: MemoryItem, b: MemoryItem): number {
  const ta = episodicTime(a);
  const tb = episodicTime(b);
  if (ta !== tb) return ta < tb ? 1 : -1;
  if (a.id === b.id) return 0;
  return a.id < b.id ? 1 : -1;
}

/** YYYY-MM-DD of an episodic item's event time (UTC date part). */
export function episodicDate(item: MemoryItem): string {
  return episodicDateOf(item) ?? '';
}

/**
 * Which side of a conflict pair is this device's: only the copy (id ≠ conflictGroupId) carries the
 * author's deviceId — the original was re-pushed as a local edit, so its deviceId is always the pushing device.
 */
export function isThisDeviceVersion(item: MemoryItem, pair: readonly MemoryItem[], localDeviceId: string): boolean {
  const copy = pair.find((m) => m.conflictGroupId !== null && m.id !== m.conflictGroupId);
  const copyIsLocal = copy?.deviceId === localDeviceId;
  return item === copy ? copyIsLocal : !copyIsLocal;
}

/** L2 conflict pair, this device's version first (same order as iOS / Android). */
export function thisDeviceFirst(pair: readonly MemoryItem[], localDeviceId: string): MemoryItem[] {
  const local = pair.filter((item) => isThisDeviceVersion(item, pair, localDeviceId));
  return [...local, ...pair.filter((item) => !local.includes(item))];
}

export function groupMemoryItems(items: readonly MemoryItem[]): MemoryItemGroups {
  const visible = visibleMemoryItems(items);
  const ordered = MemoryItems.listOrder(visible.filter((m) => !isEpisodic(m)));
  const conflictMap = new Map<string, MemoryItem[]>();
  const byCategory = new Map<MemoryCategory, MemoryItem[]>();
  for (const item of ordered) {
    if (item.status === 'conflicted') {
      const key = item.conflictGroupId ?? item.id;
      conflictMap.set(key, [...(conflictMap.get(key) ?? []), item]);
      continue;
    }
    const category = categoryOfKind(item.kind);
    if (!category) continue;
    byCategory.set(category, [...(byCategory.get(category) ?? []), item]);
  }

  const episodicItems = visible.filter(isEpisodic);
  const episodicConflictMap = new Map<string, MemoryItem[]>();
  for (const item of episodicItems) {
    if (item.status !== 'conflicted' || item.conflictGroupId === null) continue;
    episodicConflictMap.set(item.conflictGroupId, [...(episodicConflictMap.get(item.conflictGroupId) ?? []), item]);
  }
  const episodicConflicts: MemoryL3ConflictPair[] = [];
  for (const pair of episodicConflictMap.values()) {
    if (pair.length !== 2) continue;
    const [newer, older] = [...pair].sort(compareEpisodicNewestFirst);
    episodicConflicts.push({ newer, older });
  }

  return {
    conflicts: [...conflictMap.values()],
    episodicConflicts,
    groups: MEMORY_CATEGORIES
      .filter((category) => (byCategory.get(category)?.length ?? 0) > 0)
      .map((category) => ({ category, items: byCategory.get(category) ?? [] })),
    episodic: episodicItems
      .filter((m) => m.status === 'active' || m.status === 'paused')
      .sort(compareEpisodicNewestFirst),
  };
}

/** "10·14" + "2026" from YYYY-MM-DD. */
function splitEpisodicDate(date: string): { day: string; year: string } | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  return { day: `${date.slice(5, 7)}·${date.slice(8, 10)}`, year: date.slice(0, 4) };
}

/* ───────── Composition spectrum (sidebar) ───────── */

/** Segmented bar of the four groups' counts, a legend, and the events total under a dashed rule. */
export function MemorySpectrum({ items }: { items: readonly MemoryItem[] }) {
  const t = useTranslations('pages.memory');
  const { groups, episodic } = groupMemoryItems(items);
  return (
    <section className={styles.spectrumCard} data-testid="memory-spectrum">
      {groups.length > 0 && (
        <div className={styles.spectrumBar} aria-hidden>
          {groups.map(({ category, items: groupItems }) => (
            <span
              key={category}
              className={`${styles.spectrumSegment} ${categoryHueClass(category)}`}
              style={{ flexGrow: groupItems.length }}
            />
          ))}
        </div>
      )}
      {groups.length > 0 && (
        <div className={styles.spectrumLegend}>
          {groups.map(({ category, items: groupItems }) => (
            <div key={category} className={`${styles.spectrumLegendRow} ${categoryHueClass(category)}`}>
              <span className={styles.spectrumSwatch} aria-hidden />
              <span>{t(categoryTitleKey(category))}</span>
              <span className={styles.spectrumCount}>{groupItems.length}</span>
            </div>
          ))}
        </div>
      )}
      <div className={`${styles.spectrumEpisodic} ${groups.length > 0 ? '' : styles.spectrumEpisodicOnly}`}>
        <span className={styles.spectrumEpisodicMark} aria-hidden>
          <MemoryEpisodicKindGlyph kind="decision" size={11} />
        </span>
        <span>{t('groupEpisodic')}</span>
        <span className={styles.spectrumCount}>{episodic.length}</span>
      </div>
    </section>
  );
}

/* ───────── Item list ───────── */

interface MemoryItemListProps {
  items: readonly MemoryItem[];
  localDeviceId: string;
  /** Folder id → name, for the episodic scope line. */
  folderNames?: ReadonlyMap<string, string>;
  onAdd: (category: MemoryCategory) => void;
  onAddEpisodic: () => void;
  onEdit: (item: MemoryItem) => void;
  onTogglePinned: (item: MemoryItem) => void;
  onToggleStatus: (item: MemoryItem) => void;
  onDelete: (item: MemoryItem) => void;
  onKeepConflict: (item: MemoryItem) => void;
  onResolveL3Conflict: (pair: MemoryL3ConflictPair, resolution: MemoryRecallResolution) => void;
  onOrganize: (item: MemoryItem) => void;
}

function GroupHeader({
  glyph,
  title,
  count,
  action,
}: {
  glyph: ReactNode;
  title: string;
  count: number;
  action?: ReactNode;
}) {
  return (
    <div className={styles.itemGroupHeader}>
      <span className={styles.itemGroupGlyph} aria-hidden>
        {glyph}
      </span>
      <h3 className={styles.itemGroupTitle}>{title}</h3>
      <span className={styles.itemGroupCount} aria-hidden>
        {count}
      </span>
      <span className={styles.itemGroupSpacer} />
      {action}
    </div>
  );
}

export function MemoryItemList({
  items,
  localDeviceId,
  folderNames,
  onAdd,
  onAddEpisodic,
  onEdit,
  onTogglePinned,
  onToggleStatus,
  onDelete,
  onKeepConflict,
  onResolveL3Conflict,
  onOrganize,
}: MemoryItemListProps) {
  const t = useTranslations('pages.memory');
  const { conflicts, episodicConflicts, groups, episodic } = groupMemoryItems(items);
  const [showAllEpisodic, setShowAllEpisodic] = useState(false);
  const collapsed = !showAllEpisodic && episodic.length > EPISODIC_COLLAPSED_LIMIT;
  const shownEpisodic = collapsed ? episodic.slice(0, EPISODIC_COLLAPSED_LIMIT) : episodic;

  const scopeLabel = (item: MemoryItem): string => {
    if (item.scope.type === 'folder') {
      const name = item.scope.id ? folderNames?.get(item.scope.id) : undefined;
      return name ? t('scopeFolderNamed', { name }) : t('scopeFolder');
    }
    if (item.scope.type === 'conversation') return t('scopeConversation');
    return t('scopeAll');
  };

  const addButton = (onClick: () => void) => (
    <button type="button" className={styles.itemGroupAdd} onClick={onClick}>
      <Plus size={13} strokeWidth={2.2} aria-hidden />
      <span>{t('addItem')}</span>
    </button>
  );

  return (
    <div className={styles.itemList}>
      {(conflicts.length > 0 || episodicConflicts.length > 0) && (
        <section className={`${styles.itemGroup} ${styles.conflictGroup}`}>
          <GroupHeader
            glyph={<MemoryConflictGlyph />}
            title={t('groupConflicts')}
            count={conflicts.length + episodicConflicts.length}
          />
          {conflicts.map((pair) => (
            <ul key={pair[0].conflictGroupId ?? pair[0].id} className={styles.conflictPair}>
              {thisDeviceFirst(pair, localDeviceId).map((item) => {
                const thisDevice = isThisDeviceVersion(item, pair, localDeviceId);
                return (
                  <li key={item.id} className={styles.conflictRow}>
                    <span className={styles.conflictOrigin}>
                      <span
                        className={`${styles.conflictMark} ${thisDevice ? '' : styles.conflictMarkHollow}`}
                        aria-hidden
                      />
                      {thisDevice ? t('conflictThisDevice') : t('conflictOtherDevice')}
                    </span>
                    <span className={styles.itemContent} data-testid="memory-item-content">
                      {item.content}
                    </span>
                    <button type="button" className={styles.conflictKeep} onClick={() => onKeepConflict(item)}>
                      {t('conflictKeep')}
                    </button>
                  </li>
                );
              })}
            </ul>
          ))}
          {episodicConflicts.map((pair) => (
            <ul
              key={pair.older.conflictGroupId ?? pair.older.id}
              className={`${styles.conflictPair} ${styles.conflictPairWithFooter}`}
            >
              {([
                ['newer', pair.newer, 'useNew'],
                ['older', pair.older, 'useOld'],
              ] as const).map(([side, item, resolution]) => (
                <li key={item.id} className={styles.conflictRow}>
                  <span className={styles.conflictOrigin}>
                    <span
                      className={`${styles.conflictMark} ${styles.conflictMarkDiamond} ${
                        side === 'newer' ? '' : styles.conflictMarkHollow
                      }`}
                      aria-hidden
                    />
                    {`${t(side === 'newer' ? 'conflictNewer' : 'conflictOlder')} · ${episodicDate(item)}`}
                  </span>
                  <span className={styles.itemContent} data-testid="memory-item-content">
                    {item.content}
                  </span>
                  <button
                    type="button"
                    className={styles.conflictKeep}
                    onClick={() => onResolveL3Conflict(pair, resolution)}
                  >
                    {t('conflictKeep')}
                  </button>
                </li>
              ))}
              <li className={styles.conflictPairFooter}>
                <button type="button" className={styles.conflictKeepBoth} onClick={() => onResolveL3Conflict(pair, 'keepBoth')}>
                  <MemoryKeepBothGlyph />
                  {t('conflictKeepBoth')}
                </button>
              </li>
            </ul>
          ))}
        </section>
      )}

      {groups.map(({ category, items: groupItems }) => (
        <section key={category} className={`${styles.itemGroup} ${categoryHueClass(category)}`}>
          <GroupHeader
            glyph={<MemoryCategoryGlyph category={category} />}
            title={t(categoryTitleKey(category))}
            count={groupItems.length}
            action={addButton(() => onAdd(category))}
          />
          <ul className={styles.itemRows}>
            {groupItems.map((item) => (
              <MemoryItemRow
                key={item.id}
                item={item}
                onEdit={onEdit}
                onTogglePinned={onTogglePinned}
                onToggleStatus={onToggleStatus}
                onDelete={onDelete}
                onOrganize={onOrganize}
              />
            ))}
          </ul>
        </section>
      ))}

      {/* Always shown, even when empty: its "+ Add" is the only way to create an episodic item by hand. */}
      <section className={`${styles.itemGroup} ${styles.hueEpisodic}`}>
        <GroupHeader
          glyph={<MemoryEpisodicGlyph />}
          title={t('groupEpisodic')}
          count={episodic.length}
          action={addButton(onAddEpisodic)}
        />
        {(shownEpisodic.length > 0 || collapsed) && (
          <div className={styles.itemRowsCard}>
            <ul className={styles.itemRows}>
              {shownEpisodic.map((item, index) => (
                <MemoryItemRow
                  key={item.id}
                  item={item}
                  episodic={{
                    date: episodicDate(item),
                    scope: scopeLabel(item),
                    first: index === 0,
                  }}
                  onEdit={onEdit}
                  onTogglePinned={onTogglePinned}
                  onToggleStatus={onToggleStatus}
                  onDelete={onDelete}
                  onOrganize={onOrganize}
                />
              ))}
            </ul>
            {collapsed && (
              <button type="button" className={styles.itemShowAll} onClick={() => setShowAllEpisodic(true)}>
                <span>{t('showAll', { count: episodic.length })}</span>
                <ChevronRight size={14} strokeWidth={2.2} className={styles.itemShowAllChevron} aria-hidden />
              </button>
            )}
          </div>
        )}
        <p className={styles.itemGroupFootnote}>
          <Smartphone size={13} strokeWidth={1.8} aria-hidden />
          <span>{t('episodicLocalOnly')}</span>
        </p>
      </section>
    </div>
  );
}

interface MemoryItemRowProps {
  item: MemoryItem;
  /** Episodic rows: date column + timeline marker + scope tag; no "Split into items". */
  episodic?: { date: string; scope: string; first: boolean };
  onEdit: (item: MemoryItem) => void;
  onTogglePinned: (item: MemoryItem) => void;
  onToggleStatus: (item: MemoryItem) => void;
  onDelete: (item: MemoryItem) => void;
  onOrganize: (item: MemoryItem) => void;
}

/** Migrated free-text memory that still spans several lines gets an inline "Split into items". */
function suggestsOrganize(item: MemoryItem): boolean {
  return item.source.type === 'migration' && item.content.includes('\n');
}

function MemoryItemRow({ item, episodic, onEdit, onTogglePinned, onToggleStatus, onDelete, onOrganize }: MemoryItemRowProps) {
  const t = useTranslations('pages.memory');
  const tSidebar = useTranslations('sidebar');
  const [menuOpen, setMenuOpen] = useState(false);
  const rowRef = useRef<HTMLLIElement | null>(null);
  const paused = item.status === 'paused';

  // Close the menu on outside pointer down or Escape.
  useEffect(() => {
    if (!menuOpen) return;
    const onPointerDown = (e: PointerEvent) => {
      if (rowRef.current && !rowRef.current.contains(e.target as Node)) setMenuOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [menuOpen]);

  const choose = (action: (item: MemoryItem) => void) => {
    setMenuOpen(false);
    action(item);
  };

  const dateParts = episodic ? splitEpisodicDate(episodic.date) : null;
  const rowClass = [
    styles.itemRow,
    episodic ? styles.timelineRow : '',
    paused ? styles.itemRowPaused : '',
    item.pinned && !episodic ? styles.itemRowPinned : '',
    menuOpen ? styles.itemRowMenuOpen : '',
  ].filter(Boolean).join(' ');

  return (
    <li ref={rowRef} className={rowClass}>
      {episodic && (
        <>
          <time className={styles.timelineDate} dateTime={episodic.date} data-testid="memory-item-date">
            {dateParts && (
              <>
                <span className={styles.timelineDay}>{dateParts.day}</span>
                <span className={styles.timelineYear}>{dateParts.year}</span>
              </>
            )}
          </time>
          <span className={`${styles.timelineRail} ${episodic.first ? styles.timelineRailFirst : ''}`} aria-hidden>
            <span className={item.kind === 'event' ? styles.timelineMarkEvent : styles.timelineMarkDecision} />
          </span>
        </>
      )}
      <div className={episodic ? styles.timelineBody : styles.itemBody}>
        <span className={styles.itemText}>
          {item.pinned && (
            <span className={styles.itemPin} role="img" aria-label={t('itemPinnedA11y')}>
              <Pin size={12} strokeWidth={2.4} aria-hidden />
            </span>
          )}
          <span className={styles.itemContent} data-testid="memory-item-content">
            {item.content}
          </span>
        </span>
        {episodic && (
          <span className={styles.scopeTag} data-testid="memory-item-scope">
            <MemoryScopeGlyph type={item.scope.type} />
            {episodic.scope}
          </span>
        )}
        {!episodic && suggestsOrganize(item) && (
          <button type="button" className={styles.itemOrganize} onClick={() => onOrganize(item)}>
            <MemorySparkleGlyph size={11} />
            {t('actionOrganize')}
          </button>
        )}
      </div>
      {paused && <span className={styles.itemPausedBadge}>{t('itemPausedBadge')}</span>}
      <div className={styles.itemMenuAnchor}>
        <button
          type="button"
          className={styles.itemMore}
          aria-label={tSidebar('more')}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen((open) => !open)}
        >
          <MoreHorizontal size={16} strokeWidth={2.2} aria-hidden />
        </button>
        {menuOpen && (
          <div className={styles.itemMenu} role="menu">
            <button type="button" role="menuitem" className={styles.itemMenuItem} onClick={() => choose(onEdit)}>
              <Pencil size={15} strokeWidth={1.9} aria-hidden />
              {t('actionEdit')}
            </button>
            <button type="button" role="menuitem" className={styles.itemMenuItem} onClick={() => choose(onTogglePinned)}>
              {item.pinned ? <PinOff size={15} strokeWidth={1.9} aria-hidden /> : <Pin size={15} strokeWidth={1.9} aria-hidden />}
              {item.pinned ? t('actionUnpin') : t('actionPin')}
            </button>
            <button type="button" role="menuitem" className={styles.itemMenuItem} onClick={() => choose(onToggleStatus)}>
              {paused ? <CirclePlay size={15} strokeWidth={1.9} aria-hidden /> : <CirclePause size={15} strokeWidth={1.9} aria-hidden />}
              {paused ? t('actionResume') : t('actionPause')}
            </button>
            {!episodic && (
              <button type="button" role="menuitem" className={styles.itemMenuItem} onClick={() => choose(onOrganize)}>
                <Sparkles size={15} strokeWidth={1.9} aria-hidden />
                {t('actionOrganize')}
              </button>
            )}
            <div className={styles.itemMenuSeparator} role="separator" />
            <button
              type="button"
              role="menuitem"
              className={`${styles.itemMenuItem} ${styles.itemMenuItemDanger}`}
              onClick={() => choose(onDelete)}
            >
              <Trash2 size={15} strokeWidth={1.9} aria-hidden />
              {t('actionDelete')}
            </button>
          </div>
        )}
      </div>
    </li>
  );
}

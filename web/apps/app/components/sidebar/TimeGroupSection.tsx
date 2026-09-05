'use client';

import { useTranslations } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import { ConversationGroup } from './ConversationGroup';
import type { GroupKey } from '../../lib/utils/conversation-grouping';
import styles from './ConversationList.module.css';

export const EARLIER_PAGE_SIZE = 10;

interface ConversationGroupDisplay {
  items: Conversation[];
  remainingCount: number;
}

export function resolveConversationGroupDisplay(
  groupKey: GroupKey,
  items: Conversation[],
  editMode: boolean,
  earlierDisplayCount: number,
): ConversationGroupDisplay {
  if (groupKey !== 'earlier' || editMode) {
    return {
      items,
      remainingCount: 0,
    };
  }

  const displayItems = items.slice(0, earlierDisplayCount);
  return {
    items: displayItems,
    remainingCount: Math.max(0, items.length - displayItems.length),
  };
}

interface TimeGroupSectionProps {
  group: { key: GroupKey; items: Conversation[] };
  activeId: string | null;
  editMode: boolean;
  selectedIds: Set<string>;
  earlierDisplayCount: number;
  onSelect: (id: string) => void;
  onRename: (id: string, newTitle: string) => void;
  onDelete: (id: string) => void;
  onTogglePin: (id: string) => void;
  onToggleSelect: (id: string) => void;
  variant?: 'sidebar' | 'mobileHome';
  onShowMore: () => void;
}

export function TimeGroupSection({
  group,
  activeId,
  editMode,
  selectedIds,
  earlierDisplayCount,
  onSelect,
  onRename,
  onDelete,
  onTogglePin,
  onToggleSelect,
  variant,
  onShowMore,
}: TimeGroupSectionProps) {
  const t = useTranslations('sidebar');
  const display = resolveConversationGroupDisplay(
    group.key,
    group.items,
    editMode,
    earlierDisplayCount,
  );

  return (
    <div>
      <div className={styles.groupLabel}>{t(group.key)}</div>
      <div className={styles.groupedCard}>
        <ConversationGroup conversations={display.items} activeId={activeId} editMode={editMode}
          selectedIds={selectedIds} isPinned={false} onSelect={onSelect}
          onRename={onRename} onDelete={onDelete} onTogglePin={onTogglePin}
          onToggleSelect={onToggleSelect}
          variant={variant} />
      </div>
      {group.key === 'earlier' && display.remainingCount > 0 && (
        <button
          type="button"
          className={styles.showMoreBtn}
          onClick={onShowMore}
        >
          {t('showMore', { count: display.remainingCount })}
        </button>
      )}
    </div>
  );
}

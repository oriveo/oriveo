'use client';

import { useTranslations } from 'next-intl';
import { SearchIcon, CloseIcon } from '@oriveo/ui';
import styles from './ConversationList.module.css';

interface SidebarToolbarProps {
  editMode: boolean;
  selectedIds: Set<string>;
  allVisibleIds: string[];
  searchQuery: string;
  onSearchChange: (value: string) => void;
  hasVisibleConversations: boolean;
  onSelectAll: () => void;
  onDeselectAll: () => void;
  onShowBatchConfirm: () => void;
  onExitEditMode: () => void;
  onShowCreateFolder: () => void;
  onEnterEditMode: () => void;
}

export function SidebarToolbar({
  editMode,
  selectedIds,
  allVisibleIds,
  searchQuery,
  onSearchChange,
  hasVisibleConversations,
  onSelectAll,
  onDeselectAll,
  onShowBatchConfirm,
  onExitEditMode,
  onShowCreateFolder,
  onEnterEditMode,
}: SidebarToolbarProps) {
  const t = useTranslations('sidebar');

  return (
    <div className={styles.toolbar}>
      {editMode ? (
        <div className={styles.editToolbar}>
          <button type="button" className={styles.editToolbarBtn}
            onClick={selectedIds.size === allVisibleIds.length ? onDeselectAll : onSelectAll}>
            {selectedIds.size === allVisibleIds.length ? t('deselectAll') : t('selectAll')}
          </button>
          <span className={styles.editToolbarSpacer} />
          {selectedIds.size > 0 && (
            <button type="button" className={`${styles.editToolbarBtn} ${styles.editToolbarDanger}`}
              onClick={onShowBatchConfirm}>
              {t('batchDelete')} ({selectedIds.size})
            </button>
          )}
          <button type="button" className={styles.editToolbarDone} onClick={onExitEditMode}>
            {t('exitEditMode')}
          </button>
        </div>
      ) : (
        <div className={styles.searchRow}>
          <div className={styles.searchWrap}>
            <SearchIcon className={styles.searchIcon} />
            <input type="text" className={styles.searchInput} placeholder={t('searchPlaceholder')}
              value={searchQuery} onChange={(e) => onSearchChange(e.target.value)} />
            {searchQuery && (
              <button type="button" className={styles.searchClear}
                onClick={() => onSearchChange('')} aria-label={t('clearSearch')}>
                <CloseIcon size={12} />
              </button>
            )}
          </div>
          <button type="button" className={styles.editToggle}
            onClick={onShowCreateFolder} aria-label={t('newFolder')}
            title={t('newFolder')}>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
              <line x1="12" y1="11" x2="12" y2="17" /><line x1="9" y1="14" x2="15" y2="14" />
            </svg>
          </button>
          {hasVisibleConversations && (
            <button type="button" className={styles.editToggle}
              onClick={onEnterEditMode} aria-label={t('editMode')}>
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <rect x="3" y="5" width="6" height="6" rx="1" /><path d="M3 17l2 2 4-4" />
                <line x1="13" y1="6" x2="21" y2="6" /><line x1="13" y1="12" x2="21" y2="12" /><line x1="13" y1="18" x2="21" y2="18" />
              </svg>
            </button>
          )}
        </div>
      )}
    </div>
  );
}

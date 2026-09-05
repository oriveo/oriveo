'use client';

import { useMemo, useCallback, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import type { Folder } from '@oriveo/shared';
import { getFolderColorPair } from '@oriveo/shared';
import { useAppStore } from '../../providers/StoreProvider';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as folderOps from '../../lib/core/folder-ops';
import { useDismissOnOutsideClick } from '../../lib/hooks/useDismissOnOutsideClick';
import { showToast } from '../Toast';

interface MoveToFolderMenuProps {
  position: { x: number; y: number };
  convIds: string[];
  currentFolderId?: string;
  onClose: () => void;
}

export function MoveToFolderMenu({ position, convIds, currentFolderId, onClose }: MoveToFolderMenuProps) {
  const folders = useAppStore((s) => s.folders);
  const t = useTranslations('sidebar');
  const menuRef = useRef<HTMLDivElement>(null);
  const [showCreateInput, setShowCreateInput] = useState(false);
  const [newFolderName, setNewFolderName] = useState('');

  useDismissOnOutsideClick(menuRef, { onDismiss: onClose, closeOnEscape: true });

  const sorted = useMemo(
    () => [...folders].sort((a, b) => a.sortOrder - b.sortOrder),
    [folders],
  );

  const handleMoveToFolder = useCallback((folderId: string, folderName: string) => {
    if (convIds.length === 1) {
      folderOps.moveConversationToFolder(getVanillaStore(), convIds[0], folderId);
      showToast(t('movedToFolder', { name: folderName }));
    } else {
      folderOps.batchMoveToFolder(getVanillaStore(), convIds, folderId);
      showToast(t('batchMovedToFolder', { count: convIds.length, name: folderName }));
    }
    onClose();
  }, [convIds, onClose, t]);

  const handleRemoveFromFolder = useCallback(() => {
    if (convIds.length === 1) {
      folderOps.moveConversationToFolder(getVanillaStore(), convIds[0], null);
      showToast(t('movedOutOfFolder'));
    } else {
      folderOps.batchMoveToFolder(getVanillaStore(), convIds, null);
      showToast(t('batchMovedOut', { count: convIds.length }));
    }
    onClose();
  }, [convIds, onClose, t]);

  const handleCreateAndMove = useCallback(() => {
    if (!newFolderName.trim()) return;
    const folder = folderOps.createFolder(getVanillaStore(), newFolderName);
    if (!folder) return;
    if (convIds.length === 1) {
      folderOps.moveConversationToFolder(getVanillaStore(), convIds[0], folder.id);
    } else {
      folderOps.batchMoveToFolder(getVanillaStore(), convIds, folder.id);
    }
    showToast(t('movedToFolder', { name: folder.name }));
    onClose();
  }, [convIds, newFolderName, onClose, t]);

  // Keep the menu inside the viewport.
  const menuStyle: React.CSSProperties = {
    position: 'fixed',
    left: Math.min(position.x, typeof window !== 'undefined' ? window.innerWidth - 220 : position.x),
    top: Math.min(position.y, typeof window !== 'undefined' ? window.innerHeight - 300 : position.y),
    zIndex: 10001,
    minWidth: 200,
    maxHeight: 280,
    overflowY: 'auto',
    background: 'var(--o-surface-overlay)',
    backdropFilter: 'blur(12px)',
    border: '1px solid var(--o-border)',
    borderRadius: 'var(--o-radius-md)',
    boxShadow: 'var(--o-elevation-modal)',
    padding: '4px 0',
    animation: 'menuIn 120ms ease-out',
  };

  const itemStyle: React.CSSProperties = {
    display: 'flex', alignItems: 'center', gap: 8, width: '100%',
    padding: '8px 12px', border: 'none', background: 'none',
    color: 'var(--o-text)', fontSize: 'var(--o-text-sm)', cursor: 'pointer',
    textAlign: 'left',
  };

  return (
    <div ref={menuRef} style={menuStyle}>
      <style>{`@keyframes menuIn { from { opacity: 0; transform: scale(0.96); } to { opacity: 1; transform: scale(1); } }`}</style>

      {/*   */}
      {sorted.map((folder) => {
        const isCurrent = folder.id === currentFolderId;
        return (
          <button
          key={folder.id}
          type="button"
          disabled={isCurrent}
          style={{
            ...itemStyle,
            fontWeight: isCurrent ? 600 : 400,
            color: isCurrent ? 'var(--o-text-tertiary)' : 'var(--o-text)',
            cursor: isCurrent ? 'not-allowed' : 'pointer',
            opacity: isCurrent ? 0.5 : 1,
          }}
          onClick={() => !isCurrent && handleMoveToFolder(folder.id, folder.name)}
          onMouseEnter={(e) => !isCurrent && (e.currentTarget.style.background = 'var(--o-surface-raised)')}
          onMouseLeave={(e) => (e.currentTarget.style.background = 'none')}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke={getFolderColorPair(folder.colorTag)[0]} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
          </svg>
          <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {folder.name}
          </span>
        </button>
        );
      })}

      {/*   */}
      {sorted.length > 0 && (
        <div style={{ height: 1, background: 'var(--o-border)', margin: '4px 8px' }} />
      )}

      {/*   */}
      {showCreateInput ? (
        <div style={{ padding: '6px 12px', display: 'flex', gap: 6 }}>
          <input
            type="text"
            value={newFolderName}
            onChange={(e) => setNewFolderName(e.target.value.slice(0, 30))}
            placeholder={t('folderNamePlaceholder')}
            autoFocus
            onKeyDown={(e) => {
              if (e.key === 'Enter' && newFolderName.trim()) handleCreateAndMove();
              if (e.key === 'Escape') setShowCreateInput(false);
            }}
            maxLength={30}
            style={{
              flex: 1, minWidth: 0, padding: '4px 8px', border: '1px solid var(--o-border)',
              borderRadius: 'var(--o-radius-sm)', background: 'var(--o-surface)',
              color: 'var(--o-text)', fontSize: 'var(--o-text-xs)', outline: 'none',
            }}
          />
        </div>
      ) : (
        <button
          type="button"
          style={{ ...itemStyle, color: 'var(--o-primary)' }}
          onClick={() => setShowCreateInput(true)}
          onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--o-surface-raised)')}
          onMouseLeave={(e) => (e.currentTarget.style.background = 'none')}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
          </svg>
          {t('newFolder')}
        </button>
      )}

      {/*   */}
      {currentFolderId && (
        <>
          <div style={{ height: 1, background: 'var(--o-border)', margin: '4px 8px' }} />
          <button
            type="button"
            style={{ ...itemStyle, color: 'var(--o-text-secondary)' }}
            onClick={handleRemoveFromFolder}
            onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--o-surface-raised)')}
            onMouseLeave={(e) => (e.currentTarget.style.background = 'none')}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
            {t('removeFromFolder')}
          </button>
        </>
      )}
    </div>
  );
}

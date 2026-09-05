'use client';

import { useState, useCallback, useRef } from 'react';
import { useTranslations } from 'next-intl';
import { useFocusTrap } from '../../lib/hooks/useFocusTrap';
import { getVanillaStore } from '../../providers/StoreProvider';
import { createFolder } from '../../lib/core/folder-ops';
import { showToast } from '../Toast';

interface CreateFolderDialogProps {
  open: boolean;
  onClose: () => void;
}

export function CreateFolderDialog({ open, onClose }: CreateFolderDialogProps) {
  const [name, setName] = useState('');
  const t = useTranslations('sidebar');
  const dialogRef = useRef<HTMLDivElement>(null);
  useFocusTrap(dialogRef, open);

  const handleCreate = useCallback(() => {
    if (!name.trim()) return;
    const folder = createFolder(getVanillaStore(), name);
    if (!folder) return;
    showToast(t('folderCreated', { name: folder.name }));
    onClose();
    setName('');
  }, [name, onClose, t]);

  const handleClose = useCallback(() => {
    onClose();
    setName('');
  }, [onClose]);

  if (!open) return null;

  return (
    <div
      style={{
        position: 'fixed', inset: 0, zIndex: 9999, display: 'flex',
        alignItems: 'center', justifyContent: 'center',
        background: 'rgba(0,0,0,0.4)',
      }}
      onClick={handleClose}
    >
      <div
        ref={dialogRef}
        style={{
          background: 'var(--o-surface-raised)', border: '1px solid var(--o-border)',
          borderRadius: 'var(--o-radius-lg)', padding: 'var(--o-space-lg)',
          maxWidth: 340, width: '90%', boxShadow: 'var(--o-elevation-modal)',
          animation: 'dialogIn 200ms ease-out',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <style>{`@keyframes dialogIn { from { opacity: 0; transform: scale(0.96); } to { opacity: 1; transform: scale(1); } }`}</style>
        <h3 style={{ margin: '0 0 12px', fontSize: 'var(--o-text-sm)', fontWeight: 600, color: 'var(--o-text)' }}>
          {t('newFolder')}
        </h3>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value.slice(0, 30))}
          placeholder={t('folderNamePlaceholder')}
          autoFocus
          onKeyDown={(e) => e.key === 'Enter' && name.trim() && handleCreate()}
          maxLength={30}
          style={{
            width: '100%', padding: '8px 12px', border: '1px solid var(--o-border)',
            borderRadius: 'var(--o-radius-md)', background: 'var(--o-surface)',
            color: 'var(--o-text)', fontSize: 'var(--o-text-sm)', outline: 'none',
            boxSizing: 'border-box',
          }}
        />
        <div style={{ textAlign: 'right', fontSize: 11, color: 'var(--o-text-tertiary)', margin: '4px 0 12px' }}>
          {name.length}/30
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button type="button" style={{
            flex: 1, padding: '8px 12px', border: 'none', borderRadius: 'var(--o-radius-md)',
            background: 'var(--o-surface)', color: 'var(--o-text-secondary)', fontSize: 'var(--o-text-sm)',
            fontWeight: 600, cursor: 'pointer',
          }} onClick={handleClose}>{t('cancel')}</button>
          <button type="button" style={{
            flex: 1, padding: '8px 12px', border: 'none', borderRadius: 'var(--o-radius-md)',
            background: 'var(--o-primary)', color: 'var(--o-primary-text)', fontSize: 'var(--o-text-sm)',
            fontWeight: 600, cursor: 'pointer', opacity: name.trim() ? 1 : 0.5,
          }} onClick={handleCreate} disabled={!name.trim()}>{t('create')}</button>
        </div>
      </div>
    </div>
  );
}

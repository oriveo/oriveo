'use client';

import { useTranslations } from 'next-intl';
import type { Conversation, Folder } from '@oriveo/shared';
import { FolderItem } from './FolderItem';

interface FolderSectionProps {
  folders: Folder[];
  conversationsByFolder: Map<string, Conversation[]>;
  onSelectConversation: (id: string) => void;
  editMode: boolean;
  selectedIds: Set<string>;
  onToggleSelect: (id: string) => void;
  variant?: 'sidebar' | 'mobileHome';
}

export function FolderSection({
  folders,
  conversationsByFolder,
  onSelectConversation,
  editMode,
  selectedIds,
  onToggleSelect,
  variant = 'sidebar',
}: FolderSectionProps) {
  const t = useTranslations('sidebar');

  return (
    <div role="group" aria-label={t('folders')}>
      {folders.map((folder) => (
        <FolderItem
          key={folder.id}
          folder={folder}
          conversations={conversationsByFolder.get(folder.id) ?? []}
          onSelectConversation={onSelectConversation}
          editMode={editMode}
          selectedIds={selectedIds}
          onToggleSelect={onToggleSelect}
          variant={variant}
        />
      ))}
    </div>
  );
}

'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Archive, FolderPlus, NotebookPen, Plus, Trash2 } from 'lucide-react';
import { Button } from '@oriveo/ui';
import { useAppStore, getVanillaStore } from '../../providers/StoreProvider';
import { createNote, deleteNote, restoreNote } from '../../lib/core/note-ops';
import { buildBlankNoteInput } from '../../lib/core/notes/capture';
import { getAllNoteTags, sortNotes, filterNotesByTags, type NoteSortKey } from '../../lib/utils/note-list';
import { searchNotes } from '../../lib/utils/note-search';
import { ConfirmDialog } from '../../components/dialogs/ConfirmDialog';
import { showToast } from '../../components/Toast';
import { CreateNoteFolderDialog } from '../../components/notes/CreateNoteFolderDialog';
import { NoteFolderList, UNCATEGORIZED_NOTE_FOLDER_FILTER } from '../../components/notes/NoteFolderList';
import { NoteList } from '../../components/notes/NoteList';
import { NoteListToolbar } from '../../components/notes/NoteListToolbar';
import { NoteTrashView } from '../../components/notes/NoteTrashView';
import { showSavedNoteToast } from '../../components/notes/note-toast';
import styles from '../../components/notes/Notes.module.css';

type NotesView = 'notes' | 'trash';

const PAGE_SIZE = 10;

export function NotesPage() {
  const router = useRouter();
  const t = useTranslations('notes');
  const tSidebar = useTranslations('sidebar');
  const notes = useAppStore((s) => s.notes);
  const trashedNotes = useAppStore((s) => s.trashedNotes);
  const noteFolders = useAppStore((s) => s.noteFolders);
  const hydrationPhase = useAppStore((s) => s.hydrationPhase);

  const [query, setQuery] = useState('');
  const [sortKey, setSortKey] = useState<NoteSortKey>('updatedAt');
  const [selectedTags, setSelectedTags] = useState<string[]>([]);
  const [activeFolderId, setActiveFolderId] = useState<string | null>(null);
  const [view, setView] = useState<NotesView>('notes');
  const [showFolderDialog, setShowFolderDialog] = useState(false);
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);

  const folderFiltered = useMemo(
    () => {
      if (!activeFolderId) return notes;
      if (activeFolderId === UNCATEGORIZED_NOTE_FOLDER_FILTER) {
        return notes.filter((note) => !note.noteFolderID);
      }
      return notes.filter((note) => note.noteFolderID === activeFolderId);
    },
    [activeFolderId, notes],
  );
  // The tag chips list only tags present in the current folder, so a tag that is absent here cannot be tapped into an empty, dead-end list.
  const allTags = useMemo(() => getAllNoteTags(folderFiltered), [folderFiltered]);
  const visibleNotes = useMemo(
    () => sortNotes(filterNotesByTags(searchNotes(folderFiltered, query), selectedTags), sortKey),
    [folderFiltered, query, selectedTags, sortKey],
  );

  // Clear the tag filter when switching folders: tags are scoped to the current folder, and keeping them across folders filters down to nothing.
  useEffect(() => {
    setSelectedTags([]);
  }, [activeFolderId]);

  // Any change to the filters returns to the first page, so results are not hidden behind a stale expanded page count.
  useEffect(() => {
    setVisibleCount(PAGE_SIZE);
  }, [activeFolderId, query, selectedTags, sortKey]);

  const pagedNotes = useMemo(() => visibleNotes.slice(0, visibleCount), [visibleNotes, visibleCount]);
  const remainingCount = visibleNotes.length - pagedNotes.length;

  const handleCreateBlank = useCallback(() => {
    // Creating a note while inside a folder files it there; otherwise it lands in "unfiled".
    const note = createNote(getVanillaStore(), buildBlankNoteInput(activeFolderId ?? undefined));
    showSavedNoteToast({
      note,
      fallbackTitle: t('untitled'),
      viewLabel: t('toast.view'),
      onView: () => router.push(`/notes/${note.id}`),
    });
    router.push(`/notes/${note.id}`);
  }, [router, t, activeFolderId]);

  const handleConfirmDelete = useCallback(() => {
    if (!pendingDeleteId) return;
    const id = pendingDeleteId;
    deleteNote(getVanillaStore(), id);
    setPendingDeleteId(null);
    showToast(t('toast.deleted'), 5000, () => restoreNote(getVanillaStore(), id), 'warning', t('actions.undo'));
  }, [pendingDeleteId, t]);

  const activeFolder = activeFolderId === UNCATEGORIZED_NOTE_FOLDER_FILTER
    ? { name: t('folders.uncategorized') }
    : noteFolders.find((folder) => folder.id === activeFolderId);

  return (
    <div className={styles.pageShell}>
      <div className={styles.pageHeader}>
        <div>
          <h1 className={styles.pageTitle}>{t('title')}</h1>
          <p className={styles.pageSubtitle}>
            {!activeFolder ? (
              <span className={styles.notePurposeLine}>
                <span className={styles.notePurposeIcon} aria-hidden="true">
                  {/* The same NotebookPen icon as the home and sidebar entries. The old sticky-note
                      plus-sign overlay turned to mush at 14px, and the plus belongs to the "save as
                      note" action button rather than to the page identity. */}
                  <NotebookPen size={14} strokeWidth={2.35} />
                </span>
                <span>{t('subtitle')}</span>
              </span>
            ) : activeFolder.name}
          </p>
        </div>
        <div className={styles.headerCluster}>
          <div className={styles.headerActions}>
            <Button tone="secondary" size="sm" className={styles.headerButton} onClick={() => setShowFolderDialog(true)}>
              <FolderPlus size={15} aria-hidden />
              {t('folders.new')}
            </Button>
            <Button size="sm" className={styles.primaryHeaderButton} onClick={handleCreateBlank}>
              <Plus size={15} aria-hidden />
              {t('actions.newBlank')}
            </Button>
          </div>
        </div>
      </div>

      <div className={styles.viewTabs} role="tablist" aria-label={t('tabs.label')}>
        <button
          type="button"
          className={styles.viewTab}
          data-active={view === 'notes' ? 'true' : undefined}
          onClick={() => setView('notes')}
        >
          <Archive size={15} aria-hidden />
          {t('tabs.notes')}
        </button>
        <button
          type="button"
          className={styles.viewTab}
          data-active={view === 'trash' ? 'true' : undefined}
          onClick={() => setView('trash')}
        >
          <Trash2 size={15} aria-hidden />
          {t('tabs.trash')}
          {trashedNotes.length > 0 ? <span className={styles.countPill}>{trashedNotes.length}</span> : null}
        </button>
      </div>

      {view === 'notes' ? (
        <div className={styles.notesGrid}>
          <aside className={styles.folderPane}>
            <NoteFolderList
              folders={noteFolders}
              notes={notes}
              activeFolderId={activeFolderId}
              onSelectFolder={setActiveFolderId}
            />
          </aside>
          <section className={styles.listPane}>
            <NoteListToolbar
              query={query}
              onQueryChange={setQuery}
              sortKey={sortKey}
              onSortKeyChange={setSortKey}
              allTags={allTags}
              selectedTags={selectedTags}
              onSelectedTagsChange={setSelectedTags}
            />
            <NoteList
              notes={pagedNotes}
              loading={hydrationPhase !== 'ready'}
              onOpenNote={(noteId) => router.push(`/notes/${noteId}`)}
              onCreateBlank={handleCreateBlank}
              onDeleteNote={setPendingDeleteId}
            />
            {remainingCount > 0 ? (
              <button
                type="button"
                className={styles.showMoreBtn}
                onClick={() => setVisibleCount((count) => count + PAGE_SIZE)}
              >
                {tSidebar('showMore', { count: remainingCount })}
              </button>
            ) : null}
          </section>
        </div>
      ) : (
        <NoteTrashView notes={trashedNotes} onOpenNote={(noteId) => router.push(`/notes/${noteId}`)} />
      )}

      <CreateNoteFolderDialog
        open={showFolderDialog}
        onClose={() => setShowFolderDialog(false)}
        onCreated={(folderId) => setActiveFolderId(folderId)}
      />
      <ConfirmDialog
        open={pendingDeleteId !== null}
        title={t('delete.title')}
        message={t('delete.message')}
        confirmLabel={t('actions.delete')}
        cancelLabel={t('actions.cancel')}
        destructive
        onConfirm={handleConfirmDelete}
        onCancel={() => setPendingDeleteId(null)}
      />
    </div>
  );
}

'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { ArrowLeft, Check, Download, FolderInput, Pencil, Pin, PinOff, Tag, Trash2, X } from 'lucide-react';
import type { CSSProperties } from 'react';
import type { Note } from '@oriveo/shared';
import { Button, EmptyState } from '@oriveo/ui';
import { useAppStore, getVanillaStore } from '../../providers/StoreProvider';
import {
  deleteNote,
  discardEmptyBlankNote,
  moveNoteToFolder,
  restoreNote,
  toggleNotePin,
  updateNoteBody,
  updateNoteTags,
  updateNoteTitle,
} from '../../lib/core/note-ops';
import { buildNoteMarkdown, buildNoteMarkdownFilename, downloadMarkdown } from '../../lib/core/notes/note-export';
import { getNoteSourceLinkState } from '../../lib/core/notes/source-link';
import { warmConversationAnchorInStore } from '../../lib/core/chat/conversation-bootstrap';
import { PROVIDER_BRAND_COLORS } from '../../lib/constants/provider-brand-colors';
import { normalizeUUID, sameNormalizedID } from '../../lib/utils/id-utils';
import { getSuggestedNoteTags } from '../../lib/utils/note-list';
import { MarkdownRenderer } from '../chat/MarkdownRenderer';
import { ProviderIcon } from '../ProviderIcon';
import { ConfirmDialog } from '../dialogs/ConfirmDialog';
import { showToast } from '../Toast';
import { MoveToNoteFolderDialog } from './MoveToNoteFolderDialog';
import { NoteSourceCard } from './NoteSourceCard';
import { NoteTagEditor } from './NoteTagEditor';
import { extractCrosscheckDisplayBody } from './note-display-text';
import { CrosscheckSheet } from '../chat/CrosscheckSheet';
import styles from './Notes.module.css';

interface NoteDetailProps {
  noteId: string;
}

export function NoteDetail({ noteId }: NoteDetailProps) {
  const router = useRouter();
  const t = useTranslations('notes');
  const notes = useAppStore((s) => s.notes);
  const trashedNotes = useAppStore((s) => s.trashedNotes);
  const noteFolders = useAppStore((s) => s.noteFolders);
  const conversations = useAppStore((s) => s.conversations);
  const providers = useAppStore((s) => s.providers);
  const locallyDeletedConversationIds = useAppStore((s) => s.locallyDeletedConversationIds);
  const note = useMemo(
    () => [...notes, ...trashedNotes].find((candidate) => sameNormalizedID(candidate.id, noteId)),
    [noteId, notes, trashedNotes],
  );
  const isTrashed = Boolean(note?.deletedAt);
  const [isEditingBody, setIsEditingBody] = useState(false);
  const [bodyDraft, setBodyDraft] = useState('');
  const [titleDraft, setTitleDraft] = useState<string | null>(null);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [showMoveDialog, setShowMoveDialog] = useState(false);
  const [showCrosscheck, setShowCrosscheck] = useState(false);
  const [contentPane, setContentPane] = useState<'body' | 'snapshot'>('body');
  const leaveStateRef = useRef<{ note: Note | undefined; titleDraft: string | null }>({
    note: undefined,
    titleDraft: null,
  });

  const linkState = useMemo(
    () => note ? getNoteSourceLinkState(note, conversations, locallyDeletedConversationIds) : { available: false as const, reason: 'noSource' as const },
    [conversations, locallyDeletedConversationIds, note],
  );
  const sourceConversation = useMemo(
    () => note?.sourceConversationId
      ? conversations.find((conversation) => sameNormalizedID(conversation.id, note.sourceConversationId))
      : undefined,
    [conversations, note?.sourceConversationId],
  );
  const sourceMessage = useMemo(
    () => note?.sourceMessageId
      ? sourceConversation?.messages.find((message) => sameNormalizedID(message.id, note.sourceMessageId))
      : undefined,
    [note?.sourceMessageId, sourceConversation?.messages],
  );
  const sourceProvider = useMemo(
    () => sourceMessage?.providerID
      ? providers.find((provider) => sameNormalizedID(provider.id, sourceMessage.providerID))
      : providers.find((provider) => provider.kind === note?.sourceProviderKind),
    [note?.sourceProviderKind, providers, sourceMessage?.providerID],
  );
  const sourceModel = useMemo(() => {
    const modelId = sourceMessage?.modelID ?? note?.sourceModelID;
    const model = sourceProvider?.models.find((candidate) => candidate.id === modelId || candidate.canonicalModelId === modelId);
    if (model) return model;
    if (!modelId && !note?.sourceModelName) return undefined;
    return {
      id: modelId ?? note!.sourceModelName!,
      name: note?.sourceModelName ?? modelId!,
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
    };
  }, [note, sourceMessage?.modelID, sourceProvider?.models]);
  const canCrosscheck = Boolean(
    note &&
    !isTrashed &&
    sourceConversation &&
    sourceMessage &&
    sourceProvider &&
    sourceModel &&
    note.sourcePrompt,
  );
  const isCrosscheckNote = Boolean(note?.bodySnapshot && note.body.includes('\n## Cross-check'));
  const hasSnapshotPane = Boolean(note?.bodySnapshot && note.bodySnapshot.trim() && note.bodySnapshot !== note.body);
  const primaryBody = note
    ? (isCrosscheckNote ? extractCrosscheckDisplayBody(note.body) : note.body)
    : '';
  const activeBody = contentPane === 'snapshot'
    ? note?.bodySnapshot ?? primaryBody
    : primaryBody;
  const availableTags = useMemo(
    () => note ? getSuggestedNoteTags(notes, note.tags) : [],
    [note, notes],
  );

  // The full messages of the source conversation are loaded lazily, so the detail page warms the
  // source anchor: when the message is not in the local window it fetches the anchor window on a
  // best-effort basis and degrades silently on failure.
  useEffect(() => {
    if (note?.sourceConversationId) {
      void warmConversationAnchorInStore(note.sourceConversationId, note.sourceMessageId);
    }
  }, [note?.sourceConversationId, note?.sourceMessageId]);

  useEffect(() => {
    leaveStateRef.current = { note, titleDraft };
  });

  const prepareToLeave = useCallback(() => {
    const latest = leaveStateRef.current;
    const trimmedTitle = latest.titleDraft?.trim() ?? '';
    if (
      latest.note &&
      trimmedTitle &&
      (trimmedTitle !== latest.note.title || latest.note.titleSource === 'placeholder')
    ) {
      updateNoteTitle(getVanillaStore(), latest.note.id, trimmedTitle);
    }
    discardEmptyBlankNote(getVanillaStore(), noteId);
  }, [noteId]);

  useEffect(() => () => {
    prepareToLeave();
  }, [prepareToLeave]);

  const beginBodyEdit = useCallback(() => {
    if (!note) return;
    setBodyDraft(note.body);
    setIsEditingBody(true);
  }, [note]);

  if (!note) {
    return (
      <div className={styles.pageShell}>
        <EmptyState
          title={t('detail.notFound')}
          description={t('detail.notFoundDescription')}
          action={<Button onClick={() => router.push('/notes')}>{t('actions.backToNotes')}</Button>}
        />
      </div>
    );
  }

  const title = note.title.trim() || t('untitled');
  const folderName = noteFolders.find((folder) => folder.id === note.noteFolderID)?.name ?? t('folders.uncategorized');
  const sourceColor = note.sourceProviderKind
    ? PROVIDER_BRAND_COLORS[note.sourceProviderKind]?.light ?? PROVIDER_BRAND_COLORS.relay.light
    : 'var(--o-primary)';

  const saveTitle = () => {
    if (titleDraft === null) return;
    updateNoteTitle(getVanillaStore(), note.id, titleDraft);
    setTitleDraft(null);
    showToast(t('toast.savedPlain'), 2500, undefined, 'success');
  };

  const saveBody = () => {
    updateNoteBody(getVanillaStore(), note.id, bodyDraft);
    setIsEditingBody(false);
    showToast(t('toast.savedPlain'), 2500, undefined, 'success');
  };

  const handleBack = () => {
    prepareToLeave();
    router.push('/notes');
  };

  const handleDelete = () => {
    deleteNote(getVanillaStore(), note.id);
    setShowDeleteConfirm(false);
    showToast(t('toast.deleted'), 5000, () => restoreNote(getVanillaStore(), note.id), 'warning', t('actions.undo'));
    router.push('/notes');
  };

  const handleJump = () => {
    if (!linkState.available) return;
    const params = new URLSearchParams({ fromNote: note.id });
    if (note.sourceMessageId) params.set('focusMessageId', normalizeUUID(note.sourceMessageId));
    router.push(`/chat/${linkState.conversationId}?${params.toString()}`);
  };

  const handleExport = () => {
    downloadMarkdown(buildNoteMarkdown(note, t('untitled')), buildNoteMarkdownFilename(note, t('untitled')));
    showToast(t('toast.exported'), 3000, undefined, 'success');
  };

  return (
    <div className={styles.detailShell} style={{ '--note-source-color': sourceColor } as CSSProperties}>
      <div className={styles.detailHeader}>
        <Button tone="secondary" size="sm" onClick={handleBack}>
          <ArrowLeft size={15} aria-hidden />
          {t('actions.backToNotes')}
        </Button>
        <div className={styles.detailHeaderActions}>
          <Button tone="secondary" size="sm" onClick={handleExport}>
            <Download size={15} aria-hidden />
            {t('actions.export')}
          </Button>
          <Button tone="secondary" size="sm" onClick={() => toggleNotePin(getVanillaStore(), note.id)} disabled={isTrashed}>
            {note.isPinned ? <PinOff size={15} aria-hidden /> : <Pin size={15} aria-hidden />}
            {note.isPinned ? t('actions.unpin') : t('actions.pin')}
          </Button>
          <Button tone="secondary" size="sm" onClick={() => setShowMoveDialog(true)} disabled={isTrashed}>
            <FolderInput size={15} aria-hidden />
            {folderName}
          </Button>
        </div>
      </div>

      {isTrashed ? (
        <div className={styles.trashBanner}>
          <span>{t('detail.inTrash')}</span>
          <Button size="sm" tone="secondary" onClick={() => restoreNote(getVanillaStore(), note.id)}>
            {t('trash.restore')}
          </Button>
        </div>
      ) : null}

      <main className={styles.detailContent}>
        <section className={styles.detailHero} style={{ '--note-source-color': sourceColor } as CSSProperties}>
          <div className={styles.detailSourceStrip}>
            {note.sourceProviderKind ? (
              <span className={styles.detailSourceModel}>
                <ProviderIcon
                  kind={note.sourceProviderKind}
                  size={16}
                  bare
                  providerName={note.sourceProviderName}
                />
                <span>{note.sourceModelName || note.sourceProviderName || note.sourceProviderKind}</span>
              </span>
            ) : (
              <span className={styles.detailSourceModel}>{folderName}</span>
            )}
            {note.isPinned ? <span className={styles.detailPinnedPill}>{t('labels.pinned')}</span> : null}
            <time className={styles.detailSourceDate}>{new Date(note.createdAt).toLocaleDateString()}</time>
          </div>
          <input
            className={styles.detailTitleInput}
            value={titleDraft ?? title}
            onChange={(event) => setTitleDraft(event.target.value)}
            onBlur={() => {
              // While titleSource is still a placeholder, any non-empty title is saved and pinned as manual; otherwise editing the body would overwrite the title again.
              if (
                titleDraft !== null &&
                titleDraft.trim() &&
                (titleDraft.trim() !== note.title || note.titleSource === 'placeholder')
              ) {
                saveTitle();
              }
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.currentTarget.blur();
              }
            }}
            aria-label={t('detail.title')}
            disabled={isTrashed}
          />
        </section>

        {note.tags.length > 0 || !isTrashed ? (
          <section className={styles.inlineTagsSection} aria-label={t('tags.title')}>
            <div className={styles.inlineTagsScroller}>
              {note.tags.map((tag) => (
                <span key={tag} className={styles.inlineTagChip}>
                  <Tag size={11} aria-hidden className={styles.tagChipIcon} />
                  {tag}
                  {!isTrashed ? (
                    <button
                      type="button"
                      onClick={() => updateNoteTags(getVanillaStore(), note.id, note.tags.filter((item) => item !== tag))}
                      aria-label={t('tags.remove', { tag })}
                    >
                      <X size={11} aria-hidden />
                    </button>
                  ) : null}
                </span>
              ))}
              {!isTrashed ? (
                <NoteTagEditor
                  tags={note.tags}
                  availableTags={availableTags}
                  compact
                  editable
                  onChange={(tags) => updateNoteTags(getVanillaStore(), note.id, tags)}
                />
              ) : null}
            </div>
          </section>
        ) : null}

        <NoteSourceCard
          note={note}
          linkState={linkState}
          onJump={handleJump}
          onCrosscheck={canCrosscheck ? () => setShowCrosscheck(true) : undefined}
        />

        <section className={styles.detailPanel}>
          {hasSnapshotPane ? (
            <div className={styles.detailContentTabs} role="tablist" aria-label={t('detail.body')}>
              <button type="button" data-active={contentPane === 'body'} onClick={() => setContentPane('body')}>
                {isCrosscheckNote ? t('source.crosscheck') : t('detail.body')}
              </button>
              <button type="button" data-active={contentPane === 'snapshot'} onClick={() => setContentPane('snapshot')}>
                {t('detail.snapshot')}
              </button>
            </div>
          ) : null}
          {isEditingBody ? (
            <textarea
              className={styles.bodyTextarea}
              value={bodyDraft}
              onChange={(event) => setBodyDraft(event.target.value)}
              autoFocus
            />
          ) : (
            <div className={styles.detailContentCard}>
              <div className={styles.markdownPreviewEditorial}>
                {activeBody.trim() ? (
                  <>
                    <MarkdownRenderer content={activeBody} />
                    <div className={styles.colophon} aria-hidden>
                      <span className={styles.colophonDiamond}>◆</span>
                    </div>
                  </>
                ) : (
                  <p className={styles.mutedText}>{t('empty.body')}</p>
                )}
              </div>
            </div>
          )}
          {!isTrashed && contentPane === 'body' ? (
            <div className={styles.detailEditActions}>
              {isEditingBody ? (
                <>
                  <Button tone="secondary" size="sm" onClick={() => setIsEditingBody(false)}>
                    <X size={14} aria-hidden />
                    {t('actions.cancel')}
                  </Button>
                  <Button size="sm" onClick={saveBody}>
                    <Check size={14} aria-hidden />
                    {t('actions.save')}
                  </Button>
                </>
              ) : (
                <Button tone="secondary" size="sm" onClick={beginBodyEdit}>
                  <Pencil size={14} aria-hidden />
                  {t('actions.edit')}
                </Button>
              )}
            </div>
          ) : null}
        </section>

        <section className={styles.dangerZone}>
          <Button tone="danger" onClick={() => setShowDeleteConfirm(true)} disabled={isTrashed}>
            <Trash2 size={15} aria-hidden />
            {t('actions.delete')}
          </Button>
        </section>
      </main>

      <MoveToNoteFolderDialog
        open={showMoveDialog}
        folders={noteFolders}
        currentFolderId={note.noteFolderID}
        onClose={() => setShowMoveDialog(false)}
        onSelect={(folderId) => {
          moveNoteToFolder(getVanillaStore(), note.id, folderId);
          setShowMoveDialog(false);
          showToast(t('toast.savedPlain'), 2500, undefined, 'success');
        }}
      />
      <ConfirmDialog
        open={showDeleteConfirm}
        title={t('delete.title')}
        message={t('delete.message')}
        confirmLabel={t('actions.delete')}
        cancelLabel={t('actions.cancel')}
        destructive
        onConfirm={handleDelete}
        onCancel={() => setShowDeleteConfirm(false)}
      />
      {canCrosscheck && sourceConversation && sourceMessage && sourceProvider && sourceModel ? (
        <CrosscheckSheet
          open={showCrosscheck}
          conversation={sourceConversation}
          originMessage={sourceMessage}
          originalPrompt={note.sourcePrompt ?? ''}
          originalAnswer={note.bodySnapshot ?? sourceMessage.text}
          originProvider={sourceProvider}
          originModel={sourceModel}
          providers={providers}
          onClose={() => setShowCrosscheck(false)}
        />
      ) : null}
    </div>
  );
}

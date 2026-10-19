'use client';

import { useState, useCallback, useRef, useMemo, useEffect, useLayoutEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { ChevronRight, FileText, Plus, ShieldAlert } from 'lucide-react';
import { BackButton, Button, Dialog } from '@oriveo/ui';
import type { MemoryItem } from '@oriveo/core/context/memory-items';
import type { MemoryRecallResolution } from '@oriveo/core/context/memory-recall';
import { useAppStore } from '../../../providers/StoreProvider';
import { getVanillaStore } from '../../../providers/StoreProvider';
import { requestMemoryDraft } from '../../../lib/core/memory-draft';
import { FEATURE_BADGE_IDS, markSeen } from '../../../lib/core/feature-badges';
import { getConversationById } from '../../../lib/infra/storage/idb';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { getOrCreateStableWebDeviceId } from '../../../lib/core/bootstrap';
import {
  createMemoryItemRepository,
  type MemoryItemRepository,
} from '../../../lib/core/memory/memory-item-repository';
import { createMemoryCandidateRepository } from '../../../lib/core/memory/memory-candidate-repository';
import type { MemoryModelCandidate } from '../../../lib/core/memory/memory-organize';
import {
  MEMORY_EXTRACTION_COPY,
  memoryDraftExcerpts,
  memoryExtractionDisclosure,
  type MemoryDraftSourceMessage,
  type MemoryExtractionDisclosure,
} from '../../../lib/core/memory/memory-extraction';
import { reportSilentError } from '../../../lib/sentry/report-silent';
import { localizeProviderError } from '../../../lib/core/providers/error-i18n';
import styles from './MemoryPage.module.css';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import {
  MEMORY_CONTENT_MAX,
  MemoryItemEditor,
  categoryOfKind,
  episodicDateOf,
  kindForCategory,
  occurredAtForDate,
  todayDate,
  type MemoryCategory,
  type MemoryEpisodicChoice,
  type MemoryEditorSession,
} from './MemoryItemEditor';
import { MemoryItemList, MemorySpectrum, visibleMemoryItems, type MemoryL3ConflictPair } from './MemoryItemList';
import {
  MemoryCategoryGlyph,
  MemoryEpisodicGlyph,
  MemoryInboxGlyph,
  MemorySparkleGlyph,
  categoryHueClass,
} from './MemoryGlyphs';
import { MemoryRawView } from './MemoryRawView';
import { MemoryOrganizeDialog } from './MemoryOrganizeDialog';

const DRAFT_CONVERSATION_LIMIT = 5;
const DRAFT_EXCERPT_LIMIT = 500;

type MemoryPageMode = 'starter' | 'list';
type MemoryHeroStyle = 'draftStarter' | 'manualStarter' | 'activeMemory';
type MemoryPageAction = 'generateDraft' | 'addItem';

/** Request pending confirmation in the disclosure dialog: drafting carries the computed send scope, organizing carries the memory to split. */
type ExtractionDisclosureState = MemoryExtractionDisclosure & (
  | { scope: 'draft'; excerpts: string }
  | { scope: 'organize'; item: MemoryItem }
);

type ErrorDialogState = {
  title: string;
  message: string;
} | null;

type MemoryPagePresentation = {
  mode: MemoryPageMode;
  heroStyle: MemoryHeroStyle;
  primaryAction: MemoryPageAction | null;
  secondaryAction: MemoryPageAction | null;
};

function buildPresentation(
  visibleCount: number,
  hasRecentConversations: boolean,
): MemoryPagePresentation {
  if (visibleCount > 0) {
    return { mode: 'list', heroStyle: 'activeMemory', primaryAction: null, secondaryAction: null };
  }
  // Empty state: "Add" is the primary action; drafting from recent chats stays as the secondary one.
  return {
    mode: 'starter',
    heroStyle: hasRecentConversations ? 'draftStarter' : 'manualStarter',
    primaryAction: 'addItem',
    secondaryAction: hasRecentConversations ? 'generateDraft' : null,
  };
}

/** Truncates to the item limit in code points (the contract unit). */
function takeCodePoints(text: string, max: number): string {
  const points = Array.from(text);
  return points.length <= max ? text : points.slice(0, max).join('');
}

export function MemoryPage() {
  const t = useTranslations('pages.memory');
  const tCommon = useTranslations('common');
  const tErrors = useTranslations('errors');
  const router = useRouter();

  const providers = useAppStore((s) => s.providers);
  const lastUsedModelRef = useAppStore((s) => s.lastUsedModelRef);
  const conversations = useAppStore((s) => s.conversations);
  const memoryItems = useAppStore((s) => s.memoryItems);
  const folders = useAppStore((s) => s.folders);
  const folderNames = useMemo(
    () => new Map((folders ?? []).map((folder) => [folder.id, folder.name] as const)),
    [folders],
  );

  const localDeviceId = useMemo(() => getOrCreateStableWebDeviceId(), []);
  const visibleItems = useMemo(() => visibleMemoryItems(memoryItems ?? []), [memoryItems]);

  const [editor, setEditor] = useState<MemoryEditorSession | null>(null);
  const [editorKey, setEditorKey] = useState(0);
  const [saving, setSaving] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<MemoryItem | null>(null);
  const [isDrafting, setIsDrafting] = useState(false);
  // Drafting preparation phase (reading recent conversations): shows generateDraftLoading, cleared before the disclosure dialog appears.
  const [isPreparingDraft, setIsPreparingDraft] = useState(false);
  const draftBusy = isDrafting || isPreparingDraft;
  const [showDraftConflict, setShowDraftConflict] = useState(false);
  const [pendingDraft, setPendingDraft] = useState<string | null>(null);
  const [errorDialog, setErrorDialog] = useState<ErrorDialogState>(null);
  // Disclosure dialog: the open flag controls open/close, and the content snapshot is kept until the close animation ends (onExited) before clearing, so the title does not vanish first.
  const [extractionDisclosureOpen, setExtractionDisclosureOpen] = useState(false);
  const [extractionDisclosure, setExtractionDisclosure] = useState<ExtractionDisclosureState | null>(null);
  const [rawView, setRawView] = useState(false);
  const [rawViewKey, setRawViewKey] = useState(0);
  const [organizeTarget, setOrganizeTarget] = useState<
    { item: MemoryItem; candidates: MemoryModelCandidate[] } | null
  >(null);
  const [appeared, setAppeared] = useState(false);
  const [inboxCount, setInboxCount] = useState(0);
  // Second line of the entry card stack: the original text of the first pending suggestion (reads existing candidates only, no extra fetch).
  const [inboxPreview, setInboxPreview] = useState<string | null>(null);

  // Request id shared by drafting (prepare / send) and organize disclosure: the later one wins, and late old results are discarded.
  const extractionRequestIdRef = useRef(0);
  const preparingDraftRef = useRef(false);
  const editorOpenRef = useRef(false);
  const editQueryHandledRef = useRef(false);

  useEffect(() => {
    editorOpenRef.current = editor !== null;
  }, [editor]);

  // New-feature dot: entering the memory page marks it as seen.
  useEffect(() => {
    markSeen(FEATURE_BADGE_IDS.settingsMemory);
  }, []);

  // Entrance animation
  useEffect(() => {
    const id = requestAnimationFrame(() => setAppeared(true));
    return () => cancelAnimationFrame(id);
  }, []);

  // Count on the suggestions inbox entry row: refetched when entering the page (including returning from the inbox).
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const uid = getActiveUIDSync();
      const items = createMemoryItemRepository({ store: getVanillaStore(), uid, deviceId: localDeviceId });
      const pending = await createMemoryCandidateRepository({ uid, items }).pending();
      if (cancelled) return;
      setInboxCount(pending.length);
      setInboxPreview(pending[0]?.content ?? null);
    })().catch((error: unknown) => reportSilentError('memory-candidates.pending', error));
    return () => {
      cancelled = true;
    };
  }, [localDeviceId]);

  // Use remoteMessageCount: after hydrate, messages in the store is always [], because
  // persistence.ts moves messages into IDB and keeps only the conversation summary plus
  // remoteMessageCount in memory.
  const hasRecentConversations = conversations.some(
    (c) => !c.isDraft && (c.remoteMessageCount ?? 0) > 0,
  );
  const presentation = buildPresentation(visibleItems.length, hasRecentConversations);

  /* ───────── Repository writes ───────── */

  // Build the repository fresh on every write: the partition may have switched, uid takes the current active partition; repositories with the same uid share one lock.
  const runWrite = useCallback(
    async (context: string, op: (repository: MemoryItemRepository) => Promise<unknown>): Promise<boolean> => {
      try {
        const repository = createMemoryItemRepository({
          store: getVanillaStore(),
          uid: getActiveUIDSync(),
          deviceId: localDeviceId,
        });
        await op(repository);
        return true;
      } catch (error) {
        reportSilentError(`memory-items.${context}`, error);
        return false;
      }
    },
    [localDeviceId],
  );

  /* ───────── Editor ───────── */

  const openEditor = useCallback((session: MemoryEditorSession) => {
    setEditorKey((key) => key + 1);
    setEditor(session);
  }, []);

  const openNewEditor = useCallback(
    (category: MemoryCategory = 'about', content = '') => openEditor({
      itemId: null,
      category,
      content,
    }),
    [openEditor],
  );

  const openNewEpisodicEditor = useCallback(
    () => openEditor({
      itemId: null,
      layer: 'episodic',
      category: 'about',
      episodicKind: 'decision',
      date: todayDate(),
      content: '',
    }),
    [openEditor],
  );

  const openItemEditor = useCallback(
    (item: MemoryItem) => openEditor({
      itemId: item.id,
      layer: item.layer,
      category: categoryOfKind(item.kind) ?? 'about',
      episodicKind: item.kind === 'event' ? 'event' : 'decision',
      date: episodicDateOf(item) ?? todayDate(),
      content: item.content,
    }),
    [openEditor],
  );

  const handleEditorSave = useCallback(
    async (category: MemoryCategory, content: string, episodic?: MemoryEpisodicChoice) => {
      if (!editor) return;
      const session = editor;
      setSaving(true);
      const ok = await runWrite('save', (repository) => {
        if (episodic) {
          const occurredAt = occurredAtForDate(episodic.date);
          if (!session.itemId) {
            return repository.create({ kind: episodic.kind, content, layer: 'episodic', occurredAt });
          }
          return repository.update(session.itemId, { content, kind: episodic.kind, occurredAt });
        }
        if (!session.itemId) {
          return repository.create({ kind: kindForCategory(category), content });
        }
        // If the category is unchanged, leave kind alone: existing fact / constraint / goal / decision stay as they are.
        return repository.update(session.itemId, {
          content,
          ...(category !== session.category ? { kind: kindForCategory(category) } : {}),
        });
      });
      setSaving(false);
      if (ok) setEditor(null);
    },
    [editor, runWrite],
  );

  // ?edit=<id>: opened once after the item has hydrated into the slice.
  useEffect(() => {
    if (editQueryHandledRef.current) return;
    const id = new URLSearchParams(window.location.search).get('edit');
    if (!id) {
      editQueryHandledRef.current = true;
      return;
    }
    const target = visibleItems.find((m) => m.id === id.toLowerCase());
    if (!target) return;
    editQueryHandledRef.current = true;
    openItemEditor(target);
  }, [visibleItems, openItemEditor]);

  /* ───────── Row actions ───────── */

  const handleTogglePinned = useCallback(
    (item: MemoryItem) => void runWrite('pin', (repository) => repository.setPinned(item.id, !item.pinned)),
    [runWrite],
  );

  const handleToggleStatus = useCallback(
    (item: MemoryItem) => void runWrite(
      'status',
      (repository) => repository.setStatus(item.id, item.status === 'paused' ? 'active' : 'paused'),
    ),
    [runWrite],
  );

  const handleConfirmDelete = useCallback(async () => {
    const target = pendingDelete;
    setPendingDelete(null);
    if (target) await runWrite('remove', (repository) => repository.remove(target.id));
  }, [pendingDelete, runWrite]);

  const handleKeepConflict = useCallback(
    (item: MemoryItem) => void runWrite('resolveConflict', (repository) => repository.resolveConflict(item.id)),
    [runWrite],
  );

  const handleResolveL3Conflict = useCallback(
    (pair: MemoryL3ConflictPair, resolution: MemoryRecallResolution) => void runWrite(
      'resolveL3Conflict',
      (repository) => repository.resolveL3Conflict(pair.newer.id, pair.older.id, resolution),
    ),
    [runWrite],
  );

  /* ───────── Plain-text view ───────── */

  const toggleRawView = useCallback(() => {
    setRawViewKey((key) => key + 1);
    setRawView((open) => !open);
  }, []);

  /* ───────── Navigation ───────── */

  const handleBack = useCallback(() => {
    router.push('/settings');
  }, [router]);

  /* --------- Generate Draft (disclosure before running, one provider + model only) --------- */

  // Tapping "AI draft": first pick the model and compute the send scope, then show the disclosure dialog; no request is sent before tapping [Send].
  const handleGenerateDraft = useCallback(async () => {
    // Tapping again during the preparation phase does not start another round.
    if (preparingDraftRef.current) return;
    extractionRequestIdRef.current += 1;
    const thisRequestId = extractionRequestIdRef.current;
    const chosen = memoryExtractionDisclosure(providers, lastUsedModelRef);

    if (!chosen) {
      const hasAnyKey = providers.some((p) => resolveProviderAPIKey(p));
      setErrorDialog(
        hasAnyKey
          ? { title: t('errorNoModelTitle'), message: t('errorNoModelMessage') }
          : { title: t('errorNoProviderTitle'), message: t('errorNoProviderMessage') },
      );
      return;
    }

    // 1. Candidate conversation IDs, ordered by remoteMessageCount from the in-memory summary.
    const recentSummary = conversations
      .filter((c) => !c.isDraft && (c.remoteMessageCount ?? 0) > 0)
      .sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime())
      .slice(0, DRAFT_CONVERSATION_LIMIT);

    if (recentSummary.length === 0) {
      setErrorDialog({
        title: t('errorNotEnoughTitle'),
        message: t('errorNotEnoughMessage'),
      });
      return;
    }

    // 2. Actively pull full messages from IDB (persistence.ts clears messages to [] to save memory,
    //    and reads them back by id only when conversation content has to be analyzed, the same idea as iOS fetchConversationProjection)
    let hydrated: Array<{ id: string; messages: MemoryDraftSourceMessage[] }>;
    preparingDraftRef.current = true;
    setIsPreparingDraft(true);
    try {
      hydrated = await Promise.all(
        recentSummary.map(async (c) => {
          const full = await getConversationById(c.id);
          return { id: c.id, messages: full?.messages ?? [] };
        }),
      );
    } catch {
      if (extractionRequestIdRef.current !== thisRequestId) return;
      preparingDraftRef.current = false;
      setIsPreparingDraft(false);
      setErrorDialog({
        title: t('errorHydrateTitle'),
        message: t('errorHydrateMessage'),
      });
      return;
    }

    // A late old preparation result (organize was tapped in the meantime) is discarded.
    if (extractionRequestIdRef.current !== thisRequestId) return;
    preparingDraftRef.current = false;
    setIsPreparingDraft(false);

    // 3. Send only the user messages of the chosen provider; if filtering leaves nothing -> not enough conversation content, no disclosure.
    const excerpts = memoryDraftExcerpts(hydrated, chosen.candidate.provider.id, DRAFT_EXCERPT_LIMIT);
    if (!excerpts.trim()) {
      setErrorDialog({
        title: t('errorNotEnoughTitle'),
        message: t('errorNotEnoughMessage'),
      });
      return;
    }

    setExtractionDisclosure({ ...chosen, scope: 'draft', excerpts });
    setExtractionDisclosureOpen(true);
  }, [providers, lastUsedModelRef, conversations, t]);

  const handleCancelExtractionDisclosure = useCallback(() => {
    setExtractionDisclosureOpen(false);
  }, []);

  // [Send]: request once with the provider + model written in the dialog; a failure or empty reply reports an error directly, with no switching to another provider.
  const handleSendDraft = useCallback(async () => {
    const pending = extractionDisclosure;
    if (!extractionDisclosureOpen || pending?.scope !== 'draft') return;
    setExtractionDisclosureOpen(false);

    extractionRequestIdRef.current += 1;
    const thisRequestId = extractionRequestIdRef.current;
    setIsDrafting(true);

    let draft = '';
    let errorDetail = '';
    let emptyReply = false;
    try {
      const fullText = await requestMemoryDraft({
        provider: pending.candidate.provider,
        model: pending.candidate.model,
        excerpts: pending.excerpts,
      });
      draft = takeCodePoints(fullText.trim(), MEMORY_CONTENT_MAX);
      emptyReply = !draft;
    } catch (err) {
      const message = err && typeof err === 'object' && 'message' in err
        ? (err as { message?: unknown }).message
        : undefined;
      errorDetail = typeof message === 'string' ? message : '';
    }

    setIsDrafting(false);
    if (extractionRequestIdRef.current !== thisRequestId) return;
    if (!draft) {
      // Upstream errors go through localizeProviderError; an empty reply uses the dedicated empty-reply text (errors.emptyResponse talks about the model catalog and does not apply).
      const message = emptyReply
        ? t('generateDraftEmpty')
        : errorDetail
          ? localizeProviderError(errorDetail, tErrors)
          : t('generateDraftFailed');
      setErrorDialog({ title: t('errorGenericTitle'), message });
      return;
    }
    // The draft no longer writes memoryText: open the new editor pre-filled (category "About me"); if an editor is already open, ask first.
    if (editorOpenRef.current) {
      setPendingDraft(draft);
      setShowDraftConflict(true);
    } else {
      openNewEditor('about', draft);
    }
  }, [extractionDisclosure, extractionDisclosureOpen, t, tErrors, openNewEditor]);

  /* --------- Organize (disclosure before running, one provider + model only) --------- */

  // Tapping "Organize into items": show the disclosure dialog first; with no usable model, no dialog, and the organize dialog opens directly showing organizeNoModel.
  const handleOrganize = useCallback((item: MemoryItem) => {
    // The later one wins: an in-progress drafting preparation / send result is voided.
    extractionRequestIdRef.current += 1;
    preparingDraftRef.current = false;
    setIsPreparingDraft(false);
    const chosen = memoryExtractionDisclosure(providers, lastUsedModelRef);
    if (!chosen) {
      setOrganizeTarget({ item, candidates: [] });
      return;
    }
    setExtractionDisclosure({ ...chosen, scope: 'organize', item });
    setExtractionDisclosureOpen(true);
  }, [providers, lastUsedModelRef]);

  // [Send]: only then open the organize dialog, handing it only the one candidate written in the dialog (it requests on mount, and a failure does not switch provider).
  const handleSendOrganize = useCallback(() => {
    const pending = extractionDisclosure;
    if (!extractionDisclosureOpen || pending?.scope !== 'organize') return;
    setExtractionDisclosureOpen(false);
    setOrganizeTarget({ item: pending.item, candidates: [pending.candidate] });
  }, [extractionDisclosure, extractionDisclosureOpen]);

  const handleSendExtraction = useCallback(() => {
    if (extractionDisclosure?.scope === 'organize') {
      handleSendOrganize();
    } else {
      void handleSendDraft();
    }
  }, [extractionDisclosure, handleSendOrganize, handleSendDraft]);

  /* ───────── Draft conflict resolution ───────── */

  const handleApplyDraft = useCallback(() => {
    if (pendingDraft) openNewEditor('about', pendingDraft);
    setPendingDraft(null);
    setShowDraftConflict(false);
  }, [pendingDraft, openNewEditor]);

  const handleCancelDraft = useCallback(() => {
    setPendingDraft(null);
    setShowDraftConflict(false);
  }, []);

  /* ───────── Action dispatcher ───────── */

  const handleAction = useCallback(
    async (action: MemoryPageAction) => {
      if (action === 'generateDraft') {
        await handleGenerateDraft();
      } else {
        openNewEditor();
      }
    },
    [handleGenerateDraft, openNewEditor],
  );

  /* ───────── Keyboard shortcuts ───────── */
  // Esc goes back; Cmd+Enter generates a draft
  const anyDialogOpen = editor !== null
    || pendingDelete !== null
    || showDraftConflict
    || errorDialog !== null
    || extractionDisclosureOpen
    || organizeTarget !== null;
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      // Ignore IME composition and the form's built-in enter handling.
      if (e.isComposing) return;
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key === 'Enter') {
        if (anyDialogOpen) return;
        e.preventDefault();
        if (hasRecentConversations && !draftBusy) {
          void handleGenerateDraft();
        }
        return;
      }
      if (e.key === 'Escape') {
        // While any dialog is open, leave it to the dialog itself
        if (anyDialogOpen) return;
        e.preventDefault();
        handleBack();
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [anyDialogOpen, hasRecentConversations, draftBusy, handleBack, handleGenerateDraft]);

  /* ───────── Hero chip ───────── */

  const heroChip: { label: string; tone: 'primary' | 'success' } = (() => {
    switch (presentation.heroStyle) {
      case 'draftStarter':
        return { label: t('heroChipAuto'), tone: 'primary' };
      case 'manualStarter':
        return { label: t('title'), tone: 'primary' };
      case 'activeMemory':
      default:
        return { label: t('heroChipReady'), tone: 'success' };
    }
  })();

  /* ───────── Action button copy ───────── */

  // During the drafting preparation phase the button text becomes generateDraftLoading (reading recent conversations).
  const generateDraftLabel = isPreparingDraft ? t('generateDraftLoading') : t('generateDraft');
  const actionLabel = (action: MemoryPageAction) =>
    action === 'generateDraft' ? generateDraftLabel : t('addItem');
  const actionIcon = (action: MemoryPageAction) =>
    action === 'generateDraft' ? <MemorySparkleGlyph size={15} /> : <Plus size={16} strokeWidth={2.2} aria-hidden />;

  /* ───────── Subtitles ───────── */

  const headerSubtitle =
    presentation.mode === 'starter'
      ? t('emptyDescription')
      : t('description');

  /* ───────── Render ───────── */

  const inboxEntry = (
    <div className={inboxCount > 0 ? styles.inboxDeck : undefined}>
      {inboxCount > 0 && (
        <>
          <span className={styles.inboxDeckLayerBack} aria-hidden />
          <span className={styles.inboxDeckLayerMiddle} aria-hidden />
        </>
      )}
      <button
        type="button"
        className={styles.inboxEntry}
        data-testid="memory-inbox-entry"
        onClick={() => router.push('/settings/memory/inbox')}
      >
        <span className={styles.inboxEntryGlyph} aria-hidden>
          <MemoryInboxGlyph />
        </span>
        <span className={styles.inboxEntryText}>
          <span className={styles.inboxEntryTitle}>{t('inboxTitle')}</span>
          {inboxCount > 0 && inboxPreview && <span className={styles.inboxEntryPreview}>{inboxPreview}</span>}
        </span>
        {inboxCount > 0 ? (
          <span className={styles.inboxEntryValue} data-testid="memory-inbox-count">{inboxCount}</span>
        ) : (
          <ChevronRight size={14} strokeWidth={2.2} className={styles.inboxEntryChevron} aria-hidden />
        )}
      </button>
    </div>
  );

  const privacyNote = (
    <p className={styles.footnote}>
      <ShieldAlert size={13} strokeWidth={1.8} aria-hidden />
      <span>{t('privacyWarning')}</span>
    </p>
  );

  return (
    <div className={`${styles.page} ${appeared ? styles.pageAppeared : ''}`}>
      <div className={styles.atlas} aria-hidden />
      <BackButton className={styles.backLink} label={t('backToSettings')} onClick={handleBack} />

      <header className={`${styles.header} ${styles.headerWithActions}`}>
        <div className={styles.headerText}>
          <div className={styles.headerTitleRow}>
            <h1 className={styles.title}>{t('title')}</h1>
            {/* Starter: no status chip (it would repeat the title); the list shows Ready. */}
            {presentation.mode === 'list' && (
              <span
                className={`${styles.chip} ${
                  heroChip.tone === 'primary' ? styles.chipPrimary : styles.chipSuccess
                }`}
              >
                <span className={styles.chipDot} aria-hidden />
                <span>{heroChip.label}</span>
              </span>
            )}
          </div>
          <p className={styles.subtitle}>{headerSubtitle}</p>
        </div>
        {presentation.mode === 'list' && (
          <div className={styles.headerActions}>
            <button
              type="button"
              className={`${styles.btnSecondary} ${rawView ? styles.rawViewToggleActive : ''}`}
              aria-pressed={rawView}
              data-testid="memory-raw-toggle"
              onClick={toggleRawView}
            >
              <FileText size={15} strokeWidth={1.9} aria-hidden />
              <span>{t('rawView')}</span>
            </button>
            {!rawView && (
              <button type="button" className={styles.btnPrimary} onClick={() => openNewEditor()}>
                <Plus size={15} strokeWidth={2.2} aria-hidden />
                <span>{t('addItem')}</span>
              </button>
            )}
          </div>
        )}
      </header>

      {presentation.mode === 'starter' ? (
        <div className={styles.pageGrid}>
          {/* ── Starter — text + actions, with the memory constellation beside it ── */}
          <section className={styles.starterCard}>
            <div className={styles.starterText}>
              <h2 className={styles.starterTitle}>{t('emptyTitle')}</h2>
              <p className={styles.starterBody}>{t('emptyDescription')}</p>
              <p className={styles.starterExample}>
                <span className={styles.starterExampleMark} aria-hidden>“</span>
                <span>{t('exampleHint')}</span>
              </p>
              {presentation.primaryAction && (
                <div className={styles.starterActions}>
                  <button
                    type="button"
                    className={`${styles.btnPrimary} ${styles.starterPrimary}`}
                    onClick={() => void handleAction(presentation.primaryAction!)}
                    disabled={presentation.primaryAction === 'generateDraft' && draftBusy}
                  >
                    {actionIcon(presentation.primaryAction)}
                    <span>{actionLabel(presentation.primaryAction)}</span>
                  </button>
                  {presentation.secondaryAction && (
                    <button
                      type="button"
                      className={styles.starterSecondary}
                      onClick={() => void handleAction(presentation.secondaryAction!)}
                      disabled={presentation.secondaryAction === 'generateDraft' && draftBusy}
                    >
                      {presentation.secondaryAction === 'generateDraft' && draftBusy ? (
                        <span className={styles.spinner} aria-hidden />
                      ) : (
                        actionIcon(presentation.secondaryAction)
                      )}
                      <span>{actionLabel(presentation.secondaryAction)}</span>
                    </button>
                  )}
                </div>
              )}
            </div>
            <MemoryConstellation />
          </section>

          <aside className={styles.sidebar}>
            {inboxEntry}
            {privacyNote}
          </aside>
        </div>
      ) : (
        /* ── Item list — main column + sidebar on desktop ── */
        <div className={styles.pageGrid}>
          <section className={styles.listColumn}>
            {rawView ? (
              <MemoryRawView
                key={rawViewKey}
                items={memoryItems ?? []}
                runWrite={runWrite}
                onSaved={() => setRawView(false)}
                onCancel={toggleRawView}
              />
            ) : (
              <MemoryItemList
                items={visibleItems}
                localDeviceId={localDeviceId}
                folderNames={folderNames}
                onAdd={(category) => openNewEditor(category)}
                onAddEpisodic={openNewEpisodicEditor}
                onEdit={openItemEditor}
                onTogglePinned={handleTogglePinned}
                onToggleStatus={handleToggleStatus}
                onDelete={setPendingDelete}
                onKeepConflict={handleKeepConflict}
                onResolveL3Conflict={handleResolveL3Conflict}
                onOrganize={handleOrganize}
              />
            )}
          </section>

          <aside className={styles.sidebar}>
            {!rawView && <MemorySpectrum items={visibleItems} />}
            {!rawView && inboxEntry}
            {!rawView && hasRecentConversations && (
              <button
                type="button"
                className={styles.regenerateCard}
                onClick={() => void handleGenerateDraft()}
                disabled={draftBusy}
              >
                <span className={styles.regenerateIcon} aria-hidden="true">
                  {draftBusy ? (
                    <span className={styles.regenerateSpinner} aria-hidden />
                  ) : (
                    <MemorySparkleGlyph size={17} />
                  )}
                </span>
                <span className={styles.regenerateText}>{generateDraftLabel}</span>
              </button>
            )}
            {privacyNote}
          </aside>
        </div>
      )}

      {editor && (
        <MemoryItemEditor
          key={editorKey}
          session={editor}
          saving={saving}
          onCancel={() => setEditor(null)}
          onSave={(category, content, episodic) => void handleEditorSave(category, content, episodic)}
        />
      )}

      {organizeTarget && (
        <MemoryOrganizeDialog
          key={organizeTarget.item.id}
          item={organizeTarget.item}
          candidates={organizeTarget.candidates}
          runWrite={runWrite}
          onClose={() => setOrganizeTarget(null)}
        />
      )}

      <Dialog open={pendingDelete !== null} onClose={() => setPendingDelete(null)}>
        <h2 className={styles.dialogTitle}>{t('deleteConfirmTitle')}</h2>
        <p className={styles.dialogMessage}>{t('deleteConfirmBody')}</p>
        <div className={styles.dialogActions}>
          <Button tone="secondary" size="sm" onClick={() => setPendingDelete(null)}>
            {tCommon('cancel')}
          </Button>
          <Button tone="danger" size="sm" onClick={() => void handleConfirmDelete()}>
            {t('actionDelete')}
          </Button>
        </div>
      </Dialog>

      <Dialog
        open={extractionDisclosureOpen}
        onClose={handleCancelExtractionDisclosure}
        onExited={() => setExtractionDisclosure(null)}
      >
        {extractionDisclosure && (
          <>
            <h2 className={styles.dialogTitle}>
              {t(MEMORY_EXTRACTION_COPY[extractionDisclosure.scope].title)}
            </h2>
            <p className={styles.dialogMessage}>
              {t('extractionModel', {
                provider: extractionDisclosure.providerName,
                model: extractionDisclosure.modelName,
              })}
            </p>
            <p className={styles.dialogMessage}>
              {t(MEMORY_EXTRACTION_COPY[extractionDisclosure.scope].scope)}
            </p>
            <p className={styles.dialogMessage}>{t('extractionNoFallback')}</p>
          </>
        )}
        <div className={styles.dialogActions}>
          <Button tone="secondary" size="sm" onClick={handleCancelExtractionDisclosure}>
            {tCommon('cancel')}
          </Button>
          <Button size="sm" onClick={handleSendExtraction}>
            {t('extractionSend')}
          </Button>
        </div>
      </Dialog>

      <Dialog open={showDraftConflict} onClose={handleCancelDraft}>
        <h2 className={styles.dialogTitle}>{t('draftReadyTitle')}</h2>
        <p className={styles.dialogMessage}>{t('draftReadyMessage')}</p>
        <div className={styles.dialogActions}>
          <Button tone="secondary" size="sm" onClick={handleCancelDraft}>
            {t('keepEditing')}
          </Button>
          <Button size="sm" onClick={handleApplyDraft}>
            {t('draftApply')}
          </Button>
        </div>
      </Dialog>

      <Dialog open={errorDialog != null} onClose={() => setErrorDialog(null)}>
        <h2 className={styles.dialogTitle}>{errorDialog?.title ?? ''}</h2>
        {errorDialog?.message && (
          <p className={styles.dialogMessage}>{errorDialog.message}</p>
        )}
        <div className={styles.dialogActions}>
          <Button onClick={() => setErrorDialog(null)}>OK</Button>
        </div>
      </Dialog>
    </div>
  );
}

/** Gap kept between a constellation label and the box edge. */
const CONSTELLATION_INSET = 12;

/** Starter illustration: a core with the five groups orbiting it (decorative only). */
function MemoryConstellation() {
  const t = useTranslations('pages.memory');
  const satellites = [
    { key: 'about', x: 78, y: 82, glyph: <MemoryCategoryGlyph category="about" size={14} />, hue: categoryHueClass('about'), label: t('groupAbout') },
    { key: 'preferences', x: 228, y: 70, glyph: <MemoryCategoryGlyph category="preferences" size={14} />, hue: categoryHueClass('preferences'), label: t('groupPreferences') },
    { key: 'instructions', x: 236, y: 236, glyph: <MemoryCategoryGlyph category="instructions" size={14} />, hue: categoryHueClass('instructions'), label: t('groupInstructions') },
    { key: 'projects', x: 150, y: 322, glyph: <MemoryCategoryGlyph category="projects" size={14} />, hue: categoryHueClass('projects'), label: t('groupProjects') },
    { key: 'episodic', x: 70, y: 268, glyph: <MemoryEpisodicGlyph size={14} />, hue: styles.hueEpisodic, label: t('groupEpisodic') },
  ];
  const boxRef = useRef<HTMLDivElement | null>(null);
  const labelsKey = satellites.map((s) => s.label).join('\n');
  // Keep every label inside the box: clamp each satellite's centre by its measured width.
  useLayoutEffect(() => {
    const box = boxRef.current;
    if (!box) return;
    const place = () => {
      const width = box.clientWidth;
      box.querySelectorAll<HTMLElement>('[data-x]').forEach((el) => {
        const half = el.offsetWidth / 2;
        const x = Number(el.dataset.x);
        el.style.left = `${Math.min(Math.max(x, CONSTELLATION_INSET + half), width - CONSTELLATION_INSET - half)}px`;
      });
    };
    place();
    let cancelled = false;
    void document.fonts?.ready.then(() => {
      if (!cancelled) place();
    });
    return () => {
      cancelled = true;
    };
  }, [labelsKey]);
  return (
    <div className={styles.constellation} aria-hidden ref={boxRef}>
      <svg width="300" height="380" viewBox="0 0 300 380" fill="none" className={styles.constellationOrbits}>
        <circle cx="150" cy="190" r="70" className={styles.constellationOrbitInner} strokeDasharray="2 5" />
        <circle cx="150" cy="190" r="124" className={styles.constellationOrbitOuter} strokeDasharray="2 5" />
        <path
          d="M150 190L78 82M150 190L228 70M150 190L236 236M150 190L150 322M150 190L70 268"
          className={styles.constellationSpokes}
        />
      </svg>
      <span className={styles.constellationCore} />
      {satellites.map((s) => (
        <span
          key={s.key}
          className={`${styles.constellationSatellite} ${s.hue}`}
          data-x={s.x}
          style={{ left: s.x, top: s.y }}
        >
          <span className={styles.constellationGlyph}>{s.glyph}</span>
          {s.label}
        </span>
      ))}
    </div>
  );
}

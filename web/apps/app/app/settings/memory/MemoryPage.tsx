'use client';

import { useState, useCallback, useRef, useMemo, useEffect, type ReactElement } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import {
  ArrowLeft,
  Atom,
  Bookmark,
  Brain,
  Check,
  CheckCircle2,
  NotebookPen,
  Pencil,
  ShieldAlert,
  Sparkles,
} from 'lucide-react';
import { Button, Dialog } from '@oriveo/ui';
import { useAppStore } from '../../../providers/StoreProvider';
import { getVanillaStore } from '../../../providers/StoreProvider';
import * as preferenceOps from '../../../lib/core/preference-ops';
import { sendStream } from '../../../lib/core/providers/service';
import { readStream } from '../../../lib/utils/chat-stream-utils';
import { graphemeCount, takeGraphemes } from '../../../lib/utils/grapheme-utils';
import { getConversationById } from '../../../lib/infra/storage/idb';
import styles from './MemoryPage.module.css';

const MAX_MEMORY_CHARS = 2000;
const SOFT_WARN_CHAR_THRESHOLD = 1700;
const WARN_CHAR_THRESHOLD = 1900;
const DRAFT_CONVERSATION_LIMIT = 5;
const DRAFT_EXCERPT_LIMIT = 500;
const SAVE_SUCCESS_FLASH_MS = 1400;

type MemoryPageMode = 'starter' | 'editor';
type MemoryHeroStyle = 'draftStarter' | 'manualStarter' | 'activeMemory';
type MemoryPageAction = 'generateDraft' | 'focusEditor';

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
  memoryText: string,
  isEditorFocused: boolean,
  hasRecentConversations: boolean,
): MemoryPagePresentation {
  const trimmed = memoryText.trim();
  // heroStyle is decoupled from mode: only non-empty content counts as activeMemory (available); empty content keeps the Auto/Memory chip even while focused.
  const heroStyle: MemoryHeroStyle = trimmed.length > 0
    ? 'activeMemory'
    : (hasRecentConversations ? 'draftStarter' : 'manualStarter');
  const isStarter = trimmed.length === 0 && !isEditorFocused;
  if (isStarter) {
    return {
      mode: 'starter',
      heroStyle,
      primaryAction: hasRecentConversations ? 'generateDraft' : 'focusEditor',
      secondaryAction: hasRecentConversations ? 'focusEditor' : null,
    };
  }
  return {
    mode: 'editor',
    heroStyle,
    primaryAction: null,
    secondaryAction: null,
  };
}

export function MemoryPage() {
  const t = useTranslations('pages.memory');
  const router = useRouter();

  const preferences = useAppStore((s) => s.preferences);
  const memoryUsageCount = useAppStore((s) => s.memoryUsageCount);
  const providers = useAppStore((s) => s.providers);
  const conversations = useAppStore((s) => s.conversations);

  const [text, setText] = useState(preferences.memoryText ?? '');
  const [antiForgetEnabled, setAntiForgetEnabled] = useState(
    preferences.memoryAntiForgetEnabled ?? false,
  );
  const [isDrafting, setIsDrafting] = useState(false);
  const [isEditorFocused, setIsEditorFocused] = useState(false);
  const [showUnsavedDialog, setShowUnsavedDialog] = useState(false);
  const [showSaveSuccess, setShowSaveSuccess] = useState(false);
  const [showDraftConflict, setShowDraftConflict] = useState(false);
  const [pendingDraft, setPendingDraft] = useState<string | null>(null);
  const [errorDialog, setErrorDialog] = useState<ErrorDialogState>(null);
  const [appeared, setAppeared] = useState(false);
  const [shortcutHint, setShortcutHint] = useState<string>('⌘ S');

  const pendingNavigationRef = useRef<string | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const draftRequestIdRef = useRef(0);
  const editRevisionRef = useRef(0);
  const saveSuccessTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Entrance animation plus platform key detection (macOS shows Cmd, other platforms Ctrl).
  useEffect(() => {
    const id = requestAnimationFrame(() => setAppeared(true));
    const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform);
    setShortcutHint(isMac ? '⌘ S' : 'Ctrl S');
    return () => cancelAnimationFrame(id);
  }, []);

  // The inline save-success flash retracts on its own.
  useEffect(() => {
    if (!showSaveSuccess) return;
    if (saveSuccessTimerRef.current) clearTimeout(saveSuccessTimerRef.current);
    saveSuccessTimerRef.current = setTimeout(() => setShowSaveSuccess(false), SAVE_SUCCESS_FLASH_MS);
    return () => {
      if (saveSuccessTimerRef.current) clearTimeout(saveSuccessTimerRef.current);
    };
  }, [showSaveSuccess]);

  const trimmedText = text.trim();
  const charCount = graphemeCount(text);
  const estimatedTokens = useMemo(
    () => (charCount === 0 ? null : Math.ceil(charCount * 0.35)),
    [charCount],
  );

  // Use remoteMessageCount: after hydrate, messages in the store is always [], because
  // persistence.ts moves messages into IDB and keeps only the conversation summary plus
  // remoteMessageCount in memory.
  const hasRecentConversations = conversations.some(
    (c) => !c.isDraft && (c.remoteMessageCount ?? 0) > 0,
  );
  const presentation = buildPresentation(text, isEditorFocused, hasRecentConversations);

  const hasChanges =
    text !== (preferences.memoryText ?? '') ||
    antiForgetEnabled !== (preferences.memoryAntiForgetEnabled ?? false);

  /* ───────── Save ───────── */

  const handleSave = useCallback(() => {
    const trimmed = text.trim();
    const finalAntiForgetEnabled = trimmed ? antiForgetEnabled : false;
    const finalAntiForgetText = finalAntiForgetEnabled ? text : '';
    preferenceOps.updateMemory(
      getVanillaStore(),
      text,
      finalAntiForgetEnabled,
      finalAntiForgetText,
    );
    setIsEditorFocused(false);
    textareaRef.current?.blur();
    setShowSaveSuccess(true);
    editRevisionRef.current = 0;
  }, [text, antiForgetEnabled]);

  /* ───────── Navigation / Unsaved guard ───────── */

  const handleBack = useCallback(() => {
    if (hasChanges) {
      pendingNavigationRef.current = '/settings';
      setShowUnsavedDialog(true);
    } else {
      router.push('/settings');
    }
  }, [hasChanges, router]);

  const handleDiscard = useCallback(() => {
    setText(preferences.memoryText ?? '');
    setAntiForgetEnabled(preferences.memoryAntiForgetEnabled ?? false);
    setShowUnsavedDialog(false);
    if (pendingNavigationRef.current) {
      router.push(pendingNavigationRef.current);
      pendingNavigationRef.current = null;
    }
  }, [preferences, router]);

  /* ───────── Editor focus ───────── */

  const focusEditor = useCallback(() => {
    setIsEditorFocused(true);
    requestAnimationFrame(() => textareaRef.current?.focus());
  }, []);

  /* ───────── Anti-forget toggle ───────── */

  const handleAntiForgetToggle = useCallback(() => {
    setAntiForgetEnabled((prev) => !prev);
    editRevisionRef.current += 1;
  }, []);

  /* --------- Generate draft (round-robin across providers) --------- */

  const handleGenerateDraft = useCallback(async () => {
    const candidates = providers
      .filter((p) => p.apiKey)
      .map((p) => ({
        provider: p,
        model: p.models.find((m) => m.isDefault) ?? p.models[0] ?? null,
      }))
      .filter(
        (
          c,
        ): c is { provider: typeof providers[number]; model: NonNullable<typeof c.model> } =>
          c.model !== null,
      );

    if (candidates.length === 0) {
      const hasAnyKey = providers.some((p) => p.apiKey);
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

    // 2. Pull full messages from IDB (persistence.ts clears messages to [] to save memory and
    //    reads them back by id only when conversation content actually has to be analyzed).
    let hydrated: Array<{ id: string; messages: { role: string; text: string }[] }>;
    try {
      hydrated = await Promise.all(
        recentSummary.map(async (c) => {
          const full = await getConversationById(c.id);
          return { id: c.id, messages: full?.messages ?? [] };
        }),
      );
    } catch (err) {
      setErrorDialog({
        title: t('errorHydrateTitle'),
        message: t('errorHydrateMessage'),
      });
      return;
    }

    const excerpts = hydrated
      .map((conv) =>
        conv.messages
          .filter((m) => m.role === 'user' || m.role === 'assistant')
          .map((m) => `${m.role}: ${m.text}`)
          .join('\n')
          .slice(0, DRAFT_EXCERPT_LIMIT),
      )
      .filter((s) => s.trim().length > 0)
      .join('\n---\n');

    if (!excerpts.trim()) {
      setErrorDialog({
        title: t('errorNotEnoughTitle'),
        message: t('errorNotEnoughMessage'),
      });
      return;
    }

    const prompt = `Based on the following conversation excerpts, write a concise personal profile in the same language the user is using (under 400 words).
Include: their role/expertise, current projects or tech stack, preferred response style and language.
Only include information clearly evident from the conversations. Do not invent or assume.
Write in first person, as if the user is describing themselves.

Conversation excerpts:
${excerpts}`;

    draftRequestIdRef.current += 1;
    const thisRequestId = draftRequestIdRef.current;
    const baselineRevision = editRevisionRef.current;
    const baselineText = text;

    setIsDrafting(true);
    let lastError: unknown = null;
    let attempts = 0;

    for (const candidate of candidates) {
      if (draftRequestIdRef.current !== thisRequestId) {
        setIsDrafting(false);
        return;
      }
      attempts += 1;
      try {
        const { stream } = sendStream(
          candidate.provider.kind,
          candidate.provider.apiKey,
          candidate.model.id,
          [{ role: 'user', content: prompt }],
          candidate.provider.baseURLText,
        );
        const { fullText } = await readStream(stream, '', () => {});
        if (draftRequestIdRef.current !== thisRequestId) {
          setIsDrafting(false);
          return;
        }
        const draft = takeGraphemes(fullText.trim(), MAX_MEMORY_CHARS);
        if (!draft) {
          lastError = new Error('Empty response');
          continue;
        }
        const userEditedSinceStart =
          editRevisionRef.current !== baselineRevision || text !== baselineText;
        if (userEditedSinceStart) {
          setPendingDraft(draft);
          setShowDraftConflict(true);
        } else {
          setText(draft);
          editRevisionRef.current += 1;
          focusEditor();
        }
        setIsDrafting(false);
        return;
      } catch (err) {
        lastError = err;
        continue;
      }
    }

    setIsDrafting(false);
    if (draftRequestIdRef.current !== thisRequestId) return;
    const errMsg =
      (lastError && typeof lastError === 'object' && 'message' in lastError
        ? (lastError as { message?: unknown }).message
        : undefined) ?? '';
    const errMsgStr = typeof errMsg === 'string' ? errMsg : '';
    if (attempts <= 1) {
      setErrorDialog({
        title: t('errorGenericTitle'),
        message: errMsgStr || t('errorHydrateMessage'),
      });
    } else {
      setErrorDialog({
        title: t('errorGenericTitle'),
        message: errMsgStr
          ? t('errorAggregatedWithDetail', { count: attempts, error: errMsgStr })
          : t('errorAggregated', { count: attempts }),
      });
    }
  }, [providers, conversations, text, t, focusEditor]);

  /* ───────── Draft conflict resolution ───────── */

  const handleApplyDraft = useCallback(() => {
    if (pendingDraft) {
      setText(pendingDraft);
      editRevisionRef.current += 1;
    }
    setPendingDraft(null);
    setShowDraftConflict(false);
  }, [pendingDraft]);

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
        focusEditor();
      }
    },
    [handleGenerateDraft, focusEditor],
  );

  /* --------- Keyboard shortcuts --------- */
  // Cmd+S / Ctrl+S saves (only when hasChanges); Esc goes back; Cmd+Enter generates a draft.
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      // Ignore IME composition and the form's built-in enter handling.
      if (e.isComposing) return;
      const mod = e.metaKey || e.ctrlKey;
      if (mod && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        if (hasChanges) handleSave();
        return;
      }
      if (mod && e.key === 'Enter') {
        e.preventDefault();
        if (hasRecentConversations && !isDrafting) {
          void handleGenerateDraft();
        }
        return;
      }
      if (e.key === 'Escape') {
        // Only go back when no modal is open and the editor is not focused.
        if (showUnsavedDialog || showSaveSuccess || showDraftConflict || errorDialog) return;
        if (document.activeElement === textareaRef.current) return;
        e.preventDefault();
        handleBack();
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [
    hasChanges,
    hasRecentConversations,
    isDrafting,
    handleSave,
    handleBack,
    handleGenerateDraft,
    showUnsavedDialog,
    showSaveSuccess,
    showDraftConflict,
    errorDialog,
  ]);

  /* --------- AntiForget description rendering: highlight the number, for example "10" --------- */
  const antiForgetDescNodes = useMemo<ReactElement[]>(() => {
    const desc = t('antiForgetDescription');
    return desc.split(/(\d+)/).map((part, i) =>
      /^\d+$/.test(part) ? (
        <em key={`hl-${i}`} className={styles.descHighlight}>{part}</em>
      ) : (
        <span key={`tx-${i}`}>{part}</span>
      ),
    );
  }, [t]);

  /* ───────── Hero chip ───────── */

  const heroChip: { label: string; icon: ReactElement; tone: 'primary' | 'success' } = (() => {
    switch (presentation.heroStyle) {
      case 'draftStarter':
        return { label: t('heroChipAuto'), icon: <Sparkles size={11} strokeWidth={2.4} />, tone: 'primary' };
      case 'manualStarter':
        return { label: t('title'), icon: <Pencil size={11} strokeWidth={2.4} />, tone: 'primary' };
      case 'activeMemory':
      default:
        return { label: t('heroChipReady'), icon: <CheckCircle2 size={11} strokeWidth={2.4} />, tone: 'success' };
    }
  })();

  /* ───────── Action button copy ───────── */

  const actionLabel = (action: MemoryPageAction) =>
    action === 'generateDraft' ? t('generateDraft') : t('manualWrite');
  const actionIcon = (action: MemoryPageAction) =>
    action === 'generateDraft' ? <Sparkles size={14} /> : <Pencil size={14} />;

  /* ───────── Subtitles ───────── */

  const headerSubtitle =
    presentation.mode === 'starter'
      ? t('emptyDescription')
      : t('description');

  /* ───────── Render ───────── */

  return (
    <div className={`${styles.page} ${appeared ? styles.pageAppeared : ''}`}>
      <a
        className={styles.backLink}
        onClick={handleBack}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => e.key === 'Enter' && handleBack()}
      >
        <ArrowLeft size={14} strokeWidth={2.4} />
        <span>{t('backToSettings')}</span>
      </a>

      <header className={styles.header}>
        <div className={styles.headerTitleRow}>
          <h1 className={styles.title}>{t('title')}</h1>
          <span
            className={`${styles.chip} ${
              heroChip.tone === 'primary' ? styles.chipPrimary : styles.chipSuccess
            }`}
          >
            {heroChip.icon}
            <span>{heroChip.label}</span>
          </span>
        </div>
        <p className={styles.subtitle}>{headerSubtitle}</p>
      </header>

      {presentation.mode === 'starter' ? (
        /* --- Starter: ambient gradient CTA card --- */
        <section className={styles.starterCard}>
          <div className={styles.starterGlyph} aria-hidden="true">
            <div className={styles.starterGlyphInner}>
              <Brain size={28} strokeWidth={2.2} />
            </div>
          </div>
          <h2 className={styles.starterTitle}>{t('emptyTitle')}</h2>
          <p className={styles.starterBody}>{t('emptyDescription')}</p>
          {presentation.primaryAction && (
            <div className={styles.starterActions}>
              <Button
                className={styles.starterPrimary}
                onClick={() => void handleAction(presentation.primaryAction!)}
                disabled={presentation.primaryAction === 'generateDraft' && isDrafting}
              >
                {presentation.primaryAction === 'generateDraft' && isDrafting ? (
                  <span className={styles.spinner} aria-hidden />
                ) : (
                  <>
                    {actionIcon(presentation.primaryAction)}
                    <span>{actionLabel(presentation.primaryAction)}</span>
                  </>
                )}
              </Button>
              {presentation.secondaryAction && (
                <button
                  type="button"
                  className={styles.starterSecondary}
                  onClick={() => void handleAction(presentation.secondaryAction!)}
                >
                  {actionIcon(presentation.secondaryAction)}
                  <span>{actionLabel(presentation.secondaryAction)}</span>
                </button>
              )}
            </div>
          )}
        </section>
      ) : (
        /* --- Editor: two column on desktop --- */
        <div className={styles.editorGrid}>
          <section
            className={`${styles.editorCard} ${isEditorFocused ? styles.editorCardFocused : ''}`}
          >
            <div className={styles.editorHeader}>
              <span className={styles.editorIcon} aria-hidden="true">
                <NotebookPen size={15} strokeWidth={2.2} />
              </span>
              <h2 className={styles.editorTitle}>{t('title')}</h2>
              <span
                className={`${styles.charCounter} ${
                  charCount > WARN_CHAR_THRESHOLD
                    ? styles.charCounterWarn
                    : charCount > SOFT_WARN_CHAR_THRESHOLD
                      ? styles.charCounterSoftWarn
                      : ''
                }`}
              >
                {charCount.toLocaleString()} / {MAX_MEMORY_CHARS.toLocaleString()}
              </span>
            </div>

            <textarea
              ref={textareaRef}
              className={styles.textarea}
              value={text}
              onChange={(e) => {
                const val = e.target.value;
                if (graphemeCount(val) <= MAX_MEMORY_CHARS) {
                  setText(val);
                } else {
                  setText(takeGraphemes(val, MAX_MEMORY_CHARS));
                }
                editRevisionRef.current += 1;
              }}
              onFocus={() => setIsEditorFocused(true)}
              onBlur={() => setIsEditorFocused(false)}
              placeholder={t('exampleHint')}
            />

            {estimatedTokens != null && (
              <div className={styles.editorFooter}>
                <span className={styles.editorMeta}>
                  <Atom size={11} strokeWidth={2.2} />
                  <span>≈ {estimatedTokens.toLocaleString()} tokens</span>
                </span>
              </div>
            )}
          </section>

          <aside className={styles.sidebar}>
            {hasRecentConversations && (
              <button
                type="button"
                className={styles.regenerateCard}
                onClick={() => void handleGenerateDraft()}
                disabled={isDrafting}
              >
                <span className={styles.regenerateIcon} aria-hidden="true">
                  {isDrafting ? (
                    <span className={styles.regenerateSpinner} aria-hidden />
                  ) : (
                    <Sparkles size={15} strokeWidth={2.4} />
                  )}
                </span>
                <span className={styles.regenerateText}>{t('generateDraft')}</span>
              </button>
            )}

            {memoryUsageCount > 0 && (
              <div className={styles.statCard}>
                <span className={styles.statIcon} aria-hidden="true">
                  <CheckCircle2 size={15} strokeWidth={2.4} />
                </span>
                <div className={styles.statText}>
                  <span className={styles.statValue}>{memoryUsageCount.toLocaleString()}</span>
                  <span className={styles.statLabel}>{t('usageCountLabel')}</span>
                </div>
              </div>
            )}

            <div
              className={`${styles.toggleCard} ${
                antiForgetEnabled ? styles.toggleCardActive : ''
              }`}
            >
              <div className={styles.toggleHeader}>
                <span
                  className={`${styles.toggleIcon} ${
                    antiForgetEnabled ? styles.toggleIconActive : ''
                  }`}
                  aria-hidden="true"
                >
                  <Bookmark size={14} strokeWidth={2.2} fill={antiForgetEnabled ? 'currentColor' : 'none'} />
                </span>
                <div className={styles.toggleText}>
                  <span className={styles.toggleTitle}>{t('antiForgetSection')}</span>
                  <span className={styles.toggleDesc}>{antiForgetDescNodes}</span>
                </div>
                <button
                  type="button"
                  className={styles.toggle}
                  data-on={antiForgetEnabled}
                  onClick={handleAntiForgetToggle}
                  aria-label={t('antiForgetSection')}
                  aria-pressed={antiForgetEnabled}
                >
                  <span className={styles.toggleKnob} />
                </button>
              </div>
            </div>

            <p className={styles.privacyNote}>
              <ShieldAlert size={13} strokeWidth={2.2} className={styles.privacyIcon} />
              <span>{t('privacyWarning')}</span>
            </p>
          </aside>
        </div>
      )}

      {(hasChanges || showSaveSuccess) && (
        <div className={styles.saveBar}>
          <div
            className={`${styles.saveBarInner} ${showSaveSuccess ? styles.saveBarSuccess : ''}`}
            role="status"
            aria-live="polite"
          >
            {showSaveSuccess ? (
              <>
                <span className={styles.saveSuccessIcon} aria-hidden="true">
                  <Check size={14} strokeWidth={3} />
                </span>
                <span className={styles.saveLabel}>{t('saved')}</span>
                <span className={styles.saveMeta}>
                  {charCount.toLocaleString()} / {MAX_MEMORY_CHARS.toLocaleString()}
                  {estimatedTokens != null && <> - {estimatedTokens.toLocaleString()} tokens</>}
                </span>
              </>
            ) : (
              <>
                <span className={styles.saveDot} aria-hidden="true" />
                <span className={styles.saveLabel}>{t('unsavedBarTitle')}</span>
                <span className={styles.saveMeta}>
                  {charCount.toLocaleString()} / {MAX_MEMORY_CHARS.toLocaleString()}
                  {estimatedTokens != null && <> - {estimatedTokens.toLocaleString()} tokens</>}
                </span>
                <Button className={styles.saveBtn} onClick={handleSave}>
                  <span>{t('save')}</span>
                  <kbd className={styles.kbdHint} aria-hidden="true">{shortcutHint}</kbd>
                </Button>
              </>
            )}
          </div>
        </div>
      )}

      <Dialog open={showUnsavedDialog} onClose={() => setShowUnsavedDialog(false)}>
        <h2 className={styles.dialogTitle}>{t('unsavedChanges')}</h2>
        <div className={styles.dialogActions}>
          <Button tone="secondary" size="sm" onClick={() => setShowUnsavedDialog(false)}>
            {t('keepEditing')}
          </Button>
          <Button tone="danger" size="sm" onClick={handleDiscard}>
            {t('discard')}
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

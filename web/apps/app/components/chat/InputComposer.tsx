'use client';

import React from 'react';
import { useRef, useCallback, useEffect, useLayoutEffect, useState, useId } from 'react';
import { useTranslations } from 'next-intl';
import type { Attachment, AIModel, Provider, SendShortcut, QuoteContext } from '@oriveo/shared';
import { AttachmentPreview } from './AttachmentPreview';
import { MODEL_OPTIONS_POPOVER_ID, ModelOptionsPopover } from './ModelOptionsPopover';
import { ComposerToolButton } from './ComposerToolButton';
import { Brain, FileText, Globe, Library, Quote, SlidersHorizontal } from 'lucide-react';
import { AttachmentIcon, StopIcon, SendIcon, CloseIcon } from '../icons';
import { AttachmentSizeLimitDialog } from './AttachmentSizeLimitDialog';
import { NoteReferencePreview } from './NoteReferencePreview';
import { resolveAttachmentCapabilities, buildAcceptAttribute } from '../../lib/core/chat/attachment-policy';
import { useAppStore } from '../../providers/StoreProvider';
import { useAttachmentIntake, type AttachmentFilePolicy } from '../../lib/hooks/useAttachmentIntake';
import type { ProviderAttachmentSupport } from '../../lib/core/metadata/metadata-client';
import styles from './InputComposer.module.css';
import type { LibraryDocumentRef } from '../../lib/core/library/types';
import { QuoteContextChip } from './QuoteContextChip';
import { generationParameterProfileFingerprint, loadGenerationParameterOverrides } from '../../lib/core/chat/generation-parameter-settings';
import { partitionGenerationParameterValues } from '../../lib/core/chat/generation-parameter-lifecycle';
import type { CustomFragmentOwner } from '../../lib/core/chat/custom-fragment-settings';
import type { CapabilityControlPresentation } from '../../lib/core/chat/capability-control-presentation';
import type { CapabilityWebPreference } from '../../lib/core/chat/capability-preference-settings';
import type { ReasoningIntent } from '@oriveo/core/providers/request-preference/types';

export interface AttachedNoteRef {
  id: string;
  title: string;
  /** Markdown-stripped body excerpt for the hover preview; undefined when there is no body. */
  bodyPreview?: string;
  /** Display name of the source model or provider, shown on the preview source line. */
  sourceLabel?: string;
  /** Creation time as an ISO string; the preview renders a localized date. */
  createdAt?: string;
}

interface InputComposerProps {
  value: string;
  onChange: (value: string) => void;
  onSend: () => void;
  onStop?: () => void;
  isStreaming: boolean;
  disabled?: boolean;
  /* Attachments */
  attachments?: Attachment[];
  onAttachmentsChange?: (attachments: Attachment[]) => void;
  /* Reasoning */
  /**
   * Single source of truth for the reasoning intent. `ReasoningMode` cannot express `off`, and
   * treating it as the truth produced "turned it off but the chip still says automatic". Chip
   * copy and aria state both follow this value.
   */
  reasoningIntent?: ReasoningIntent;
  /** A tier was selected in the panel. `undefined` = "automatic", i.e. inject no tier at all. */
  onReasoningIntentChange?: (intent: ReasoningIntent | undefined) => void;
  reasoningOutboundActive?: boolean;
  /* Web search */
  /** P4b tri-state control. Force is exposed only when the runtime explicitly offers it. */
  webPreference?: CapabilityWebPreference;
  onWebPreferenceChange?: (next: CapabilityWebPreference) => void;
  webOutboundActive?: boolean;
  webRuntimeRejected?: boolean;
  /* Library research — caller owns login/connection/model gates. */
  libraryResearchEnabled?: boolean;
  onLibraryResearchToggle?: (next: boolean) => void;
  /* Model capabilities */
  currentModel?: AIModel;
  generationParameterProvider?: Provider;
  generationParameterConversationId?: string;
  /** When true, the three model-control entries are view-only for this connection. */
  managedModelControls?: boolean;
  /**
   * Server decision for the three controls on the current model (state + reasonCode +
   * availableIntents). The whole object is passed down rather than a set of booleans: the panel
   * shape depends on state and reasonCode together, and splitting them always drops half the
   * information somewhere, which is how unknown and pending end up merged.
   */
  webControl?: CapabilityControlPresentation;
  reasoningControl?: CapabilityControlPresentation;
  generationControl?: CapabilityControlPresentation;
  /** Full runtime identity; when missing the panel goes read-only and offers the matching recovery action. */
  capabilityTransportIdentity?: string;
  reasoningRuntimeRejected?: boolean;
  /** Candidate models where automatic configuration really works on this connection, keyed by capability. An empty array renders an honest empty state rather than a dead button. */
  capabilityAlternativeModels?: Partial<Record<CustomFragmentOwner, AIModel[]>>;
  onSelectAlternativeModel?: (model: AIModel) => void;
  /** Opens the existing model switcher; used as the managed/read-only alternative action. */
  onOpenModelSwitcher?: () => void;
  /** The only way forward when the relay protocol is undetermined: the panel does not route itself, ChatView pushes the provider detail page. */
  onOpenConnectionSettings?: () => void;
  /**
   * Primary action of the "not adjustable" row in the model behavior panel ("find models that
   * support this parameter"). The composer only forwards it; ChatView opens the model picker and
   * adds "supports this parameter" to the filters.
   */
  onFindModelsSupportingParameter?: (parameterId: string) => void;
  /* Provider attachment support - provider-level attachment protocol limits. */
  providerAttachmentSupport?: ProviderAttachmentSupport | null;
  /** Current conversation provider.kind normalized to snake_case by telemetryProviderKind(), used for attachment_added reporting. */
  providerKind?: string;
  /** Provider-level attachment limits (managed: 20MB / 25MB / 3 files). */
  attachmentFilePolicy?: AttachmentFilePolicy;
  attachmentLimitDialogCopy?: {
    title: string;
    message: string;
    actionLabel: string;
  };
  /** Visual placement. "home" lifts the composer into the empty-chat workspace. */
  presentation?: 'docked' | 'home';
  relatedNotes?: Array<{ id: string; title: string; score: number; sourceLabel?: string }>;
  onAttachRelatedNote?: (noteId: string) => void;
  onDismissRelatedNote?: (noteId: string) => void;
  /** Notes pinned as context, shown as chips above the input and injected on every turn; removable in one click. */
  attachedNotes?: AttachedNoteRef[];
  onDetachNote?: (noteId: string) => void;
  libraryContextDocuments?: LibraryDocumentRef[];
  onAddLibraryContext?: () => void;
  onDetachLibraryContext?: (document: LibraryDocumentRef) => void;
  /** Custom placeholder; falls back to the default placeholder when absent. */
  placeholderOverride?: string;
  quoteContext?: QuoteContext;
  onRemoveQuote?: () => void;
  quoteFocusSignal?: number;
}

function formatPreviewDate(iso?: string): string | undefined {
  if (!iso) return undefined;
  const date = new Date(iso);
  //  Invalid Date 
  return Number.isNaN(date.getTime()) ? undefined : date.toLocaleDateString();
}

function isFinePointer(): boolean {
  return typeof window !== 'undefined' && window.matchMedia('(pointer: fine)').matches;
}

/**
 * Chip for a note pinned as context. With a fine pointer, hover/focus opens the preview card;
 * on touch, tapping toggles it (there is no hover). Clicking the chip body on desktop does
 * nothing, since hover already previews.
 * `open` is controlled by the parent so only one card is open at a time and cards never overlap;
 * the delete area is separate and does not trigger the preview.
 */
function AttachedNoteChip({
  note,
  onDetach,
  removeLabel,
  isOpen,
  onOpen,
  onClose,
}: {
  note: AttachedNoteRef;
  onDetach?: (noteId: string) => void;
  removeLabel: string;
  isOpen: boolean;
  onOpen: (noteId: string) => void;
  onClose: (noteId: string) => void;
}) {
  const chipRef = useRef<HTMLButtonElement>(null);
  const previewId = useId();
  const [anchorRect, setAnchorRect] = useState<DOMRect | null>(null);
  const openTimer = useRef<number | undefined>(undefined);
  const closeTimer = useRef<number | undefined>(undefined);

  //   chip  
  const hasPreview = Boolean(note.bodyPreview || note.sourceLabel);

  const doOpen = useCallback(() => {
    if (chipRef.current) setAnchorRect(chipRef.current.getBoundingClientRect());
    onOpen(note.id);
  }, [note.id, onOpen]);
  const scheduleClose = useCallback(() => {
    window.clearTimeout(closeTimer.current);
    closeTimer.current = window.setTimeout(() => onClose(note.id), 200);
  }, [note.id, onClose]);
  const cancelClose = useCallback(() => {
    window.clearTimeout(closeTimer.current);
  }, []);

  useEffect(
    () => () => {
      window.clearTimeout(openTimer.current);
      window.clearTimeout(closeTimer.current);
    },
    [],
  );

  const handleMouseEnter = () => {
    if (!hasPreview || !isFinePointer()) return;
    window.clearTimeout(closeTimer.current);
    window.clearTimeout(openTimer.current);
    openTimer.current = window.setTimeout(doOpen, 150);
  };
  const handleMouseLeave = () => {
    window.clearTimeout(openTimer.current);
    if (isFinePointer()) scheduleClose();
  };
  const handleClick = () => {
    // Desktop already previews on hover, so a click must not repeat it; touch has no hover and toggles.
    if (!hasPreview || isFinePointer()) return;
    if (isOpen) onClose(note.id);
    else doOpen();
  };
  const handleFocus = () => {
    if (hasPreview && isFinePointer()) doOpen();
  };
  const handleBlur = () => {
    if (isFinePointer()) scheduleClose();
  };

  return (
    <span className={styles.attachedNoteChip}>
      <button
        ref={chipRef}
        type="button"
        className={styles.attachedNoteChipMain}
        aria-describedby={isOpen ? previewId : undefined}
        onMouseEnter={handleMouseEnter}
        onMouseLeave={handleMouseLeave}
        onClick={handleClick}
        onFocus={handleFocus}
        onBlur={handleBlur}
      >
        <Quote size={13} className={styles.attachedNoteIcon} aria-hidden />
        <span className={styles.attachedNoteTitle}>{note.title}</span>
      </button>
      {onDetach && (
        <button
          type="button"
          className={styles.attachedNoteRemove}
          onClick={() => onDetach(note.id)}
          aria-label={removeLabel}
        >
          <CloseIcon strokeWidth={2.5} />
        </button>
      )}
      {isOpen && hasPreview && anchorRect && (
        <NoteReferencePreview
          id={previewId}
          title={note.title}
          bodyPreview={note.bodyPreview}
          sourceLabel={note.sourceLabel}
          dateLabel={formatPreviewDate(note.createdAt)}
          anchorRect={anchorRect}
          anchorRef={chipRef}
          onClose={() => onClose(note.id)}
          onPointerEnter={cancelClose}
          onPointerLeave={scheduleClose}
        />
      )}
    </span>
  );
}

const MAX_TEXTAREA_HEIGHT_PX = 200;
/** Window after sending during which a trailing IME compositionend or input event must not write the sent text back into the box. */
const SEND_RESTORE_SUPPRESS_MS = 250;

function resizeTextareaToContent(el: HTMLTextAreaElement) {
  el.style.height = 'auto';
  const nextHeight = Math.min(el.scrollHeight, MAX_TEXTAREA_HEIGHT_PX);
  el.style.height = `${nextHeight}px`;
  el.style.overflowY = el.scrollHeight > MAX_TEXTAREA_HEIGHT_PX ? 'auto' : 'hidden';
}

export function InputComposer({
  value,
  onChange,
  onSend,
  onStop,
  isStreaming,
  disabled,
  attachments = [],
  onAttachmentsChange,
  reasoningIntent,
  onReasoningIntentChange,
  reasoningOutboundActive = false,
  webPreference,
  onWebPreferenceChange,
  webOutboundActive = false,
  webRuntimeRejected = false,
  libraryResearchEnabled,
  onLibraryResearchToggle,
  currentModel,
  generationParameterProvider,
  generationParameterConversationId,
  managedModelControls = false,
  webControl,
  reasoningControl,
  generationControl,
  capabilityTransportIdentity,
  reasoningRuntimeRejected = false,
  capabilityAlternativeModels,
  onSelectAlternativeModel,
  onOpenModelSwitcher,
  onOpenConnectionSettings,
  onFindModelsSupportingParameter,
  providerAttachmentSupport,
  providerKind,
  attachmentFilePolicy,
  attachmentLimitDialogCopy,
  presentation = 'docked',
  relatedNotes = [],
  onAttachRelatedNote,
  onDismissRelatedNote,
  attachedNotes = [],
  onDetachNote,
  libraryContextDocuments = [],
  onAddLibraryContext,
  onDetachLibraryContext,
  placeholderOverride,
  quoteContext,
  onRemoveQuote,
  quoteFocusSignal,
}: InputComposerProps) {
  const t = useTranslations('pages.chat');
  // These session-scope labels live in the shared `common` contract. Keeping this namespace
  // exact is important: next-intl otherwise renders a raw key in production locales.
  const tCommon = useTranslations('common');
  const tLibrary = useTranslations('library');
  // Hover preview card for reference chips: only one is open at a time so cards never overlap.
  const [openNoteId, setOpenNoteId] = useState<string | null>(null);
  const handleNoteClose = useCallback(
    (id: string) => setOpenNoteId((cur) => (cur === id ? null : cur)),
    [],
  );
  const composerRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const suppressSendRestoreRef = useRef(false);
  const lastSentValueRef = useRef('');
  const sendGenerationRef = useRef(0);
  const sendShortcut = useAppStore((s) => s.preferences.sendShortcut) as SendShortcut;
  const storageQuota = null as { blockUploads?: boolean; status?: string } | null;
  const [modelControlsOpen, setModelControlsOpen] = useState(false);
  const [hasModelBehaviorOverride, setHasModelBehaviorOverride] = useState(false);
  /**
   * Return focus to the chip after the popover closes.
   *
   * Only when focus was actually inside the popover: the popover is non-modal, so when it closes
   * because the user clicked elsewhere, focus already has a new owner and stealing it back would
   * yank them out of the field they just clicked. Conversely, when focus is inside the popover as
   * it unmounts, not returning it drops focus to `<body>` and keyboard users have to Tab from the
   * top of the page again.
   */
  const modelControlsTriggerRef = useRef<HTMLButtonElement>(null);
  const restoresModelControlsFocus = useRef(false);
  const closeModelControlsWithFocus = useCallback(() => {
    const popover = document.getElementById(MODEL_OPTIONS_POPOVER_ID);
    const active = document.activeElement;
    restoresModelControlsFocus.current = Boolean(popover && active && popover.contains(active));
    setModelControlsOpen(false);
  }, []);
  useEffect(() => {
    if (modelControlsOpen || !restoresModelControlsFocus.current) return;
    restoresModelControlsFocus.current = false;
    modelControlsTriggerRef.current?.focus({ preventScroll: true });
  }, [modelControlsOpen]);

  useEffect(() => {
    if (managedModelControls || !generationParameterProvider || !currentModel || !generationParameterConversationId) {
      setHasModelBehaviorOverride(false);
      return;
    }
    const stored = loadGenerationParameterOverrides({
      providerId: generationParameterProvider.id,
      modelId: currentModel.id,
      conversationId: generationParameterConversationId,
      profileFingerprint: generationParameterProfileFingerprint(generationParameterProvider, currentModel),
    });
    // The dot on the chip means "this conversation has custom behavior in effect". A dormant value
    // cannot be sent right now, so lighting the dot with it would be another fake state; its honest
    // home is the "retained, currently inactive" summary inside the panel.
    const active = stored
      ? partitionGenerationParameterValues({
          provider: generationParameterProvider,
          model: currentModel,
          values: stored,
        }).active
      : undefined;
    setHasModelBehaviorOverride(Boolean(active && Object.values(active).some((item) => item?.state !== 'inherit')));
  }, [currentModel, generationParameterConversationId, generationParameterProvider, managedModelControls]);

  const { supportsImage, supportsAttachment } = resolveAttachmentCapabilities(
    generationParameterProvider,
    currentModel,
    providerAttachmentSupport,
  );
  const showLibraryContextButton = Boolean(onAddLibraryContext);

  const {
    showAttachmentSizeLimit,
    setShowAttachmentSizeLimit,
    handleFileInput,
    handlePaste,
    handleRemoveAttachment,
  } = useAttachmentIntake({
    attachments,
    onAttachmentsChange,
    supportsImage,
    providerKind,
    attachmentFilePolicy,
  });

  // Keep controlled updates, draft restore, and send/reset in sync with the textarea height.
  useLayoutEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    // After clearing on send, the IME may have written the original text back into the DOM while React still thinks value is unchanged.
    if (suppressSendRestoreRef.current && el.value !== value) {
      el.value = value;
    }
    resizeTextareaToContent(el);
  }, [value]);

  useEffect(() => {
    if (!quoteFocusSignal) return;
    textareaRef.current?.focus({ preventScroll: true });
  }, [quoteFocusSignal]);

  useEffect(() => {
    if (!modelControlsOpen) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      if (composerRef.current?.contains(event.target as Node)) {
        return;
      }
      closeModelControlsWithFocus();
    };

    // Esc only reaches here from the main pane: the popover handles it first in the document
    // capture phase, where secondary and tertiary panes go back one level and stopPropagation().
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        closeModelControlsWithFocus();
      }
    };

    document.addEventListener('pointerdown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);

    return () => {
      document.removeEventListener('pointerdown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [closeModelControlsWithFocus, modelControlsOpen]);

  const requestSend = useCallback(() => {
    if (isStreaming || !value.trim()) return;
    const generation = ++sendGenerationRef.current;
    lastSentValueRef.current = value;
    suppressSendRestoreRef.current = true;
    onSend();
    window.setTimeout(() => {
      if (sendGenerationRef.current !== generation) return;
      suppressSendRestoreRef.current = false;
      lastSentValueRef.current = '';
    }, SEND_RESTORE_SUPPRESS_MS);
  }, [isStreaming, onSend, value]);

  const revertSuppressedRestore = useCallback((el: HTMLTextAreaElement) => {
    el.value = value;
    resizeTextareaToContent(el);
  }, [value]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if (e.key !== 'Enter') return;

      // Do not send while the IME candidate window is open. Chrome usually suppresses this, but
      // Edge and some Chromium derivatives report isComposing inconsistently on the Enter keydown
      // that selects a candidate. Checking isComposing and keyCode 229 covers every browser.
      if (e.nativeEvent.isComposing || e.keyCode === 229) return;

      const shouldSend =
        sendShortcut === 'enter'
          ? !e.shiftKey && !e.ctrlKey && !e.metaKey
          : e.ctrlKey || e.metaKey;

      if (shouldSend) {
        e.preventDefault();
        requestSend();
      }
    },
    [requestSend, sendShortcut],
  );

  const handleTextChange = useCallback(
    (e: React.ChangeEvent<HTMLTextAreaElement>) => {
      const next = e.currentTarget.value;
      if (suppressSendRestoreRef.current && next === lastSentValueRef.current) {
        revertSuppressedRestore(e.currentTarget);
        return;
      }
      if (suppressSendRestoreRef.current) {
        suppressSendRestoreRef.current = false;
        lastSentValueRef.current = '';
      }
      resizeTextareaToContent(e.currentTarget);
      onChange(next);
    },
    [onChange, revertSuppressedRestore],
  );

  const handleCompositionEnd = useCallback(
    (e: React.CompositionEvent<HTMLTextAreaElement>) => {
      if (!suppressSendRestoreRef.current) return;
      revertSuppressedRestore(e.currentTarget);
    },
    [revertSuppressedRestore],
  );

  const acceptTypes = buildAcceptAttribute(generationParameterProvider, currentModel, providerAttachmentSupport);

  const hasAttachments = attachments.length > 0;
  const capabilityRuntimeReadOnly = isStreaming || Boolean(disabled);
  const capabilityRuntimeReadOnlyReason = isStreaming
    ? t('aiAnswering')
    : tCommon('capabilityControlsReadOnlyConversation');
  const closeModelControls = closeModelControlsWithFocus;
  const webModelControlGlyphActive = !managedModelControls && webOutboundActive && !webRuntimeRejected;
  const reasoningModelControlGlyphActive = !managedModelControls
    && reasoningOutboundActive
    && !reasoningRuntimeRejected;
  const modelBehaviorGlyphActive = !managedModelControls
    && generationControl?.state !== 'unavailable'
    && hasModelBehaviorOverride;
  const modelControlGlyphActive = webModelControlGlyphActive
    || reasoningModelControlGlyphActive
    || modelBehaviorGlyphActive;
  const modelControlCapabilityIcons: Array<{ key: string; icon: React.ReactNode }> = [];
  if (webModelControlGlyphActive) {
    modelControlCapabilityIcons.push({ key: 'web', icon: <Globe size={11} strokeWidth={2.5} /> });
  }
  if (reasoningModelControlGlyphActive) {
    modelControlCapabilityIcons.push({ key: 'reasoning', icon: <Brain size={11} strokeWidth={2.5} /> });
  }
  const modelControlStateDescription = [
    webModelControlGlyphActive ? tCommon('capabilityControlWebSearch') : null,
    reasoningModelControlGlyphActive ? tCommon('capabilityControlThinking') : null,
    modelBehaviorGlyphActive ? tCommon('modelBehavior') : null,
  ].filter((label): label is string => label !== null).join(' - ') || undefined;

  return (
    <div className={`${styles.wrap} ${presentation === 'home' ? styles.wrapHome : ''}`}>
      <AttachmentSizeLimitDialog
        open={showAttachmentSizeLimit}
        onClose={() => setShowAttachmentSizeLimit(false)}
        title={attachmentLimitDialogCopy?.title}
        message={attachmentLimitDialogCopy?.message}
        actionLabel={attachmentLimitDialogCopy?.actionLabel}
      />
      <div ref={composerRef} className={styles.composer} data-focused={undefined}>
        {quoteContext ? (
          <div className={styles.pendingQuote}>
            <QuoteContextChip
              quoteContext={quoteContext}
              presentation="composer"
              onRemove={onRemoveQuote}
            />
          </div>
        ) : null}
        {libraryContextDocuments.length > 0 && (
          <div className={styles.attachedNotes} aria-label={tLibrary('contextDocumentsLabel')}>
            {libraryContextDocuments.map((document) => (
              <span key={`${document.source}:${document.docId}`} className={styles.attachedNoteChip}>
                <span className={styles.attachedNoteChipMain}>
                  {document.source === 'notion' ? (
                    <span className={styles.libraryContextMonogram} aria-hidden="true">N</span>
                  ) : (
                    <FileText size={13} className={styles.attachedNoteIcon} aria-hidden="true" />
                  )}
                  <span className={styles.attachedNoteTitle}>{document.title}</span>
                </span>
                {onDetachLibraryContext && (
                  <button
                    type="button"
                    className={styles.attachedNoteRemove}
                    onClick={() => onDetachLibraryContext(document)}
                    aria-label={tLibrary('removeDocumentContext', { title: document.title })}
                  >
                    <CloseIcon strokeWidth={2.5} />
                  </button>
                )}
              </span>
            ))}
          </div>
        )}
        {attachedNotes.length > 0 && (
          <div className={styles.attachedNotes} aria-label={t('attachedNotesTitle')}>
            {attachedNotes.map((note) => (
              <AttachedNoteChip
                key={note.id}
                note={note}
                onDetach={onDetachNote}
                removeLabel={t('removeNoteContext', { title: note.title })}
                isOpen={openNoteId === note.id}
                onOpen={setOpenNoteId}
                onClose={handleNoteClose}
              />
            ))}
          </div>
        )}
        {relatedNotes.length > 0 && (
          <div className={styles.relatedNotes} aria-label={t('relatedNotesTitle')}>
            <span className={styles.relatedNotesTitle}>{t('relatedNotesTitle')}</span>
            <div className={styles.relatedNoteList}>
              {relatedNotes.map((note) => (
                <div key={note.id} className={styles.relatedNoteItem}>
                  <span className={styles.relatedNoteCopy}>
                    {note.sourceLabel ? <span className={styles.relatedNoteSource}>{note.sourceLabel}</span> : null}
                    <span className={styles.relatedNoteTitle}>{note.title}</span>
                  </span>
                  <span className={styles.relatedNoteActions}>
                    <button type="button" className={styles.relatedNoteAttach} onClick={() => onAttachRelatedNote?.(note.id)}>
                      {t('attachNoteContext')}
                    </button>
                    <button type="button" className={styles.relatedNoteDismiss} onClick={() => onDismissRelatedNote?.(note.id)}>
                      {t('dismissNoteSuggestion')}
                    </button>
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
        {/* Attachment preview */}
        {attachments.length > 0 && (
          <AttachmentPreview
            attachments={attachments}
            onRemove={handleRemoveAttachment}
          />
        )}

        {/* Textarea — no border, blends into container */}
        <textarea
          ref={textareaRef}
          className={styles.textarea}
          rows={1}
          placeholder={isStreaming ? t('aiAnswering') : (placeholderOverride ?? t('placeholder'))}
          value={value}
          onChange={handleTextChange}
          onCompositionEnd={handleCompositionEnd}
          onKeyDown={handleKeyDown}
          onPaste={handlePaste}
          disabled={disabled || isStreaming}
          aria-label={t('placeholder')}
        />

        {modelControlsOpen && (
          <ModelOptionsPopover
            provider={generationParameterProvider}
            model={currentModel}
            conversationId={generationParameterConversationId}
            webControl={webControl}
            reasoningControl={reasoningControl}
            generationControl={generationControl}
            webPreference={webPreference}
            onWebPreferenceChange={onWebPreferenceChange}
            reasoningIntent={reasoningIntent}
            onReasoningIntentChange={onReasoningIntentChange}
            runtimeIsReadOnly={capabilityRuntimeReadOnly}
            runtimeReadOnlyReason={capabilityRuntimeReadOnlyReason}
            transportIdentity={capabilityTransportIdentity}
            webRuntimeRejected={webRuntimeRejected}
            reasoningRuntimeRejected={reasoningRuntimeRejected}
            alternativeModels={capabilityAlternativeModels}
            onSelectAlternativeModel={onSelectAlternativeModel}
            onOpenModelSwitcher={onOpenModelSwitcher}
            onOpenConnectionSettings={onOpenConnectionSettings}
            onFindModelsSupportingParameter={onFindModelsSupportingParameter}
            onOverrideChange={setHasModelBehaviorOverride}
            onClose={closeModelControls}
          />
        )}

        {/* Bottom row: tools left, send right */}
        <div className={styles.bottomRow}>
          <div className={styles.tools}>
              {supportsAttachment && (
                <>
                  <ComposerToolButton
                    icon={(
                      <AttachmentIcon />
                    )}
                    label={t('attachFile')}
                    ariaLabel={t('attachFile')}
                    count={hasAttachments ? attachments.length : undefined}
                    emphasized={hasAttachments}
                    onClick={() => fileInputRef.current?.click()}
                  />
                  <input
                    ref={fileInputRef}
                    type="file"
                    className={styles.hiddenInput}
                    accept={acceptTypes}
                    multiple
                    onChange={handleFileInput}
                  />
                </>
              )}

            {/* The entry point stays reachable; the panel explains why a control cannot be edited. */}
            <ComposerToolButton
              buttonRef={modelControlsTriggerRef}
              icon={<SlidersHorizontal size={16} />}
              label={tCommon('modelControls')}
              value={managedModelControls ? tCommon('managedByOriveo') : undefined}
              active={modelControlsOpen}
              emphasized={modelControlGlyphActive}
              capabilityIcons={modelControlCapabilityIcons}
              showEmphasisOrb={modelControlGlyphActive && modelControlCapabilityIcons.length === 0}
              ariaDescription={modelControlStateDescription}
              expandable
              ariaExpanded={modelControlsOpen}
              // Omitted while closed: `aria-controls` pointing at an id that does not exist is itself a defect.
              ariaControls={modelControlsOpen ? MODEL_OPTIONS_POPOVER_ID : undefined}
              onClick={() => (modelControlsOpen ? closeModelControlsWithFocus() : setModelControlsOpen(true))}
            />

              {/*
                 A single Library entry point. Research mode and "pick a document" are two
                 implementations of the same intent, differing only in who chooses the document;
                 two sibling buttons would look identical and behave differently. Both live in the panel. */}
              {showLibraryContextButton && (
                <ComposerToolButton
                  icon={<Library size={16} />}
                  label={tLibrary('title')}
                  count={libraryContextDocuments.length || undefined}
                  emphasized={
                    libraryContextDocuments.length > 0 || Boolean(libraryResearchEnabled)
                  }
                  active={Boolean(libraryResearchEnabled)}
                  onClick={() => onAddLibraryContext?.()}
                />
              )}
          </div>

          {isStreaming ? (
            <button
              type="button"
              className={styles.stopBtn}
              onClick={onStop}
              aria-label={t('stop')}
            >
              <StopIcon />
            </button>
          ) : (
            <button
              type="button"
              className={styles.sendBtn}
              onClick={requestSend}
              disabled={!value.trim() || disabled}
              aria-label={t('send')}
            >
              <SendIcon />
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

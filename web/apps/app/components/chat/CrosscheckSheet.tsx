'use client';

import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import { createPortal } from 'react-dom';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Check, ChevronDown, X } from 'lucide-react';
import type { AIModel, ChatMessage, Conversation, Provider, ProviderKind } from '@oriveo/shared';
import { Button } from '@oriveo/ui';
import { getVanillaStore, useAppStore } from '../../providers/StoreProvider';
import { crosscheckAnswer } from '../../lib/core/note-ai-ops';
import { createNoteFromCrosscheck } from '../../lib/core/note-ops';
import { getProviderInstanceDisplayName } from '../../lib/core/providers/provider-display';
import { showSavedNoteToast } from '../notes/note-toast';
import { ProviderIcon } from '../ProviderIcon';
import { VendorIdentity } from '../VendorIdentity';
import { MarkdownRenderer } from './MarkdownRenderer';
import { groupModelsByVendor } from './ModelSwitcher/model-vendor-groups';
import { getDefaultExpandedModelSwitcherProviderIds } from './model-switcher-sorting';
import styles from './CrosscheckSheet.module.css';

const SIDEBAR_WIDTH_KEY = 'oriveo:sidebarWidth';
const SIDEBAR_WIDTH_MIN = 220;
const SIDEBAR_WIDTH_MAX = 520;
const SIDEBAR_WIDTH_DEFAULT = 300;
const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'textarea:not([disabled])',
  'select:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(', ');

interface ModelOption {
  provider: Provider;
  model: AIModel;
}

interface ModelOptionVendorGroup {
  key: string;
  name: string;
  options: ModelOption[];
}

interface ModelOptionProviderGroup {
  provider: Provider;
  providerName: string;
  options: ModelOption[];
  vendorGroups: ModelOptionVendorGroup[];
}

interface CrosscheckSheetProps {
  open: boolean;
  conversation: Conversation;
  originMessage: ChatMessage;
  originalPrompt: string;
  originalAnswer: string;
  originProvider: Provider;
  originModel: AIModel;
  providers: Provider[];
  onClose: () => void;
}

interface CrosscheckExclusion {
  providerKind: ProviderKind;
  modelId: string;
}

function buildOptions(providers: Provider[], excluding?: CrosscheckExclusion): ModelOption[] {
  const eligibleProviders = providers.filter(
    (provider) => Boolean(provider.apiKey.trim()),
  );
  return eligibleProviders.flatMap((provider) =>
    provider.models
      .filter((model) => model.isAvailable !== false && model.capabilities.includes('text'))
      // Drop the original model entirely, matched on kind plus modelID
      .filter((model) => !(excluding && provider.kind === excluding.providerKind && model.id === excluding.modelId))
      .map((model) => ({ provider, model })),
  );
}

function optionKey(option: ModelOption): string {
  return `${option.provider.id}::${option.model.id}`;
}

function optionProviderName(option: ModelOption): string {
  return getProviderInstanceDisplayName(option.provider);
}

function groupModelOptions(options: ModelOption[]): ModelOptionProviderGroup[] {
  const order: string[] = [];
  const byProvider = new Map<string, ModelOptionProviderGroup>();
  for (const option of options) {
    let group = byProvider.get(option.provider.id);
    if (!group) {
      group = {
        provider: option.provider,
        providerName: optionProviderName(option),
        options: [],
        vendorGroups: [],
      };
      byProvider.set(option.provider.id, group);
      order.push(option.provider.id);
    }
    group.options.push(option);
  }

  return order.map((providerId) => {
    const group = byProvider.get(providerId)!;
    const optionByModelId = new Map(group.options.map((option) => [option.model.id, option]));
    return {
      ...group,
      vendorGroups: groupModelsByVendor(group.options.map((option) => option.model)).map((vendor) => ({
        key: vendor.key,
        name: vendor.name,
        options: vendor.models.map((model) => optionByModelId.get(model.id)!),
      })),
    };
  });
}

function vendorGroupStateKey(providerId: string, groupKey: string): string {
  return `${providerId}::${groupKey}`;
}

function readPersistedSidebarWidth(): number | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(SIDEBAR_WIDTH_KEY);
    if (!raw) return null;
    const parsed = Number.parseInt(raw, 10);
    if (!Number.isFinite(parsed)) return null;
    if (parsed < SIDEBAR_WIDTH_MIN || parsed > SIDEBAR_WIDTH_MAX) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function CrosscheckSheet({
  open,
  conversation,
  originMessage,
  originalPrompt,
  originalAnswer,
  originProvider,
  originModel,
  providers,
  onClose,
}: CrosscheckSheetProps) {
  const t = useTranslations('notes.crosscheck');
  const tChat = useTranslations('pages.chat');
  const router = useRouter();
  const options = useMemo(
    () => buildOptions(providers, { providerKind: originProvider.kind, modelId: originModel.id }),
    [providers, originProvider.kind, originModel.id],
  );
  // The original model is already excluded from the candidates, so selecting the first one is enough
  const [selectedKey, setSelectedKey] = useState(() => (options[0] ? optionKey(options[0]) : ''));
  const [resultText, setResultText] = useState('');
  const [errorMessage, setErrorMessage] = useState('');
  const [isRunning, setIsRunning] = useState(false);
  const [portalTarget, setPortalTarget] = useState<HTMLElement | null>(null);
  const [isModelMenuOpen, setIsModelMenuOpen] = useState(false);
  const [activeOptionIndex, setActiveOptionIndex] = useState(0);
  const [expandedProviderIds, setExpandedProviderIds] = useState<Set<string>>(() => new Set());
  const [expandedVendorGroupKeys, setExpandedVendorGroupKeys] = useState<Set<string>>(() => new Set());
  const triggerId = useId();
  const listboxId = useId();
  const modelLabelId = useId();
  const modelValueId = useId();
  const dialogRef = useRef<HTMLDivElement | null>(null);
  const sheetRef = useRef<HTMLElement | null>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  const modelMenuOpenRef = useRef(false);
  const modelPickerRef = useRef<HTMLDivElement | null>(null);
  const modelTriggerRef = useRef<HTMLButtonElement | null>(null);
  const modelListRef = useRef<HTMLDivElement | null>(null);
  const runAbortRef = useRef<AbortController | null>(null);
  const ignoreInitialMenuScrollRef = useRef(false);
  const sidebarOpen = useAppStore((s) => s.sidebarOpen);
  const appLanguage = useAppStore((s) => s.preferences.language);

  useEffect(() => {
    setPortalTarget(typeof document !== 'undefined' ? document.body : null);
    return () => runAbortRef.current?.abort();
  }, []);

  useEffect(() => {
    if (!open) runAbortRef.current?.abort();
  }, [open]);

  useEffect(() => {
    if (!open || typeof document === 'undefined') return;
    const width = sidebarOpen ? readPersistedSidebarWidth() ?? SIDEBAR_WIDTH_DEFAULT : 0;
    document.body.style.setProperty('--o-crosscheck-sidebar-width', `${width}px`);
    return () => {
      document.body.style.removeProperty('--o-crosscheck-sidebar-width');
    };
  }, [open, sidebarOpen]);

  useEffect(() => {
    if (!open || typeof document === 'undefined') return;

    previousFocusRef.current = document.activeElement as HTMLElement | null;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    const focusFrame = window.requestAnimationFrame(() => {
      const focusable = sheetRef.current?.querySelector<HTMLElement>(FOCUSABLE_SELECTOR);
      focusable?.focus({ preventScroll: true });
    });

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        if (modelMenuOpenRef.current) {
          setIsModelMenuOpen(false);
          modelTriggerRef.current?.focus({ preventScroll: true });
          event.preventDefault();
          return;
        }
        onClose();
        event.preventDefault();
        return;
      }

      if (event.key !== 'Tab') return;
      const focusables = Array.from(sheetRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR) ?? []);
      if (focusables.length === 0) return;

      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      if (!sheetRef.current?.contains(document.activeElement)) {
        event.preventDefault();
        first.focus();
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => {
      window.cancelAnimationFrame(focusFrame);
      document.removeEventListener('keydown', handleKeyDown);
      document.body.style.overflow = previousOverflow;
      if (previousFocusRef.current?.isConnected) {
        previousFocusRef.current.focus();
      }
    };
  }, [open, onClose]);

  useEffect(() => {
    modelMenuOpenRef.current = isModelMenuOpen;
  }, [isModelMenuOpen]);

  const selected = options.find((option) => optionKey(option) === selectedKey) ?? options[0];
  const selectedIndex = Math.max(0, options.findIndex((option) => optionKey(option) === (selected ? optionKey(selected) : selectedKey)));
  const activeOption = options[activeOptionIndex] ?? options[selectedIndex] ?? options[0];
  const activeOptionId = activeOption ? `${listboxId}-${optionKey(activeOption)}` : undefined;
  const optionGroups = useMemo(() => groupModelOptions(options), [options]);
  const optionIndexByKey = useMemo(
    () => new Map(options.map((option, index) => [optionKey(option), index])),
    [options],
  );

  useEffect(() => {
    if (!isModelMenuOpen) return;

    setActiveOptionIndex(selectedIndex);
    ignoreInitialMenuScrollRef.current = true;
    modelListRef.current?.focus({ preventScroll: true });
    const scrollGuardFrame = window.requestAnimationFrame(() => {
      ignoreInitialMenuScrollRef.current = false;
    });

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (modelPickerRef.current?.contains(target)) return;
      setIsModelMenuOpen(false);
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      setIsModelMenuOpen(false);
      modelTriggerRef.current?.focus({ preventScroll: true });
    };

    const handleClose = () => setIsModelMenuOpen(false);
    const handleScroll = (event: Event) => {
      if (ignoreInitialMenuScrollRef.current) return;
      const target = event.target;
      if (target instanceof Node && modelListRef.current?.contains(target)) return;
      setIsModelMenuOpen(false);
    };
    document.addEventListener('pointerdown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);
    window.addEventListener('resize', handleClose);
    document.addEventListener('scroll', handleScroll, true);
    return () => {
      window.cancelAnimationFrame(scrollGuardFrame);
      ignoreInitialMenuScrollRef.current = false;
      document.removeEventListener('pointerdown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
      window.removeEventListener('resize', handleClose);
      document.removeEventListener('scroll', handleScroll, true);
    };
  }, [isModelMenuOpen, selectedIndex]);

  if (!open || !portalTarget) return null;

  const revealModelOption = (option: ModelOption, replaceProvider = false) => {
    setExpandedProviderIds((current) => {
      if (!replaceProvider && current.has(option.provider.id)) return current;
      return replaceProvider ? new Set([option.provider.id]) : new Set([...current, option.provider.id]);
    });
    const providerGroup = optionGroups.find((group) => group.provider.id === option.provider.id);
    if (!providerGroup || providerGroup.vendorGroups.length <= 1) return;
    const vendor = providerGroup.vendorGroups.find((group) =>
      group.options.some((candidate) => optionKey(candidate) === optionKey(option)),
    );
    if (!vendor) return;
    const stateKey = vendorGroupStateKey(option.provider.id, vendor.key);
    setExpandedVendorGroupKeys((current) => (
      current.has(stateKey) ? current : new Set([...current, stateKey])
    ));
  };

  const openModelMenu = (initialIndex = selectedIndex) => {
    setActiveOptionIndex(initialIndex);
    const initialOption = options[initialIndex] ?? selected ?? options[0];
    setExpandedProviderIds(
      getDefaultExpandedModelSwitcherProviderIds(
        optionGroups.map((group) => group.provider),
        initialOption?.provider.id,
      ),
    );
    if (initialOption) revealModelOption(initialOption);
    setIsModelMenuOpen(true);
  };

  const activateModelOption = (index: number) => {
    const option = options[index];
    if (!option) return;
    setActiveOptionIndex(index);
    revealModelOption(option, true);
  };

  const handleSelectModel = (key: string) => {
    setSelectedKey(key);
    setErrorMessage('');
    setIsModelMenuOpen(false);
    modelTriggerRef.current?.focus({ preventScroll: true });
  };

  const handleModelTriggerKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      openModelMenu(selectedIndex);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      openModelMenu(options.length > 0 ? options.length - 1 : 0);
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      openModelMenu(selectedIndex);
    }
  };

  const handleModelTriggerClick = () => {
    if (isModelMenuOpen) {
      setIsModelMenuOpen(false);
      return;
    }
    openModelMenu(selectedIndex);
  };

  const handleModelListKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (options.length === 0) return;

    if (event.key === 'ArrowDown') {
      event.preventDefault();
      activateModelOption((activeOptionIndex + 1) % options.length);
      return;
    }

    if (event.key === 'ArrowUp') {
      event.preventDefault();
      activateModelOption((activeOptionIndex - 1 + options.length) % options.length);
      return;
    }

    if (event.key === 'Home') {
      event.preventDefault();
      activateModelOption(0);
      return;
    }

    if (event.key === 'End') {
      event.preventDefault();
      activateModelOption(options.length - 1);
      return;
    }

    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      const next = options[activeOptionIndex];
      if (next) handleSelectModel(optionKey(next));
      return;
    }

    if (event.key === 'Tab') {
      setIsModelMenuOpen(false);
    }
  };

  const handleRun = async () => {
    if (!selected || isRunning || runAbortRef.current) return;
    const abortController = new AbortController();
    runAbortRef.current = abortController;
    setResultText('');
    setErrorMessage('');
    setIsRunning(true);
    try {
      const result = await crosscheckAnswer({
        provider: selected.provider,
        model: selected.model,
        originalPrompt,
        originalAnswer,
        appLanguage,
        onChunk: (chunk) => setResultText((current) => `${current}${chunk}`),
        signal: abortController.signal,
      });
      setResultText(result.text);
    } catch (error) {
      if (!(error instanceof DOMException && error.name === 'AbortError')) {
        setErrorMessage(t('failed'));
      }
    } finally {
      if (runAbortRef.current === abortController) {
        runAbortRef.current = null;
      }
      setIsRunning(false);
    }
  };

  const handleSave = () => {
    if (!selected || !resultText.trim()) return;
    const note = createNoteFromCrosscheck(getVanillaStore(), {
      conversation,
      originMessage,
      originalPrompt,
      originalAnswer,
      originProvider,
      originModel,
      crosscheckProvider: selected.provider,
      crosscheckModel: selected.model,
      crosscheckText: resultText,
    });
    onClose();
    showSavedNoteToast({
      note,
      fallbackTitle: tChat('savedNoteUntitled'),
      viewLabel: tChat('viewNote'),
      onView: () => router.push(`/notes/${note.id}`),
    });
  };

  const renderModelOption = (option: ModelOption) => {
    const key = optionKey(option);
    const index = optionIndexByKey.get(key) ?? 0;
    const isSelected = key === (selected ? optionKey(selected) : selectedKey);
    const isActive = index === activeOptionIndex;
    return (
      <button
        key={key}
        id={`${listboxId}-${key}`}
        type="button"
        role="option"
        aria-selected={isSelected}
        className={styles.modelOption}
        tabIndex={-1}
        data-active={isActive || undefined}
        data-selected={isSelected || undefined}
        onMouseEnter={() => setActiveOptionIndex(index)}
        onClick={() => handleSelectModel(key)}
      >
        <span className={styles.modelOptionCopy}>
          <span className={styles.modelOptionName}>{option.model.name}</span>
        </span>
        <span className={styles.modelOptionCheck} aria-hidden="true">
          {isSelected ? <Check size={14} strokeWidth={2.8} /> : null}
        </span>
      </button>
    );
  };

  return createPortal(
    <div
      ref={dialogRef}
      className={styles.layer}
      role="dialog"
      aria-modal="true"
      aria-label={t('title')}
      data-menu-open={isModelMenuOpen || undefined}
      data-has-result={resultText.trim() ? 'true' : undefined}
    >
      <div className={styles.backdrop} onClick={onClose} aria-hidden="true" />
      <section className={styles.sheet} ref={sheetRef}>
        <header className={styles.header}>
          <div>
            <h2>{t('title')}</h2>
            <p>{t('subtitle')}</p>
          </div>
          <button type="button" className={styles.closeButton} onClick={onClose} aria-label={t('close')}>
            <X size={18} strokeWidth={2.3} aria-hidden="true" />
          </button>
        </header>

        <div className={styles.controls}>
          {options.length === 0 ? (
            <p className={styles.noCandidate}>{t('noCandidate')}</p>
          ) : (
            <div className={styles.modelField} data-disabled={isRunning || undefined}>
              <span id={modelLabelId}>{t('model')}</span>
              <div className={styles.modelPicker} ref={modelPickerRef}>
                <button
                  id={triggerId}
                  ref={modelTriggerRef}
                  type="button"
                  className={styles.modelTrigger}
                  aria-labelledby={`${modelLabelId} ${modelValueId}`}
                  aria-haspopup="listbox"
                  aria-expanded={isModelMenuOpen}
                  aria-controls={isModelMenuOpen ? listboxId : undefined}
                  onClick={handleModelTriggerClick}
                  onKeyDown={handleModelTriggerKeyDown}
                  disabled={isRunning}
                >
                  <span id={modelValueId} className={styles.modelTriggerCopy}>
                    <span className={styles.modelName}>{selected?.model.name ?? ''}</span>
                    <span className={styles.providerName}>{selected ? optionProviderName(selected) : ''}</span>
                  </span>
                  <span className={styles.modelChevron} aria-hidden="true">
                    <ChevronDown size={15} strokeWidth={2.4} />
                  </span>
                </button>
                {isModelMenuOpen ? (
                  <div
                    id={listboxId}
                    ref={modelListRef}
                    className={styles.modelMenu}
                    role="listbox"
                    aria-labelledby={triggerId}
                    aria-activedescendant={activeOptionId}
                    tabIndex={-1}
                    onKeyDown={handleModelListKeyDown}
                  >
                    {optionGroups.map((providerGroup) => {
                      const providerExpanded = expandedProviderIds.has(providerGroup.provider.id);
                      return (
                        <section
                          key={providerGroup.provider.id}
                          className={styles.modelProviderGroup}
                          data-expanded={providerExpanded || undefined}
                        >
                          <button
                            type="button"
                            className={styles.modelProviderHeader}
                            aria-expanded={providerExpanded}
                            tabIndex={-1}
                            onClick={() => {
                              setExpandedProviderIds((current) => (
                                current.has(providerGroup.provider.id)
                                  ? new Set()
                                  : new Set([providerGroup.provider.id])
                              ));
                            }}
                          >
                            <span className={styles.modelGroupLead}>
                              <ChevronDown
                                size={14}
                                className={styles.modelGroupChevron}
                                data-collapsed={!providerExpanded || undefined}
                              />
                              <ProviderIcon kind={providerGroup.provider.kind} size={22} bare />
                              <span>{providerGroup.providerName}</span>
                            </span>
                            <span className={styles.modelGroupCount}>{providerGroup.options.length}</span>
                          </button>

                          {providerExpanded ? (
                            <div className={styles.modelProviderBody}>
                              {providerGroup.vendorGroups.length > 1
                                ? providerGroup.vendorGroups.map((vendorGroup) => {
                                  const stateKey = vendorGroupStateKey(
                                    providerGroup.provider.id,
                                    vendorGroup.key,
                                  );
                                  const vendorExpanded = expandedVendorGroupKeys.has(stateKey);
                                  return (
                                    <div key={vendorGroup.key} className={styles.modelVendorGroup}>
                                      <button
                                        type="button"
                                        className={styles.modelVendorHeader}
                                        aria-expanded={vendorExpanded}
                                        tabIndex={-1}
                                        onClick={() => {
                                          setExpandedVendorGroupKeys((current) => {
                                            const next = new Set(current);
                                            if (next.has(stateKey)) next.delete(stateKey);
                                            else next.add(stateKey);
                                            return next;
                                          });
                                        }}
                                      >
                                        <span className={styles.modelGroupLead}>
                                          <ChevronDown
                                            size={13}
                                            className={styles.modelGroupChevron}
                                            data-collapsed={!vendorExpanded || undefined}
                                          />
                                          <VendorIdentity
                                            groupId={vendorGroup.key}
                                            title={vendorGroup.name}
                                            small
                                          />
                                          <span>{vendorGroup.name}</span>
                                        </span>
                                        <span className={styles.modelGroupCount}>{vendorGroup.options.length}</span>
                                      </button>
                                      {vendorExpanded ? (
                                        <div className={styles.modelVendorBody}>
                                          {vendorGroup.options.map(renderModelOption)}
                                        </div>
                                      ) : null}
                                    </div>
                                  );
                                })
                                : providerGroup.options.map(renderModelOption)}
                            </div>
                          ) : null}
                        </section>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            </div>
          )}
          <div className={styles.runButtonWrap}>
            <Button size="sm" onClick={handleRun} disabled={!selected || isRunning}>
              {isRunning ? t('running') : t('run')}
            </Button>
          </div>
        </div>

        <div className={styles.compareGrid}>
          <article>
            <h3>{t('original')}</h3>
            <div className={styles.answerContent}>
              <MarkdownRenderer content={originalAnswer} />
            </div>
          </article>
          <article>
            <h3>{t('secondOpinion')}</h3>
            <div className={`${styles.answerContent} ${styles.secondAnswerContent}`}>
              {resultText ? (
                <MarkdownRenderer content={resultText} isStreaming={isRunning} />
              ) : errorMessage ? (
                <p className={styles.emptyOpinion} role="alert">{errorMessage}</p>
              ) : (
                <p className={styles.emptyOpinion}>{t('empty')}</p>
              )}
            </div>
          </article>
        </div>

        <footer className={styles.footer}>
          <Button tone="secondary" onClick={onClose}>{t('close')}</Button>
          <Button onClick={handleSave} disabled={!resultText.trim() || isRunning}>{t('save')}</Button>
        </footer>
      </section>
    </div>,
    portalTarget,
  );
}

'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { CircleNotch, HardDrives, PencilSimple, SquaresFour } from '@phosphor-icons/react';
import type { Provider, RelayKind } from '@oriveo/shared';
import { relayKeySecrets } from '@oriveo/shared/relay/relay-keys';
import type { RelayFormIssue } from '@oriveo/core/providers/relay-form-validation';
import { Button } from '@oriveo/ui';
import { getVanillaStore, useAppStore } from '../../../../providers/StoreProvider';
import * as providerOps from '../../../../lib/core/provider-ops';
import { extractPingErrorMessage } from '../../../../lib/core/providers/ping-relay';
import { UNEXPECTED_ERROR_MESSAGE } from '../../../../lib/core/providers/error-i18n';
import { refreshRelayCatalogInStore } from '../../../../lib/core/providers/provider-sync';
import { relayFormIssueMessage } from '../../../../lib/core/providers/relay-form-messages';
import { setProviderDetailNotice } from '../../[providerId]/provider-detail-notice';
import { relayEditNextGroupChoice, relayRevealsFailureCard, type RelayEditDraft } from '../../[providerId]/relay-edit-board';
import { RelayEditGroupView } from '../../[providerId]/components/RelayEditConnection';
import { RelaySettingsFailureCard } from '../../[providerId]/components/RelaySettingsFailureCard';
import styles from './RelaySetup.module.css';
import {
  manualSetupBoard,
  manualSetupEffectiveRelayKind,
  manualSetupInputKey,
  manualSetupProvider,
  manualSetupUnverified,
  quickSetupButtonFit,
  relayFlagshipModelID,
  type ManualSetupDraft,
  type QuickSetupButtonFit,
  type ManualSetupPhase,
} from './manual-setup-board';
import { relayFilledKeyDrafts, type RelayKeyDraft } from './relay-setup-two-step';
import { verifyRelayManualSetup } from './relay-setup-two-step-run';
import { RelaySetupEndpointField, RelaySetupKeySlots } from './RelaySetupStepOne';

export interface RelayManualSetupProps {
  providerID: string;
  providers: readonly Provider[];
  entryPoint: string;
  endpoint: string;
  onEndpointChange: (value: string) => void;
  endpointNormalizationVersion: number;
  keys: RelayKeyDraft[];
  onKeyChange: (index: number, patch: Partial<Pick<RelayKeyDraft, 'apiKey' | 'name'>>) => void;
  onAddKey: () => void;
  onRemoveKey: (index: number) => void;
  showKey: boolean;
  onToggleKey: () => void;
  draft: ManualSetupDraft;
  onDraftChange: (patch: Partial<ManualSetupDraft>) => void;
  advancedChoice: boolean | undefined;
  onAdvancedChoice: (expanded: boolean) => void;
  /** `validateRelayForm(draft, 'create')` (the same form validation as quick setup). */
  issues: readonly RelayFormIssue[];
  normalizedEndpoint: string | null;
  /** Normalizes the address and writes it back to the input (counts as one submission); null when the address is invalid, and no request is sent. */
  normalizeForSubmit: (relayKind: RelayKind) => string | null;
  trackKeyValidated: (input: { success: boolean; errorCode?: string | null; endpoint: string; relayKind: RelayKind }) => void;
  onUseQuickSetup: () => void;
}

interface PhaseState {
  phase: ManualSetupPhase;
  /** Which input this state belongs to; if the input changed it counts as idle (editing input in flight resets the primary button immediately). */
  key: string;
}

interface Failure {
  error: unknown;
  endpoint: string;
}

/**
 * A persistence exception is handed to the failure card: the reason row is a localized generic sentence and the original exception text does not go on the reason row;
 * the exception name and original text become technical details and the address becomes the address row (the failure card renders text from detail / upstreamURL, through the same redaction list).
 * An error object that already carries a detail keeps its detail; its reason row likewise becomes the generic sentence, with the address added.
 */
function manualSetupPersistenceError(error: unknown, endpoint: string): unknown {
  if (error && typeof error === 'object' && typeof (error as { detail?: unknown }).detail === 'string') {
    return { upstreamURL: endpoint, ...(error as object), message: UNEXPECTED_ERROR_MESSAGE };
  }
  const raw = error instanceof Error ? error.message : String(error);
  const detail = error instanceof Error ? `${error.name}: ${error.message}` : raw;
  return { message: UNEXPECTED_ERROR_MESSAGE, detail, upstreamURL: endpoint };
}

/**
 * Manual setup (board ManualSetup): one page for address, key, model, connection name, protocol and auth / headers;
 * the primary button "Verify and Save" sends exactly 1 verification, a failure is not persisted, and the failure card's "Save anyway (unverified)" is the only unverified exit.
 */
/**
 * "Use quick setup" width tiering: available width = parent content width, the 100% one-line width = the width of the hidden ruler;
 * a change in either (window resize, font load, language change) re-evaluates. Environments without ResizeObserver stay at 100% one line.
 */
function useQuickSetupButtonFit() {
  const buttonRef = useRef<HTMLButtonElement>(null);
  const measureRef = useRef<HTMLSpanElement>(null);
  const [fit, setFit] = useState<QuickSetupButtonFit>('full');
  useEffect(() => {
    const button = buttonRef.current;
    const measure = measureRef.current;
    const container = button?.parentElement;
    if (!button || !measure || !container || typeof ResizeObserver === 'undefined') return;
    const update = () => {
      const style = getComputedStyle(container);
      const available = container.clientWidth
        - (Number.parseFloat(style.paddingLeft) || 0)
        - (Number.parseFloat(style.paddingRight) || 0);
      setFit(quickSetupButtonFit(available, measure.getBoundingClientRect().width));
    };
    const observer = new ResizeObserver(update);
    observer.observe(container);
    observer.observe(measure);
    update();
    return () => observer.disconnect();
  }, []);
  return { buttonRef, measureRef, fit };
}

export function RelayManualSetup(props: RelayManualSetupProps) {
  const tRoot = useTranslations();
  const quickSetupFit = useQuickSetupButtonFit();
  const te = useTranslations('errors');
  const router = useRouter();
  const setHasCompletedOnboarding = useAppStore((state) => state.setHasCompletedOnboarding);
  const setLastUsedModelRef = useAppStore((state) => state.setLastUsedModelRef);
  const { draft, keys } = props;

  const inputKey = manualSetupInputKey({
    normalizedEndpoint: props.normalizedEndpoint,
    endpoint: props.endpoint,
    keys,
    draft,
  });
  const [phaseState, setPhaseState] = useState<PhaseState>({ phase: { kind: 'idle' }, key: inputKey });
  const attemptRef = useRef(0);
  const abortRef = useRef<AbortController | null>(null);
  /** Click accepted (verification or persistence in flight): repeated clicks are accepted only once. */
  const acceptedRef = useRef(false);
  /** Completion latch: from persistence until leaving the page, neither the primary button nor "Save anyway" responds any more. */
  const doneRef = useRef(false);
  const failureRef = useRef<Failure | null>(null);
  const failureSeq = useRef(0);
  const previousKey = useRef(inputKey);
  const failureCardRef = useRef<HTMLDivElement>(null);
  const previousFailureID = useRef<number | null>(null);

  const phase: ManualSetupPhase = phaseState.key === inputKey || phaseState.phase.kind === 'saved'
    ? phaseState.phase
    : { kind: 'idle' };

  // Changing any input (except the name): invalidates the in-flight one, dismisses the failure card, resets the primary button; changing and changing back also invalidates (the attempt number has changed).
  useEffect(() => {
    if (previousKey.current === inputKey) return;
    previousKey.current = inputKey;
    if (doneRef.current) return;
    attemptRef.current += 1;
    abortRef.current?.abort();
    abortRef.current = null;
    acceptedRef.current = false;
    failureRef.current = null;
    setPhaseState({ phase: { kind: 'idle' }, key: inputKey });
  }, [inputKey]);

  // Leaving the page: the in-flight result is invalidated.
  useEffect(() => () => {
    attemptRef.current += 1;
    abortRef.current?.abort();
  }, []);

  const board = manualSetupBoard({
    endpoint: props.endpoint,
    keys,
    draft,
    issues: props.issues,
    normalizedEndpoint: props.normalizedEndpoint,
    flagshipModelID: relayFlagshipModelID(),
    phase,
    advancedChoice: props.advancedChoice,
  });

  // Failure card reveal: the same reveal function as Edit Connection (BOARD-EDIT-14 / BOARD-MANUAL-12).
  const failureID = board.failure?.failureID ?? null;
  useEffect(() => {
    const previous = previousFailureID.current;
    previousFailureID.current = failureID;
    if (!relayRevealsFailureCard(previous, failureID)) return;
    (document.activeElement as HTMLElement | null)?.blur?.();
    failureCardRef.current?.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' });
  }, [failureID]);

  const commit = useCallback(async (provider: Provider, attempt: number, key: string, unverifiedReason?: string) => {
    setPhaseState({ phase: { kind: 'saving' }, key });
    const store = getVanillaStore();
    const isCurrent = () => attempt === attemptRef.current && !doneRef.current;
    let committed: Awaited<ReturnType<typeof providerOps.addProvider>>;
    try {
      committed = await providerOps.addProvider(store, provider, { shouldCommit: isCurrent });
    } catch (error) {
      // A persistence throw must not spin forever: reset the acceptance latch and return to the failed state (the failure card reason row is the generic sentence and the original exception text goes into technical details;
      // this is not a verification failure, so "Save anyway" is not offered, BOARD-MANUAL-13).
      if (attempt !== attemptRef.current) return;
      acceptedRef.current = false;
      const endpoint = provider.baseURLText ?? '';
      failureRef.current = { error: manualSetupPersistenceError(error, endpoint), endpoint };
      failureSeq.current += 1;
      setPhaseState({ phase: { kind: 'failed', failureID: failureSeq.current, cause: 'persistence' }, key });
      return;
    }
    // The old providerOps implementation used to return void; only false is an explicit refusal to persist.
    if (committed === false || attempt !== attemptRef.current) {
      acceptedRef.current = false;
      if (attempt === attemptRef.current) setPhaseState({ phase: { kind: 'idle' }, key });
      return;
    }
    doneRef.current = true;
    setPhaseState({ phase: { kind: 'saved' }, key });
    const endpoint = provider.baseURLText ?? '';
    const relayKind = manualSetupEffectiveRelayKind(endpoint, draft.transport);
    if (unverifiedReason === undefined) {
      setLastUsedModelRef({ providerID: provider.id, modelID: provider.models[0]!.id });
      props.trackKeyValidated({ success: true, errorCode: null, endpoint, relayKind });
    } else {
      // An explicit unverified save reports one more entry, distinguishable on the board from the verification failure one.
      props.trackKeyValidated({ success: false, errorCode: 'unverified_connection', endpoint, relayKind });
    }
    setHasCompletedOnboarding(true);
    // The one-time notice appears only at the providers entry (the same one as quick setup).
    if (props.entryPoint === 'providers') {
      setProviderDetailNotice(provider.id, unverifiedReason === undefined
        ? { count: provider.models.length }
        : { unverifiedReason });
    }
    router.push(`/providers/${provider.id}`);
    // After verification passes, persist first, then refresh the catalog without blocking; a failure is not rolled back (the detail page conveys the catalog failure state).
    if (unverifiedReason === undefined) {
      void (async () => {
        const saved = store.getState().providers.find((item) => item.id === provider.id) ?? provider;
        await refreshRelayCatalogInStore(store, saved);
      })().catch(() => undefined);
    }
  }, [draft.transport, props, router, setHasCompletedOnboarding, setLastUsedModelRef]);

  const buildProvider = (endpoint: string): Provider => manualSetupProvider({
    id: props.providerID,
    endpoint,
    keys: relayFilledKeyDrafts(keys),
    draft,
    providers: props.providers,
    now: new Date().toISOString(),
  });

  const onPrimary = async () => {
    // Click acceptance uses the same criterion as the button being tappable (BOARD-MANUAL-11).
    if (doneRef.current || acceptedRef.current || !board.primary.enabled) return;
    const relayKind = manualSetupEffectiveRelayKind(props.normalizedEndpoint ?? props.endpoint, draft.transport);
    const endpoint = props.normalizeForSubmit(relayKind);
    if (!endpoint) return;
    acceptedRef.current = true;
    attemptRef.current += 1;
    const attempt = attemptRef.current;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    const key = inputKey;
    failureRef.current = null;
    setPhaseState({ phase: { kind: 'validating' }, key });
    const provider = buildProvider(endpoint);
    let outcome: Awaited<ReturnType<typeof verifyRelayManualSetup>>;
    try {
      outcome = await verifyRelayManualSetup({ provider, modelID: draft.model.trim(), signal: controller.signal });
    } catch {
      // Only an invalidated one (input edited / page left) reaches here: finish silently.
      return;
    }
    if (attempt !== attemptRef.current || controller.signal.aborted) return;
    abortRef.current = null;
    if (!outcome.ok) {
      acceptedRef.current = false;
      failureRef.current = { error: outcome.error, endpoint };
      props.trackKeyValidated({ success: false, errorCode: outcome.errorCode, endpoint, relayKind });
      failureSeq.current += 1;
      setPhaseState({ phase: { kind: 'failed', failureID: failureSeq.current }, key });
      return;
    }
    await commit(outcome.provider, attempt, key);
  };

  const onSaveAnyway = async () => {
    const failure = failureRef.current;
    if (doneRef.current || acceptedRef.current || phase.kind !== 'failed' || phase.cause === 'persistence' || !failure) return;
    acceptedRef.current = true;
    const reason = extractPingErrorMessage(failure.error, te);
    // No more requests; the name is the one at this moment (changing the name does not invalidate the failure card).
    await commit(manualSetupUnverified(buildProvider(failure.endpoint)), attemptRef.current, inputKey, reason);
  };

  const locked = phase.kind === 'saving' || phase.kind === 'saved';
  const editDraft: RelayEditDraft = {
    endpoint: '',
    transport: draft.transport,
    authMode: draft.authMode,
    customUserAgent: draft.customUserAgent,
    headers: draft.headers,
    queryParams: draft.queryParams,
    stream: true,
    serviceTier: '',
    disableResponseStorage: false,
  };
  const onEditDraftChange = (patch: Partial<RelayEditDraft>) => {
    const next: Partial<ManualSetupDraft> = {};
    if (patch.transport !== undefined) next.transport = patch.transport;
    if (patch.authMode !== undefined) next.authMode = patch.authMode;
    if (patch.customUserAgent !== undefined) next.customUserAgent = patch.customUserAgent;
    if (patch.headers !== undefined) next.headers = patch.headers;
    if (patch.queryParams !== undefined) next.queryParams = patch.queryParams;
    props.onDraftChange(next);
  };
  const issueMessage = (issue: RelayFormIssue) => relayFormIssueMessage(issue, tRoot);
  const failure = failureRef.current;
  const primaryKey = keys[0]?.apiKey.trim() ?? ''; // key-choke: not-provider

  const section = (id: (typeof board.sections)[number]) => {
    switch (id) {
      case 'requestURL':
        return (
          <div key={id} data-manual-section={id}>
            <RelaySetupEndpointField
              endpoint={props.endpoint}
              onEndpointChange={props.onEndpointChange}
              endpointNormalizationVersion={props.endpointNormalizationVersion}
            />
          </div>
        );
      case 'apiKeys':
        return (
          <div key={id} data-manual-section={id}>
            <RelaySetupKeySlots
              keys={keys}
              onKeyChange={props.onKeyChange}
              onAddKey={props.onAddKey}
              onRemoveKey={props.onRemoveKey}
              showKey={props.showKey}
              onToggleKey={props.onToggleKey}
              issues={board.apiKeys.issues.map(issueMessage)}
            />
          </div>
        );
      case 'model':
        return (
          <div key={id} className={styles.field} data-manual-section={id}>
            <label htmlFor="relay-manual-model"><SquaresFour size={16} aria-hidden="true" data-field-icon={board.model.icon} />{tRoot(board.model.titleKey)}</label>
            <div className={styles.inputShell}>
              <input
                id="relay-manual-model"
                className={styles.shellInput}
                value={draft.model}
                placeholder={board.model.placeholder}
                onChange={(event) => props.onDraftChange({ model: event.target.value })}
                autoComplete="off"
                spellCheck={false}
                dir="ltr"
                disabled={locked}
              />
            </div>
            <small>{tRoot(board.model.footnoteKey)}</small>
          </div>
        );
      case 'connectionName':
        return (
          <div key={id} className={styles.field} data-manual-section={id}>
            <label htmlFor="relay-manual-name"><PencilSimple size={16} aria-hidden="true" data-field-icon={board.connectionName.icon} />{tRoot(board.connectionName.titleKey)}</label>
            <div className={styles.inputShell}>
              <span className={styles.slotTag} aria-hidden="true">{tRoot(board.connectionName.slotLabelKey)}</span>
              <input
                id="relay-manual-name"
                className={`${styles.shellInput} ${styles.slotInputEnd}`}
                value={draft.name}
                placeholder={board.connectionName.placeholder}
                onChange={(event) => props.onDraftChange({ name: event.target.value })}
                autoComplete="off"
                disabled={locked}
              />
            </div>
            <small>{tRoot(board.connectionName.footnoteKey)}</small>
          </div>
        );
      case 'protocol':
      case 'advanced':
        return (
          <div key={id} data-manual-section={id}>
            <RelayEditGroupView
              group={id === 'protocol' ? board.protocolGroup : board.advancedGroup}
              draft={editDraft}
              locked={locked}
              issueMessage={issueMessage}
              onDraftChange={onEditDraftChange}
              onToggleGroup={(group) => props.onAdvancedChoice(relayEditNextGroupChoice(group))}
            />
          </div>
        );
      case 'failure':
        return failure && board.failure ? (
          <div key={id} ref={failureCardRef} data-manual-section={id} data-testid="relay-manual-failure">
            <RelaySettingsFailureCard
              error={failure.error}
              canSaveUnverified={board.failure.saveUnverifiedKey !== null}
              localError={phase.kind === 'failed' && phase.cause === 'persistence'}
              apiKey={primaryKey}
              connectionKeySecrets={relayKeySecrets(buildProvider(failure.endpoint))}
              relayRequested={buildProvider(failure.endpoint).relayRequested!}
              showRetry={false}
              notSavedNote={tRoot(board.failure.noteKey)}
              onRetry={() => undefined}
              onSaveUnverified={() => { void onSaveAnyway(); }}
            />
          </div>
        ) : null;
    }
  };

  return (
    <div className={styles.form} data-testid="relay-manual-setup">
      <button
        type="button"
        ref={quickSetupFit.buttonRef}
        className={styles.quickSetupButton}
        data-fit={quickSetupFit.fit}
        onClick={props.onUseQuickSetup}
      >
        {tRoot(board.leadingAction.titleKey)}
        {/* Width of one line at 100% font size: inside a zero-size clip box, taking no layout space and causing no horizontal scrollbar */}
        <span className={styles.quickSetupMeasureBox} aria-hidden="true">
          <span ref={quickSetupFit.measureRef} className={styles.quickSetupMeasure}>
            {tRoot(board.leadingAction.titleKey)}
          </span>
        </span>
      </button>
      <header className={styles.hero}>
        <p className={styles.heroLabel}>
          <HardDrives size={34} weight="duotone" aria-hidden="true" />
          <span>{tRoot(board.hero.labelKey)}</span>
          <span className={styles.heroTrailing}>{tRoot(board.hero.trailingKey)}</span>
        </p>
        <h1>{tRoot(board.hero.titleKey)}</h1>
        <p>{tRoot(board.hero.subtitleKey)}</p>
      </header>

      {board.sections.map(section)}

      {/* Local network / CORS proxy note: a full-width footnote at the end of the form. */}
      <small className={styles.formFootnote}>{tRoot('pages.relaySetup.apiKeyPrivacy')}</small>

      <div className={styles.actionBar}>
        <Button
          className={styles.primaryAction}
          onClick={() => { void onPrimary(); }}
          disabled={!board.primary.enabled}
          data-testid="relay_manual_setup_primary_button"
        >
          {board.primary.spinning ? <CircleNotch className={styles.spinner} size={18} data-spinner aria-hidden="true" /> : null}
          <span>{tRoot(board.primary.titleKey)}</span>
        </Button>
      </div>
    </div>
  );
}

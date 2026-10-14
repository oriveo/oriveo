'use client';

import { useCallback, useMemo, useRef, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { HardDrives, Plug } from '@phosphor-icons/react';
import { setProviderDetailNotice } from '../../[providerId]/provider-detail-notice';
import type { AIModel, RelayKind } from '@oriveo/shared';
import { useAppStore, getVanillaStore } from '../../../../providers/StoreProvider';
import * as providerOps from '../../../../lib/core/provider-ops';
import {
  providerKeyValidatedProperties,
  ProviderSetupSurface,
  trackEvent,
} from '../../../../lib/core/telemetry';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import { rememberRelayCatalogEndpointTypes } from '../../../../lib/core/providers/relay-probe-candidates';
import {
  displayableRelayFormIssues,
  relayFormNormalizedEndpoint,
  validateRelayForm,
  type RelayFormDraft,
  type RelayFormIssue,
} from '@oriveo/core/providers/relay-form-validation';
import { relaySensitiveCredentialValues } from '@oriveo/core/providers/relay-runtime-support';
import type { RelayRequestedConfig } from '@oriveo/shared';
import { extractErrorSnippet } from '@oriveo/core/util/error-snippet';
import { BackButton } from '@oriveo/ui';
import { relayFormFieldMessage } from '../../../../lib/core/providers/relay-form-messages';
import { relayDomainNameFromEndpoint } from '../../../../lib/core/providers/provider-display';
import { createCanonicalUUID } from '../../../../lib/utils/id-utils';
import { consumeRelayHandoff } from '../../new/relay-handoff';
import { RelaySetupStepOne } from './RelaySetupStepOne';
import { RelaySetupStepTwo } from './RelaySetupStepTwo';
import { RelayManualSetup } from './RelayManualSetup';
import styles from './RelaySetup.module.css';
import {
  useCustomLLMConnectionCoordinator,
  type CustomLLMConnectionCoordinator,
  type CustomLLMConnectionResult,
  type CustomLLMScenario,
} from './custom-llm-connection-coordinator';
import { LocalComputeSetup } from './LocalComputeSetup';
import { LOCAL_SETUP_HERO_KEYS, RELAY_SETUP_HERO_KEYS } from './setup-board';
import { initialManualSetupDraft, manualSetupRequested, type ManualSetupDraft } from './manual-setup-board';
import {
  RELAY_SECURITY_MODE,
  initialRelayKeyDrafts,
  relayAddBaseProvider,
  relayFilledKeyDrafts,
  relayKindForTransport,
  relayModelProtocol,
  relayQuickFormRequested,
  relayStepOneAutoAdvances,
  relayStepOnePrimary,
  relayStepTwoAddManual,
  relayStepTwoCatalog,
  relayStepTwoGroupExpanded,
  relayStepTwoGroups,
  relayStepTwoKeyChips,
  relayStepTwoOrderedSelection,
  relayStepTwoSelectGroup,
  withRelayKeyDrafts,
  type RelayKeyDraft,
  type RelayStepOneDetection,
} from './relay-setup-two-step';
import { runRelayStepOne, saveRelayTwoStep } from './relay-setup-two-step-run';

/** Quick connect has no user-picked protocol: analytics reports it as OpenAI compatible (as before). */
const QUICK_RELAY_KIND: RelayKind = 'openai_compatible';

type RelayCloudMode = 'quick' | 'models' | 'manual';

export function RelaySetup() {
  // Both entry points share the underlying connection coordinator, but the entry point has
  // already made the scenario choice, so the page does not ask the user to decide again.
  const searchParams = useSearchParams();
  const scenario: CustomLLMScenario = searchParams.get('mode') === 'local'
    ? 'local'
    : 'relay';
  const connection = useCustomLLMConnectionCoordinator();
  const t = useTranslations('pages.relaySetup');
  const tc = useTranslations('common');
  const router = useRouter();
  // Relay step 2 (the SetupModels board) has no Hero; its back button sits in its own title row. Manual setup draws its own header and Hero from the board.
  const [cloudMode, setCloudMode] = useState<RelayCloudMode>('quick');
  // The topBar keeps only the back button; the page title lives only in the Hero.
  const [labelKey, titleKey, subtitleKey] = scenario === 'local' ? LOCAL_SETUP_HERO_KEYS : RELAY_SETUP_HERO_KEYS;
  const HeroIcon = scenario === 'local' ? Plug : HardDrives;
  const showsHero = scenario === 'local' || cloudMode === 'quick';
  return (
    <main className={styles.page} data-scenario={scenario}>
      {showsHero ? (
        <>
          <BackButton className={styles.backButton} label={tc('back')} onClick={() => router.back()} />
          <header className={styles.hero}>
            <p className={styles.heroLabel}>
              <HeroIcon size={34} weight="duotone" aria-hidden="true" />
              <span>{t(labelKey)}</span>
            </p>
            <h1>{t(titleKey)}</h1>
            <p>{t(subtitleKey)}</p>
          </header>
        </>
      ) : null}
      {scenario === 'local'
        ? <LocalComputeSetup connection={connection} />
        : <RelayCloudSetup connection={connection} onModeChange={setCloudMode} />}
    </main>
  );
}

function RelayCloudSetup({ connection, onModeChange }: {
  connection: CustomLLMConnectionCoordinator;
  onModeChange: (mode: RelayCloudMode) => void;
}) {
  const router = useRouter();
  /** Form issue message keys are full keys including the namespace (both flows share one mapping), so resolve them with the root translator. */
  const tRoot = useTranslations();
  const providers = useAppStore((state) => state.providers ?? []);
  const setHasCompletedOnboarding = useAppStore((state) => state.setHasCompletedOnboarding);
  const setLastUsedModelRef = useAppStore((state) => state.setLastUsedModelRef);
  const [handoff] = useState(() => consumeRelayHandoff());
  const entryPoint = handoff?.entryPoint ?? (providers.length === 0 ? 'onboarding' : 'direct_link');
  /**
   * Submission analytics context. The relay path used to emit no `provider_key_validated`
   * at all, so "entered a relay address, pressed the button, could not connect" - the number
   * one relay failure - did not exist in analytics.
   * `wasFirstProvider` is snapshotted the moment the button is pressed, since providers is
   * no longer empty once the save succeeds.
   */
  const submitTelemetryRef = useRef({ attempts: 0, wasFirstProvider: providers.length === 0 });

  const trackKeyValidated = useCallback((input: {
    success: boolean;
    errorCode?: string | null;
    endpoint: string | null | undefined;
    relayKind: RelayKind;
  }) => {
    trackEvent('provider_key_validated', providerKeyValidatedProperties({
      providerKind: 'relay',
      success: input.success,
      errorCode: input.errorCode,
      endpoint: input.endpoint,
      relayKind: input.relayKind,
      entryPoint,
      isFirstProvider: submitTelemetryRef.current.wasFirstProvider,
      connectionAttempts: submitTelemetryRef.current.attempts,
      setupSurface: ProviderSetupSurface.relaySetup,
    }));
  }, [entryPoint]);

  // The id of the connection this page will create: step 1 per-key catalog and step 2 save use the same one.
  const [providerID] = useState(() => createCanonicalUUID());
  // The address and all keys (including names) are shared between quick connect and manual setup.
  const [endpoint, setEndpoint] = useState('');
  const [keys, setKeys] = useState<RelayKeyDraft[]>(initialRelayKeyDrafts);
  const apiKey = keys[0]!.apiKey; // key-choke: not-provider
  const [manualMode, setManualMode] = useState(false);
  // Inputs owned by the manual page: they are still there when the user re-enters.
  const [manualDraft, setManualDraft] = useState<ManualSetupDraft>(initialManualSetupDraft);
  const [manualAdvancedChoice, setManualAdvancedChoice] = useState<boolean | undefined>(undefined);
  const [endpointNormalizationVersion, setEndpointNormalizationVersion] = useState(0);
  const [showKey, setShowKey] = useState(false);

  // Two-step state: the detection card appears on the first Next press and disappears when the address or any key changes, detection is cancelled, or manual setup is entered.
  const [step, setStep] = useState<1 | 2>(1);
  const [detection, setDetection] = useState<RelayStepOneDetection | null>(null);
  const detectionGenerationRef = useRef(0);
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<ReadonlySet<string>>(() => new Set());
  const [manualIDs, setManualIDs] = useState<string[]>([]);
  const [userExpanded, setUserExpanded] = useState<Record<string, boolean>>({});
  const [addManualHint, setAddManualHint] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveFailure, setSaveFailure] = useState<RelayDiscoveryResult | null>(null);

  const goToStep = useCallback((next: 1 | 2) => {
    setStep(next);
    onModeChange(next === 2 ? 'models' : 'quick');
  }, [onModeChange]);

  const resetModelsStep = useCallback(() => {
    setQuery('');
    setSelected(new Set());
    setManualIDs([]);
    setUserExpanded({});
    setAddManualHint(false);
    setSaveFailure(null);
  }, []);

  const invalidateDiscovery = useCallback(() => {
    detectionGenerationRef.current += 1;
    connection.invalidate();
    setDetection(null);
  }, [connection]);

  const changeEndpoint = useCallback((value: string) => {
    setEndpoint(value);
    invalidateDiscovery();
  }, [invalidateDiscovery]);

  /** The protocol configuration currently in effect for the form: manual setup uses the protocol / auth / headers the user picked, quick connect uses the OpenAI-compatible preset (only its auth and headers). */
  const formRequested: RelayRequestedConfig = useMemo(
    () => (manualMode ? manualSetupRequested(manualDraft) : relayQuickFormRequested()),
    [manualDraft, manualMode],
  );

  /**
   * The add and edit pages share one form definition and one pure validation function. This
   * page no longer decides on its own whether an address is valid or a key is required -
   * that check may exist in exactly one place, or the same rule drifts separately in each flow.
   */
  const draft: RelayFormDraft = useMemo(() => ({
    endpoint,
    apiKey,
    authMode: formRequested.authMode,
    securityMode: RELAY_SECURITY_MODE,
    transport: formRequested.transport,
    modelID: manualMode ? manualDraft.model : '',
    // Raw rows (including rows with an empty name): validation uses the same rules as the edit-connection page.
    headers: manualMode ? manualDraft.headers : formRequested.headers ?? [],
    queryParams: manualMode ? manualDraft.queryParams : formRequested.queryParams ?? [],
    // The add flow has no key store, only the key the user is typing right now.
    hasSavedCredential: false,
  }), [apiKey, endpoint, formRequested, manualDraft, manualMode]);

  const issues: RelayFormIssue[] = useMemo(() => validateRelayForm(draft, 'create'), [draft]);
  // Empty extra-key rows are ignored during detection and saving and do not block Next.
  const filledKeys = useMemo(() => relayFilledKeyDrafts(keys), [keys]);

    // Required-field issues only keep the primary button disabled rather than flashing red text; everything else must produce a plain-language message.
  const errors = useMemo(() => ({
    endpoint: relayFormFieldMessage(displayableRelayFormIssues(issues), 'endpoint', tRoot),
    apiKey: relayFormFieldMessage(displayableRelayFormIssues(issues), 'api_key', tRoot),
  }), [issues, tRoot]);

  const validate = useCallback(() => issues.length === 0, [issues]);
  const normalizedEndpoint = useMemo(() => relayFormNormalizedEndpoint(draft, 'create'), [draft]);

  /** Unified address normalization: shares one classification with form validation, and the normalized address is filled back and selected. */
  const normalizeEndpointForSubmit = useCallback((relayKind: RelayKind): string | null => {
    submitTelemetryRef.current.attempts += 1;
    submitTelemetryRef.current.wasFirstProvider = providers.length === 0;
    if (!normalizedEndpoint) {
    // An invalid address is the number one relay failure and exactly the submission that analytics should capture.
      trackKeyValidated({
        success: false,
        errorCode: 'invalid_endpoint',
        endpoint,
        relayKind,
      });
      return null;
    }
    if (normalizedEndpoint !== endpoint.trim()) {
      setEndpoint(normalizedEndpoint);
      setEndpointNormalizationVersion((version) => version + 1);
    }
    return normalizedEndpoint;
  }, [endpoint, normalizedEndpoint, providers, trackKeyValidated]);

  const failureFor = useCallback((error: unknown): RelayDiscoveryResult => ({
    state: 'failed',
    attempts: [],
    failure: 'network',
    diagnostic: relayFailureDiagnostic(error, apiKey, formRequested.headers, formRequested.queryParams),
    retriedRequestCount: 0,
  }), [apiKey, formRequested.headers, formRequested.queryParams]);

  // MARK: - Quick path: two steps

  const runStepOne = useCallback(async () => {
    if (!validate()) return;
    const submitEndpoint = normalizeEndpointForSubmit(QUICK_RELAY_KIND);
    if (!submitEndpoint) return;
    detectionGenerationRef.current += 1;
    const generation = detectionGenerationRef.current;
    let latest: RelayStepOneDetection | null = null;
    resetModelsStep();
    const completed = await connection.run('relay', (signal) => runRelayStepOne({
      providerID,
      endpoint: submitEndpoint,
      keys: filledKeys,
      providers,
      signal,
      failureFor,
      onUpdate: (next) => {
        if (signal.aborted || generation !== detectionGenerationRef.current) return;
        latest = next;
        setDetection(next);
      },
    }), (next) => ({
      verification: false,
      catalog: Boolean(next.detection?.catalogEvidenceSucceeded),
      // Step 1 does not verify: even on failure the user can go to step 2 and add manually, and the verification at save time decides whether it can be persisted.
      canCommit: true,
    }), failureFor);
    if (!completed || generation !== detectionGenerationRef.current) return;
    if (completed.value.state === 'failed') {
      trackKeyValidated({
        success: false,
        errorCode: completed.value.failure ?? 'unknown',
        endpoint: submitEndpoint,
        relayKind: QUICK_RELAY_KIND,
      });
    }
    if (relayStepOneAutoAdvances(latest)) goToStep(2);
  }, [connection, failureFor, filledKeys, goToStep, normalizeEndpointForSubmit, providerID, providers, resetModelsStep, trackKeyValidated, validate]);

  const stepOnePrimary = relayStepOnePrimary({
    detection,
    isDetecting: connection.phase === 'detecting',
    canSubmit: issues.length === 0,
  });

  const quickEndpoint = normalizedEndpoint ?? endpoint.trim();
  const host = relayDomainNameFromEndpoint(quickEndpoint) ?? quickEndpoint;
  const stepTwoCatalog = useMemo(
    () => relayStepTwoCatalog(detection?.catalogModels ?? [], manualIDs),
    [detection, manualIDs],
  );
  const otherGroupTitle = tRoot('pages.relayDetail.catalogGroupOther');
  const fullGroups = useMemo(
    () => relayStepTwoGroups({ catalogModels: stepTwoCatalog, host, query: '', otherTitle: otherGroupTitle }),
    [host, otherGroupTitle, stepTwoCatalog],
  );
  const visibleGroups = useMemo(
    () => (query.trim()
      ? relayStepTwoGroups({ catalogModels: stepTwoCatalog, host, query, otherTitle: otherGroupTitle })
      : fullGroups),
    [fullGroups, host, otherGroupTitle, query, stepTwoCatalog],
  );
  const orderedSelection = useMemo((): AIModel[] => {
    const byID = new Map(stepTwoCatalog.map((model) => [model.id, model]));
    return relayStepTwoOrderedSelection(fullGroups, selected).flatMap((id) => {
      const model = byID.get(id);
      return model ? [model] : [];
    });
  }, [fullGroups, selected, stepTwoCatalog]);
  const keyChips = useMemo(() => {
    if (filledKeys.length < 2) return {};
    const keyed = withRelayKeyDrafts(relayAddBaseProvider({
      id: providerID,
      endpoint: quickEndpoint,
      apiKey: apiKey.trim(),
      detection: detection?.discovery?.detection,
      providers,
      now: '',
    }), filledKeys);
    return relayStepTwoKeyChips({ ...keyed, catalogModels: stepTwoCatalog }, orderedSelection);
  }, [apiKey, detection, filledKeys, orderedSelection, providerID, providers, quickEndpoint, stepTwoCatalog]);

  const saveTwoStep = useCallback(async () => {
    const committedResult = connection.result?.scenario === 'relay'
      ? connection.result as CustomLLMConnectionResult<RelayDiscoveryResult>
      : null;
    if (!connection.canCommit(committedResult) || orderedSelection.length === 0) return;
    setSaving(true);
    setSaveFailure(null);
    const signal = connection.commitSignal();
    let outcome: Awaited<ReturnType<typeof saveRelayTwoStep>>;
    try {
      outcome = await saveRelayTwoStep({
        providerID,
        endpoint: quickEndpoint,
        keys: filledKeys,
        detection,
        catalogModels: stepTwoCatalog,
        selected: orderedSelection,
        providers,
        signal,
      });
    } catch (error) {
      setSaving(false);
      // Abort the in-flight 1-token check when leaving the page or when the input is invalidated: finish silently and do not persist.
      if (signal.aborted) return;
      throw error;
    }
    if (signal.aborted || !connection.canCommit(committedResult)) {
      setSaving(false);
      return;
    }
    const detectedKind = detection?.discovery?.detection
      ? relayKindForTransport(detection.discovery.detection.transport)
      : 'openai_compatible';
    if (!outcome.ok) {
      // A failed verification stays on step 2 with a failure card and is not persisted.
      setSaveFailure(outcome.result);
      setSaving(false);
      trackKeyValidated({
        success: false,
        errorCode: outcome.result.failure ?? 'unknown',
        endpoint: quickEndpoint,
        relayKind: detectedKind,
      });
      return;
    }
    const { provider, firstModelID } = outcome;
    const committed = await providerOps.addProvider(getVanillaStore(), provider, {
      shouldCommit: () => connection.canCommit(committedResult),
    });
    // The older providerOps implementation returned void; only false is an explicit refusal to persist, so a compatibility return value must not be read as failure.
    if (committed === false || !connection.canCommit(committedResult)) {
      setSaving(false);
      return;
    }
    rememberRelayCatalogEndpointTypes(provider.id, detection?.endpointTypes);
    // After setup completes, select the model that was just verified.
    setLastUsedModelRef({ providerID: provider.id, modelID: firstModelID });
    trackKeyValidated({ success: true, errorCode: null, endpoint: quickEndpoint, relayKind: detectedKind });
    setHasCompletedOnboarding(true);
    // Show the one-time notice only from the providers entry; other entries keep the existing completion path. The notice reports the number actually enabled.
    if (entryPoint === 'providers') setProviderDetailNotice(provider.id, { count: provider.models.length });
    router.push(`/providers/${provider.id}`);
  }, [connection, detection, entryPoint, filledKeys, orderedSelection, providerID, providers, quickEndpoint, router, setHasCompletedOnboarding, setLastUsedModelRef, stepTwoCatalog, trackKeyValidated]);


  // MARK: - Manual setup (one page, sharing the address and all keys with step 1)

  const toggleManual = useCallback(() => {
    // Entering the manual page while quick-connect detection is in flight cancels the detection; coming back stays on step 1.
    invalidateDiscovery();
    resetModelsStep();
    setStep(1);
    setManualMode(!manualMode);
    onModeChange(manualMode ? 'quick' : 'manual');
  }, [invalidateDiscovery, manualMode, onModeChange, resetModelsStep]);

  const changeKey = useCallback((index: number, patch: Partial<Pick<RelayKeyDraft, 'apiKey' | 'name'>>) => {
    setKeys((previous) => previous.map((key, position) => (position === index ? { ...key, ...patch } : key)));
    // Changing only the name does not invalidate the current detection.
    if ('apiKey' in patch) invalidateDiscovery();
  }, [invalidateDiscovery]);
  const addKey = useCallback(() => setKeys((previous) => [...previous, { id: newRelayKeyID(), apiKey: '', name: '' }]), []);
  const removeKey = useCallback((index: number) => {
    if (index === 0) return;
    setKeys((previous) => previous.filter((_, position) => position !== index));
    invalidateDiscovery();
  }, [invalidateDiscovery]);

  if (manualMode) {
    return (
      <RelayManualSetup
        providerID={providerID}
        providers={providers}
        entryPoint={entryPoint}
        endpoint={endpoint}
        onEndpointChange={changeEndpoint}
        endpointNormalizationVersion={endpointNormalizationVersion}
        keys={keys}
        onKeyChange={changeKey}
        onAddKey={addKey}
        onRemoveKey={removeKey}
        showKey={showKey}
        onToggleKey={() => setShowKey((visible) => !visible)}
        draft={manualDraft}
        onDraftChange={(patch) => setManualDraft((previous) => ({ ...previous, ...patch }))}
        advancedChoice={manualAdvancedChoice}
        onAdvancedChoice={setManualAdvancedChoice}
        issues={issues}
        normalizedEndpoint={normalizedEndpoint}
        normalizeForSubmit={normalizeEndpointForSubmit}
        trackKeyValidated={trackKeyValidated}
        onUseQuickSetup={toggleManual}
      />
    );
  }

  if (step === 2) {
    return (
      <RelaySetupStepTwo
        host={host}
        keyCount={filledKeys.length}
        totalCount={stepTwoCatalog.length}
        query={query}
        onQueryChange={setQuery}
        groups={visibleGroups}
        fullGroups={fullGroups}
        selected={selected}
        isExpanded={(group) => relayStepTwoGroupExpanded({ group, selected, query, userExpanded })}
        onToggleGroup={(group, expanded) => setUserExpanded((previous) => ({ ...previous, [group.id]: expanded }))}
        onToggleModel={(modelID) => {
          setAddManualHint(false);
          setSelected((previous) => {
            const next = new Set(previous);
            if (next.has(modelID)) next.delete(modelID);
            else next.add(modelID);
            return next;
          });
        }}
        onSelectGroup={(group) => {
          setAddManualHint(false);
          setSelected((previous) => relayStepTwoSelectGroup(previous, group));
        }}
        protocolOf={(modelID) => relayModelProtocol(modelID, detection?.endpointTypes ?? {})}
        keyChips={keyChips}
        onAddManual={(raw) => {
          // Duplicate detection uses the same criterion as the enabled state at save (trimmed, case-insensitive, dates not folded); a model that is added or already in the list is checked.
          const result = relayStepTwoAddManual({ catalogModels: detection?.catalogModels ?? [], manualIDs }, raw);
          if (result.kind === 'ignored') return;
          if (result.kind === 'added') setManualIDs((previous) => [...previous, result.modelID]);
          setSelected((previous) => new Set(previous).add(result.modelID));
          setAddManualHint(result.kind === 'existing');
        }}
        onOpenAddManual={() => setAddManualHint(false)}
        addManualHint={addManualHint}
        saving={saving}
        saveFailure={saveFailure}
        onSave={() => { void saveTwoStep(); }}
        onBack={() => {
          setSaveFailure(null);
          goToStep(1);
        }}
      />
    );
  }

  return (
    <RelaySetupStepOne
      endpoint={endpoint}
      onEndpointChange={changeEndpoint}
      endpointNormalizationVersion={endpointNormalizationVersion}
      keys={keys}
      onKeyChange={changeKey}
      onAddKey={addKey}
      onRemoveKey={removeKey}
      errors={errors}
      showKey={showKey}
      onToggleKey={() => setShowKey((visible) => !visible)}
      detection={detection}
      isDetecting={connection.phase === 'detecting'}
      primaryEnabled={stepOnePrimary.enabled}
      onPrimary={() => {
        if (stepOnePrimary.action === 'advance') goToStep(2);
        else void runStepOne();
      }}
      onCancelDetection={invalidateDiscovery}
      onToggleManual={toggleManual}
    />
  );
}

/** Uses the same errorSnippet plus relay credential list as the upstream diagnostics in probe-runner; never surfaces Error.message directly. */
export function relayFailureDiagnostic(
  error: unknown,
  apiKey: string,
  headers: RelayRequestedConfig['headers'],
  queryParams: RelayRequestedConfig['queryParams'],
): string | undefined {
  const message = error instanceof Error ? error.message : String(error);
  return extractErrorSnippet(JSON.stringify({ error: message }), 1_000, relaySensitiveCredentialValues({
    apiKey,
    headers,
    queryParams,
  }));
}

function newRelayKeyID(): string {
  return globalThis.crypto.randomUUID().toLowerCase();
}
